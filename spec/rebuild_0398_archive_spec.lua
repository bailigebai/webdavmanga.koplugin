local ArchivePages = require("webdavmanga.archive_pages")
local BookIndex = require("webdavmanga.book_index")
local DocumentBridge = require("webdavmanga.document_bridge")
local Errors = require("webdavmanga.errors")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function field(value, width)
    value = tostring(value or "")
    return value .. string.rep("\0", math.max(0, width - #value))
end

local image_data = "not-decoded-in-index"
local tar_header = table.concat({
    field("001.jpg", 100), field("0000644", 8), field("0000000", 8),
    field("0000000", 8), field(string.format("%011o\0", #image_data), 12),
    field("00000000000", 12), field("        ", 8), "0",
    field("", 100), field("ustar", 6), field("00", 2), field("", 32),
    field("", 32), field("", 8), field("", 8), field("", 155),
})
tar_header = field(tar_header, 512)
local tar = tar_header .. image_data
tar = tar .. string.rep("\0", 512 - (#tar % 512)) .. string.rep("\0", 512)
local function read_at(offset, count)
    return tar:sub(offset + 1, offset + count)
end

local book, reason = ArchivePages:new():inspect_remote({
    size = #tar,
    read_at = read_at,
}, "cbt", "/comic.cbt")
expect(book and not reason and book.layout == "archive_images",
    "CBT must expose a tar page index without downloading the whole archive")
local page = book and book.index:get(1)
expect(page and page.archive_kind == "tar"
    and page.archive_entry_name == "001.jpg"
    and page.archive_entry_offset == 512
    and page.archive_size == #image_data,
    "CBT page entries must carry a bounded range offset and size")

local endless_header = table.concat({
    field("notes.txt", 100), field("0000644", 8), field("0000000", 8),
    field("0000000", 8), field("00000000000", 12),
    field("00000000000", 12), field("        ", 8), "0",
    field("", 100), field("ustar", 6), field("00", 2), field("", 32),
    field("", 32), field("", 8), field("", 8), field("", 155),
})
endless_header = field(endless_header, 512)
local oversized_tar, oversized_tar_error = ArchivePages:new():inspect_remote({
    size = 20001 * 512,
    read_at = function(_, count)
        return count == 512 and endless_header or nil
    end,
}, "cbt", "/too-many.cbt")
expect(oversized_tar == nil and oversized_tar_error == "tar_too_many_entries",
    "CBT archives must reject an unterminated entry list at the safety limit")

local bridge = DocumentBridge:new{
    cache = {}, client_factory = function() return {} end,
    open_reader = function() return true end,
    archive_pages = { inspect_remote = function() end },
    mupdf_pages = {},
}
local capability = bridge:stream_capability({ name = "comic.cbt" })
expect(capability and capability.kind == "archive_pages" and capability.supported == true,
    "CBT capability must be advertised as plugin archive streaming")

local zip_bridge = DocumentBridge:new{
    cache = {}, client_factory = function() return {} end,
    open_reader = function() return true end,
    archive_pages = {
        can_stream = function(_, kind) return kind == "zip" end,
        inspect_remote = function() end,
    },
    mupdf_pages = {},
}
local zip_capability = zip_bridge:stream_capability({ name = "comic.zip" })
expect(zip_capability and zip_capability.kind == "archive_pages"
    and zip_capability.supported == true,
    "plain ZIP capability must be advertised as plugin archive streaming")

local tar_index = BookIndex.from_items({{
    name = "001.jpg", path = "/comic.cbt#tar/1", is_file = true,
    archive_kind = "tar", archive_remote_path = "/comic.cbt",
    archive_source_size = 2048, archive_entry_name = "001.jpg",
    archive_entry_offset = 512, archive_method = 0, archive_size = 12,
    archive_version = "2048:0::", etag = "",
}})
local tar_table = tar_index:to_table()
local restored_tar = tar_table and BookIndex.from_table(tar_table)
expect(restored_tar and restored_tar:get(1).archive_kind == "tar"
    and restored_tar:get(1).archive_entry_offset == 512,
    "CBT manifests must preserve the tar page offset without ZIP-only fields")

local rar_index = BookIndex.from_items({{
    name = "page-01.png", path = "/comic.rar#archive/3", is_file = true,
    archive_kind = "libarchive", archive_format = "rar",
    archive_remote_path = "/comic.rar", archive_source_size = 4096,
    archive_entry_name = "page-01.png", archive_entry_ordinal = 3,
    archive_size = 24, archive_version = "4096:0::", etag = "",
}})
local rar_table = rar_index:to_table()
local restored_rar = rar_table and BookIndex.from_table(rar_table)
expect(restored_rar and restored_rar:get(1).archive_kind == "libarchive"
    and restored_rar:get(1).archive_format == "rar"
    and restored_rar:get(1).archive_entry_ordinal == 3,
    "RAR/7z manifests must preserve the libarchive entry ordinal")

expect(Errors.message(Errors.document("stream",
    "cbr:libarchive_open_failed")):find("设备", 1, true) ~= nil,
    "missing native archive codec must have a clear device-capability message")
expect(Errors.message(Errors.document("stream",
    "cbt:tar_too_many_entries")):find("条目过多", 1, true) ~= nil,
    "oversized comic archives must have a clear safety-limit message")
expect(Errors.message(Errors.document("stream",
    "cbz:zip_encrypted")):find("加密", 1, true) ~= nil,
    "encrypted comic archives must have a clear message")

print(("rebuild_0398_archive_spec: %d checks"):format(checks))
