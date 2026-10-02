local BookIndex = require("webdavmanga.book_index")
local Formats = require("webdavmanga.image_formats")

local ArchivePages = {}
ArchivePages.__index = ArchivePages

local EOCD_SIZE = 22
local EOCD_TAIL_SIZE = 65557
local MAX_ENTRIES = 20000
local MAX_DIRECTORY_SIZE = 8 * 1024 * 1024
local MAX_NAME_SIZE = 4096
local MAX_ENTRY_SIZE = 128 * 1024 * 1024
local MAX_METADATA_SIZE = 1024 * 1024
local ZIP64_U16 = 65535
local ZIP64_U32 = 4294967295
local COPY_BYTES = 64 * 1024
local LIBARCHIVE_KINDS = { cbr = true, rar = true, cb7 = true, ["7z"] = true }
local EPUB_IMAGE_TYPES = {
    ["image/jpeg"] = true,
    ["image/png"] = true,
    ["image/webp"] = true,
    ["image/gif"] = true,
    ["image/tiff"] = true,
    ["image/svg+xml"] = true,
}
local EPUB_ACTIVE_ELEMENTS = {
    script = true, iframe = true, object = true, embed = true,
    canvas = true, video = true, audio = true, foreignobject = true,
    animate = true, animatecolor = true, animatemotion = true,
    animatetransform = true, set = true, discard = true,
}
local EPUB_DRAWING_ELEMENTS = {
    rect = true, circle = true, ellipse = true, line = true,
    polygon = true, polyline = true, path = true, text = true, use = true,
    math = true, filter = true, mask = true, pattern = true, clippath = true,
}
local EPUB_SIMPLE_SVG_ELEMENTS = {
    svg = true, image = true, g = true, defs = true,
    title = true, desc = true, style = true,
}

local function u16(bytes, position)
    local a, b = bytes:byte(position, position + 1)
    return b and a + b * 256 or nil
end

local function u32(bytes, position)
    local a, b, c, d = bytes:byte(position, position + 3)
    return d and a + b * 256 + c * 65536 + d * 16777216 or nil
end

local function read_exact(descriptor, offset, count)
    if offset < 0 or count < 0 or offset + count > descriptor.size then return nil end
    local chunks, position, remaining = {}, offset, count
    while remaining > 0 do
        local bytes = descriptor.read_at(position, remaining)
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > remaining then return nil end
        chunks[#chunks + 1] = bytes
        position, remaining = position + #bytes, remaining - #bytes
    end
    return table.concat(chunks)
end

local function eocd_in_tail(tail)
    for position = #tail - EOCD_SIZE + 1, 1, -1 do
        if tail:sub(position, position + 3) == "PK\005\006" then
            local comment_size = u16(tail, position + 20)
            if comment_size and position + EOCD_SIZE + comment_size - 1 == #tail then
                return position
            end
        end
    end
end

function ArchivePages:new(options)
    options = options or {}
    return setmetatable({
        image_probe = options.image_probe or require("webdavmanga.image_probe"),
        archiver = options.archiver,
        archive_stream = options.archive_stream,
        logger = options.logger,
        open_file = options.open_file or io.open,
        remove_file = options.remove_file or os.remove,
        temp_name = options.temp_name or os.tmpname,
    }, self)
end

local function libarchive_kind(kind)
    return LIBARCHIVE_KINDS[tostring(kind or ""):lower()] == true
end

local function progress_interval(options)
    if not options or type(options.on_progress) ~= "function" then return nil end
    local value = math.floor(tonumber(options.progress_interval) or 5)
    return math.max(1, math.min(MAX_ENTRIES, value))
end

local function notify_progress(options, items, total_pages, preserve_order)
    local interval = progress_interval(options)
    if not interval or #items == 0 or #items % interval ~= 0 then return true end
    local index = BookIndex.from_items({})
    if preserve_order then
        local copy = {}
        for position, item in ipairs(items) do copy[position] = item end
        index.items = copy
    else
        index = BookIndex.from_items(items)
    end
    local ok, result = pcall(options.on_progress, index, total_pages)
    return ok and result ~= false
end

local function load_archive_stream()
    local loaded, value = pcall(require, "webdavmanga.archive_stream")
    if not loaded or type(value) ~= "table" then return nil end
    if type(value.new) == "function" then
        local ok, instance = pcall(value.new, value, { formats = Formats })
        if ok and type(instance) == "table" then return instance end
    end
    return value
end

function ArchivePages:can_stream(kind)
    if kind == "cbz" or kind == "zip" or kind == "epub" or kind == "cbt" or kind == "tar" then return true end
    if not libarchive_kind(kind) then return false end
    return self:_archive_stream_available()
end

function ArchivePages:_archive_stream_available()
    local stream = self.archive_stream
    if type(stream) ~= "table" then
        stream = load_archive_stream()
        if stream then self.archive_stream = stream end
    end
    if type(stream) ~= "table" or type(stream.open) ~= "function" then return false end
    if type(stream.available) ~= "function" then return true end
    local ok, value = pcall(stream.available, stream)
    return ok and value == true
end

function ArchivePages:_inspect_libarchive(descriptor, kind, remote_path, options)
    local preserve_order = kind == "7z" or kind == "cb7"
        or (options and options.preserve_archive_order == true)
    local opening_targets = options and options.opening_targets
    local opening_metadata = opening_targets and {} or nil
    local stream = self.archive_stream
    if type(stream) ~= "table" then
        stream = load_archive_stream()
        if not stream then return nil, "libarchive_unavailable" end
        self.archive_stream = stream
    end
    if type(stream.open) ~= "function" then return nil, "libarchive_unavailable" end
    local reader, open_error = stream:open({ size = descriptor.size, read_at = descriptor.read_at, format = kind,
        -- Three opening images share a reader. Larger bounded blocks amortize
        -- HTTP latency without overfetching every remaining RAR header.
        block_size = opening_targets and (kind == "rar" or kind == "cbr") and 512 * 1024 or nil })
    if not reader then return nil, open_error or "libarchive_open_failed" end
    local function next_entry()
        if type(stream.next) == "function" then return stream:next(reader) end
        if type(reader.next) == "function" then return reader:next() end
        return nil, "libarchive_next_unavailable"
    end
    local page_limit = options and tonumber(options.page_limit)
    if page_limit then page_limit = math.max(1, math.min(MAX_ENTRIES, math.floor(page_limit))) end
    local entries, error_code, exhausted, limited = {}, nil, false, false
    local ok, caught = pcall(function()
        local scanned = 0
        while scanned < MAX_ENTRIES do
            local entry, next_error = next_entry()
            if not entry then
                if next_error then error_code = next_error end
                exhausted = true
                break
            end
            scanned = scanned + 1
            local entry_name = entry.name or entry.path
            if entry.mode == "file" and Formats.is_image(entry_name)
                and tonumber(entry.size) and entry.size >= 0
                and entry.size <= MAX_ENTRY_SIZE then
                local ordinal = tonumber(entry.index)
                if page_limit and #entries >= page_limit then
                    limited = true
                    break
                end
                entries[#entries + 1] = {
                    name = entry_name,
                    path = tostring(remote_path or "") .. "#archive/" .. tostring(ordinal),
                    is_file = true,
                    archive_kind = "libarchive",
                    archive_format = kind,
                    archive_remote_path = remote_path,
                    archive_source_size = descriptor.size,
                    archive_entry_name = entry_name,
                    archive_entry_ordinal = ordinal,
                    archive_size = entry.size,
                }
                if opening_targets and opening_targets[#entries] then
                    local target = opening_targets[#entries]
                    local extracted, extract_error
                    if type(stream.extract_current) == "function" then
                        extracted, extract_error = stream:extract_current(reader, target)
                    elseif type(reader.extract_current) == "function" then
                        extracted, extract_error = reader:extract_current(target)
                    end
                    if not extracted then error_code = extract_error or "archive_extract_failed"; break end
                    local metadata, probe_error = self.image_probe.inspect(target, Formats.extension(entry_name))
                    if not metadata or type(extracted) ~= "table" or extracted.size ~= entry.size then
                        error_code = probe_error or "archive_image_invalid"; break
                    end
                    metadata.size = extracted.size
                    opening_metadata[#entries] = metadata
                    if #entries == #opening_targets then limited = true; break end
                end
                local progress_options = options
                if preserve_order and options and options.on_progress and options.start_page == 4
                    and #entries >= 4 and #entries <= 20 then
                    progress_options = { on_progress = options.on_progress, progress_interval = 1 }
                end
                if not notify_progress(progress_options, entries, nil, preserve_order) then
                    error_code = "archive_progress_failed"
                    break
                end
            end
        end
        if not exhausted and not limited and not error_code then error_code = "archive_too_many_entries" end
    end)
    if type(stream.close) == "function" then stream:close(reader)
    elseif type(reader.close) == "function" then reader:close() end
    if not ok then return nil, "archive_header_failed" end
    if error_code then return nil, error_code end
    if #entries == 0 then return nil, "archive_no_images" end
    local index = BookIndex.from_items(entries)
    if preserve_order then index.items = entries end
    return { index = index, layout = "archive_images", opening_metadata = opening_metadata,
        opening_lower_bound = opening_metadata and #opening_metadata or nil,
        incomplete = limited == true, total_pages = exhausted and #entries or nil }
end

local function diagnostic(self, phase, detail)
    local logger = self.logger
    if logger == nil then
        local loaded, value = pcall(require, "logger")
        if loaded then logger = value end
    end
    if logger and type(logger.warn) == "function" then
        pcall(logger.warn, "WebDavManga archive:", tostring(phase), tostring(detail or ""))
    end
end

local function zip_entries(descriptor, kind, remote_path)
    local size = descriptor.size
    local tail_size = math.min(size, EOCD_TAIL_SIZE)
    local tail_offset = size - tail_size
    local tail = read_exact(descriptor, tail_offset, tail_size)
    if not tail then return nil, "zip_read_failed" end
    local eocd_position = eocd_in_tail(tail)
    if not eocd_position then return nil, "zip_eocd_missing" end

    local disk = u16(tail, eocd_position + 4)
    local start_disk = u16(tail, eocd_position + 6)
    local disk_entries = u16(tail, eocd_position + 8)
    local entries = u16(tail, eocd_position + 10)
    local directory_size = u32(tail, eocd_position + 12)
    local directory_offset = u32(tail, eocd_position + 16)
    if not directory_offset then return nil, "zip_eocd_missing" end
    if disk == ZIP64_U16 or start_disk == ZIP64_U16 or disk_entries == ZIP64_U16
        or entries == ZIP64_U16 or directory_size == ZIP64_U32
        or directory_offset == ZIP64_U32 then
        return nil, "zip64_unsupported"
    end
    if disk ~= 0 or start_disk ~= 0 or disk_entries ~= entries then
        return nil, "zip_multidisk_unsupported"
    end
    if entries > MAX_ENTRIES or directory_size > MAX_DIRECTORY_SIZE then
        return nil, "zip_directory_too_large"
    end

    local eocd_offset = tail_offset + eocd_position - 1
    if directory_offset + directory_size > eocd_offset then
        return nil, "zip_directory_invalid"
    end
    local directory = read_exact(descriptor, directory_offset, directory_size)
    if not directory then return nil, "zip_read_failed" end

    local archive_entries, position = {}, 1
    for ordinal = 1, entries do
        if position + 45 > #directory or directory:sub(position, position + 3) ~= "PK\001\002" then
            return nil, "zip_directory_invalid"
        end
        local flags = u16(directory, position + 8)
        local method = u16(directory, position + 10)
        local crc32 = u32(directory, position + 16)
        local compressed_size = u32(directory, position + 20)
        local uncompressed_size = u32(directory, position + 24)
        local name_size = u16(directory, position + 28)
        local extra_size = u16(directory, position + 30)
        local comment_size = u16(directory, position + 32)
        local disk_start = u16(directory, position + 34)
        local local_offset = u32(directory, position + 42)
        if name_size > MAX_NAME_SIZE then return nil, "zip_name_too_long" end
        local entry_size = 46 + name_size + extra_size + comment_size
        if not local_offset or position + entry_size - 1 > #directory then
            return nil, "zip_directory_invalid"
        end
        if compressed_size == ZIP64_U32 or uncompressed_size == ZIP64_U32
            or local_offset == ZIP64_U32 or disk_start == ZIP64_U16 then
            return nil, "zip64_unsupported"
        end
        if disk_start ~= 0 then return nil, "zip_multidisk_unsupported" end
        if local_offset + 30 > directory_offset then
            return nil, "zip_local_offset_invalid"
        end
        if flags % 2 == 1 then
            return nil, kind == "epub" and "epub_drm" or "zip_encrypted"
        end
        local entry_name = directory:sub(position + 46, position + 45 + name_size)
        if entry_name:sub(-1) ~= "/" then
            archive_entries[#archive_entries + 1] = {
                name = entry_name,
                path = tostring(remote_path or "") .. "#zip/" .. ordinal,
                is_file = true,
                archive_kind = "zip",
                archive_format = kind,
                archive_entry_ordinal = ordinal,
                archive_remote_path = remote_path,
                archive_source_size = size,
                archive_entry_name = entry_name,
                archive_local_offset = local_offset,
                archive_method = method,
                archive_flags = flags,
                archive_crc32 = crc32,
                archive_compressed_size = compressed_size,
                archive_size = uncompressed_size,
            }
        end
        position = position + entry_size
    end
    if position ~= #directory + 1 then return nil, "zip_directory_invalid" end
    return archive_entries
end

local function as_libarchive_page(entry)
    local page = {}
    for key, value in pairs(entry) do page[key] = value end
    page.path = tostring(entry.archive_remote_path or "") .. "#archive/" .. entry.archive_entry_ordinal
    page.archive_kind = "libarchive"
    return page
end

local function tar_number(bytes)
    local value = tostring(bytes or ""):gsub("%z", ""):match("^%s*(.-)%s*$")
    if not value or value == "" then return 0 end
    if not value:match("^[0-7]+$") then return nil end
    return tonumber(value, 8)
end

local function tar_entries(descriptor, remote_path, options)
    local page_limit = options and tonumber(options.page_limit)
    if page_limit then page_limit = math.max(1, math.min(MAX_ENTRIES, math.floor(page_limit))) end
    local entries, offset, terminated, limited = {}, 0, false, false
    for _ = 1, MAX_ENTRIES do
        local header = read_exact(descriptor, offset, 512)
        if not header then return nil, "tar_read_failed" end
        if header == string.rep("\0", 512) then
            terminated = true
            break
        end
        local name = header:sub(1, 100):match("^[^%z]*")
        local prefix = header:sub(346, 500):match("^[^%z]*")
        if prefix and prefix ~= "" then name = prefix .. "/" .. name end
        local size = tar_number(header:sub(125, 136))
        local typeflag = header:sub(157, 157)
        if not name or name == "" or not size then return nil, "tar_header_invalid" end
        if size > MAX_ENTRY_SIZE then return nil, "tar_entry_too_large" end
        local data_offset = offset + 512
        if data_offset + size > descriptor.size then return nil, "tar_entry_out_of_range" end
        if typeflag == "" or typeflag == "0" then
            if Formats.is_image(name) then
                if page_limit and #entries >= page_limit then
                    limited = true
                    break
                end
                entries[#entries + 1] = {
                    name = name,
                    path = tostring(remote_path or "") .. "#tar/" .. tostring(#entries + 1),
                    is_file = true, archive_kind = "tar",
                    archive_remote_path = remote_path,
                    archive_source_size = descriptor.size,
                    archive_entry_name = name,
                    archive_entry_offset = data_offset,
                    archive_method = 0, archive_size = size,
                }
                if not notify_progress(options, entries, nil, false) then
                    return nil, "archive_progress_failed"
                end
            end
        end
        offset = data_offset + math.ceil(size / 512) * 512
        if offset > descriptor.size then return nil, "tar_entry_out_of_range" end
    end
    if not terminated and not limited then return nil, "tar_too_many_entries" end
    if #entries == 0 then return nil, "tar_no_images" end
    return entries, nil, limited
end

function ArchivePages:inspect_remote(descriptor, kind, remote_path, options)
    if (kind ~= "cbz" and kind ~= "zip" and kind ~= "epub" and kind ~= "cbt" and kind ~= "tar" and not libarchive_kind(kind))
        or type(descriptor) ~= "table"
        or type(descriptor.read_at) ~= "function" then
        return nil, "invalid_remote_archive"
    end
    local size = tonumber(descriptor.size)
    if not size or size < 1 or size ~= math.floor(size) then
        return nil, "zip_eocd_missing"
    end
    descriptor = { size = size, read_at = descriptor.read_at,
        metadata_work_path = descriptor.metadata_work_path }
    local page_limit = options and tonumber(options.page_limit)
    if page_limit then page_limit = math.max(1, math.min(MAX_ENTRIES, math.floor(page_limit))) end
    local scan_options
    if options then
        scan_options = {
            page_limit = page_limit,
            progress_interval = options.progress_interval,
            on_progress = options.on_progress,
            continuation = options.continuation,
            start_page = options.start_page,
            source_version = options.source_version,
            generation = options.generation,
            opening_targets = options.opening_targets,
            preserve_archive_order = options.preserve_archive_order,
        }
    end
    if libarchive_kind(kind) then
        return self:_inspect_libarchive(descriptor, kind, remote_path, scan_options)
    end
    if kind == "cbt" or kind == "tar" then
        local entries, entries_error, incomplete = tar_entries(descriptor, remote_path, scan_options)
        if not entries then return nil, entries_error end
        return { index = BookIndex.from_items(entries), layout = "archive_images",
            incomplete = incomplete == true, total_pages = incomplete and nil or #entries }
    end
    if kind == "epub" then
        if scan_options and scan_options.continuation then
            return self:_inspect_epub(descriptor, nil, remote_path, scan_options)
        end
    end
    local entries, entries_error = zip_entries(descriptor, kind, remote_path)
    if not entries then return nil, entries_error end
    if kind == "epub" then
        return self:_inspect_epub(descriptor, entries, remote_path, scan_options)
    end

    local pages, total_pages = {}, 0
    for _, entry in ipairs(entries) do
        if Formats.is_image(entry.name) then
            if entry.archive_method ~= 0 and entry.archive_method ~= 8 then
                if not self:_archive_stream_available() then return nil, "zip_unsupported_method" end
                entry = as_libarchive_page(entry)
            end
            if entry.archive_size > MAX_ENTRY_SIZE then return nil, "zip_entry_too_large" end
            total_pages = total_pages + 1
            if not page_limit or #pages < page_limit then pages[#pages + 1] = entry end
            if not page_limit and not notify_progress(scan_options, pages, nil, false) then
                return nil, "archive_progress_failed"
            end
        end
    end
    if #pages == 0 then return nil, "zip_no_images" end
    return { index = BookIndex.from_items(pages), layout = "archive_images",
        incomplete = #pages < total_pages, total_pages = total_pages }
end

local function arithmetic_xor32(left, right)
    local result, place = 0, 1
    for _ = 1, 32 do
        if left % 2 ~= right % 2 then result = result + place end
        left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
    end
    return result
end

local bit_ok, bit = pcall(require, "bit")
local bxor = bit_ok and bit.bxor or arithmetic_xor32
local rshift = bit_ok and bit.rshift or function(value, count)
    return math.floor(value / 2 ^ count)
end
local band = bit_ok and bit.band or function(value, mask)
    return value % (mask + 1)
end
local CRC32_TABLE = {}
for value = 0, 255 do
    local crc = value
    for _ = 1, 8 do
        if band(crc, 1) == 1 then
            crc = bxor(rshift(crc, 1), 3988292384)
        else
            crc = rshift(crc, 1)
        end
    end
    CRC32_TABLE[value] = crc
end

local function crc32_update(crc, bytes)
    for index = 1, #bytes do
        local lookup = band(bxor(crc, bytes:byte(index)), 255)
        crc = bxor(rshift(crc, 8), CRC32_TABLE[lookup])
    end
    return crc
end

local function crc32_finish(crc)
    local value = bxor(crc, 4294967295)
    return value < 0 and value + 4294967296 or value
end

local function crc32(bytes)
    return crc32_finish(crc32_update(4294967295, bytes))
end

local function percent_decode(path)
    local position = 1
    while true do
        local marker = path:find("%", position, true)
        if not marker then break end
        if not path:sub(marker + 1, marker + 2):match("^%x%x$") then return nil end
        position = marker + 3
    end
    path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    if path:find("\\", 1, true) or path:find("[%z\1-\31\127]") then return nil end
    return path
end

local function safe_relative_path(path)
    path = percent_decode(tostring(path or ""))
    if not path or path == "" or path:sub(1, 1) == "/" or path:sub(-1) == "/"
        or path:find("//", 1, true) or path:match("^[%a][%w+.-]*:") then return nil end
    return path
end

local function resolve_path(parent, reference)
    reference = safe_relative_path(reference)
    if not reference then return nil end
    local combined = {}
    local directory = tostring(parent or ""):match("^(.*)/") or ""
    for segment in (directory .. "/" .. reference):gmatch("[^/]+") do
        if segment == ".." then
            if #combined == 0 then return nil end
            combined[#combined] = nil
        elseif segment ~= "." then
            combined[#combined + 1] = segment
        end
    end
    return #combined > 0 and table.concat(combined, "/") or nil
end

local XML_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xml_value(value)
    return value:gsub("&([%a]+);", function(name) return XML_ENTITIES[name] or "&" .. name .. ";" end)
end

local function xml_elements(xml)
    local loaded, luxl = pcall(require, "luxl")
    if not loaded or type(luxl) ~= "table" or type(luxl.new) ~= "function" then return nil end
    xml = xml:gsub("<%?xml.-%?>", ""):gsub("<!%-%-.-%-%->", "")
    local ok, elements = pcall(function()
        local lexer = luxl.new(xml, #xml)
        local result, stack, attribute = {}, {}, nil
        for event, offset, size in lexer:Lexemes() do
            local token = xml:sub(offset + 1, offset + size)
            if event == luxl.EVENT_START then
                local element = {
                    name = token:match("([^:]+)$"):lower(),
                    attributes = {},
                    parent = stack[#stack],
                }
                result[#result + 1] = element
                stack[#stack + 1] = element
                attribute = nil
            elseif event == luxl.EVENT_ATTR_NAME then
                attribute = token:lower()
            elseif event == luxl.EVENT_ATTR_VAL and stack[#stack] and attribute then
                stack[#stack].attributes[attribute] = xml_value(token)
                attribute = nil
            elseif event == luxl.EVENT_END then
                if #stack == 0 then error("unmatched XML end") end
                local end_name = token ~= "/" and token:match("([^:/]+)$")
                if end_name and end_name:lower() ~= stack[#stack].name then
                    error("mismatched XML end")
                end
                stack[#stack] = nil
                attribute = nil
            end
        end
        if #stack ~= 0 then error("unclosed XML element") end
        return result
    end)
    return ok and elements or nil
end

local function integer(value, maximum)
    value = tonumber(value)
    if not value or value < 0 or value ~= math.floor(value)
        or (maximum and value > maximum) then return nil end
    return value
end

local function read_at_exact(read_at, offset, count)
    local chunks, position, remaining = {}, offset, count
    while remaining > 0 do
        local bytes = read_at(position, remaining)
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > remaining then return nil end
        chunks[#chunks + 1] = bytes
        position, remaining = position + #bytes, remaining - #bytes
    end
    return table.concat(chunks)
end

local function zip_entry(image)
    if type(image) ~= "table" or type(image.archive_entry_name) ~= "string"
        or image.archive_entry_name == "" or #image.archive_entry_name > MAX_NAME_SIZE then
        return nil, "zip_entry_invalid"
    end
    local entry = {
        name = image.archive_entry_name,
        source_size = integer(image.archive_source_size),
        offset = integer(image.archive_local_offset),
        method = integer(image.archive_method),
        flags = integer(image.archive_flags, ZIP64_U16),
        crc32 = integer(image.archive_crc32, ZIP64_U32),
        compressed_size = integer(image.archive_compressed_size),
        size = integer(image.archive_size),
    }
    if not entry.source_size or not entry.offset or not entry.method or not entry.flags
        or entry.crc32 == nil or entry.compressed_size == nil or entry.size == nil then
        return nil, "zip_entry_invalid"
    end
    if entry.compressed_size > MAX_ENTRY_SIZE or entry.size > MAX_ENTRY_SIZE then
        return nil, "zip_entry_too_large"
    end
    if entry.method ~= 0 and entry.method ~= 8 then return nil, "zip_unsupported_method" end
    if entry.flags % 2 == 1 then return nil, "zip_encrypted" end
    if entry.offset + 30 > entry.source_size
        or entry.offset + 30 + #entry.name + entry.compressed_size > entry.source_size then
        return nil, "zip_local_offset_invalid"
    end
    return entry
end

local function close_file(file)
    if not file or type(file.close) ~= "function" then return false end
    local ok, closed = pcall(file.close, file)
    return ok and closed ~= nil
end

function ArchivePages:_open(path, mode)
    local ok, file = pcall(self.open_file, path, mode)
    if not ok or not file then return nil end
    return file
end

function ArchivePages:_local_data_offset(entry, read_at)
    local header = read_at_exact(read_at, entry.offset, 30)
    if not header then return nil, "zip_read_failed" end
    if header:sub(1, 4) ~= "PK\003\004" then return nil, "zip_local_header_invalid" end
    local flags, method = u16(header, 7), u16(header, 9)
    local crc32, compressed_size, size = u32(header, 15), u32(header, 19), u32(header, 23)
    local name_size, extra_size = u16(header, 27), u16(header, 29)
    if flags ~= entry.flags or method ~= entry.method or not crc32 or not compressed_size
        or not size or not name_size or not extra_size or name_size > MAX_NAME_SIZE then
        return nil, "zip_local_header_invalid"
    end
    local local_name = read_at_exact(read_at, entry.offset + 30, name_size)
    if not local_name then return nil, "zip_read_failed" end
    if local_name ~= entry.name then return nil, "zip_local_header_invalid" end
    if math.floor(flags / 8) % 2 == 0 and (crc32 ~= entry.crc32
        or compressed_size ~= entry.compressed_size or size ~= entry.size) then
        return nil, "zip_local_header_invalid"
    end
    local data_offset = entry.offset + 30 + name_size + extra_size
    if data_offset + entry.compressed_size > entry.source_size then
        return nil, "zip_local_offset_invalid"
    end
    return data_offset
end

function ArchivePages:_copy_entry(read_at, offset, size, target)
    local output = self:_open(target, "wb")
    if not output then return nil, "zip_write_failed" end
    local copied, error_code = self:_write_entry(read_at, offset, size, output)
    if not close_file(output) and copied then copied, error_code = false, "zip_write_failed" end
    if not copied then return nil, error_code end
    return true
end

function ArchivePages:_write_entry(read_at, offset, size, output)
    local position, remaining = offset, size
    local copied, error_code = true, nil
    while remaining > 0 do
        local count = math.min(COPY_BYTES, remaining)
        local bytes = read_at_exact(read_at, position, count)
        if not bytes then copied, error_code = false, "zip_read_failed"; break end
        local wrote, write_result = pcall(output.write, output, bytes)
        if not wrote or write_result == nil or write_result == false then
            copied, error_code = false, "zip_write_failed"; break
        end
        position, remaining = position + count, remaining - count
    end
    return copied, error_code
end

local function zip_header(entry)
    return "PK\003\004" .. string.char(20, 0) .. string.char(entry.flags % 256,
        math.floor(entry.flags / 256)) .. string.char(entry.method % 256,
        math.floor(entry.method / 256)) .. "\0\0\0\0"
        .. string.char(entry.crc32 % 256, math.floor(entry.crc32 / 256) % 256,
            math.floor(entry.crc32 / 65536) % 256, math.floor(entry.crc32 / 16777216) % 256)
        .. string.char(entry.compressed_size % 256, math.floor(entry.compressed_size / 256) % 256,
            math.floor(entry.compressed_size / 65536) % 256,
            math.floor(entry.compressed_size / 16777216) % 256)
        .. string.char(entry.size % 256, math.floor(entry.size / 256) % 256,
            math.floor(entry.size / 65536) % 256, math.floor(entry.size / 16777216) % 256)
        .. string.char(#entry.name % 256, math.floor(#entry.name / 256)) .. "\0\0" .. entry.name
end

local function central_directory(entry, local_size)
    return "PK\001\002" .. string.char(20, 0, 20, 0, entry.flags % 256,
        math.floor(entry.flags / 256), entry.method % 256, math.floor(entry.method / 256))
        .. "\0\0\0\0"
        .. string.char(entry.crc32 % 256, math.floor(entry.crc32 / 256) % 256,
            math.floor(entry.crc32 / 65536) % 256, math.floor(entry.crc32 / 16777216) % 256)
        .. string.char(entry.compressed_size % 256, math.floor(entry.compressed_size / 256) % 256,
            math.floor(entry.compressed_size / 65536) % 256,
            math.floor(entry.compressed_size / 16777216) % 256)
        .. string.char(entry.size % 256, math.floor(entry.size / 256) % 256,
            math.floor(entry.size / 65536) % 256, math.floor(entry.size / 16777216) % 256)
        .. string.char(#entry.name % 256, math.floor(#entry.name / 256))
        .. "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
        .. entry.name .. "PK\005\006\0\0\0\0\1\0\1\0"
        .. string.char((46 + #entry.name) % 256, math.floor((46 + #entry.name) / 256), 0, 0,
            local_size % 256, math.floor(local_size / 256) % 256,
            math.floor(local_size / 65536) % 256, math.floor(local_size / 16777216) % 256, 0, 0)
end

function ArchivePages:_open_deflated(entry, read_at, data_offset, work)
    local output = self:_open(work, "wb")
    if not output then diagnostic(self, "zipwork.open", "write failed"); return nil, "zip_write_failed" end
    local work_entry = {
        name = entry.name,
        flags = entry.flags - (math.floor(entry.flags / 8) % 2) * 8,
        method = entry.method,
        crc32 = entry.crc32,
        compressed_size = entry.compressed_size,
        size = entry.size,
    }
    local header = zip_header(work_entry)
    local wrote, result = pcall(output.write, output, header)
    if not wrote or result == nil or result == false then
        close_file(output)
        diagnostic(self, "zipwork.header", "write failed"); return nil, "zip_write_failed"
    end
    local copied, copy_error = self:_write_entry(read_at, data_offset,
        entry.compressed_size, output)
    if copied then
        local tail = central_directory(work_entry, #header + entry.compressed_size)
        local ok, value = pcall(output.write, output, tail)
        if not ok or value == nil or value == false then copied, copy_error = nil, "zip_write_failed" end
    end
    if not close_file(output) and copied then copied, copy_error = nil, "zip_write_failed" end
    if not copied then diagnostic(self, "zipwork.data", copy_error); return nil, copy_error end

    local archiver = self.archiver
    if not archiver then
        local loaded, module = pcall(require, "ffi/archiver")
        if not loaded then diagnostic(self, "archiver.require", "zip_archiver_unavailable"); return nil, "zip_archiver_unavailable" end
        archiver = module
    end
    local created, reader = pcall(function()
        return archiver and archiver.Reader and archiver.Reader:new()
    end)
    if not created or not reader then diagnostic(self, "archiver.reader", "zip_extract_failed"); return nil, "zip_extract_failed" end
    local opened, open_result = pcall(reader.open, reader, work)
    if not opened or not open_result then
        if reader.close then pcall(reader.close, reader) end
        diagnostic(self, "archiver.open", "zip_extract_failed"); return nil, "zip_extract_failed"
    end
    -- ffi/archiver indexes entries lazily.  extractToMemory/Path(1) cannot
    -- seek until the first header has been enumerated.
    local indexed, first_entry = pcall(reader.next, reader)
    if not indexed or not first_entry then
        if reader.close then pcall(reader.close, reader) end
        diagnostic(self, "archiver.next", "zip_extract_failed"); return nil, "zip_extract_failed"
    end
    return reader
end

function ArchivePages:_extract_deflated(entry, read_at, data_offset, target)
    local reader, reader_error = self:_open_deflated(entry, read_at, data_offset,
        target .. ".zipwork")
    if not reader then return nil, reader_error end
    local ok, extracted = pcall(reader.extractToPath, reader, 1, target)
    if reader.close then pcall(reader.close, reader) end
    if not ok or not extracted then
        diagnostic(self, "archiver.extract", "zip_extract_failed")
        return nil, "zip_extract_failed"
    end
    return true
end

function ArchivePages:_read_metadata(image, descriptor)
    if image.archive_size > MAX_METADATA_SIZE then return nil, "epub_metadata_too_large" end
    if image.archive_method ~= 0 and image.archive_method ~= 8 then
        if not self:_archive_stream_available() then return nil, "zip_unsupported_method" end
        local work = descriptor.metadata_work_path
        if work == nil then
            local named, temporary = pcall(self.temp_name)
            if not named or type(temporary) ~= "string" or temporary == "" then return nil, "zip_write_failed" end
            work = temporary
        end
        if type(work) ~= "string" or work == "" or work:find("%z") then return nil, "zip_write_failed" end
        local extracted, extract_error = self:_extract_libarchive_entry(
            as_libarchive_page(image), descriptor.read_at, work, MAX_METADATA_SIZE + 1)
        if not extracted then
            pcall(self.remove_file, work)
            return nil, extract_error == "archive_entry_too_large" and "epub_metadata_too_large" or extract_error
        end
        local input = self:_open(work, "rb")
        local read_ok, bytes = false, nil
        if input then read_ok, bytes = pcall(input.read, input, MAX_METADATA_SIZE + 1) end
        local closed = input and close_file(input)
        local removed, remove_result = pcall(self.remove_file, work)
        if not removed or not remove_result then return nil, "zip_write_failed" end
        if not read_ok or type(bytes) ~= "string" or not closed then return nil, "zip_read_failed" end
        if #bytes > MAX_METADATA_SIZE then return nil, "epub_metadata_too_large" end
        if #bytes ~= image.archive_size then return nil, "zip_size_mismatch" end
        if crc32(bytes) ~= image.archive_crc32 then return nil, "zip_crc_mismatch" end
        return bytes
    end
    local entry, entry_error = zip_entry(image)
    if not entry then return nil, entry_error end
    local data_offset, offset_error = self:_local_data_offset(entry, descriptor.read_at)
    if not data_offset then return nil, offset_error end

    local bytes
    if entry.method == 0 then
        if entry.compressed_size ~= entry.size then return nil, "zip_size_mismatch" end
        bytes = read_at_exact(descriptor.read_at, data_offset, entry.size)
        if not bytes then return nil, "zip_read_failed" end
    else
        local work = descriptor.metadata_work_path
        if work == nil then
            local named, temporary = pcall(self.temp_name)
            if not named or type(temporary) ~= "string" or temporary == "" then return nil, "zip_write_failed" end
            work = temporary .. ".zipwork"
        end
        if type(work) ~= "string" or work == "" or work:find("%z") then return nil, "zip_write_failed" end
        local reader, reader_error = self:_open_deflated(entry, descriptor.read_at,
            data_offset, work)
        if reader then
            local extracted, value = pcall(reader.extractToMemory, reader, 1)
            if extracted and type(value) == "string" then bytes = value end
            if reader.close then pcall(reader.close, reader) end
        end
        pcall(self.remove_file, work)
        if not reader then return nil, reader_error end
        if not bytes then return nil, "zip_extract_failed" end
    end
    if #bytes ~= entry.size then return nil, "zip_size_mismatch" end
    if crc32(bytes) ~= entry.crc32 then return nil, "zip_crc_mismatch" end
    return bytes
end

local function entry_map(entries)
    local result = {}
    for _, entry in ipairs(entries) do
        if result[entry.name] ~= nil then
            result[entry.name] = false
        else
            result[entry.name] = entry
        end
    end
    return result
end

local function valid_epub_continuation(value, descriptor, remote_path, options)
    if type(value) ~= "table" or value.version ~= 1
        or type(options.source_version) ~= "string" or options.source_version == ""
        or type(options.generation) ~= "string" or options.generation == ""
        or value.source_version ~= options.source_version
        or value.generation ~= options.generation
        or value.source_size ~= descriptor.size or value.remote_path ~= remote_path
        or type(value.entries) ~= "table" or type(value.manifest) ~= "table"
        or type(value.manifest_images) ~= "table" or type(value.spine) ~= "table"
        or type(value.pages) ~= "table" or #value.entries > MAX_ENTRIES
        or #value.spine < 1 or #value.spine > MAX_ENTRIES
        or type(value.next_cursor) ~= "number"
        or value.next_cursor ~= math.floor(value.next_cursor)
        or value.next_cursor < 2 or value.next_cursor > #value.spine + 1
        or options.start_page ~= value.next_cursor then return nil end
    for key in pairs(value.entries) do
        if type(key) ~= "number" or key < 1 or key > #value.entries
            or key ~= math.floor(key) then return nil end
    end
    local previous_ordinal = 0
    for _, entry in ipairs(value.entries) do
        if type(entry) ~= "table" or type(entry.name) ~= "string"
            or #entry.name < 1 or #entry.name > MAX_NAME_SIZE
            or entry.is_file ~= true
            or entry.archive_kind ~= "zip" or entry.archive_format ~= "epub"
            or entry.archive_remote_path ~= remote_path
            or entry.archive_source_size ~= descriptor.size
            or entry.archive_entry_name ~= entry.name
            or type(entry.archive_entry_ordinal) ~= "number"
            or entry.archive_entry_ordinal <= previous_ordinal
            or entry.archive_entry_ordinal > MAX_ENTRIES
            or entry.archive_entry_ordinal ~= math.floor(entry.archive_entry_ordinal)
            or entry.path ~= remote_path .. "#zip/" .. entry.archive_entry_ordinal
            or type(entry.archive_local_offset) ~= "number"
            or type(entry.archive_compressed_size) ~= "number"
            or type(entry.archive_size) ~= "number"
            or entry.archive_local_offset < 0
            or entry.archive_local_offset ~= math.floor(entry.archive_local_offset)
            or entry.archive_compressed_size < 0
            or entry.archive_compressed_size >= ZIP64_U32
            or entry.archive_compressed_size ~= math.floor(entry.archive_compressed_size)
            or entry.archive_size < 0 or entry.archive_size >= ZIP64_U32
            or entry.archive_size ~= math.floor(entry.archive_size)
            or entry.archive_local_offset + 30 + #entry.name
                + entry.archive_compressed_size > descriptor.size
            or type(entry.archive_method) ~= "number"
            or entry.archive_method < 0 or entry.archive_method > ZIP64_U16
            or entry.archive_method ~= math.floor(entry.archive_method)
            or type(entry.archive_flags) ~= "number"
            or entry.archive_flags < 0 or entry.archive_flags > ZIP64_U16
            or entry.archive_flags ~= math.floor(entry.archive_flags)
            or entry.archive_flags % 2 == 1
            or type(entry.archive_crc32) ~= "number"
            or entry.archive_crc32 < 0 or entry.archive_crc32 > ZIP64_U32
            or entry.archive_crc32 ~= math.floor(entry.archive_crc32)
            or (entry.archive_method == 0
                and entry.archive_size ~= entry.archive_compressed_size) then return nil end
        previous_ordinal = entry.archive_entry_ordinal
    end
    for id, item in pairs(value.manifest) do
        if type(id) ~= "string" or #id < 1 or #id > MAX_NAME_SIZE
            or type(item) ~= "table" or type(item.path) ~= "string"
            or #item.path < 1 or #item.path > MAX_NAME_SIZE
            or resolve_path("", item.path) ~= item.path
            or type(item.media_type) ~= "string"
            or type(item.is_cover) ~= "boolean" then return nil end
    end
    for path, included in pairs(value.manifest_images) do
        if type(path) ~= "string" or #path < 1 or #path > MAX_NAME_SIZE
            or included ~= true then return nil end
    end
    for position, idref in ipairs(value.spine) do
        if type(idref) ~= "string" or not value.manifest[idref]
            or position > MAX_ENTRIES then return nil end
    end
    if value.manifest_cover ~= nil and (type(value.manifest_cover) ~= "string"
        or not value.manifest_images[value.manifest_cover]) then return nil end
    local index = BookIndex.from_table(value.pages)
    if not index or index:count() ~= value.next_cursor - 1 then return nil end
    for position, page in ipairs(index.items) do
        if page.archive_remote_path ~= remote_path
            or page.archive_source_size ~= descriptor.size
            or (page.archive_spine_position ~= nil and page.archive_spine_position ~= position)
            or not BookIndex.matches_archive_format(page, "epub") then return nil end
    end
    return index.items
end

function ArchivePages:validate_epub_continuation(descriptor, remote_path, options)
    if type(descriptor) ~= "table" or type(descriptor.size) ~= "number"
        or type(options) ~= "table" then return false end
    return valid_epub_continuation(options.continuation, descriptor,
        remote_path, options) ~= nil
end

function ArchivePages:_inspect_epub(descriptor, entries, remote_path, options)
    local resumed = options and options.continuation
    local manifest, manifest_images, manifest_cover, spine, pages
    if resumed then
        pages = valid_epub_continuation(resumed, descriptor, remote_path, options)
        if not pages then return nil, "epub_continuation_invalid" end
        entries = resumed.entries
        manifest, manifest_images, manifest_cover, spine = resumed.manifest,
            resumed.manifest_images, resumed.manifest_cover, resumed.spine
    end
    local by_name = entry_map(entries)
    if not resumed then
    if by_name["META-INF/encryption.xml"] ~= nil then return nil, "epub_drm" end
    local container_entry = by_name["META-INF/container.xml"]
    if type(container_entry) ~= "table" then return nil, "epub_container_missing" end
    local container, container_error = self:_read_metadata(container_entry, descriptor)
    if not container then return nil, container_error end
    local container_elements = xml_elements(container)
    if not container_elements then return nil, "epub_not_image_book" end

    local opf_path
    for _, element in ipairs(container_elements) do
        if element.name == "rootfile" and element.attributes["full-path"] then
            if opf_path then return nil, "epub_not_image_book" end
            opf_path = resolve_path("", element.attributes["full-path"])
        end
    end
    if not opf_path then return nil, "epub_not_image_book" end
    local opf_entry = by_name[opf_path]
    if type(opf_entry) ~= "table" then return nil, "epub_not_image_book" end
    local opf, opf_error = self:_read_metadata(opf_entry, descriptor)
    if not opf then return nil, opf_error end
    local opf_elements = xml_elements(opf)
    if not opf_elements then return nil, "epub_not_image_book" end

    local package, manifest_element, spine_element
    for _, element in ipairs(opf_elements) do
        if element.name == "package" and not element.parent then
            if package then return nil, "epub_not_image_book" end
            package = element
        end
    end
    if not package then return nil, "epub_not_image_book" end
    for _, element in ipairs(opf_elements) do
        if element.parent == package and element.name == "manifest" then
            if manifest_element then return nil, "epub_not_image_book" end
            manifest_element = element
        elseif element.parent == package and element.name == "spine" then
            if spine_element then return nil, "epub_not_image_book" end
            spine_element = element
        end
    end
    if not manifest_element or not spine_element then return nil, "epub_not_image_book" end

    manifest, manifest_images, manifest_cover, spine = {}, {}, nil, {}
    for _, element in ipairs(opf_elements) do
        if element.name == "item" and element.parent == manifest_element then
            local id = element.attributes.id
            if not id or manifest[id] ~= nil then return nil, "epub_not_image_book" end
            local path = resolve_path(opf_path, element.attributes.href)
            local media_type = element.attributes["media-type"]
            local lowered_id = tostring(id):lower()
            local lowered_path = tostring(path or ""):lower()
            local properties = tostring(element.attributes.properties or ""):lower()
            local is_cover = properties:find("cover-image", 1, true) ~= nil
                or lowered_id:find("cover", 1, true) ~= nil
                or lowered_path:match("^cover[^/]*$") ~= nil
                or lowered_path:match("/cover[^/]*$") ~= nil
                or lowered_path:match("^titlepage[^/]*$") ~= nil
                or lowered_path:match("/titlepage[^/]*$") ~= nil
            manifest[id] = { path = path, media_type = media_type,
                is_cover = is_cover }
            if path and EPUB_IMAGE_TYPES[element.attributes["media-type"]] then
                manifest_images[path] = true
                if is_cover and not manifest_cover then manifest_cover = path end
            end
        elseif element.name == "itemref" and element.parent == spine_element then
            spine[#spine + 1] = element.attributes.idref
        elseif element.name == "itemref" then
            return nil, "epub_not_image_book"
        end
    end
    if #spine == 0 then return nil, "epub_not_image_book" end
    end

    local page_limit = options and tonumber(options.page_limit)
    if page_limit then page_limit = math.max(1, math.min(MAX_ENTRIES, math.floor(page_limit))) end
    pages = pages or {}
    -- A spine may legitimately display the same image more than once (e.g.
    -- two Calibre cover wrappers). Reading pages need independent cache keys;
    -- ZIP entry descriptors must remain unchanged for continuation validation.
    local seen_images = {}
    for _, page in ipairs(pages) do seen_images[page.archive_entry_name] = true end
    local first = resumed and options.start_page or 1
    for position = first, #spine do
        local idref = spine[position]
        local item = idref and manifest[idref]
        if not item or not item.path then return nil, "epub_not_image_book" end
        local image_path
        if EPUB_IMAGE_TYPES[item.media_type] then
            image_path = item.path
        elseif item.media_type == "application/xhtml+xml" then
            local xhtml_entry = by_name[item.path]
            if type(xhtml_entry) ~= "table" then return nil, "epub_not_image_book" end
            local xhtml, xhtml_error = self:_read_metadata(xhtml_entry, descriptor)
            if not xhtml then return nil, xhtml_error end
            local cover_candidate = item.is_cover == true
            if not cover_candidate and xhtml:lower():find("<?xml-stylesheet", 1, true) then
                return nil, "epub_not_image_book"
            end
            if cover_candidate and xhtml:lower():find("<?xml-stylesheet", 1, true) then
                -- luxl may omit leading punctuation in attribute values. Read
                -- the complete quoted PI href before applying path validation.
                local valid = true
                local without_stylesheets = xhtml:gsub("<%?xml%-stylesheet(%s.-)%?>", function(attributes)
                    local href, position = nil, 1
                    while position <= #attributes and not attributes:sub(position):match("^%s*$") do
                        local first, last, name, quote, value = attributes:find(
                            "^%s+([%w_:.-]+)%s*=%s*([\"'])(.-)%2", position)
                        if not first then valid = false; break end
                        if name:lower() == "href" then
                            if href then valid = false end
                            href = value
                        end
                        position = last + 1
                    end
                    -- Do not guess at XML entity decoding for an ignored
                    -- resource. Percent escapes still use resolve_path's rules.
                    if not href or href:find("&", 1, true) or href:match("^%s")
                        or not resolve_path(item.path, href) then valid = false end
                    return ""
                end)
                if not valid or without_stylesheets:lower():find("<?xml-stylesheet", 1, true) then
                    return nil, "epub_not_image_book"
                end
            end
            local elements = xml_elements(xhtml)
            if not elements then return nil, "epub_not_image_book" end
            if xhtml:lower():find("background-image", 1, true)
                or xhtml:lower():find("background%s*:")
                or xhtml:lower():find("url%s*%(")
                or xhtml:lower():find("@import", 1, true) then
                return nil, "epub_not_image_book"
            end
            local html, body, candidates, has_display_image = nil, nil, {}, false
            local function add_candidate(reference)
                if type(reference) ~= "string" or reference == ""
                    or reference:match("^[%a][%w+.-]*:")
                    or reference:sub(1, 2) == "//" then
                    return nil
                end
                local candidate = resolve_path(item.path, reference)
                if not candidate or not manifest_images[candidate] then return nil end
                candidates[candidate] = true
                return true
            end
            for _, element in ipairs(elements) do
                local svg_ancestor = element.parent
                while svg_ancestor and svg_ancestor.name ~= "svg" do
                    svg_ancestor = svg_ancestor.parent
                end
                if EPUB_ACTIVE_ELEMENTS[element.name] or element.attributes.background
                    or (not cover_candidate and (EPUB_DRAWING_ELEMENTS[element.name]
                        or (svg_ancestor and not EPUB_SIMPLE_SVG_ELEMENTS[element.name]))) then
                    return nil, "epub_not_image_book"
                end
                if element.name == "html" and not element.parent then
                    if html then return nil, "epub_not_image_book" end
                    html = element
                elseif element.name == "body" then
                    if body or element.parent ~= html then
                        return nil, "epub_not_image_book"
                    end
                    body = element
                end
                local attributes = element.attributes
                for _, key in ipairs({ "src", "href", "xlink:href" }) do
                    local reference = attributes[key]
                    if reference and (reference:match("^%s*[%a][%w+.-]*:")
                        or reference:match("^%s*//")) then
                        return nil, "epub_not_image_book"
                    end
                end
                if element.name == "link" and attributes.href then
                    if not resolve_path(item.path, attributes.href) then
                        return nil, "epub_not_image_book"
                    end
                elseif element.name == "img" or element.name == "image"
                    or element.name == "source" then
                    local ancestor, inside_body, inside_svg = element.parent, false, false
                    while ancestor do
                        if ancestor == body then inside_body = true end
                        if ancestor.name == "svg" then inside_svg = true end
                        ancestor = ancestor.parent
                    end
                    if not inside_body or (element.name == "image" and not inside_svg) then
                        return nil, "epub_not_image_book"
                    end
                    local has_reference = false
                    for _, key in ipairs({ "src", "href", "xlink:href" }) do
                        if attributes[key] then
                            if not add_candidate(attributes[key]) then return nil, "epub_not_image_book" end
                            has_reference = true
                        end
                    end
                    if attributes.srcset then
                        for part in (attributes.srcset .. ","):gmatch("(.-),") do
                            local reference = part:match("^%s*(%S+)")
                            if not add_candidate(reference) then return nil, "epub_not_image_book" end
                            has_reference = true
                        end
                    end
                    if not has_reference then return nil, "epub_not_image_book" end
                    if element.name ~= "source" then has_display_image = true end
                end
            end
            if not html or not body then return nil, "epub_not_image_book" end
            local count = 0
            for candidate in pairs(candidates) do
                image_path, count = candidate, count + 1
            end
            if count > 0 and not has_display_image then return nil, "epub_not_image_book" end
            if count > 1 then return nil, "epub_not_image_book" end
            if count == 0 and cover_candidate then image_path = manifest_cover end
            if not image_path or not manifest_images[image_path] then
                return nil, "epub_not_image_book"
            end
        else
            return nil, "epub_not_image_book"
        end
        local image = by_name[image_path]
        if type(image) ~= "table" or image.archive_size > MAX_ENTRY_SIZE then
            return nil, "epub_not_image_book"
        end
        if image.archive_method ~= 0 and image.archive_method ~= 8 then
            if not self:_archive_stream_available() then return nil, "zip_unsupported_method" end
            image = as_libarchive_page(image)
        end
        local page = {}
        for key, value in pairs(image) do page[key] = value end
        if seen_images[image.archive_entry_name] then
            page.archive_spine_position = position
            page.path = image.path .. "/spine/" .. position
        end
        seen_images[image.archive_entry_name] = true
        pages[#pages + 1] = page
        if options and type(options.on_progress) == "function"
            and (not resumed or #pages <= 20 or #pages % 5 == 0) then
            local index = BookIndex.from_items({})
            index.items = pages
            local ok, continued = pcall(options.on_progress, index, #spine)
            if not ok or continued == false then return nil, "archive_progress_failed" end
        end
        if page_limit and #pages >= page_limit then break end
    end

    local index = BookIndex.from_items({})
    index.items = pages
    local continuation
    if #pages < #spine and options and type(options.source_version) == "string"
        and type(options.generation) == "string" then
        continuation = { version = 1, source_version = options.source_version,
            generation = options.generation, source_size = descriptor.size,
            remote_path = remote_path, entries = entries, manifest = manifest,
            manifest_images = manifest_images, manifest_cover = manifest_cover,
            spine = spine, pages = index:to_table(), next_cursor = #pages + 1 }
    end
    return { index = index, layout = "archive_images",
        incomplete = #pages < #spine, total_pages = #spine,
        continuation = continuation }
end

function ArchivePages:_validate_output(entry, target)
    local input = self:_open(target, "rb")
    if not input then return nil, "zip_extract_failed" end
    local crc, size = 4294967295, 0
    while true do
        local ok, bytes = pcall(input.read, input, COPY_BYTES)
        if not ok then close_file(input); return nil, "zip_read_failed" end
        if not bytes then break end
        size = size + #bytes
        if size > MAX_ENTRY_SIZE then close_file(input); return nil, "zip_entry_too_large" end
        crc = crc32_update(crc, bytes)
    end
    if not close_file(input) then return nil, "zip_read_failed" end
    if size ~= entry.size then return nil, "zip_size_mismatch" end
    if crc32_finish(crc) ~= entry.crc32 then return nil, "zip_crc_mismatch" end
    local extension = Formats.extension(entry.name)
    local ok, metadata, probe_error = pcall(self.image_probe.inspect, target, extension)
    if not ok or not metadata then return nil, probe_error or "zip_image_invalid" end
    metadata.size = size
    return metadata
end

local function tar_entry(image)
    if type(image) ~= "table" or image.archive_kind ~= "tar"
        or type(image.archive_entry_name) ~= "string" then
        return nil, "tar_entry_invalid"
    end
    local offset = tonumber(image.archive_entry_offset)
    local size = tonumber(image.archive_size)
    local source_size = tonumber(image.archive_source_size)
    if not offset or not size or not source_size
        or offset < 0 or size < 0 or source_size < 1
        or offset + size > source_size or size > MAX_ENTRY_SIZE then
        return nil, "tar_entry_invalid"
    end
    return { offset = math.floor(offset), size = math.floor(size),
        source_size = math.floor(source_size), name = image.archive_entry_name }
end

function ArchivePages:_extract_tar(image, read_at, target)
    local entry, entry_error = tar_entry(image)
    if not entry then return nil, entry_error end
    local copied, copy_error = self:_copy_entry(read_at, entry.offset, entry.size, target)
    if not copied then pcall(self.remove_file, target); return nil, copy_error end
    local input = self:_open(target, "rb")
    if not input then pcall(self.remove_file, target); return nil, "tar_read_failed" end
    local size = 0
    while true do
        local ok, bytes = pcall(input.read, input, COPY_BYTES)
        if not ok then close_file(input); pcall(self.remove_file, target); return nil, "tar_read_failed" end
        if not bytes then break end
        size = size + #bytes
        if size > MAX_ENTRY_SIZE then close_file(input); pcall(self.remove_file, target); return nil, "tar_entry_too_large" end
    end
    if not close_file(input) or size ~= entry.size then
        pcall(self.remove_file, target); return nil, "tar_size_mismatch"
    end
    local extension = Formats.extension(entry.name)
    local ok, metadata, probe_error = pcall(self.image_probe.inspect, target, extension)
    if not ok or not metadata then pcall(self.remove_file, target); return nil, probe_error or "tar_image_invalid" end
    metadata.size = size
    return metadata
end

function ArchivePages:_extract_libarchive_entry(image, read_at, target, max_bytes)
    if type(image) ~= "table" or image.archive_kind ~= "libarchive"
        or type(read_at) ~= "function" or type(target) ~= "string" then
        return nil, "archive_entry_invalid"
    end
    local source_size = tonumber(image.archive_source_size)
    local ordinal = tonumber(image.archive_entry_ordinal)
    local name = tostring(image.archive_entry_name or "")
    local size = tonumber(image.archive_size)
    if not source_size or source_size < 1 or not ordinal or ordinal < 1
        or ordinal ~= math.floor(ordinal) or name == "" or not size
        or size < 0 or size > MAX_ENTRY_SIZE then
        return nil, "archive_entry_invalid"
    end
    local zip_fallback = image.archive_format == "zip" or image.archive_format == "cbz"
        or image.archive_format == "epub"
    local function native_error(reason)
        if zip_fallback and (reason == "libarchive_unavailable" or reason == "libarchive_open_failed"
            or reason == "libarchive_callback_unavailable" or reason == "libarchive_reader_unavailable"
            or reason == "libarchive_next_unavailable"
            or reason == "archive_read_failed" or reason == "archive_header_failed"
            or reason == "archive_skip_failed" or reason == "libarchive_extract_unavailable") then
            return "zip_unsupported_method"
        end
        return reason
    end
    if not self:_archive_stream_available() then return nil, native_error("libarchive_unavailable") end
    local stream = self.archive_stream
    local opened, reader, open_error = pcall(stream.open, stream, {
        size = source_size, read_at = read_at, format = image.archive_format })
    if not opened or not reader then return nil, native_error(open_error or "libarchive_open_failed") end
    local function next_entry()
        if type(stream.next) == "function" then return stream:next(reader) end
        if type(reader.next) == "function" then return reader:next() end
        return nil, "libarchive_next_unavailable"
    end
    local target_entry, error_code
    local ok, caught = pcall(function()
        for _ = 1, ordinal do
            local entry, next_error = next_entry()
            if not entry then error_code = next_error or "archive_entry_missing"; break end
            target_entry = entry
        end
        if not error_code and (not target_entry or target_entry.index ~= ordinal
            or tostring(target_entry.name or "") ~= name or target_entry.mode ~= "file") then
            error_code = "archive_entry_mismatch"
        end
        if not error_code then
            local extracted, extract_error
            if type(stream.extract_current) == "function" then
                extracted, extract_error = stream:extract_current(reader, target, max_bytes)
            elseif type(reader.extract_current) == "function" then
                extracted, extract_error = reader:extract_current(target, max_bytes)
            else
                extract_error = "libarchive_extract_unavailable"
            end
            if not extracted then error_code = extract_error or "archive_extract_failed" end
        end
    end)
    local closed, close_result
    if type(stream.close) == "function" then closed, close_result = pcall(stream.close, stream, reader)
    elseif type(reader.close) == "function" then closed, close_result = pcall(reader.close, reader) end
    if not ok then
        pcall(self.remove_file, target)
        return nil, zip_fallback and "zip_unsupported_method" or "archive_read_failed"
    end
    if error_code then
        pcall(self.remove_file, target)
        return nil, native_error(error_code)
    end
    if not closed or close_result == false then
        pcall(self.remove_file, target)
        return nil, "archive_read_failed"
    end
    return true
end

function ArchivePages:_extract_libarchive(image, read_at, target)
    local extracted, extract_error = self:_extract_libarchive_entry(image, read_at, target)
    if not extracted then return nil, extract_error end
    if image.archive_format == "zip" or image.archive_format == "cbz"
        or image.archive_format == "epub" then
        local metadata, validation_error = self:_validate_output({
            name = image.archive_entry_name, size = image.archive_size,
            crc32 = image.archive_crc32,
        }, target)
        if not metadata then pcall(self.remove_file, target); return nil, validation_error end
        return metadata
    end
    local extension = Formats.extension(image.archive_entry_name)
    local inspected, metadata, probe_error = pcall(self.image_probe.inspect, target, extension)
    if not inspected or not metadata then
        pcall(self.remove_file, target)
        return nil, probe_error or "archive_image_invalid"
    end
    metadata.size = image.archive_size
    return metadata
end

function ArchivePages:_extract(image, read_at, target)
    if image and image.archive_kind == "libarchive" then
        return self:_extract_libarchive(image, read_at, target)
    end
    if image and image.archive_kind == "tar" then
        return self:_extract_tar(image, read_at, target)
    end
    local entry, entry_error = zip_entry(image)
    if not entry then return nil, entry_error end
    local data_offset, offset_error = self:_local_data_offset(entry, read_at)
    if not data_offset then return nil, offset_error end
    local extracted, extract_error
    if entry.method == 0 then
        extracted, extract_error = self:_copy_entry(read_at, data_offset, entry.compressed_size, target)
    else
        extracted, extract_error = self:_extract_deflated(entry, read_at, data_offset, target)
    end
    pcall(self.remove_file, target .. ".zipwork")
    if not extracted then pcall(self.remove_file, target); return nil, extract_error end
    local metadata, validation_error = self:_validate_output(entry, target)
    if not metadata then pcall(self.remove_file, target); return nil, validation_error end
    return metadata
end

function ArchivePages:_protected_extract(image, read_at, target)
    local ok, metadata, error_code = pcall(self._extract, self, image, read_at, target)
    pcall(self.remove_file, target .. ".zipwork")
    if not ok then
        pcall(self.remove_file, target)
        return nil, "zip_extract_failed"
    end
    return metadata, error_code
end

function ArchivePages:extract_remote(image, read_at, target)
    if type(read_at) ~= "function" or type(target) ~= "string" or target == "" then
        return nil, "zip_read_failed"
    end
    return self:_protected_extract(image, read_at, target)
end

function ArchivePages:extract_local(image, target)
    local source_path = type(image) == "table" and image.archive_local_path
    if type(source_path) ~= "string" or source_path == "" then return nil, "zip_read_failed" end
    local source = self:_open(source_path, "rb")
    if not source or type(source.seek) ~= "function" then
        if source then close_file(source) end
        return nil, "zip_read_failed"
    end
    local function read_at(offset, count)
        local ok = pcall(source.seek, source, "set", offset)
        if not ok then return nil end
        local read_ok, bytes = pcall(source.read, source, count)
        return read_ok and bytes or nil
    end
    local metadata, error_code = self:_protected_extract(image, read_at, target)
    close_file(source)
    return metadata, error_code
end

return ArchivePages
