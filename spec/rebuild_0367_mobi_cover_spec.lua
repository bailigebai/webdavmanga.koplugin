local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local connection = {
    server_url = "http://nas", username = "u", root_path = "/Books",
}
local manga = { name = "book.mobi", path = "/Books/book.mobi", is_file = true }
local chapter = { name = "book.mobi", path = "/Books/book.mobi", is_file = true }
local image = {
    name = "00002.jpg", path = "/Books/book.mobi#mobi/2", is_file = true,
    size = 90000, format = "jpeg", width = 800, height = 1200,
    mobi_remote_path = "/Books/book.mobi", mobi_source_size = 200000,
    mobi_record = 2, mobi_offset = 1234, mobi_size = 90000,
}

-- A streamed MOBI history checkpoint must keep the page metadata needed to
-- re-fetch its synthetic #mobi path when the ordinary page cache is gone.
local Progress = require("webdavmanga.progress")
local stored = {}
local store = {
    readSetting = function(_self, key, fallback) return stored[key] or fallback end,
    saveSetting = function(_self, key, value) stored[key] = value end,
    flush = function() end,
}
local progress = Progress:new{
    store = store, md5 = function(value) return value end,
    clock = function() return 1 end,
}
progress:save("chapter", image.path, 1, "whole", {
    connection = connection, manga = manga, chapter = chapter, total = 4,
    layout = "mobi_images", cover_hint = { image = image },
})
local history = progress:list_history(connection)[1]
expect(history and history.cover_hint and history.cover_hint.image,
    "history should retain the streamed MOBI cover hint")
expect(history.cover_hint.image.mobi_remote_path == image.mobi_remote_path
    and history.cover_hint.image.mobi_source_size == image.mobi_source_size
    and history.cover_hint.image.mobi_record == image.mobi_record
    and history.cover_hint.image.mobi_offset == image.mobi_offset
    and history.cover_hint.image.mobi_size == image.mobi_size,
    "history should retain MOBI Range metadata for a streamed cover")

-- Cover service must pass the same metadata through its validation/storage
-- boundary; otherwise CoverGrid falls back to downloading #mobi/2 as a URL.
local Cover = require("webdavmanga.cover")
local saved_cover
local cover = Cover:new{
    library = {
        get_cover = function() return nil end,
        set_cover = function(_self, _connection, _path, value)
            saved_cover = value
            return true
        end,
    },
    directory_store = {},
}
local resolved
cover:resolve(connection, {
    manga = manga, layout = "mobi_images", cover_hint = { image = image },
}, {
    on_ready = function(value) resolved = value end,
    on_error = function(error_value) error("unexpected cover error: " .. tostring(error_value)) end,
})
expect(resolved ~= nil, "resolved streamed MOBI cover should be delivered")
expect(resolved and resolved.mobi_remote_path == image.mobi_remote_path
    and resolved.mobi_record == image.mobi_record,
    "resolved streamed MOBI cover should retain Range metadata: "
        .. tostring(resolved and resolved.mobi_remote_path) .. "/"
        .. tostring(resolved and resolved.mobi_record))
expect(saved_cover and saved_cover.mobi_offset == image.mobi_offset,
    "stored streamed MOBI cover should retain its record offset: "
        .. tostring(saved_cover and saved_cover.mobi_offset))

-- MOBI failures should identify the MOBI/Range stage instead of masquerading
-- as a generic image decode failure.
local Errors = require("webdavmanga.errors")
local mobi_message = Errors.message(Errors.image_decode("short_mobi_page", "remote"))
expect(mobi_message:find("MOBI", 1, true) ~= nil,
    "MOBI extraction errors should be visible in the user-facing message")

-- Some MOBI resources contain a JPEG APP/EXIF segment larger than the old
-- 64 KiB probe window.  The image is valid, but the indexer used to omit it.
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
local function small_jpeg()
    return string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
        4, 176, 3, 32, 1, 1, 0x11, 0)
end
local function large_header_jpeg()
    local app_length = 65530
    return string.char(0xFF, 0xD8, 0xFF, 0xE1) .. be16(app_length)
        .. string.rep("E", app_length - 2)
        .. string.char(0xFF, 0xC0) .. be16(11)
        .. string.char(8, 4, 176, 3, 32, 1, 1, 0x11, 0)
end
local function large_header_mobi()
    local records = {}
    local record0 = string.rep("\0", 300)
    record0 = replace_at(record0, 0, be16(1))
    record0 = replace_at(record0, 4, be32(10))
    record0 = replace_at(record0, 8, be16(1))
    record0 = replace_at(record0, 16, "MOBI")
    record0 = replace_at(record0, 20, be32(232))
    record0 = replace_at(record0, 108, be32(2))
    record0 = replace_at(record0, 128, be32(0x40))
    record0 = replace_at(record0, 248,
        "EXTH" .. be32(24) .. be32(1) .. be32(122) .. be32(12) .. "true")
    records[1], records[2] = record0, "TEXT"
    records[3] = large_header_jpeg()
    for index = 4, 6 do records[index] = small_jpeg() end
    local offsets, cursor = {}, 160
    for index, record in ipairs(records) do
        offsets[index] = cursor
        cursor = cursor + #record
    end
    local header = string.rep("\0", 78)
    header = replace_at(header, 60, "BOOKMOBI")
    header = replace_at(header, 76, be16(#records))
    local table_bytes = ""
    for _, offset in ipairs(offsets) do
        table_bytes = table_bytes .. be32(offset) .. string.rep("\0", 4)
    end
    return header .. table_bytes
        .. string.rep("\0", 160 - 78 - #table_bytes)
        .. table.concat(records)
end
local large_blob = large_header_mobi()
local MobiPages = require("webdavmanga.mobi_pages")
local large_book, large_error = MobiPages:new():inspect_remote({
    size = #large_blob,
    read_at = function(offset, count) return large_blob:sub(offset + 1, offset + count) end,
}, "/Books/large-header.mobi")
expect(large_book ~= nil and large_error == nil and large_book.index:count() == 4,
    "MOBI indexing should recognize a valid JPEG whose header exceeds 64 KiB")
local failed_book, failed_error = MobiPages:new():inspect_remote({
    size = #large_blob, read_at = function() return nil end,
}, "/Books/unavailable.mobi")
expect(failed_book == nil and failed_error == "mobi_header_read_failed",
    "MOBI Range read failures should preserve a typed extraction error")

-- If a remote MOBI cannot be indexed as image pages, it must fall back to the
-- normal complete-document path instead of leaving the tap without a result.
local fallback_downloads, fallback_opened, fallback_runs = 0, nil, 0
local fallback_client = {
    connection = connection,
    read_range = function() return nil, nil, "range unavailable" end,
    download_document = function()
        fallback_downloads = fallback_downloads + 1
        return { size = 123, format = "mobi" }
    end,
}
local fallback_bridge = require("webdavmanga.document_bridge"):new{
    cache = {
        key_for = function() return "fallback-key" end,
        lookup_record = function() return nil end,
        paths_for = function() return "/cache/book.mobi", "/cache/book.mobi.part" end,
        publish = function() return "/cache/book.mobi" end,
        discard_part = function() end,
    },
    client_factory = function() return fallback_client end,
    async = { run = function(worker, done)
        fallback_runs = fallback_runs + 1
        if fallback_runs == 1 then
            done(true, { error = "not_image_mobi" })
        else
            local ok, result = pcall(worker)
            done(ok, result, ok and nil or result, {})
        end
        return { cancel = function() end }
    end },
    open_reader = function() return true end,
    ui_manager = { showReader = function(_self, path) fallback_opened = path; return true end },
}
local confirm_fallback
local scheduled_fallback = fallback_bridge:open({
    path = "/Books/text.mobi", name = "text.mobi", size = 123,
    file_kind = "document", connection = connection,
}, { on_document_fallback_prompt = function(format, reason, retry)
    expect(format == "mobi" and reason == "not_image_mobi", "MOBI rejection must be classified")
    confirm_fallback = retry
    return true
end })
expect(scheduled_fallback == true and fallback_downloads == 0 and confirm_fallback,
    "a failed remote MOBI probe must wait for complete-download confirmation")
confirm_fallback()
expect(fallback_downloads == 1
    and fallback_opened == "/cache/book.mobi",
    "a failed remote MOBI image probe should fall back to the native document reader: "
        .. tostring(fallback_runs) .. "/" .. tostring(fallback_downloads) .. "/"
        .. tostring(fallback_opened))

print(("rebuild_0367_mobi_cover_spec: %d checks"):format(checks))
