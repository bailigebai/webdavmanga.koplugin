local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function be16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function be32(value)
    return string.char(math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 256) % 256,
        value % 256)
end

local function replace_at(value, offset, bytes)
    return value:sub(1, offset) .. bytes .. value:sub(offset + #bytes + 1)
end

local function jpeg(width, height, size)
    local header = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
        math.floor(height / 256), height % 256,
        math.floor(width / 256), width % 256, 1, 1, 0x11, 0)
    return header .. string.rep("J", math.max(0, size - #header))
end

local sample = assert(io.open(TEST_PLUGIN_ROOT
    .. "/resources/format_samples/grayscale.png", "rb"))
local png = sample:read("*a")
sample:close()

local function build_mobi(image_count, options)
    options = options or {}
    local record0 = string.rep("\0", 300)
    record0 = replace_at(record0, 4, be32(10))
    record0 = replace_at(record0, 8, be16(1))
    record0 = replace_at(record0, 16, "MOBI")
    record0 = replace_at(record0, 20, be32(232))
    record0 = replace_at(record0, 108, be32(2))
    if options.fixed ~= false then
        record0 = replace_at(record0, 128, be32(0x40))
        record0 = replace_at(record0, 248,
            "EXTH" .. be32(24) .. be32(1) .. be32(122) .. be32(12) .. "true")
    end

    local records = { record0, "TEXT" }
    for index = 1, image_count do
        local size = 70 * 1024 + index
        local image
        if options.nonimages_after_first and index > 1 then
            image = "FONT" .. string.rep("F", 60)
        else
            image = index == 2 and png or jpeg(800, 1200, size)
        end
        records[#records + 1] = image
            .. string.rep("\0", math.max(0, size - #image))
    end
    local fcis_index = #records
    if options.fdst then
        record0 = replace_at(record0, 36, be32(options.mobi_version or 8))
        record0 = replace_at(record0, 192, be32(fcis_index))
        record0 = replace_at(record0, 196, be32(options.flow_count or 3))
        records[#records + 1] = "FDST" .. string.rep("\0", 32)
        fcis_index = #records
    end
    records[#records + 1] = "FCIS"
    local flis_index = #records
    records[#records + 1] = "FLIS"
    if options.zero_length_tail then
        records[#records + 1] = ""
        records[#records + 1] = ""
        records[#records + 1] = "BOUNDARY"
    end
    record0 = replace_at(record0, 200, be32(fcis_index))
    record0 = replace_at(record0, 204, be32(1))
    record0 = replace_at(record0, 208, be32(flis_index))
    record0 = replace_at(record0, 212, be32(1))
    records[1] = record0

    local first_offset = 2048
    local offsets, cursor = {}, first_offset
    for index, record in ipairs(records) do
        offsets[index] = cursor
        cursor = cursor + #record
    end
    local header = replace_at(string.rep("\0", 78), 60, "BOOKMOBI")
    header = replace_at(header, 76, be16(#records))
    local record_table = ""
    for _, offset in ipairs(offsets) do
        record_table = record_table .. be32(offset) .. string.rep("\0", 4)
    end
    return header .. record_table
        .. string.rep("\0", first_offset - 78 - #record_table)
        .. table.concat(records), offsets, records
end

local blob, offsets, records = build_mobi(120)
local range_calls, inspected_second_page = 0, false
local RemoteStream = require("webdavmanga.remote_stream")
local stream = assert(RemoteStream:new{
    size = #blob,
    block_size = 64 * 1024,
    max_blocks = 8,
    read_range = function(first, last)
        range_calls = range_calls + 1
        return blob:sub(first + 1, last + 1), {
            ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, #blob),
        }
    end,
})

local MobiPages = require("webdavmanga.mobi_pages")
local book, error_message = MobiPages:new():inspect_remote({
    size = #blob,
    read_at = function(offset, count)
        if offset >= offsets[4] then inspected_second_page = true end
        return stream:read_at(offset, count)
    end,
}, "/Books/comic.mobi")

expect(book ~= nil, "image MOBI should open from a bounded remote index: "
    .. tostring(error_message))
expect(book.index:count() == 120,
    "FCIS and FLIS records must not become comic pages")
expect(range_calls <= 3,
    "opening a 120-page MOBI must not issue one Range request per page: "
        .. tostring(range_calls))
expect(inspected_second_page == false,
    "opening must enter after validating the first page, before reading page two")

for _, options in ipairs({{fdst=true}, {fdst=true,flow_count=1}, {fdst=true,mobi_version=6}}) do
    local bytes = build_mobi(120, options)
    local inspected = assert(MobiPages:new():inspect_remote({size=#bytes,
        read_at=function(offset,count) return bytes:sub(offset+1,offset+count) end}, "/comic.azw3"))
    local valid_fdst = options.flow_count ~= 1 and options.mobi_version ~= 6
    expect(inspected.index:count() == (valid_fdst and 120 or 121),
        "KF8 multi-flow FDST must be excluded; old/single-flow fields are not FDST boundaries")
    expect(inspected.index:get(120).mobi_record == 121,
        "FDST boundary retains the actual final image record")
end
expect(book.index:get(1).format == "jpeg"
    and book.index:get(1).width == 800 and book.index:get(1).height == 1200,
    "the first page must be validated before the reader opens")
expect(book.index:get(2).name:match("%.jpg$") ~= nil,
    "lazy pages need an image extension so existing preloading can request them")
expect(book.index:get(2).format == nil and book.index:get(2).width == nil,
    "later pages must remain unprobed until they are requested")

local zero_length_blob = build_mobi(4, { zero_length_tail = true })
local zero_length_book, zero_length_error = MobiPages:new():inspect_remote({
    size = #zero_length_blob,
    read_at = function(offset, count)
        return zero_length_blob:sub(offset + 1, offset + count)
    end,
}, "/Books/zero-length-records.mobi")
expect(zero_length_book and zero_length_book.index:count() == 4,
    "valid zero-length MOBI records must not reject image streaming: "
        .. tostring(zero_length_error))

local target_path = os.tmpname()
local extract_reads = 0
local metadata, extract_error = MobiPages:new():extract_remote(
    book.index:get(2), function(offset, count)
        extract_reads = extract_reads + 1
        return blob:sub(offset + 1, offset + count)
    end, target_path)
expect(metadata and not extract_error and metadata.format == "png"
    and metadata.width == 8 and metadata.height == 12,
    "downloading a lazy page must detect its real format and dimensions")
local extracted = assert(io.open(target_path, "rb"))
local extracted_bytes = extracted:read("*a")
extracted:close()
os.remove(target_path)
expect(extracted_bytes == records[4],
    "lazy extraction must copy exactly the requested MOBI record")
expect(extract_reads == 2,
    "format detection must reuse downloaded bytes instead of issuing another read")

local unmarked_blob, unmarked_offsets = build_mobi(120, { fixed = false })
local unmarked_reads, unmarked_second_page = 0, false
local unmarked_book, unmarked_error = MobiPages:new():inspect_remote({
    size = #unmarked_blob,
    read_at = function(offset, count)
        unmarked_reads = unmarked_reads + 1
        if offset >= unmarked_offsets[4] then unmarked_second_page = true end
        return unmarked_blob:sub(offset + 1, offset + count)
    end,
}, "/Books/old-comic.mobi")
expect(unmarked_book and not unmarked_error and unmarked_book.index:count() == 120,
    "an image-oriented MOBI without a fixed-layout marker should stream")
expect(unmarked_reads <= 4 and unmarked_second_page == false,
    "an unmarked image MOBI must open after validating only its first page")

local cached_reads, cached_second_page = 0, false
local cached_parser = MobiPages:new{
    open_file = function()
        local position = 0
        return {
            seek = function(_self, whence, offset)
                if whence == "end" then position = #blob; return position end
                if whence ~= "set" then return nil end
                position = offset
                if position >= offsets[4] then cached_second_page = true end
                return position
            end,
            read = function(_self, count)
                cached_reads = cached_reads + 1
                local value = blob:sub(position + 1, position + count)
                position = position + #value
                return value
            end,
            close = function() end,
        }
    end,
}
local cached_book = type(cached_parser.inspect_lazy) == "function"
    and cached_parser:inspect_lazy("/cache/comic.mobi", "/Books/comic.mobi")
expect(cached_book and cached_book.index:count() == 120,
    "a completed MOBI cache should use the lazy image index")
expect(cached_reads <= 6 and cached_second_page == false,
    "opening a completed MOBI cache must not scan its later pages")

local cached_source_path, cached_target_path = os.tmpname(), os.tmpname()
local cached_source = assert(io.open(cached_source_path, "wb"))
assert(cached_source:write(blob))
cached_source:close()
local local_parser = MobiPages:new()
local local_book = assert(local_parser:inspect_lazy(
    cached_source_path, "/Books/comic.mobi"))
local local_metadata, local_extract_error = local_parser:extract(
    local_book.index:get(2), cached_target_path)
expect(local_metadata and not local_extract_error
    and local_metadata.format == "png"
    and local_metadata.width == 8 and local_metadata.height == 12
    and local_metadata.extension_mismatch == true,
    "a lazy page from a completed MOBI cache must detect its real image format")
local cached_target = assert(io.open(cached_target_path, "rb"))
local cached_target_bytes = cached_target:read("*a")
cached_target:close()
os.remove(cached_source_path)
os.remove(cached_target_path)
expect(cached_target_bytes == records[4],
    "local lazy extraction must copy exactly the requested MOBI record")

local used_lazy_inspect, opened_cached_book = false, false
local DocumentBridge = require("webdavmanga.document_bridge")
local bridge = DocumentBridge:new{
    cache = {
        key_for = function() return "cached-mobi" end,
        lookup_record = function()
            return "/cache/comic.mobi", { kind = "document" }
        end,
    },
    client_factory = function() return {} end,
    mobi_pages = {
        inspect_lazy = function(_self, path, remote_path)
            used_lazy_inspect = path == "/cache/comic.mobi"
                and remote_path == "/Books/comic.mobi"
            return cached_book
        end,
        inspect = function() error("completed MOBI cache scanned eagerly") end,
    },
    open_reader = function(context)
        opened_cached_book = context.chapter_index == cached_book.index
        return true
    end,
}
expect(bridge:open({
    name = "comic.mobi", path = "/Books/comic.mobi",
    file_kind = "document", connection = {},
}, {}) == true and used_lazy_inspect and opened_cached_book,
    "a cached MOBI must enter the manga reader through lazy inspection")

local misleading_blob = build_mobi(3, {
    fixed = false, nonimages_after_first = true,
})
local misleading_book, misleading_error = MobiPages:new():inspect_remote({
    size = #misleading_blob,
    read_at = function(offset, count)
        return misleading_blob:sub(offset + 1, offset + count)
    end,
}, "/Books/text-with-cover.mobi")
expect(misleading_book == nil and misleading_error == "not_image_mobi",
    "a non-fixed text MOBI with a cover and non-image resources must fall back")

local loader_target = os.tmpname()
local published_record, ready_path, loader_error
local Loader = require("webdavmanga.loader")
local loader = Loader:new{
    client_factory = function()
        return {
            read_range = function(_self, _path, first, last)
                return blob:sub(first + 1, last + 1), {
                    ["Content-Range"] = ("bytes %d-%d/%d"):format(
                        first, last, #blob),
                }
            end,
        }
    end,
    cache = {
        limit_bytes = 1024 * 1024,
        key_for = function(_self, _identity, path) return path end,
        lookup = function() return nil end,
        paths_for = function() return "/cache/page.jpg", loader_target end,
        publish = function(_self, record, part)
            published_record = record
            os.remove(part)
            if record.extension_mismatch == true and record.format == "png" then
                return "/cache/page.png"
            end
            return nil, "unvalidated"
        end,
        discard_part = function() os.remove(loader_target); return true end,
        total_size = function() return 0 end,
        evict = function() return 0 end,
    },
    async = { run = function(worker, done)
        local ok, result = pcall(worker)
        done(ok, result, ok and nil or result, {})
        return { cancel = function() end }
    end },
    mobi_pages = MobiPages:new(),
    error_reporter = { guard = function(_self, _stage, callback)
        return callback()
    end },
}
loader:request("reader", book.index:get(2), {
    on_ready = function(path) ready_path = path end,
    on_error = function(error_value) loader_error = error_value end,
})
expect(ready_path == "/cache/page.png" and loader_error == nil
    and published_record and published_record.extension == "jpg"
    and published_record.extension_mismatch == true,
    "mixed-format lazy pages must survive Loader and cache publication")

print(("rebuild_0370_mobi_fast_stream_spec: %d checks"):format(checks))
