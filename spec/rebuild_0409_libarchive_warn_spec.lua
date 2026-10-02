local ArchiveStream = require("webdavmanga.archive_stream")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function reader_with(result)
    return {
        closed = false,
        consumed = true,
        archive = {},
        entry = {},
        ffi = { string = function(value) return value end },
        libarchive = {
            archive_read_next_header2 = function() return result end,
            archive_entry_pathname = function() return "中文页面/001.jpg" end,
            archive_entry_size = function() return 1234 end,
            archive_entry_filetype = function() return 32768 end,
            archive_read_data_skip = function() return 0 end,
        },
    }
end

local warned = reader_with(-20) -- ARCHIVE_WARN: header is usable.
local entry, warn_error = ArchiveStream:new():next(warned)
expect(entry and entry.name == "中文页面/001.jpg" and entry.size == 1234,
    "ARCHIVE_WARN must preserve the usable entry: " .. tostring(warn_error))
expect(warned.consumed == false, "warned header must enter the normal data state")

local failed = reader_with(-25) -- ARCHIVE_FAILED.
local failed_entry, failed_error = ArchiveStream:new():next(failed)
expect(failed_entry == nil and failed_error == "archive_header_failed",
    "ARCHIVE_FAILED must remain a hard failure: " .. tostring(failed_error))

print(("rebuild_0409_libarchive_warn_spec: %d checks"):format(checks))
