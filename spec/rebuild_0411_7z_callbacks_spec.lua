local Stream = require("webdavmanga.archive_stream")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end

local function fixture(seek_result, missing)
    local state = { requests = {}, freed = 0, opened = 0 }
    local ffi = {
        cast = function(_, callback) return setmetatable({ free = function() end }, {
            __call = function(_, ...) return callback(...) end }) end,
        new = function() return {} end,
        copy = function(buffer, bytes) buffer.bytes = bytes end,
        string = function(value) return value end,
    }
    local lib = {
        archive_read_new = function() return {} end,
        archive_entry_new = function() return {} end,
        archive_read_support_format_all = function() end,
        archive_read_support_filter_all = function() end,
        archive_read_set_seek_callback = function(_, callback)
            state.seek = callback; return seek_result or 0
        end,
        archive_read_open2 = function(_, _, _, read, skip)
            state.opened = state.opened + 1; state.read, state.skip = read, skip; return 0
        end,
        archive_read_close = function() end,
        archive_free = function() state.freed = state.freed + 1 end,
        archive_entry_free = function() end,
    }
    if missing then lib.archive_read_set_seek_callback = nil end
    local stream = Stream:new{ ffi = ffi, libarchive = lib }
    local function open(format)
        return stream:open{ format = format, size = 100, read_at = function(offset, count)
            state.requests[#state.requests + 1] = {offset, count}
            if state.fail then error("https://account:secret@server/private.7z") end
            return string.rep("x", math.min(count, 7))
        end }
    end
    return stream, state, open
end

for _, format in ipairs({"7z", "cb7"}) do
    for _, failure in ipairs({"missing", "rejected"}) do
        local stream, state, open = fixture(-25, failure == "missing")
        local reader, reason = open(format)
        expect(not reader and reason == "archive_seek_unavailable",
            format .. " rejects " .. failure .. " seek registration before opening")
        expect(state.opened == 0 and state.freed == 1, "failed seek releases native reader")
    end
end
for _, format in ipairs({"rar", "cbr"}) do
    local stream, _, open = fixture(nil, true)
    local reader = assert(open(format))
    expect(reader.seek_enabled == false, "RAR retains sequential compatibility")
    stream:close(reader)
end
local stream, state, open = fixture()
local reader = assert(open("7z"))
expect(reader.seek_enabled == true, "7Z verifies registered seek")
expect(state.seek(reader.archive, nil, 80, 0) == 80, "SEEK_SET")
expect(state.seek(reader.archive, nil, -10, 1) == 70, "backward SEEK_CUR")
expect(state.seek(reader.archive, nil, -5, 2) == 95, "SEEK_END")
expect(state.read(reader.archive, nil, {}) == 5 and reader.position == 100, "read clips at EOF")
expect(state.read(reader.archive, nil, {}) == 0 and #state.requests == 1, "EOF makes no Range request")
expect(state.seek(reader.archive, nil, 0, 0) == 0, "backward seek after EOF")
expect(state.read(reader.archive, nil, {}) == 7 and reader.position == 7,
    "nonempty short response advances only by returned bytes")
expect(state.read(reader.archive, nil, {}) == 7 and state.requests[3][1] == 7,
    "next read resumes from short response boundary")
expect(state.seek(reader.archive, nil, -1, 0) == -1
    and state.seek(reader.archive, nil, 101, 0) == -1
    and state.seek(reader.archive, nil, 0, 99) == -1, "invalid seeks leave position unchanged")
expect(reader.position == 14, "invalid seek never mutates position")
state.fail = true
expect(state.read(reader.archive, nil, {}) == -1
    and reader.error == "archive_range_read_failed", "Range exception is categorized without its URL")
stream:close(reader)

do
    local logs = {}
    local native = "LZMA codec is unsupported"
    local probe = Stream:new{
        ffi = { string = function(value) return value end },
        libarchive = { archive_error_string = function() return native end },
        logger = { warn = function(...)
            local fields = {}
            for _, value in ipairs({...}) do fields[#fields + 1] = tostring(value) end
            logs[#logs + 1] = table.concat(fields, " ")
        end },
    }
    local current = { archive = {}, ffi = probe.ffi, libarchive = probe.libarchive }
    expect(probe:_native_status(current, -30, "archive_header_failed")
        == "archive_codec_unsupported" and current.native_detail == "lzma",
        "unsupported LZMA2 reports a fixed codec category")
    expect(table.concat(logs, "\n"):find("archive_codec_unsupported lzma", 1, true),
        "LZMA2 diagnosis stays visible without archive details")
end
print(("rebuild_0411_7z_callbacks_spec: %d checks"):format(checks))
