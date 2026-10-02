local ArchivePages = require("webdavmanga.archive_pages")
local ArchiveStream = require("webdavmanga.archive_stream")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local target = os.tmpname()
local reader = { ordinal = 0, closed = false }
function reader:next()
    self.ordinal = self.ordinal + 1
    if self.ordinal == 1 then
        return { index = 1, name = "cover.png", mode = "file", size = 4 }
    end
    return nil
end
function reader:extract_current(path)
    local file = assert(io.open(path, "wb")); file:write("PNG!"); file:close()
    return { size = 4 }
end
function reader:close() self.closed = true end

local pages = ArchivePages:new{
    archive_stream = {
        open = function(_, options)
            expect(options.size == 99 and type(options.read_at) == "function",
                "extract must pass the archive size and Range reader")
            reader.ordinal = 0; reader.closed = false
            return reader
        end,
    },
    image_probe = {
        inspect = function(path, extension)
            expect(path == target and extension == "png", "extracted image must be probed")
            return { width = 2, height = 2, format = "png" }
        end,
    },
    remove_file = os.remove,
}
local image = {
    archive_kind = "libarchive", archive_source_size = 99,
    archive_entry_ordinal = 1, archive_entry_name = "cover.png", archive_size = 4,
}
local metadata, reason = pages:extract_remote(image, function() return "x" end, target)
expect(metadata and not reason and metadata.size == 4 and metadata.width == 2,
    "libarchive image extraction must return validated metadata")
expect(reader.closed, "libarchive reader must close after extraction")
os.remove(target)

local direct_target = os.tmpname()
local read_calls = 0
local direct_reader = {
    closed = false,
    consumed = false,
    current = { name = "page.jpg", mode = "file", size = 4 },
    archive = {},
    ffi = {
        new = function() return {} end,
        string = function(_, count) return count == 4 and "JPEG" or "" end,
    },
    libarchive = {
        archive_read_data = function()
            read_calls = read_calls + 1
            return read_calls == 1 and 4 or 0
        end,
    },
}
local direct_metadata, direct_reason = ArchiveStream:new{
    formats = {
        extension = function() return "jpg" end,
        extension_for_format = function() return "jpeg" end,
    },
}:extract_current(direct_reader, direct_target)
local direct_file = io.open(direct_target, "rb")
local direct_bytes = direct_file and direct_file:read("*a")
if direct_file then direct_file:close() end
expect(direct_metadata and direct_reason == nil and direct_metadata.size == 4
    and direct_bytes == "JPEG" and direct_reader.consumed == true,
    "the real Range-backed libarchive writer must publish a fully closed page file")
os.remove(direct_target)

print(("rebuild_0398_libarchive_extract_spec: %d checks"):format(checks))
