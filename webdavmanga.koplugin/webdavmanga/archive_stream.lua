-- Range-backed libarchive reader for RAR/7z and other formats exposed by the
-- KOReader build. It never creates a complete archive file: libarchive asks
-- for sequential blocks and this adapter translates them into HTTP Range reads.
local ArchiveStream = {}
ArchiveStream.__index = ArchiveStream

local BLOCK_SIZE = 128 * 1024
local MAX_ENTRY_SIZE = 128 * 1024 * 1024
local module_source = debug.getinfo(1, "S").source:gsub("\\", "/")
local plugin_root = module_source:match("^@(.+)/webdavmanga/archive_stream%.lua$")

local function close_file(value)
    if not value or type(value.close) ~= "function" then return false end
    local ok, result = pcall(value.close, value)
    return ok and result ~= false
end

local function image_name(name, formats)
    if type(formats) == "table" and type(formats.is_image) == "function" then
        return formats.is_image(name)
    end
    return tostring(name or ""):lower():match("%.(jpe?g|png|webp|gif|tiff?)$") ~= nil
end

function ArchiveStream:new(options)
    options = options or {}
    return setmetatable({
        ffi = options.ffi,
        libarchive = options.libarchive,
        header_loaded = false,
        formats = options.formats,
        logger = options.logger,
    }, self)
end

function ArchiveStream:_load_native()
    if self.libarchive and self.ffi then return true end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return false, "libarchive_unavailable" end
    local ok_header = pcall(require, "ffi/libarchive_h")
    if not ok_header then return false, "libarchive_unavailable" end
    local ok_lib, lib = pcall(ffi.loadlib, "archive", "13")
    if not ok_lib or not lib then return false, "libarchive_unavailable" end
    local ok_cdef = pcall(ffi.cdef, [[
        int archive_read_open2(struct archive *, void *,
            int (*)(struct archive *, void *),
            long (*)(struct archive *, void *, const void **),
            long long (*)(struct archive *, void *, long long),
            int (*)(struct archive *, void *));
        int archive_read_set_seek_callback(struct archive *,
            long long (*)(struct archive *, void *, long long, int));
        int archive_read_data_skip(struct archive *);
        int archive_set_error(struct archive *, int, const char *, ...);
        const char *archive_error_string(struct archive *);
    ]])
    if not ok_cdef then return false, "libarchive_unavailable" end
    self.ffi, self.libarchive, self.header_loaded = ffi, lib, true
    return true
end

-- Some KindleHF KOReader releases ship libarchive without LZMA. Keep its
-- library for every other format; load the optional, pinned official build
-- only for 7Z/CB7 on the matching ABI. This never replaces KOReader's files.
function ArchiveStream:_library_for_format(format)
    local ffi, core = self.ffi, self.libarchive
    if format ~= "7z" and format ~= "cb7" then return core end
    if ffi.arch ~= "arm" or ffi.os ~= "Linux" or ffi.abi("softfp") then return core end
    local loaded, device = pcall(require, "device")
    if not loaded or type(device.isKindle) ~= "function" or not device:isKindle() then return core end
    pcall(ffi.cdef, "const char *archive_version_details(void);")
    local function has_lzma(lib)
        local ok, details = pcall(function() return ffi.string(lib.archive_version_details()) end)
        return ok and details:find("liblzma/", 1, true) ~= nil
    end
    if has_lzma(core) then return core end
    if not self.lzma_load_attempted then
        self.lzma_load_attempted = true
        if plugin_root then
            local ok, library = pcall(ffi.load, plugin_root .. "/lib/kindlehf/libarchive.so.13")
            if ok and library and has_lzma(library) then self.lzma_libarchive = library end
        end
    end
    return self.lzma_libarchive or core
end

local function set_error(reader, archive)
    reader.error = "archive_range_read_failed"
    local setter
    local available = reader.libarchive and pcall(function()
        setter = reader.libarchive.archive_set_error
    end)
    if available and setter then pcall(setter, archive, 5, "%s", reader.error) end
end

-- Native text can contain server URLs and entry pathnames. It exists only
-- during classification; reader state and logs retain program-owned codes.
function ArchiveStream:_native_status(reader, status, fallback)
    reader.last_status = tonumber(status)
    reader.native_detail = nil
    local reason = reader.error
    if not reason and status ~= 0 and status ~= 1 then
        local ok, native = pcall(function()
            local value = reader.libarchive.archive_error_string(reader.archive)
            return value ~= nil and reader.ffi.string(value):lower() or ""
        end)
        if ok then
            if native:sub(1, #"unsupported compression method") == "unsupported compression method" then
                reader.native_detail = "compression_method"
            elseif native:sub(1, #"lzma codec is not supported") == "lzma codec is not supported"
                or native:sub(1, #"lzma codec is unsupported") == "lzma codec is unsupported" then
                reader.native_detail = "lzma"
            end
            if native:find("encrypt", 1, true) or native:find("passphrase", 1, true)
                or native:find("password", 1, true) then reason = "archive_encrypted"
            elseif native:find("unsupported", 1, true) or native:find("not supported", 1, true)
                or native:find("not compiled", 1, true) then reason = "archive_codec_unsupported"
            elseif native:find("truncat", 1, true) or native:find("unexpected end", 1, true)
                or native:find("premature end", 1, true) then reason = "archive_truncated" end
        end
    end
    reader.native_reason = reason or fallback or "ok"
    local logger = self.logger
    if status ~= 0 and status ~= 1 then
        if not logger then
            local loaded, value = pcall(require, "logger")
            if loaded then logger = value end
        end
        if logger and type(logger.warn) == "function" then
            pcall(logger.warn, "WebDavManga archive native:", reader.last_status,
                reader.native_reason, reader.native_detail or "unspecified")
        end
    end
    return reader.native_reason
end

function ArchiveStream:_new_reader(options)
    options = options or {}
    local available, reason = self:_load_native()
    if not available then return nil, reason end
    local ffi, lib = self.ffi, self:_library_for_format(options.format)
    local size = tonumber(options.size)
    if not size or size < 1 or size ~= math.floor(size)
        or type(options.read_at) ~= "function" then
        return nil, "invalid_archive_source"
    end
    local reader = {
        ffi = ffi, libarchive = lib, size = size, read_at = options.read_at,
        position = 0, block = nil, error = nil, current = nil,
        block_size = options.block_size == 512 * 1024 and 512 * 1024 or BLOCK_SIZE,
        consumed = true, closed = false, formats = self.formats,
    }
    reader.close = function()
        return self:close(reader)
    end
    local function read_callback(archive, _client_data, buffer)
        if reader.closed or reader.position >= reader.size then
            buffer[0] = nil
            return 0
        end
        local count = math.min(reader.block_size, reader.size - reader.position)
        local ok, bytes = pcall(reader.read_at, reader.position, count)
        if not ok or type(bytes) ~= "string" or #bytes == 0 then
            set_error(reader, archive)
            buffer[0] = nil
            return -1
        end
        if #bytes > count then bytes = bytes:sub(1, count) end
        reader.block = ffi.new("uint8_t[?]", #bytes)
        ffi.copy(reader.block, bytes, #bytes)
        buffer[0] = reader.block
        reader.position = reader.position + #bytes
        return #bytes
    end
    local function skip_callback(_, _, request)
        request = tonumber(request) or 0
        if request <= 0 then return 0 end
        local available = math.max(0, reader.size - reader.position)
        local skipped = math.min(request, available)
        reader.position = reader.position + skipped
        reader.block = nil
        return skipped
    end
    local function seek_callback(_, _, offset, whence)
        offset, whence = tonumber(offset), tonumber(whence)
        if not offset or not whence then return -1 end
        local base
        if whence == 0 then base = 0
        elseif whence == 1 then base = reader.position
        elseif whence == 2 then base = reader.size
        else return -1 end
        local target = base + offset
        if target < 0 or target > reader.size or target ~= math.floor(target) then
            return -1
        end
        reader.position = target
        reader.block = nil
        return target
    end
    local function open_callback() return 0 end
    local function close_callback() return 0 end
    local function cast(signature, callback)
        local ok, value = pcall(ffi.cast, signature, callback)
        return ok and value or nil
    end
    reader.callbacks = {
        open = cast("int (*)(struct archive *, void *)", open_callback),
        read = cast("long (*)(struct archive *, void *, const void **)", read_callback),
        skip = cast("long long (*)(struct archive *, void *, long long)", skip_callback),
        seek = cast("long long (*)(struct archive *, void *, long long, int)", seek_callback),
        close = cast("int (*)(struct archive *, void *)", close_callback),
    }
    if not reader.callbacks.open or not reader.callbacks.read
        or not reader.callbacks.skip or not reader.callbacks.close then
        self:close(reader)
        return nil, "libarchive_callback_unavailable"
    end
    reader.archive = lib.archive_read_new()
    reader.entry = lib.archive_entry_new()
    if reader.archive == nil or reader.entry == nil then
        self:close(reader)
        return nil, "libarchive_reader_unavailable"
    end
    lib.archive_read_support_format_all(reader.archive)
    lib.archive_read_support_filter_all(reader.archive)
    local seek_setter
    local has_seek_setter = pcall(function()
        seek_setter = lib.archive_read_set_seek_callback
    end)
    if has_seek_setter and seek_setter ~= nil and reader.callbacks.seek then
        local seek_ok, seek_result = pcall(seek_setter,
            reader.archive, reader.callbacks.seek)
        reader.seek_enabled = seek_ok and seek_result == 0
    else
        reader.seek_enabled = false
    end
    local format = tostring(options.format or ""):lower()
    if (format == "7z" or format == "cb7") and not reader.seek_enabled then
        self:close(reader)
        return nil, "archive_seek_unavailable"
    end
    local opened = lib.archive_read_open2(reader.archive, nil,
        reader.callbacks.open, reader.callbacks.read,
        reader.callbacks.skip, reader.callbacks.close)
    if opened ~= 0 then
        local reason = self:_native_status(reader, opened, "libarchive_open_failed")
        self:close(reader)
        return nil, reason
    end
    reader.last_status, reader.native_reason = 0, "ok"
    return reader
end

function ArchiveStream:open(options)
    return self:_new_reader(options)
end

function ArchiveStream.available(self)
    local probe = type(self) == "table" and getmetatable(self) == ArchiveStream
        and self or ArchiveStream:new()
    local ok = probe:_load_native()
    return ok == true
end

function ArchiveStream:is_image(name)
    return image_name(name, self.formats)
end

function ArchiveStream:next(reader)
    if not reader or reader.closed then return nil, "archive_reader_closed" end
    if not reader.consumed then
        local skipped = reader.libarchive.archive_read_data_skip(reader.archive)
        if skipped ~= 0 and skipped ~= -20 then
            return nil, self:_native_status(reader, skipped, "archive_skip_failed")
        end
    end
    local result = reader.libarchive.archive_read_next_header2(reader.archive, reader.entry)
    self:_native_status(reader, result,
        (result == 0 or result == 1 or result == -20) and "ok" or "archive_header_failed")
    if result == 1 then return nil end -- ARCHIVE_EOF
    -- libarchive may return ARCHIVE_WARN while still exposing a usable
    -- header (for example, a non-ASCII pathname warning in a 7z archive).
    if result ~= 0 and result ~= -20 then
        return nil, reader.native_reason
    end
    reader.ordinal = (reader.ordinal or 0) + 1
    local path = reader.libarchive.archive_entry_pathname(reader.entry)
    local name = path ~= nil and reader.ffi.string(path) or ""
    local size = tonumber(reader.libarchive.archive_entry_size(reader.entry)) or 0
    local mode = reader.libarchive.archive_entry_filetype(reader.entry)
    reader.current = { path = name, name = name, size = size,
        index = reader.ordinal, mode = mode == 32768 and "file" or "other" }
    reader.consumed = false
    return reader.current
end

function ArchiveStream:extract_current(reader, target, max_bytes)
    if not reader or reader.closed or reader.consumed then
        return nil, "archive_entry_unavailable"
    end
    local limit = max_bytes or MAX_ENTRY_SIZE
    if type(limit) ~= "number" or limit < 0 or limit ~= math.floor(limit)
        or limit > MAX_ENTRY_SIZE then return nil, "archive_entry_too_large" end
    local entry = reader.current
    if not entry or entry.mode ~= "file" or entry.size < 0
        or entry.size > limit then
        return nil, "archive_entry_too_large"
    end
    local file = io.open(target, "wb")
    if not file then return nil, "archive_write_failed" end
    local buffer = reader.ffi.new("uint8_t[?]", 64 * 1024)
    local total = 0
    while true do
        local count = tonumber(reader.libarchive.archive_read_data(reader.archive, buffer,
            math.min(64 * 1024, limit - total + 1)))
        if not count then
            close_file(file)
            pcall(os.remove, target)
            return nil, "archive_read_failed"
        end
        if count == 0 then break end
        if count < 0 then
            close_file(file)
            pcall(os.remove, target)
            return nil, self:_native_status(reader, count, "archive_read_failed")
        end
        if total + count > limit then
            close_file(file); pcall(os.remove, target)
            return nil, "archive_entry_too_large"
        end
        local bytes = reader.ffi.string(buffer, count)
        local ok, wrote = pcall(file.write, file, bytes)
        if not ok or wrote == nil or wrote == false then
            close_file(file); pcall(os.remove, target)
            return nil, "archive_write_failed"
        end
        total = total + count
    end
    if not close_file(file) then pcall(os.remove, target); return nil, "archive_write_failed" end
    if total ~= entry.size then
        pcall(os.remove, target)
        reader.native_reason = "archive_truncated"
        return nil, "archive_truncated"
    end
    reader.consumed = true
    return { size = total, format = reader.formats
        and reader.formats.extension_for_format(reader.formats.extension(entry.name))
        or nil }
end

function ArchiveStream:close(reader)
    if not reader or reader.closed then return true end
    reader.closed = true
    if reader.archive then
        pcall(reader.libarchive.archive_read_close, reader.archive)
        pcall(reader.libarchive.archive_free, reader.archive)
    end
    if reader.entry then pcall(reader.libarchive.archive_entry_free, reader.entry) end
    reader.archive, reader.entry, reader.block, reader.current = nil, nil, nil, nil
    for _, callback in pairs(reader.callbacks or {}) do pcall(function() callback:free() end) end
    reader.callbacks = nil
    return true
end

return ArchiveStream
