local ArchivePages = require("webdavmanga.archive_pages")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local entries = {
    { path = "cover.png", mode = "file", size = 10, index = 1 },
    { path = "notes.txt", mode = "file", size = 4, index = 2 },
    { path = "page-02.jpg", mode = "file", size = 20, index = 3 },
}
local cursor = 0
local fake_reader = {
    next = function(self)
        cursor = cursor + 1
        return entries[cursor]
    end,
    close = function() end,
}
local fake_archive_stream = {
    open = function(_, options)
        expect(options.size == 123456 and type(options.read_at) == "function",
            "libarchive adapter must receive the remote size and Range reader")
        cursor = 0
        return fake_reader
    end,
    available = function() return true end,
}

local archive = ArchivePages:new{ archive_stream = fake_archive_stream }
local book, reason = archive:inspect_remote({ size = 123456,
    read_at = function() return "" end,
}, "cbr", "/comic.cbr")
expect(book and not reason and book.layout == "archive_images",
    "CBR must use the capability-gated libarchive page index")
local first, second = book.index:get(1), book.index:get(2)
expect(first and first.archive_kind == "libarchive"
    and first.archive_format == "cbr"
    and first.archive_entry_ordinal == 1
    and first.archive_entry_name == "cover.png",
    "libarchive entries must retain ordinal and original image names")
expect(second and second.archive_entry_ordinal == 3
    and second.name == "page-02.jpg",
    "non-image archive entries must be skipped without changing page order")

local registered_seek
local registered_read
local error_archive
local open_read_count
local copied_bytes
local fake_ffi = {
    cdef = function() return true end,
    cast = function(_, callback)
        return setmetatable({ callback = callback, free = function() end }, {
            __call = function(self, ...) return self.callback(...) end,
        })
    end,
    new = function() return {} end,
    copy = function(_, bytes) copied_bytes = bytes end,
    string = function(value) return value or "" end,
}
local fake_libarchive = {
    archive_read_new = function() return {} end,
    archive_entry_new = function() return {} end,
    archive_read_support_format_all = function() end,
    archive_read_support_filter_all = function() end,
    archive_read_set_seek_callback = function(_, callback)
        registered_seek = callback
        return 0
    end,
    archive_read_open2 = function(archive, _, _, read_callback)
        registered_read = read_callback
        open_read_count = read_callback(archive, nil, {})
        return 0
    end,
    archive_set_error = function(archive)
        error_archive = archive
        return 0
    end,
    archive_read_close = function() return 0 end,
    archive_free = function() return 0 end,
    archive_entry_free = function() return 0 end,
}
local native_stream = require("webdavmanga.archive_stream"):new{
    ffi = fake_ffi, libarchive = fake_libarchive,
}
expect(native_stream:available() == true,
    "libarchive capability must use the active native instance")
local range_reader, range_error = native_stream:open{
    size = 100,
    read_at = function() return "" end,
}
expect(range_reader and range_error == nil and registered_seek,
    "RAR/7z streaming must register a random-access Range seek callback")
expect(registered_seek(range_reader.archive, nil, 80, 0) == 80
    and range_reader.position == 80
    and registered_seek(range_reader.archive, nil, -10, 1) == 70
    and registered_seek(range_reader.archive, nil, -5, 2) == 95,
    "libarchive seeks must map SEEK_SET/CUR/END to bounded remote offsets")
expect(registered_seek(range_reader.archive, nil, 101, 0) == -1,
    "libarchive seeks outside the remote archive must be rejected")
expect(registered_read(range_reader.archive, nil, {}) == -1
    and error_archive == range_reader.archive,
    "a short Range read must attach the error to the active archive handle")
native_stream:close(range_reader)

local missing_error_libarchive = setmetatable({}, {
    __index = function(_, name)
        if name == "archive_set_error" then error("missing native symbol") end
        return fake_libarchive[name]
    end,
})
local missing_error_stream = require("webdavmanga.archive_stream"):new{
    ffi = fake_ffi, libarchive = missing_error_libarchive,
}
local missing_error_reader = assert(missing_error_stream:open{
    size = 100, read_at = function() return "" end,
})
local missing_error_ok, missing_error_result = pcall(
    registered_read, missing_error_reader.archive, nil, {})
expect(missing_error_ok and missing_error_result == -1,
    "a missing optional archive_set_error symbol must not crash short-read handling")
missing_error_stream:close(missing_error_reader)

local no_seek_libarchive = {}
for name, value in pairs(fake_libarchive) do
    no_seek_libarchive[name] = value
end
no_seek_libarchive.archive_read_set_seek_callback = nil
local no_seek_stream = require("webdavmanga.archive_stream"):new{
    ffi = fake_ffi, libarchive = no_seek_libarchive,
}
expect(no_seek_stream:available() == true,
    "libarchive sequential callbacks must remain available without seek")
local no_seek_reader, no_seek_reason = no_seek_stream:open{
    size = 100,
    read_at = function(offset, count)
        return string.rep("x", math.min(count, 100 - offset))
    end,
}
expect(no_seek_reader and no_seek_reason == nil,
    "RAR/7z must open sequentially when the optional seek symbol is missing")
expect(open_read_count == 100 and copied_bytes == string.rep("x", 100)
    and no_seek_reader.position == 100,
    "no-seek open must consume sequential Range bytes through the real read callback")
no_seek_stream:close(no_seek_reader)

local rejected_seek_libarchive = {}
for name, value in pairs(fake_libarchive) do
    rejected_seek_libarchive[name] = value
end
rejected_seek_libarchive.archive_read_set_seek_callback = function() return -1 end
local rejected_seek_stream = require("webdavmanga.archive_stream"):new{
    ffi = fake_ffi, libarchive = rejected_seek_libarchive,
}
local rejected_seek_reader, rejected_seek_reason = rejected_seek_stream:open{
    size = 100,
    read_at = function(offset, count)
        return string.rep("y", math.min(count, 100 - offset))
    end,
}
expect(rejected_seek_reader and rejected_seek_reason == nil
    and rejected_seek_reader.seek_enabled == false
    and open_read_count == 100 and rejected_seek_reader.position == 100,
    "a rejected seek registration must still open through sequential callbacks")
rejected_seek_stream:close(rejected_seek_reader)

local failing_open_libarchive = {}
for name, value in pairs(fake_libarchive) do
    failing_open_libarchive[name] = value
end
failing_open_libarchive.archive_read_open2 = function() return -1 end
failing_open_libarchive.archive_error_string = function()
    return "device-specific codec failure"
end
local failing_open_reader, failing_open_reason = require("webdavmanga.archive_stream"):new{
    ffi = fake_ffi, libarchive = failing_open_libarchive,
}:open{
    size = 100,
    read_at = function() return "x" end,
}
expect(failing_open_reader == nil and failing_open_reason == "libarchive_open_failed",
    "native archive errors must not escape the stable open error contract")

local header_results = { 0, 1, -1 }
local skipped_entries = 0
local next_stream = require("webdavmanga.archive_stream"):new{}
local next_reader = {
    archive = {}, entry = {}, consumed = true, closed = false,
    ffi = { string = function(value) return value end },
    libarchive = {
        archive_read_data_skip = function()
            skipped_entries = skipped_entries + 1
            return 0
        end,
        archive_read_next_header2 = function()
            local result = header_results[1]
            table.remove(header_results, 1)
            return result
        end,
        archive_entry_pathname = function() return "page-01.jpg" end,
        archive_entry_size = function() return 42 end,
        archive_entry_filetype = function() return 32768 end,
    },
}
local header, header_reason = next_stream:next(next_reader)
expect(header and header_reason == nil and header.name == "page-01.jpg"
    and header.size == 42 and header.mode == "file" and header.index == 1,
    "the real ArchiveStream next must expose native header metadata")
local eof, eof_reason = next_stream:next(next_reader)
expect(eof == nil and eof_reason == nil and skipped_entries == 1,
    "next must skip an unconsumed entry before reporting native EOF")
next_reader.consumed = true
local failed_header, failed_header_reason = next_stream:next(next_reader)
expect(failed_header == nil and failed_header_reason == "archive_header_failed",
    "native header failures must use the stable ArchiveStream error")

local close_calls, free_calls, entry_free_calls, callback_free_calls = 0, 0, 0, 0
local close_ffi = {
    cast = function(_, callback)
        local wrapped = { callback = callback, freed = false }
        function wrapped:free()
            self.freed = true
            callback_free_calls = callback_free_calls + 1
        end
        return wrapped
    end,
    new = function() return {} end,
    copy = function() end,
    string = function(value) return value or "" end,
}
local close_stream = require("webdavmanga.archive_stream"):new{
    ffi = close_ffi,
    libarchive = {
        archive_read_new = function() return {} end,
        archive_entry_new = function() return {} end,
        archive_read_support_format_all = function() end,
        archive_read_support_filter_all = function() end,
        archive_read_open2 = function() return 0 end,
        archive_read_close = function() close_calls = close_calls + 1; return 0 end,
        archive_free = function() free_calls = free_calls + 1; return 0 end,
        archive_entry_free = function() entry_free_calls = entry_free_calls + 1; return 0 end,
    },
}
local close_reader = assert(close_stream:open{
    size = 100, read_at = function() return "x" end,
})
close_reader.block, close_reader.current = {}, {}
expect(close_stream:close(close_reader) and close_calls == 1 and free_calls == 1
    and entry_free_calls == 1 and callback_free_calls == 5
    and close_reader.archive == nil and close_reader.entry == nil
    and close_reader.block == nil and close_reader.current == nil
    and close_reader.callbacks == nil,
    "close must free every native resource and clear reader-owned state")
expect(close_stream:close(close_reader) and close_calls == 1 and free_calls == 1
    and entry_free_calls == 1 and callback_free_calls == 5,
    "close must be idempotent after native resources are released")

for _, failed_cast in ipairs({ 1, 2, 3, 5, 4 }) do
    local casts, allocated, freed, native_allocated, native_freed = 0, 0, 0, 0, 0
    local partial_stream = require("webdavmanga.archive_stream"):new{
        ffi = {
            cast = function()
                casts = casts + 1
                if casts == failed_cast then error("callback cast unavailable") end
                allocated = allocated + 1
                return { free = function() freed = freed + 1 end }
            end,
            new = function() return {} end,
        },
        libarchive = {
            archive_read_new = function() native_allocated = native_allocated + 1; return {} end,
            archive_entry_new = function() native_allocated = native_allocated + 1; return {} end,
            archive_read_support_format_all = function() end,
            archive_read_support_filter_all = function() end,
            archive_read_open2 = function() return 0 end,
            archive_read_close = function() native_freed = native_freed + 1; return 0 end,
            archive_free = function() native_freed = native_freed + 1; return 0 end,
            archive_entry_free = function() native_freed = native_freed + 1; return 0 end,
        },
    }
    local partial_reader, partial_reason = partial_stream:open{
        size = 100, read_at = function() return "x" end,
    }
    if failed_cast == 4 then
        expect(partial_reader and not partial_reason and not partial_reader.seek_enabled
            and allocated == 4 and freed == 0 and native_allocated == 2,
            "optional seek cast failure must retain required callbacks on a successful reader")
        expect(partial_stream:close(partial_reader) and freed == allocated and native_freed == 3,
            "reader without optional seek must release every owned callback and native object")
        expect(partial_stream:close(partial_reader) and freed == allocated and native_freed == 3,
            "reader without optional seek must close idempotently")
    else
        expect(not partial_reader and partial_reason == "libarchive_callback_unavailable",
            "required callback cast failure must return the stable availability error")
        expect(allocated == 4 and freed == allocated and native_allocated == 0 and native_freed == 0,
            "required callback cast failure must free all allocated callbacks without touching unallocated native objects")
    end
end

print(("rebuild_0398_libarchive_spec: %d checks"):format(checks))
