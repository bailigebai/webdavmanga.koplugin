local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function zip_fixture(options)
    options = options or {}
    local entries = options.entries or {
        { name = "002.png", method = 8, data = "deflated" },
        { name = "chapter/", method = 0, data = "" },
        { name = "notes.txt", method = 0, data = "notes" },
        { name = "001.jpg", method = 0, data = "jpeg" },
    }
    local local_parts, central_parts, offset = {}, {}, 0
    for ordinal, entry in ipairs(entries) do
        local name, data = entry.name, entry.data or ""
        local flags, method = entry.flags or 0, entry.method or 0
        local compressed = entry.compressed_size or #data
        local uncompressed = entry.size or #data
        local local_header = "PK\003\004" .. le16(20) .. le16(flags) .. le16(method)
            .. le16(0) .. le16(0) .. le32(0) .. le32(compressed)
            .. le32(uncompressed) .. le16(#name) .. le16(0) .. name .. data
        local_parts[#local_parts + 1] = local_header
        central_parts[#central_parts + 1] = "PK\001\002" .. le16(20) .. le16(20)
            .. le16(flags) .. le16(method) .. le16(0) .. le16(0) .. le32(0)
            .. le32(entry.central_compressed_size or compressed)
            .. le32(entry.central_size or uncompressed) .. le16(#name) .. le16(0)
            .. le16(0) .. le16(entry.disk_start or 0) .. le16(0) .. le32(0)
            .. le32(entry.local_offset or offset) .. name
        offset = offset + #local_header
    end
    local local_bytes, central = table.concat(local_parts), table.concat(central_parts)
    local count = options.entry_count or #entries
    local central_size = options.central_size or #central
    local eocd = "PK\005\006" .. le16(options.disk or 0) .. le16(options.start_disk or 0)
        .. le16(options.disk_entries or count) .. le16(count) .. le32(central_size)
        .. le32(options.central_offset or #local_bytes) .. le16(0)
    return local_bytes .. central .. eocd .. (options.trailer or "")
end

local fixture = zip_fixture()
local requests = {}
local function read_fixture(offset, count)
    requests[#requests + 1] = { first = offset, count = count }
    return fixture:sub(offset + 1, offset + count)
end

local fake_probe = { inspect_bytes = function() error("ZIP indexing must not probe page data") end }
local ArchivePages = require("webdavmanga.archive_pages")
local book, err = ArchivePages:new{ image_probe = fake_probe }
    :inspect_remote({ size = #fixture, read_at = read_fixture }, "cbz", "/book.cbz")
expect(err == nil and book.index:count() == 2, "CBZ image index expected")
expect(book.index:get(1).archive_entry_name == "001.jpg", "natural order expected")
expect(book.index:get(2).archive_entry_name == "002.png", "deflated image expected")
expect(book.index:get(1).archive_method == 0 and book.index:get(2).archive_method == 8,
    "stored and deflated methods expected")
expect(book.layout == "archive_images" and book.index:find("/book.cbz#zip/4") == 1,
    "book index must retain stable archive paths")
expect(#book.index:window(2, 1) == 2, "book index window expected")
expect(requests[1].first >= #fixture - 65557, "EOCD must be read from the tail")

local plain_zip, plain_zip_error = ArchivePages:new{ image_probe = fake_probe }
    :inspect_remote({ size = #fixture, read_at = read_fixture }, "zip", "/book.zip")
expect(plain_zip_error == nil and plain_zip and plain_zip.layout == "archive_images"
    and plain_zip.index:count() == 2,
    "plain ZIP comic archives must use the same bounded Range index as CBZ")
expect(plain_zip.index:get(1).path == "/book.zip#zip/4",
    "plain ZIP page paths must retain the ZIP stream namespace")

local function inspect_error(bytes)
    return ArchivePages:new():inspect_remote({
        size = #bytes,
        read_at = function(offset, count) return bytes:sub(offset + 1, offset + count) end,
    }, "cbz", "/book.cbz")
end

local encrypted_book, encrypted_error = inspect_error(zip_fixture{
    entries = { { name = "001.jpg", flags = 1, data = "jpeg" } },
})
expect(encrypted_book == nil and encrypted_error == "zip_encrypted",
    "encrypted ZIP entries must be rejected")

local zip64_book, zip64_error = inspect_error(zip_fixture{ entry_count = 65535 })
expect(zip64_book == nil and zip64_error == "zip64_unsupported",
    "ZIP64 sentinels must be rejected")

local missing_book, missing_error = inspect_error(zip_fixture{
    trailer = string.rep("\0", 65557),
})
expect(missing_book == nil and missing_error == "zip_eocd_missing",
    "an EOCD outside the final 65557 bytes must be rejected")

local many_book, many_error = inspect_error(zip_fixture{ entry_count = 20001 })
expect(many_book == nil and many_error == "zip_directory_too_large",
    "ZIPs with more than 20000 entries must be rejected")

local large_book, large_error = inspect_error(zip_fixture{
    central_size = 8 * 1024 * 1024 + 1,
})
expect(large_book == nil and large_error == "zip_directory_too_large",
    "ZIP central directories over 8 MiB must be rejected")

local max_name = string.rep("n", 4092) .. ".jpg"
local max_name_book, max_name_error = inspect_error(zip_fixture{
    entries = { { name = max_name, data = "jpeg" } },
})
expect(max_name_book and max_name_error == nil and max_name_book.index:count() == 1,
    "a 4096-byte ZIP filename must remain supported")

local long_name_book, long_name_error = inspect_error(zip_fixture{
    entries = { { name = max_name .. "x", data = "jpeg" } },
})
expect(long_name_book == nil and long_name_error == "zip_name_too_long",
    "ZIP filenames over 4096 bytes must be rejected")

local huge_page_book, huge_page_error = inspect_error(zip_fixture{
    entries = { { name = "001.jpg", size = 128 * 1024 * 1024 + 1, data = "jpeg" } },
})
expect(huge_page_book == nil and huge_page_error == "zip_entry_too_large",
    "ZIP pages over 128 MiB after inflation must be rejected")

local split_book, split_error = inspect_error(zip_fixture{
    entries = { { name = "001.jpg", disk_start = 1, data = "jpeg" } },
})
expect(split_book == nil and split_error == "zip_multidisk_unsupported",
    "ZIP entries on another disk must be rejected")

local offset_book, offset_error = inspect_error(zip_fixture{
    entries = { { name = "001.jpg", local_offset = 0x100000, data = "jpeg" } },
})
expect(offset_book == nil and offset_error == "zip_local_offset_invalid",
    "ZIP local offsets outside the local-header area must be rejected")

local function crc32(value)
    local function xor32(left, right)
        local result, place = 0, 1
        for _ = 1, 32 do
            if left % 2 ~= right % 2 then result = result + place end
            left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
        end
        return result
    end
    local crc = 4294967295
    for index = 1, #value do
        crc = xor32(crc, value:byte(index))
        for _ = 1, 8 do
            local low = crc % 2
            crc = math.floor(crc / 2)
            if low == 1 then crc = xor32(crc, 3988292384) end
        end
    end
    return 4294967295 - crc
end

local function extraction_fixture(name, method, data, compressed, flags, local_fields)
    compressed = compressed or data
    flags = flags or 0
    local_fields = local_fields or {}
    local local_name = local_fields.name or name
    local expected_crc = local_fields.expected_crc32
    if expected_crc == nil then expected_crc = crc32(data) end
    local local_crc = local_fields.crc32
    if local_crc == nil then local_crc = expected_crc end
    local local_compressed = local_fields.compressed_size or #compressed
    local local_size = local_fields.size or #data
    local header = "PK\003\004" .. le16(20) .. le16(flags) .. le16(method)
        .. le16(0) .. le16(0) .. le32(local_crc) .. le32(local_compressed) .. le32(local_size)
        .. le16(#local_name) .. le16(0) .. local_name
    return header .. compressed, {
        name = name,
        archive_entry_name = name,
        archive_source_size = #header + #compressed,
        archive_local_offset = 0,
        archive_method = method,
        archive_flags = flags,
        archive_crc32 = expected_crc,
        archive_compressed_size = #compressed,
        archive_size = #data,
    }
end

local files, removed = {}, {}
local function memory_file(path, mode)
    if mode == "wb" then
        local chunks = {}
        return {
            write = function(_, bytes) chunks[#chunks + 1] = bytes; return true end,
            close = function() files[path] = table.concat(chunks); return true end,
        }
    end
    local bytes, position = files[path], 1
    if type(bytes) ~= "string" then return nil end
    return {
        read = function(_, count)
            local value = bytes:sub(position, position + count - 1)
            position = position + #value
            return value ~= "" and value or nil
        end,
        seek = function(_, whence, offset)
            if whence ~= "set" then return nil end
            position = offset + 1
            return offset
        end,
        close = function() return true end,
    }
end
local function extraction_pages(options)
    options = options or {}
    return ArchivePages:new{
        open_file = memory_file,
        remove_file = function(path) removed[path] = true; files[path] = nil; return true end,
        image_probe = {
            inspect = function(path, extension)
                local data = files[path]
                if not data then return nil, "missing" end
                return { format = extension == "jpg" and "jpeg" or extension,
                    width = 1, height = 1 }
            end,
        },
        archiver = options.archiver,
    }
end

local jpeg = "\255\216\255\192\0\11\8\0\1\0\1\1\1\17\0\255\217"
local stored_zip, stored_item = extraction_fixture("001.jpg", 0, jpeg)
local extraction_reads = {}
local stored_pages = extraction_pages()
local stored_metadata, stored_error = stored_pages:extract_remote(stored_item,
    function(offset, count)
        extraction_reads[#extraction_reads + 1] = { offset = offset, count = count }
        return stored_zip:sub(offset + 1, offset + count)
    end, "/cache/stored.jpg")
expect(stored_error == nil and files["/cache/stored.jpg"] == jpeg,
    "stored ZIP entries must be written byte-for-byte")
expect(stored_metadata and stored_metadata.format == "jpeg" and stored_metadata.size == #jpeg,
    "stored ZIP entries must be probed after extraction")
expect(#extraction_reads == 3 and extraction_reads[1].offset == 0
    and extraction_reads[2].offset == 30
    and extraction_reads[3].offset == 30 + #stored_item.archive_entry_name,
    "stored extraction must request only its local header and data")

local budget_data = string.rep("page", 131072)
local budget_zip, budget_item = extraction_fixture("budget.jpg", 0, budget_data,
    nil, 0, { expected_crc32 = 2579109172 })
local budget_started = os.clock()
local budget_metadata, budget_error = extraction_pages():extract_remote(budget_item,
    function(offset, count) return budget_zip:sub(offset + 1, offset + count) end,
    "/cache/budget.jpg")
local budget_elapsed = os.clock() - budget_started
expect(budget_error == nil and budget_metadata and budget_metadata.size == #budget_data,
    "table-driven CRC must preserve ZIP integrity validation")
expect(budget_elapsed < 3,
    ("512 KiB CRC validation exceeded the host budget: %.3fs"):format(budget_elapsed))

local function expect_local_header_rejected(fields, label)
    local bytes, item = extraction_fixture("001.jpg", 0, jpeg, nil, 0, fields)
    local metadata, error_code = extraction_pages():extract_remote(item,
        function(offset, count) return bytes:sub(offset + 1, offset + count) end,
        "/cache/local-header-" .. label .. ".jpg")
    expect(metadata == nil and error_code == "zip_local_header_invalid",
        "local " .. label .. " must match the central directory")
end

expect_local_header_rejected({ name = "002.jpg" }, "name")
expect_local_header_rejected({ crc32 = 0 }, "crc")
expect_local_header_rejected({ compressed_size = #jpeg + 1 }, "compressed-size")
expect_local_header_rejected({ size = #jpeg + 1 }, "uncompressed-size")

local png = "PNG"
local deflated_zip, deflated_item = extraction_fixture("002.png", 8, png, "deflated-png", 8)
local deflated_next_calls = 0
local fake_archiver = { Reader = { new = function()
    return {
        open = function(_, path)
            local work = files[path]
            expect(path == "/cache/deflated.png.zipwork" and work:sub(1, 4) == "PK\003\004"
                and work:find("deflated-png", 1, true) and work:sub(-22, -19) == "PK\005\006"
                and work:byte(7) == 0 and work:byte(8) == 0,
                "deflated extraction must build a complete one-entry ZIP without a data descriptor")
            return true
        end,
        next = function() deflated_next_calls = deflated_next_calls + 1; return true end,
        extractToPath = function(_, key, path)
            if key ~= 1 then return false end
            files[path] = png
            return true
        end,
        close = function() return true end,
    }
end } }
local deflated_metadata, deflated_error = extraction_pages{ archiver = fake_archiver }
    :extract_remote(deflated_item, function(offset, count)
        return deflated_zip:sub(offset + 1, offset + count)
    end, "/cache/deflated.png")
expect(deflated_error == nil and files["/cache/deflated.png"] == png
    and deflated_metadata.format == "png", "deflated ZIP entries must use the archiver")
expect(deflated_next_calls > 0,
    "deflated extraction must enumerate the temporary ZIP before extracting entry one")
expect(removed["/cache/deflated.png.zipwork"] == true,
    "deflated extraction must always remove its temporary ZIP")

local crc_zip, crc_item = extraction_fixture("bad.jpg", 0, jpeg, nil, 8)
crc_item.archive_crc32 = 0
local crc_metadata, crc_error = extraction_pages():extract_remote(crc_item,
    function(offset, count) return crc_zip:sub(offset + 1, offset + count) end,
    "/cache/crc.jpg")
expect(crc_metadata == nil and crc_error == "zip_crc_mismatch"
    and files["/cache/crc.jpg"] == nil, "CRC mismatches must reject and remove output")

local short_metadata, short_error = extraction_pages():extract_remote(stored_item,
    function(offset, count)
        if offset == 0 then return stored_zip:sub(1, 30) end
        return nil
    end, "/cache/short.jpg")
expect(short_metadata == nil and short_error == "zip_read_failed",
    "short Range reads must fail without publishing output")

local oversized = {}
for key, value in pairs(stored_item) do oversized[key] = value end
oversized.archive_size = 128 * 1024 * 1024 + 1
local large_metadata, large_error = extraction_pages():extract_remote(oversized,
    function(offset, count) return stored_zip:sub(offset + 1, offset + count) end,
    "/cache/large.jpg")
expect(large_metadata == nil and large_error == "zip_entry_too_large",
    "oversized ZIP entries must be rejected before extraction")

local unsupported = {}
for key, value in pairs(stored_item) do unsupported[key] = value end
unsupported.archive_method = 12
local method_metadata, method_error = extraction_pages():extract_remote(unsupported,
    function(offset, count) return stored_zip:sub(offset + 1, offset + count) end,
    "/cache/method.jpg")
expect(method_metadata == nil and method_error == "zip_unsupported_method",
    "unsupported ZIP methods must be rejected before extraction")

files["/archives/book.cbz"] = stored_zip
local local_item = {}
for key, value in pairs(stored_item) do local_item[key] = value end
local_item.archive_local_path = "/archives/book.cbz"
local local_metadata, local_error = extraction_pages():extract_local(local_item, "/cache/local.jpg")
expect(local_error == nil and local_metadata.size == #jpeg and files["/cache/local.jpg"] == jpeg,
    "local ZIP entries must use the same bounded extraction path")

removed["/cache/failed.png.zipwork"] = nil
local failed_closed = false
local failed_metadata, failed_error = extraction_pages{ archiver = { Reader = { new = function()
    return {
        open = function() error("archiver unavailable") end,
        close = function() failed_closed = true; return true end,
    }
end } } }:extract_remote(deflated_item, function(offset, count)
    return deflated_zip:sub(offset + 1, offset + count)
end, "/cache/failed.png")
expect(failed_metadata == nil and failed_error == "zip_extract_failed"
    and removed["/cache/failed.png.zipwork"] == true and failed_closed,
    "deflated extraction failures must remove their temporary ZIP")

print(("rebuild_0374_archive_pages_spec: %d checks"):format(checks))
