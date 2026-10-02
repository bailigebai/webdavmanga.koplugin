local Errors = require("webdavmanga.errors")
local Formats = require("webdavmanga.image_formats")
local NaturalSort = require("webdavmanga.natural_sort")
local Path = require("webdavmanga.path")
local StrictInteger = require("webdavmanga.strict_integer")
local ManifestPosix = require("webdavmanga.manifest_posix")

local M = {}

local COUNT_WIDTH = 10
local OFFSET_WIDTH = 16
local DIGEST_WIDTH = 32
local ORDINAL_ROW_BYTES = 17
local PATH_ROW_BYTES = 42
local PATH_RUN_PREFIX_BYTES = 50
local DIGEST_CHUNK_BYTES = 4096
local MAX_RECORD_BYTES = 256 * 1024
local DEFAULT_RUN_SIZE = 128
local LOCK_SUFFIX = ".wdm-lock"
local LOCK_MAGIC = "WDMLOCK1\t"
local NIL_FIELD = "ffffffff"
local ZERO_DIGEST = string.rep("0", DIGEST_WIDTH)
local MAX_SAFE_INTEGER = StrictInteger.MAX_SAFE
local parse_safe_integer = StrictInteger.parse
local normalize_nonnegative_integer = StrictInteger.normalize

local function safe_add(left, right)
    if left == nil or right == nil or left > MAX_SAFE_INTEGER - right then return nil end
    return left + right
end

local function safe_multiply(left, right)
    if left == nil or right == nil or (right ~= 0
        and left > math.floor(MAX_SAFE_INTEGER / right)) then
        return nil
    end
    return left * right
end

local function header_prefix(count, folders, images, documents, records, ordinals, paths)
    return ("WDMANIFEST4\ncount=%010d\nfolders=%010d\nimages=%010d\n"
        .. "documents=%010d\nrecords=%016x\nordinals=%016x\npaths=%016x\n")
        :format(count, folders, images, documents or 0, records, ordinals, paths)
end

local function legacy_header_prefix(count, folders, images, records, ordinals, paths)
    return ("WDMANIFEST3\ncount=%010d\nfolders=%010d\nimages=%010d\n"
        .. "records=%016x\nordinals=%016x\npaths=%016x\n")
        :format(count, folders, images, records, ordinals, paths)
end

local function manifest_header(count, folders, images, documents, records, ordinals, paths, digest)
    return header_prefix(count, folders, images, documents, records, ordinals, paths)
        .. "digest=" .. digest .. "\n\n"
end

local function prefix_for_header(header)
    if header.version == 3 then
        return legacy_header_prefix(header.count, header.folders, header.images,
            header.records, header.ordinals, header.paths)
    end
    return header_prefix(header.count, header.folders, header.images,
        header.documents, header.records, header.ordinals, header.paths)
end

local HEADER_SIZE = #manifest_header(0, 0, 0, 0, 0, 0, 0, ZERO_DIGEST)
local LEGACY_HEADER_SIZE = #(("WDMANIFEST3\ncount=%010d\nfolders=%010d\nimages=%010d\n"
    .. "records=%016x\nordinals=%016x\npaths=%016x\n"
    .. "digest=%s\n\n")
    :format(0, 0, 0, 0, 0, 0, ZERO_DIGEST))

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function default_size(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local size = handle:seek("end")
    handle:close()
    return size
end

local DEFAULT_FS = {
    open = function(path, mode) return io.open(path, mode) end,
    remove = function(path) return os.remove(path) end,
    size = default_size,
}

-- On KOReader/Linux this is a descriptor-backed O_EXCL/fsync/rename adapter.
-- Other runtimes deliberately have no publication defaults and must inject an
-- explicit storage contract rather than silently degrading to stdio races.
local PRODUCTION_FS = ManifestPosix.new()

local function filesystem(dependencies, custom_build_fs)
    dependencies = dependencies or {}
    local base = custom_build_fs and {} or (PRODUCTION_FS or DEFAULT_FS)
    return {
        open = dependencies.open or dependencies.open_file
            or base.open or DEFAULT_FS.open,
        open_existing = dependencies.open_existing or base.open_existing,
        open_exclusive = dependencies.open_exclusive or base.open_exclusive,
        remove = dependencies.remove or dependencies.remove_file
            or base.remove or DEFAULT_FS.remove,
        atomic_replace = dependencies.atomic_replace or base.atomic_replace,
        release_lock = dependencies.release_lock or base.release_lock,
        size = dependencies.size or dependencies.file_size
            or base.size or DEFAULT_FS.size,
        sync = dependencies.sync or dependencies.fsync or base.sync,
    }
end

local function is_hex(value, width)
    return type(value) == "string" and #value == width
        and value:match("^[0-9a-fA-F]+$") ~= nil
end

local function hash_value(md5, value)
    local called, digest = pcall(md5, value)
    if not called or not is_hex(digest, DIGEST_WIDTH) then
        return nil, Errors.decode("invalid MD5 provider result")
    end
    return digest:lower()
end

local function storage_error(detail)
    if type(detail) == "table" and detail.code then return detail end
    return Errors.storage(tostring(detail or "manifest storage failure"))
end

local function decode_error(detail)
    if type(detail) == "table" and detail.code then return detail end
    return Errors.decode(tostring(detail or "invalid manifest"))
end

local function seek_file(handle, whence, offset)
    local called, position, detail
    if whence == nil then
        called, position, detail = pcall(handle.seek, handle)
    else
        called, position, detail = pcall(handle.seek, handle, whence, offset)
    end
    if not called then return nil, storage_error(position) end
    if position == nil then return nil, storage_error(detail or "file seek failed") end
    local safe_position = normalize_nonnegative_integer(position)
    if safe_position == nil then return nil, storage_error("unsafe file offset") end
    return safe_position
end

local function safe_close(handle)
    if not handle then return true end
    local called, result, detail = pcall(handle.close, handle)
    if not called then return nil, tostring(result) end
    if result == nil then return nil, tostring(detail or "close failed") end
    return true
end

local function read_some(handle, count)
    local called, value, detail = pcall(handle.read, handle, count)
    if not called then return nil, storage_error(value) end
    if value == nil then
        if detail ~= nil then return nil, storage_error(detail) end
        return nil, "eof"
    end
    if type(value) ~= "string" or #value == 0 or #value > count then
        return nil, storage_error("invalid file read result")
    end
    return value
end

local function read_exact(handle, count)
    if count == 0 then return "" end
    local chunks = {}
    local received = 0
    while received < count do
        local wanted = math.min(DIGEST_CHUNK_BYTES, count - received)
        local value, err = read_some(handle, wanted)
        if not value then return nil, err, received > 0 end
        chunks[#chunks + 1] = value
        received = received + #value
    end
    return table.concat(chunks)
end

local function encode_field(value)
    if value == nil then return NIL_FIELD end
    value = tostring(value)
    return ("%08x"):format(#value) .. value
end

local function decode_field(payload, position)
    local length_text = payload:sub(position, position + 7)
    if #length_text ~= 8 or not is_hex(length_text, 8) then
        return nil, nil, "invalid record field length"
    end
    position = position + 8
    if length_text:lower() == NIL_FIELD then return nil, position end
    local length = parse_safe_integer(length_text, 16, 8)
    if not length or length > MAX_RECORD_BYTES
        or position + length - 1 > #payload then
        return nil, nil, "record field exceeds payload"
    end
    local value = payload:sub(position, position + length - 1)
    return value, position + length
end

local function encode_record(record)
    local size_text
    if record.size ~= nil then
        local _size
        _size, size_text = normalize_nonnegative_integer(record.size)
        if _size == nil then return nil, Errors.decode("invalid manifest size") end
    end
    local payload = record.kind
        .. encode_field(record.path)
        .. encode_field(record.name)
        .. encode_field(size_text)
        .. encode_field(record.modified)
        .. encode_field(record.etag)
    if #payload > MAX_RECORD_BYTES then
        return nil, Errors.decode("manifest record exceeds 256 KiB")
    end
    return ("%08x"):format(#payload) .. payload
end

local function decode_record_payload(payload)
    local kind = payload:sub(1, 1)
    if kind ~= "F" and kind ~= "I" and kind ~= "D" then
        return nil, "invalid manifest record kind"
    end
    local position = 2
    local path, next_position, err = decode_field(payload, position)
    if err then return nil, err end
    position = next_position
    local name
    name, next_position, err = decode_field(payload, position)
    if err then return nil, err end
    position = next_position
    local size_text
    size_text, next_position, err = decode_field(payload, position)
    if err then return nil, err end
    position = next_position
    local modified
    modified, next_position, err = decode_field(payload, position)
    if err then return nil, err end
    position = next_position
    local etag
    etag, next_position, err = decode_field(payload, position)
    if err then return nil, err end
    if next_position ~= #payload + 1 or path == nil or name == nil then
        return nil, "invalid manifest record payload"
    end
    local size = size_text ~= nil and parse_safe_integer(size_text, 10) or nil
    if size_text ~= nil and size == nil then return nil, "invalid manifest size" end
    return {
        kind = kind,
        path = path,
        name = name,
        size = size,
        modified = modified,
        etag = etag,
        is_folder = kind == "F" and true or nil,
        is_file = (kind == "I" or kind == "D") and true or nil,
        file_kind = kind == "D" and "document" or kind == "I" and "image" or nil,
    }
end

local function read_record(handle)
    local length_text, length_error, partial_length = read_exact(handle, 8)
    if not length_text then
        if type(length_error) == "table" then return nil, nil, length_error end
        if length_error == "eof" and not partial_length then return nil, nil, "eof" end
        return nil, nil, "truncated manifest record length"
    end
    if not is_hex(length_text, 8) then
        return nil, nil, "invalid manifest record length"
    end
    local length = parse_safe_integer(length_text, 16, 8)
    if not length or length < 1 or length > MAX_RECORD_BYTES then
        return nil, nil, "manifest record length out of range"
    end
    local payload, payload_error = read_exact(handle, length)
    if not payload then
        if type(payload_error) == "table" then return nil, nil, payload_error end
        return nil, nil, "truncated manifest record"
    end
    local record, err = decode_record_payload(payload)
    if not record then return nil, nil, err end
    return record, 8 + length
end

local function has_dot_segment(path)
    path = tostring(path or ""):gsub("\\", "/")
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return true end
    end
    return false
end

local function safe_path(value)
    if type(value) ~= "string" or value:find("\0", 1, true)
        or has_dot_segment(value) then
        return nil
    end
    return Path.normalize_remote(value)
end

local function anchor_candidate(full_path, requested)
    if requested == "" then return full_path end
    local best
    local start_at = 1
    while true do
        local first, last = full_path:find(requested, start_at, true)
        if not first then break end
        local following = full_path:sub(last + 1, last + 1)
        if following == "" or following == "/" then
            local candidate = full_path:sub(1, last)
            if not best or #candidate < #best then best = candidate end
        end
        start_at = first + 1
    end
    return best
end

local function exact_anchor_candidate(full_path, requested, kind)
    if kind ~= "F" then return nil end
    if requested == "" then return full_path end
    if #full_path < #requested
        or full_path:sub(#full_path - #requested + 1) ~= requested then
        return nil
    end
    local prefix_end = #full_path - #requested
    if prefix_end > 0 and requested:sub(1, 1) ~= "/"
        and full_path:sub(prefix_end, prefix_end) ~= "/" then
        return nil
    end
    return full_path
end

local function prefer_anchor(current, candidate)
    return candidate and (not current or #candidate < #current
        or (#candidate == #current and candidate < current))
end

local function record_less(left, right)
    if left.kind ~= right.kind then
        local rank = { F = 1, I = 2, D = 3 }
        return (rank[left.kind] or 99) < (rank[right.kind] or 99)
    end
    if NaturalSort.less(left, right, function(item) return item.name end) then return true end
    if NaturalSort.less(right, left, function(item) return item.name end) then return false end
    return left.path < right.path
end

local function path_row_less(left, right)
    if left.hash ~= right.hash then return left.hash < right.hash end
    if left.path ~= right.path then return left.path < right.path end
    return left.ordinal < right.ordinal
end

local function build_nonce(value)
    if value ~= nil then
        value = tostring(value)
        if #value < 1 or #value > 64 or not value:match("^[%w_.%-]+$") then
            return nil
        end
        return value
    end
    local identity = tostring({}):gsub("[^%w]", "")
    return ("%x-%x-%s"):format(os.time(),
        math.floor((os.clock() * 1000000) % 0x7fffffff), identity)
end

local function new_context(options)
    local fs = filesystem(options.fs, options.fs ~= nil)
    return {
        fs = fs,
        md5 = options.md5 or default_md5,
        part_path = options.part_path,
        nonce = build_nonce(options.nonce),
        open_handles = {},
        reserved_handles = {},
        temp_paths = {},
        serial = 0,
        owned_count = 0,
        open_count = 0,
        active_runs = 0,
        merge_sources = 0,
        batch_entries = 0,
        stats = {
            max_owned_temps = 0,
            max_active_runs = 0,
            max_merge_sources = 0,
            max_auxiliary_entries = 0,
        },
        lock = nil,
    }
end

local function observe_auxiliary(context)
    local stats = context.stats
    if context.owned_count > stats.max_owned_temps then
        stats.max_owned_temps = context.owned_count
    end
    if context.active_runs > stats.max_active_runs then
        stats.max_active_runs = context.active_runs
    end
    if context.merge_sources > stats.max_merge_sources then
        stats.max_merge_sources = context.merge_sources
    end
    local total = context.owned_count + context.open_count
        + context.active_runs + context.merge_sources + context.batch_entries
    if total > stats.max_auxiliary_entries then
        stats.max_auxiliary_entries = total
    end
end

local function abort(error_value)
    error({ manifest_abort = true, error = error_value }, 0)
end

local function must_open(context, path, mode)
    local reserved = context.reserved_handles[path]
    if reserved then
        if reserved.mode ~= mode then
            abort(storage_error("exclusive temporary mode changed"))
        end
        context.reserved_handles[path] = nil
        return reserved.handle
    end
    local handle, err = context.fs.open(path, mode)
    if not handle then abort(storage_error(err or ("cannot open " .. tostring(path)))) end
    context.open_handles[handle] = true
    context.open_count = context.open_count + 1
    observe_auxiliary(context)
    return handle
end

local function must_close(context, handle)
    if not context.open_handles[handle] then return end
    local ok, err = safe_close(handle)
    if not ok then abort(storage_error(err)) end
    context.open_handles[handle] = nil
    context.open_count = context.open_count - 1
end

local function write_data(handle, value)
    local called, result, detail = pcall(handle.write, handle, value)
    if not called then return nil, storage_error(result) end
    if result == nil then return nil, storage_error(detail) end
    return true
end

local function must_write(handle, value)
    local ok, err = write_data(handle, value)
    if not ok then abort(err) end
end

local function call_open_exclusive(context, path, mode)
    if type(context.fs.open_exclusive) ~= "function" then
        return nil, storage_error("atomic exclusive file creation is unavailable")
    end
    local called, handle, detail = pcall(
        context.fs.open_exclusive, path, mode)
    if not called then return nil, storage_error(handle) end
    if not handle then
        return nil, storage_error(detail or "exclusive file creation failed")
    end
    return handle
end

local function flush_handle(handle)
    local called, result, detail = pcall(handle.flush, handle)
    if not called then return nil, storage_error(result) end
    if result == nil then return nil, storage_error(detail or "file flush failed") end
    return true
end

local function lock_payload(context)
    return LOCK_MAGIC .. context.nonce .. "\n"
end

local function close_lock_handle(context, lock)
    if not lock.handle then return true end
    local closed, close_error = safe_close(lock.handle)
    lock.handle = nil
    context.open_count = context.open_count - 1
    if not closed then return nil, storage_error(close_error) end
    return true
end

local function verify_lock_handle(lock, handle)
    local positioned, position_error = seek_file(handle, "set", 0)
    if not positioned then return nil, position_error end
    local content, read_error = read_exact(handle, #lock.payload)
    if not content then
        return nil, storage_error(type(read_error) == "table"
            and read_error or "manifest lock is truncated")
    end
    local extra, extra_error = read_some(handle, 1)
    if extra ~= nil or extra_error ~= "eof" or content ~= lock.payload then
        if type(extra_error) == "table" then return nil, extra_error end
        return nil, storage_error("manifest lock ownership changed")
    end
    return true
end

local function acquire_build_lock(context)
    local path = context.part_path .. LOCK_SUFFIX
    local handle, open_error = call_open_exclusive(context, path, "wb+")
    if not handle then abort(open_error) end
    local lock = {
        path = path,
        payload = lock_payload(context),
        handle = handle,
    }
    context.lock = lock
    context.owned_count = context.owned_count + 1
    context.open_count = context.open_count + 1
    observe_auxiliary(context)
    local written, write_error = write_data(handle, lock.payload)
    if not written then abort(write_error) end
    local flushed, flush_error = flush_handle(handle)
    if not flushed then abort(flush_error) end
    local verified, verify_error = verify_lock_handle(lock, handle)
    if not verified then abort(verify_error) end
    return true
end

local function clear_lock_ownership(context)
    context.lock = nil
    context.owned_count = context.owned_count - 1
end

local function release_build_lock(context)
    local lock = context.lock
    if not lock then return true end
    if not lock.handle then
        return nil, storage_error("manifest lock owner handle is unavailable")
    end
    local verified, verify_error = verify_lock_handle(lock, lock.handle)
    if not verified then
        close_lock_handle(context, lock)
        return nil, verify_error
    end
    local called, released, release_error, handle_closed = pcall(
        context.fs.release_lock, lock)
    if handle_closed == true and lock.handle then
        lock.handle = nil
        context.open_count = context.open_count - 1
    end
    if not called or not released then
        local detail = called and release_error or released
        if lock.handle then close_lock_handle(context, lock) end
        return nil, storage_error(detail or "owner-safe lock release failed")
    end
    local closed, close_error = close_lock_handle(context, lock)
    clear_lock_ownership(context)
    if not closed then return nil, close_error end
    return true
end

local function temp_path(context, label, mode)
    mode = mode or "wb"
    context.serial = context.serial + 1
    local path = context.part_path .. ".wdm-" .. context.nonce
        .. "-" .. context.serial .. "-" .. label
    local reservation, reservation_error = call_open_exclusive(context, path, mode)
    if not reservation then
        abort(reservation_error)
    end
    context.temp_paths[path] = true
    context.owned_count = context.owned_count + 1
    observe_auxiliary(context)
    context.open_handles[reservation] = true
    context.open_count = context.open_count + 1
    observe_auxiliary(context)
    context.reserved_handles[path] = { handle = reservation, mode = mode }
    return path
end

local function must_remove_temp(context, path)
    if not context.temp_paths[path] then return end
    local removed, err = context.fs.remove(path)
    if not removed then abort(storage_error(err or "cannot remove manifest temporary file")) end
    context.temp_paths[path] = nil
    context.owned_count = context.owned_count - 1
end

local function close_all(context)
    for handle in pairs(context.open_handles) do
        pcall(handle.close, handle)
        context.open_handles[handle] = nil
        context.open_count = context.open_count - 1
    end
    context.reserved_handles = {}
end

local function cleanup_paths(context)
    for path in pairs(context.temp_paths) do
        pcall(context.fs.remove, path)
        context.temp_paths[path] = nil
        context.owned_count = context.owned_count - 1
    end
end

local function flush_record_run(context, records)
    table.sort(records, record_less)
    local path = temp_path(context, "records-run")
    local handle = must_open(context, path, "wb")
    for _, record in ipairs(records) do
        local encoded, err = encode_record(record)
        if not encoded then abort(err) end
        must_write(handle, encoded)
    end
    must_close(context, handle)
    return path
end

local function merge_record_group(context, inputs)
    local output_path = temp_path(context, "records-merge")
    local output = must_open(context, output_path, "wb")
    local sources = {}
    context.merge_sources = #inputs
    observe_auxiliary(context)
    for _, path in ipairs(inputs) do
        local handle = must_open(context, path, "rb")
        local record, _bytes, err = read_record(handle)
        if not record and err ~= "eof" then abort(decode_error(err)) end
        sources[#sources + 1] = { handle = handle, record = record }
    end
    while true do
        local selected
        for index, source in ipairs(sources) do
            if source.record and (not selected
                or record_less(source.record, sources[selected].record)) then
                selected = index
            end
        end
        if not selected then break end
        local encoded, encode_error = encode_record(sources[selected].record)
        if not encoded then abort(encode_error) end
        must_write(output, encoded)
        local next_record, _bytes, read_error = read_record(sources[selected].handle)
        if not next_record and read_error ~= "eof" then abort(decode_error(read_error)) end
        sources[selected].record = next_record
    end
    for _, source in ipairs(sources) do must_close(context, source.handle) end
    context.merge_sources = 0
    must_close(context, output)
    for _, path in ipairs(inputs) do must_remove_temp(context, path) end
    return output_path
end

local function flush_path_run(context, rows)
    table.sort(rows, path_row_less)
    local path = temp_path(context, "paths-run")
    local handle = must_open(context, path, "wb")
    for _, row in ipairs(rows) do
        must_write(handle, ("%s\t%08x\t%08x"):format(
            row.hash, row.ordinal, #row.path) .. row.path)
    end
    must_close(context, handle)
    return path
end

local function read_path_run_row(handle)
    local prefix, prefix_error, partial_prefix = read_exact(
        handle, PATH_RUN_PREFIX_BYTES)
    if not prefix then
        if type(prefix_error) == "table" then return nil, prefix_error end
        if prefix_error == "eof" and not partial_prefix then return nil, "eof" end
        return nil, "truncated path run prefix"
    end
    if prefix:sub(33, 33) ~= "\t"
        or prefix:sub(42, 42) ~= "\t" then
        return nil, "invalid path run row"
    end
    local hash = prefix:sub(1, 32)
    local ordinal_text = prefix:sub(34, 41)
    local length_text = prefix:sub(43, 50)
    if not is_hex(hash, 32) or not is_hex(ordinal_text, 8)
        or not is_hex(length_text, 8) then
        return nil, "invalid path run row"
    end
    local length = parse_safe_integer(length_text, 16, 8)
    if not length or length > MAX_RECORD_BYTES then
        return nil, "path run row exceeds limit"
    end
    local path, path_error = read_exact(handle, length)
    if not path then
        if type(path_error) == "table" then return nil, path_error end
        return nil, "truncated path run row"
    end
    return {
        hash = hash:lower(),
        ordinal = parse_safe_integer(ordinal_text, 16, 8),
        path = path,
    }
end

local function read_path_row(handle)
    local raw, raw_error, partial_raw = read_exact(handle, PATH_ROW_BYTES)
    if not raw then
        if type(raw_error) == "table" then return nil, raw_error end
        if raw_error == "eof" and not partial_raw then return nil, "eof" end
        return nil, "truncated path index row"
    end
    if raw:sub(33, 33) ~= "\t"
        or raw:sub(42, 42) ~= "\n" then
        return nil, "invalid path index row"
    end
    local hash = raw:sub(1, 32)
    local ordinal_text = raw:sub(34, 41)
    if not is_hex(hash, 32) or not is_hex(ordinal_text, 8) then
        return nil, "invalid path index row"
    end
    return {
        hash = hash:lower(),
        ordinal = parse_safe_integer(ordinal_text, 16, 8),
    }
end

local function merge_path_group(context, inputs)
    local output_path = temp_path(context, "paths-merge")
    local output = must_open(context, output_path, "wb")
    local sources = {}
    context.merge_sources = #inputs
    observe_auxiliary(context)
    for _, path in ipairs(inputs) do
        local handle = must_open(context, path, "rb")
        local row, err = read_path_run_row(handle)
        if not row and err ~= "eof" then abort(decode_error(err)) end
        sources[#sources + 1] = { handle = handle, row = row }
    end
    while true do
        local selected
        for index, source in ipairs(sources) do
            if source.row and (not selected
                or path_row_less(source.row, sources[selected].row)) then
                selected = index
            end
        end
        if not selected then break end
        local row = sources[selected].row
        must_write(output, ("%s\t%08x\t%08x"):format(
            row.hash, row.ordinal, #row.path) .. row.path)
        local next_row, read_error = read_path_run_row(sources[selected].handle)
        if not next_row and read_error ~= "eof" then abort(decode_error(read_error)) end
        sources[selected].row = next_row
    end
    for _, source in ipairs(sources) do must_close(context, source.handle) end
    context.merge_sources = 0
    must_close(context, output)
    for _, path in ipairs(inputs) do must_remove_temp(context, path) end
    return output_path
end

local function new_run_accumulator(context, merge_group)
    local accumulator = {
        levels = {},
        max_level = 0,
        active = 0,
    }

    local function set_active(value)
        accumulator.active = value
        context.active_runs = value
        observe_auxiliary(context)
    end

    function accumulator:add(run)
        local level = 1
        while self.levels[level] do
            local previous = self.levels[level]
            self.levels[level] = nil
            set_active(self.active - 1)
            run = merge_group(context, { previous, run })
            level = level + 1
        end
        self.levels[level] = run
        if level > self.max_level then self.max_level = level end
        set_active(self.active + 1)
    end

    function accumulator:finish()
        local result
        for level = 1, self.max_level do
            local run = self.levels[level]
            if run then
                self.levels[level] = nil
                set_active(self.active - 1)
                if result then
                    result = merge_group(context, { result, run })
                else
                    result = run
                end
            end
        end
        context.active_runs = 0
        observe_auxiliary(context)
        return result
    end

    return accumulator
end

local function copy_file(context, source_path, destination, expected_bytes)
    local source = must_open(context, source_path, "rb")
    local copied = 0
    while copied < expected_bytes do
        local chunk, read_error = read_some(source,
            math.min(DIGEST_CHUNK_BYTES, expected_bytes - copied))
        if not chunk then
            if read_error ~= "eof" then abort(read_error) end
            abort(Errors.decode("temporary file ended before expected section size"))
        end
        must_write(destination, chunk)
        copied = copied + #chunk
    end
    local extra, extra_error = read_some(source, 1)
    if extra then abort(Errors.decode("temporary file exceeds expected section size")) end
    if extra_error ~= "eof" then abort(extra_error) end
    must_close(context, source)
    return copied
end

local function chained_digest(handle, md5, prefix, data_offset, file_size)
    local digest, err = hash_value(md5, ZERO_DIGEST .. prefix)
    if not digest then return nil, err end
    local position, seek_error = seek_file(handle, "set", data_offset)
    if not position then return nil, seek_error end
    local remaining = file_size - data_offset
    while remaining > 0 do
        local wanted = math.min(DIGEST_CHUNK_BYTES, remaining)
        local chunk, read_error = read_exact(handle, wanted)
        if not chunk then
            if type(read_error) == "table" then return nil, read_error end
            return nil, Errors.decode("truncated manifest while hashing")
        end
        digest, err = hash_value(md5, digest .. chunk)
        if not digest then return nil, err end
        remaining = remaining - #chunk
    end
    return digest
end

local function build_impl(context, options, emit_chunks)
    if options.request_path ~= nil and type(options.request_path) ~= "string" then
        abort(Errors.invalid_path())
    end
    local requested = safe_path(options.request_path or "")
    if requested == nil then abort(Errors.invalid_path()) end
    local run_size = options.run_size == nil and DEFAULT_RUN_SIZE
        or normalize_nonnegative_integer(options.run_size)
    if not run_size or run_size < 1 then
        abort(Errors.decode("run_size must be a positive integer"))
    end
    run_size = math.min(run_size, 65535)

    for capability, detail in pairs({
        open_exclusive = "atomic exclusive file creation is unavailable",
        open_existing = "reliable existing-target inspection is unavailable",
        atomic_replace = "atomic manifest replacement is unavailable",
        sync = "reliable manifest fsync is unavailable",
        release_lock = "owner-safe lock release is unavailable",
    }) do
        if type(context.fs[capability]) ~= "function" then
            abort(Errors.storage(detail))
        end
    end

    acquire_build_lock(context)

    local existing_called, existing_target, existing_open_error, target_absent = pcall(
        context.fs.open_existing, context.part_path)
    if not existing_called then abort(storage_error(existing_target)) end
    if existing_target then
        local existing_closed, existing_close_error = safe_close(existing_target)
        if not existing_closed then abort(storage_error(existing_close_error)) end
        local existing_manifest = M.open(context.part_path, {
            open = context.fs.open,
            size = context.fs.size,
            md5 = context.md5,
        })
        if not existing_manifest then
            abort(Errors.storage("manifest part_path contains invalid existing data"))
        end
        local validation_closed, validation_close_error = existing_manifest:close()
        if not validation_closed then abort(storage_error(validation_close_error)) end
    elseif target_absent ~= true then
        abort(storage_error(existing_open_error
            or "cannot determine whether manifest target exists"))
    end
    local build_path = temp_path(context, "building", "wb+")
    local spool_path = temp_path(context, "spool")
    local spool = must_open(context, spool_path, "wb")
    local exact_anchor
    local fallback_anchor
    local producer_failed
    local spooled_count = 0

    local function emit(record)
        if producer_failed then return nil, producer_failed end
        if type(record) ~= "table" then
            producer_failed = Errors.decode("manifest input record must be a table")
            return nil, producer_failed
        end
        local full_path = safe_path(record.full_path)
        if full_path == nil then
            producer_failed = Errors.invalid_path()
            return nil, producer_failed
        end
        local kind
        if record.is_folder and not record.is_file then
            kind = "F"
        elseif record.is_file and not record.is_folder then
            local document = record.file_kind == "document"
                or record.is_document == true
                or Formats.is_document(full_path)
            -- Keep every direct file visible in the directory index. Known
            -- documents use D; unknown extensions also use D so entering a
            -- folder never depends on the file suffix. The document bridge
            -- will provide a precise unsupported-format error on activation.
            kind = document and "D"
                or (not Formats.is_image(full_path) and "D" or "I")
        end
        if not kind then
            producer_failed = Errors.decode("manifest input record has invalid kind")
            return nil, producer_failed
        end
        local exact = exact_anchor_candidate(full_path, requested, kind)
        if prefer_anchor(exact_anchor, exact) then exact_anchor = exact end
        local fallback = anchor_candidate(full_path, requested)
        if prefer_anchor(fallback_anchor, fallback) then fallback_anchor = fallback end
        local encoded, encode_error = encode_record({
            kind = kind,
            path = full_path,
            name = tostring(record.name or full_path:match("([^/]+)$") or ""),
            size = record.size,
            modified = record.modified,
            etag = record.etag,
        })
        if not encoded then
            producer_failed = encode_error
            return nil, encode_error
        end
        local written, write_error = write_data(spool, encoded)
        if not written then
            producer_failed = write_error
            return nil, write_error
        end
        spooled_count = spooled_count + 1
        return true
    end

    local called, producer_ok, producer_error = xpcall(function()
        return emit_chunks(emit)
    end, function(error_value) return error_value end)
    must_close(context, spool)
    if not called then abort(Errors.decode("manifest input producer failed")) end
    if not producer_ok then abort(producer_error or producer_failed
        or Errors.decode("manifest input producer failed")) end
    if producer_failed then abort(producer_failed) end
    local anchor = exact_anchor or fallback_anchor or requested

    local record_runs = new_run_accumulator(context, merge_record_group)
    local batch = {}
    local maximum_run_entries = 0
    local folders, images, documents = 0, 0, 0
    local spool_reader = must_open(context, spool_path, "rb")
    local child_prefix = anchor == "" and "/" or anchor .. "/"
    local spool_read_count = 0
    while true do
        local raw_record, _bytes, read_error = read_record(spool_reader)
        if not raw_record then
            if read_error ~= "eof" then abort(decode_error(read_error)) end
            break
        end
        spool_read_count = spool_read_count + 1
        local full_path = raw_record.path
        if full_path ~= anchor
            and full_path:sub(1, #child_prefix) == child_prefix then
            local relative = full_path:sub(#child_prefix + 1)
            local accepted = raw_record.kind == "F"
                or (raw_record.kind == "I" and Formats.is_image(relative))
                or raw_record.kind == "D"
            if relative ~= "" and not relative:find("/", 1, true) and accepted then
                local record = {
                    kind = raw_record.kind,
                    path = Path.join_remote(requested, relative),
                    name = relative,
                    size = raw_record.size,
                    modified = raw_record.modified,
                    etag = raw_record.etag,
                }
                batch[#batch + 1] = record
                context.batch_entries = #batch
                observe_auxiliary(context)
                if record.kind == "F" then
                    folders = folders + 1
                elseif record.kind == "D" then
                    documents = documents + 1
                else
                    images = images + 1
                end
                if #batch > maximum_run_entries then maximum_run_entries = #batch end
                if #batch == run_size then
                    record_runs:add(flush_record_run(context, batch))
                    batch = {}
                    context.batch_entries = 0
                end
            end
        end
    end
    if spool_read_count ~= spooled_count then
        abort(Errors.decode("manifest spool count changed while reading"))
    end
    must_close(context, spool_reader)
    must_remove_temp(context, spool_path)
    if #batch > 0 then record_runs:add(flush_record_run(context, batch)) end
    batch = nil
    context.batch_entries = 0
    local merged_records = record_runs:finish()
    local count = folders + images + documents

    local ordinal_path = temp_path(context, "ordinals")
    local ordinals = must_open(context, ordinal_path, "wb")
    local path_rows = {}
    local path_runs = new_run_accumulator(context, merge_path_group)
    local output = must_open(context, build_path, "wb+")
    must_write(output, manifest_header(count, folders, images, documents,
        HEADER_SIZE, 0, 0, ZERO_DIGEST))

    local merged_handle
    if merged_records then merged_handle = must_open(context, merged_records, "rb") end
    local ordinal = 0
    while merged_handle do
        local record, _bytes, read_error = read_record(merged_handle)
        if not record then
            if read_error ~= "eof" then abort(decode_error(read_error)) end
            break
        end
        ordinal = ordinal + 1
        if ordinal > 0xffffffff then abort(Errors.decode("manifest has too many entries")) end
        local offset, seek_error = seek_file(output)
        if not offset then abort(seek_error) end
        must_write(ordinals, ("%016x\n"):format(offset))
        local encoded, encode_error = encode_record(record)
        if not encoded then abort(encode_error) end
        must_write(output, encoded)
        local path_hash, hash_error = hash_value(context.md5, record.path)
        if not path_hash then abort(hash_error) end
        path_rows[#path_rows + 1] = {
            hash = path_hash,
            ordinal = ordinal,
            path = record.path,
        }
        context.batch_entries = #path_rows
        observe_auxiliary(context)
        if #path_rows == run_size then
            path_runs:add(flush_path_run(context, path_rows))
            path_rows = {}
            context.batch_entries = 0
        end
    end
    if merged_handle then must_close(context, merged_handle) end
    if merged_records then must_remove_temp(context, merged_records) end
    must_close(context, ordinals)
    if ordinal ~= count then abort(Errors.decode("manifest count changed during merge")) end
    if #path_rows > 0 then path_runs:add(flush_path_run(context, path_rows)) end
    path_rows = nil
    context.batch_entries = 0

    local ordinals_offset, seek_error = seek_file(output)
    if not ordinals_offset then abort(seek_error) end
    copy_file(context, ordinal_path, output, count * ORDINAL_ROW_BYTES)
    must_remove_temp(context, ordinal_path)
    local paths_offset
    paths_offset, seek_error = seek_file(output)
    if not paths_offset then abort(seek_error) end

    local merged_paths = path_runs:finish()
    if merged_paths then
        local paths_handle = must_open(context, merged_paths, "rb")
        local previous_path
        local path_count = 0
        while true do
            local row, row_error = read_path_run_row(paths_handle)
            if not row then
                if row_error ~= "eof" then abort(decode_error(row_error)) end
                break
            end
            if previous_path == row.path then
                abort(Errors.decode("duplicate normalized manifest path"))
            end
            previous_path = row.path
            path_count = path_count + 1
            must_write(output, ("%s\t%08x\n"):format(row.hash, row.ordinal))
        end
        must_close(context, paths_handle)
        if path_count ~= count then
            abort(Errors.decode("manifest path count changed during merge"))
        end
        must_remove_temp(context, merged_paths)
    end
    local final_size
    final_size, seek_error = seek_file(output)
    if not final_size then abort(seek_error) end
    if final_size ~= paths_offset + count * PATH_ROW_BYTES then
        abort(Errors.decode("manifest path section size changed while writing"))
    end
    local prefix = header_prefix(count, folders, images, documents,
        HEADER_SIZE, ordinals_offset, paths_offset)
    local positioned, position_error = seek_file(output, "set", 0)
    if not positioned then abort(position_error) end
    must_write(output, prefix .. "digest=" .. ZERO_DIGEST .. "\n\n")
    local flushed, flush_error = output:flush()
    if flushed == nil then abort(storage_error(flush_error)) end
    local digest, digest_error = chained_digest(output, context.md5, prefix,
        HEADER_SIZE, final_size)
    if not digest then abort(digest_error) end
    positioned, position_error = seek_file(output, "set", 0)
    if not positioned then abort(position_error) end
    must_write(output, prefix .. "digest=" .. digest .. "\n\n")
    local synced, sync_error = context.fs.sync(output, build_path)
    if not synced then abort(storage_error(sync_error)) end
    must_close(context, output)

    local built_size_called, raw_built_size, built_size_error = pcall(
        context.fs.size, build_path)
    if not built_size_called or raw_built_size == nil then
        abort(storage_error(built_size_called and built_size_error or raw_built_size))
    end
    local built_size = normalize_nonnegative_integer(raw_built_size)
    if built_size ~= final_size then
        abort(Errors.decode("closed manifest size changed before publication"))
    end
    local validated, validation_error = M.open(build_path, {
        open = context.fs.open,
        remove = context.fs.remove,
        size = context.fs.size,
        md5 = context.md5,
    })
    if not validated then abort(validation_error) end
    local validation_closed, validation_close_error = validated:close()
    if not validation_closed then abort(storage_error(validation_close_error)) end

    local replace_called, renamed, rename_error = pcall(
        context.fs.atomic_replace, build_path, context.part_path)
    if not replace_called then abort(storage_error(renamed)) end
    if not renamed then abort(storage_error(rename_error or "manifest rename failed")) end
    context.temp_paths[build_path] = nil
    context.owned_count = context.owned_count - 1
    local released, release_error = release_build_lock(context)
    if not released then abort(release_error) end
    return {
        part_path = context.part_path,
        size = final_size,
        count = count,
        folders = folders,
        images = images,
        documents = documents,
        digest = digest,
        max_run_entries = maximum_run_entries,
        max_active_runs = context.stats.max_active_runs,
        max_merge_sources = context.stats.max_merge_sources,
        max_owned_temps = context.stats.max_owned_temps,
        max_auxiliary_entries = context.stats.max_auxiliary_entries,
    }
end

function M.build(options, emit_chunks)
    options = options or {}
    if type(options.part_path) ~= "string" or options.part_path == ""
        or type(emit_chunks) ~= "function" then
        return nil, Errors.storage("part_path and emit_chunks are required")
    end
    local context = new_context(options)
    if not context.nonce then return nil, Errors.storage("invalid manifest nonce") end
    local called, result = xpcall(function()
        return build_impl(context, options, emit_chunks)
    end, function(error_value) return error_value end)
    close_all(context)
    if not called then
        cleanup_paths(context)
        pcall(release_build_lock, context)
        if type(result) == "table" and result.manifest_abort then
            return nil, result.error
        end
        return nil, Errors.storage("manifest build failed")
    end
    cleanup_paths(context)
    if context.lock then pcall(release_build_lock, context) end
    return result
end

local Manifest = {}
Manifest.__index = Manifest

function Manifest:close()
    if self.closed then return true end
    self.closed = true
    local ok, err = safe_close(self.handle)
    self.handle = nil
    return ok, err
end

function Manifest:_ordinal_offset(ordinal)
    if self.closed or type(ordinal) ~= "number" or ordinal < 1
        or ordinal > self.count or math.floor(ordinal) ~= ordinal then
        return nil
    end
    local index_position = self.ordinals_offset + (ordinal - 1) * ORDINAL_ROW_BYTES
    if not seek_file(self.handle, "set", index_position) then return nil end
    local row = read_exact(self.handle, ORDINAL_ROW_BYTES)
    if not row or row:sub(-1) ~= "\n" then return nil end
    local offset_text = row:sub(1, 16)
    if not is_hex(offset_text, 16) then return nil end
    return parse_safe_integer(offset_text, 16, 16)
end

function Manifest:_record_at(ordinal)
    local offset = self:_ordinal_offset(ordinal)
    if not offset or offset < self.records_offset or offset >= self.ordinals_offset then
        return nil
    end
    if not seek_file(self.handle, "set", offset) then return nil end
    local record = read_record(self.handle)
    return record
end

function Manifest:_path_row(index)
    if index < 1 or index > self.count then return nil end
    local position = self.paths_offset + (index - 1) * PATH_ROW_BYTES
    if not seek_file(self.handle, "set", position) then return nil end
    return read_path_row(self.handle)
end

function Manifest:_find_ordinal(path)
    if self.closed then return nil end
    local wanted_hash = hash_value(self.md5, path)
    if not wanted_hash then return nil end
    local low, high = 1, self.count
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local row = self:_path_row(middle)
        if not row then return nil end
        if row.hash < wanted_hash then low = middle + 1 else high = middle - 1 end
    end
    local index = low
    while index <= self.count do
        local row = self:_path_row(index)
        if not row or row.hash ~= wanted_hash then break end
        local record = self:_record_at(row.ordinal)
        if record and record.path == path then return row.ordinal end
        index = index + 1
    end
    return nil
end

local function parse_header(raw)
    if type(raw) ~= "string" then return nil end
    local ending = raw:find("\n\n", 1, true)
    if not ending then return nil end
    local header_size = ending + 1
    local header_text = raw:sub(1, header_size)
    local version = 4
    local count_text, folders_text, images_text, documents_text,
        records_text, ordinals_text, paths_text, digest = header_text:match(
        "^WDMANIFEST4\ncount=(%d+)\nfolders=(%d+)\nimages=(%d+)\n"
        .. "documents=(%d+)\nrecords=([0-9a-fA-F]+)\n"
        .. "ordinals=([0-9a-fA-F]+)\npaths=([0-9a-fA-F]+)\n"
        .. "digest=([0-9a-fA-F]+)\n\n$")
    if not count_text then
        version = 3
        count_text, folders_text, images_text,
            records_text, ordinals_text, paths_text, digest = header_text:match(
            "^WDMANIFEST3\ncount=(%d+)\nfolders=(%d+)\nimages=(%d+)\n"
            .. "records=([0-9a-fA-F]+)\nordinals=([0-9a-fA-F]+)\n"
            .. "paths=([0-9a-fA-F]+)\ndigest=([0-9a-fA-F]+)\n\n$")
        documents_text = string.rep("0", COUNT_WIDTH)
    end
    if not count_text or #count_text ~= COUNT_WIDTH
        or #folders_text ~= COUNT_WIDTH or #images_text ~= COUNT_WIDTH
        or #documents_text ~= COUNT_WIDTH
        or not is_hex(records_text, OFFSET_WIDTH)
        or not is_hex(ordinals_text, OFFSET_WIDTH)
        or not is_hex(paths_text, OFFSET_WIDTH)
        or not is_hex(digest, DIGEST_WIDTH) then
        return nil
    end
    local parsed = {
        version = version,
        header_size = header_size,
        count = parse_safe_integer(count_text, 10, COUNT_WIDTH),
        folders = parse_safe_integer(folders_text, 10, COUNT_WIDTH),
        images = parse_safe_integer(images_text, 10, COUNT_WIDTH),
        documents = parse_safe_integer(documents_text, 10, COUNT_WIDTH),
        records = parse_safe_integer(records_text, 16, OFFSET_WIDTH),
        ordinals = parse_safe_integer(ordinals_text, 16, OFFSET_WIDTH),
        paths = parse_safe_integer(paths_text, 16, OFFSET_WIDTH),
        digest = digest:lower(),
    }
    if parsed.count == nil or parsed.folders == nil or parsed.images == nil
        or parsed.documents == nil
        or parsed.records == nil or parsed.ordinals == nil or parsed.paths == nil then
        return nil
    end
    return parsed
end

local function open_fail(handle, detail)
    safe_close(handle)
    if type(detail) == "table" and detail.code then return nil, detail end
    return nil, Errors.decode(detail)
end

function M.open(path, dependencies)
    dependencies = dependencies or {}
    local fs = filesystem(dependencies)
    local md5 = dependencies.md5 or default_md5
    local handle, open_error = fs.open(path, "rb")
    if not handle then return nil, Errors.storage(open_error) end
    local called, raw_header, header_read_error = pcall(handle.read, handle, 512)
    if not called or type(raw_header) ~= "string" or #raw_header == 0 then
        return open_fail(handle, header_read_error or "truncated manifest header")
    end
    local header = parse_header(raw_header)
    if not header then return open_fail(handle, "invalid manifest header") end
    local size_called, raw_file_size, size_error = pcall(fs.size, path)
    if not size_called or raw_file_size == nil then
        safe_close(handle)
        return nil, storage_error(size_called and size_error or raw_file_size)
    end
    local file_size = normalize_nonnegative_integer(raw_file_size)
    local kind_total = safe_add(header.folders, header.images)
    kind_total = safe_add(kind_total, header.documents)
    local ordinal_bytes = safe_multiply(header.count, ORDINAL_ROW_BYTES)
    local expected_paths = safe_add(header.ordinals, ordinal_bytes)
    local path_bytes = safe_multiply(header.count, PATH_ROW_BYTES)
    local expected_size = safe_add(header.paths, path_bytes)
    if not file_size or file_size < header.header_size
        or header.records ~= header.header_size
        or kind_total ~= header.count
        or header.ordinals < header.records
        or expected_paths == nil or header.paths ~= expected_paths
        or expected_size == nil or file_size ~= expected_size then
        return open_fail(handle, "invalid manifest section bounds")
    end
    local prefix = prefix_for_header(header)
    local actual_digest, digest_error = chained_digest(handle, md5, prefix,
        header.records, file_size)
    if not actual_digest then
        safe_close(handle)
        return nil, digest_error
    end
    if actual_digest ~= header.digest then
        return open_fail(handle, "manifest digest mismatch")
    end

    local expected_record_offset = header.records
    for ordinal = 1, header.count do
        local index_position = header.ordinals + (ordinal - 1) * ORDINAL_ROW_BYTES
        local _position, ordinal_seek_error = seek_file(handle, "set", index_position)
        if not _position then
            return open_fail(handle, ordinal_seek_error)
        end
        local row, ordinal_read_error = read_exact(handle, ORDINAL_ROW_BYTES)
        if not row or row:sub(-1) ~= "\n" or not is_hex(row:sub(1, 16), 16) then
            return open_fail(handle, type(ordinal_read_error) == "table"
                and ordinal_read_error or "invalid manifest ordinal row")
        end
        local record_offset = parse_safe_integer(row:sub(1, 16), 16, 16)
        local record_position, record_seek_error
        if record_offset == expected_record_offset then
            record_position, record_seek_error = seek_file(handle, "set", record_offset)
        end
        if record_offset ~= expected_record_offset or not record_position then
            if record_seek_error then return open_fail(handle, record_seek_error) end
            return open_fail(handle, "invalid manifest record offset")
        end
        local record, bytes, record_error = read_record(handle)
        if not record then return open_fail(handle, record_error) end
        if record.path == "" or safe_path(record.path) ~= record.path
            or record.name ~= record.path:match("([^/]+)$") then
            return open_fail(handle, "manifest record path is not canonical")
        end
        local image_end = header.folders + header.images
        local expected_kind
        if ordinal <= header.folders then
            expected_kind = "F"
        elseif ordinal <= image_end then
            expected_kind = "I"
        else
            expected_kind = "D"
        end
        if record.kind ~= expected_kind then
            return open_fail(handle, "manifest kind counts do not match records")
        end
        expected_record_offset = expected_record_offset + bytes
    end
    if expected_record_offset ~= header.ordinals then
        return open_fail(handle, "manifest record section length mismatch")
    end
    local previous_hash
    local previous_path
    local previous_ordinal
    for index = 1, header.count do
        local _path_position, path_seek_error = seek_file(handle, "set",
            header.paths + (index - 1) * PATH_ROW_BYTES)
        if not _path_position then
            return open_fail(handle, path_seek_error)
        end
        local row, row_error = read_path_row(handle)
        if not row or row.ordinal < 1 or row.ordinal > header.count then
            return open_fail(handle, row_error or "invalid manifest path index")
        end
        local ordinal_position = header.ordinals
            + (row.ordinal - 1) * ORDINAL_ROW_BYTES
        local _ordinal_position, path_ordinal_seek_error = seek_file(
            handle, "set", ordinal_position)
        if not _ordinal_position then
            return open_fail(handle, path_ordinal_seek_error)
        end
        local ordinal_row, path_ordinal_read_error = read_exact(
            handle, ORDINAL_ROW_BYTES)
        if not ordinal_row or ordinal_row:sub(-1) ~= "\n"
            or not is_hex(ordinal_row:sub(1, 16), 16) then
            return open_fail(handle, type(path_ordinal_read_error) == "table"
                and path_ordinal_read_error or "invalid manifest path ordinal")
        end
        local record_offset = parse_safe_integer(ordinal_row:sub(1, 16), 16, 16)
        local _record_position, path_record_seek_error
        if record_offset then
            _record_position, path_record_seek_error = seek_file(
                handle, "set", record_offset)
        end
        if not record_offset or not _record_position then
            return open_fail(handle, path_record_seek_error
                or "invalid manifest path record seek")
        end
        local indexed_record, _bytes, indexed_error = read_record(handle)
        if not indexed_record then return open_fail(handle, indexed_error) end
        local expected_hash, expected_hash_error = hash_value(md5, indexed_record.path)
        if not expected_hash then
            safe_close(handle)
            return nil, expected_hash_error
        end
        if row.hash ~= expected_hash then
            return open_fail(handle, "manifest path hash does not match record")
        end
        if previous_hash then
            if row.hash < previous_hash
                or (row.hash == previous_hash and indexed_record.path < previous_path)
                or (row.hash == previous_hash and indexed_record.path == previous_path
                    and row.ordinal < previous_ordinal) then
                return open_fail(handle, "manifest path index is not sorted")
            end
            if indexed_record.path == previous_path then
                return open_fail(handle, "duplicate normalized manifest path")
            end
        end
        previous_hash = row.hash
        previous_path = indexed_record.path
        previous_ordinal = row.ordinal
    end
    return setmetatable({
        path = path,
        handle = handle,
        md5 = md5,
        count = header.count,
        folders = header.folders,
        images = header.images,
        documents = header.documents,
        records_offset = header.records,
        ordinals_offset = header.ordinals,
        paths_offset = header.paths,
        digest = header.digest,
        closed = false,
    }, Manifest)
end

M.HEADER_SIZE = HEADER_SIZE

return M
