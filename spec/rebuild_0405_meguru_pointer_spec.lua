local ok, Pointer = pcall(require, "webdavmanga.meguru_pointer")
assert(ok, "Meguru JSON pointer persistence must exist")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function copy(value) local out = {}; for k,v in pairs(value) do out[k] = v end; return out end
-- The device json module is native. This flat JSON codec double emits all values
-- so the credential byte scan tests the production allowlist, not an opaque token.
local encoded = {}
local json = {
    encode = function(value)
        local parts = {}
        for key, item in pairs(value) do
            local repr = type(item) == "string" and ('"' .. item:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"') or tostring(item)
            parts[#parts + 1] = '"' .. key .. '":' .. repr
        end
        table.sort(parts)
        local bytes = "{" .. table.concat(parts, ",") .. "}"
        encoded[bytes] = copy(value)
        return bytes
    end,
    decode = function(bytes) return encoded[bytes] and copy(encoded[bytes]) end,
}
local function filesystem(fail, throws)
    local fs = { files = {}, events = {}, locks={} }
    fs.mkdir=function(path) if fs.locks[path] then return nil end; fs.locks[path]=true;return true end
    fs.rmdir=function(path) fs.locks[path]=nil;return true end
    local function event(name)
        fs.events[#fs.events + 1] = name
        if throws and fail == name then error("filesystem failure") end
        return fail ~= name
    end
    fs.make_path = function() return event("mkdir") end
    fs.exists = function(path) return fs.files[path] ~= nil end
    fs.open = function(path, mode)
        if mode == "wb" then
            if not event("open_write") then return nil end
            fs.files[path] = ""
            return {
                write = function(_, bytes) fs.files[path] = bytes; return event("write") end,
                flush = function() return event("flush") end,
                close = function() return event("close") end,
            }
        end
        if not event("open_read") or not fs.files[path] then return nil end
        return {
            read = function()
                if not event("read") then return nil end
                if fail == "decode" then return "malformed json" end
                if fail == "verify" then
                    local value = copy(encoded[fs.files[path]])
                    value.chapter_id = "different-chapter"
                    return json.encode(value)
                end
                return fs.files[path]
            end,
            close = function() return event("close_read") end,
        }
    end
    fs.rename = function(from, to)
        if not event("rename") then return nil end
        fs.files[to], fs.files[from] = fs.files[from], nil
        return true
    end
    fs.remove = function(path) fs.files[path] = nil; return true end
    return fs
end
local desc = {
    source_id = "source-1", server_name = "Home Komga", server_kind = "komga",
    series_id = "series-1", series_name = "Series", chapter_id = "chapter-2", chapter_name = "Volume 2",
    stream_template = "https://reader:reader-password@srv/api/opds/api-key-secret/page/{pageNumber}?token=api-key-secret",
    page_count = 27, server_last_read = 2,
    cover_url = "https://srv/cover?token=api-key-secret", series_feed_url = "https://srv/series?password=reader-password",
    password = "reader-password", username = "reader", arbitrary = "api-key-secret",
}
local fs = filesystem()
local function identity_hash(value)
    if value == "source-1" then return "1111111111111111" end
    if value == "source-1\0series-1" then return "2222222222222222" end
    assert(value == "source-1\0series-1\0other", "collision suffix must hash stable ids only")
    return "abcdef1234567890"
end
package.loaded["ffi/sha2"]={md5=identity_hash}
local pointer = Pointer:new{ root = "/data/webdavmanga-streams", fs = fs, json = json, md5 = identity_hash }
local path = assert(pointer:save(desc))
expect(path == "/data/webdavmanga-streams/Home Komga [1111111111111111]/Series [2222222222222222]/Volume 2.meguru", "readable layout includes source and series identity")
expect(not fs.files[path]:find("api-key-secret", 1, true) and not fs.files[path]:find("reader-password", 1, true), "credentials cannot enter pointer bytes")
expect(not fs.files[path]:find('"password"', 1, true) and not fs.files[path]:find('"server_name"', 1, true), "persist only approved fields")
local loaded = assert(pointer:load(path))
expect(loaded.version == 1 and loaded.page_count == 27 and loaded.source_id == "source-1", "version and identity survive JSON round trip")
expect(loaded.stream_template:find("{pageNumber}", 1, true) ~= nil, "preserve PSE placeholder")
local events = table.concat(fs.events, ",")
expect(events:find("write,flush,close,open_read,read,close_read,rename,open_read,read,close_read", 1, true), "flush/close and verify owned temp before atomic publication and final readback")
local count = #fs.events
expect(pointer:save(desc) == path, "same stable identity reuses marker")
for i = count + 1, #fs.events do expect(fs.events[i] ~= "write", "reuse does not overwrite") end
local collision = copy(desc); collision.chapter_id = "other"
local original_marker = fs.files[path]
local saved, err = pointer:save(collision)
local fallback = "/data/webdavmanga-streams/Home Komga [1111111111111111]/Series [2222222222222222]/Volume 2 [abcdef123456].meguru"
expect(saved == fallback and fs.files[path] == original_marker
    and fs.files[path .. ".part"] == nil, "same title gets stable identity suffix without overwriting first chapter")
expect(pointer:save(collision) == fallback and pointer:load(fallback).chapter_id == "other",
    "same identity reuses fallback")
fs.files[fallback] = original_marker
saved, err = pointer:save(collision)
expect(not saved and err == "pointer_identity_conflict" and fs.files[fallback] == original_marker,
    "a fallback hash collision must not overwrite an unrelated chapter")
pointer.root = "/new-root"
expect(pointer:path_for(desc) == "/new-root/Home Komga [1111111111111111]/Series [2222222222222222]/Volume 2.meguru" and fs.files[path], "root edits leave existing book in place")
local restored = Pointer:new{ root = "/new-root", fs = fs, json = json,
    find_existing = function(source, series, chapter)
        expect(source == "source-1" and series == "series-1" and chapter == "chapter-2", "lookup uses stable identity")
        return path
    end }
local renamed = copy(desc); renamed.chapter_name = "New title"
expect(restored:save(renamed) == path, "Library callback reuses old title/root path")
expect(Pointer:new{root="/data", per_server=false, fs=fs, json=json}:path_for(desc) == "/data/Series [2222222222222222]/Volume 2.meguru", "optional server directory still includes source identity")
local unsafe = copy(desc)
unsafe.server_name, unsafe.series_name, unsafe.chapter_name = "../Ho\0me/\\.. ", "...", string.rep("中", 40)
local safe_path = pointer:path_for(unsafe)
expect(not safe_path:find("..", 1, true) and not safe_path:find("\0", 1, true) and not safe_path:find("\\", 1, true), "strip traversal, separators and controls")
expect(safe_path:match("([^/]+)%.meguru$") == string.rep("中", 32), "96 byte limit preserves UTF-8 characters")
unsafe.series_name, unsafe.chapter_name = "My\nSeries.", "..Book/\\\t. "
expect(pointer:path_for(unsafe) == "/new-root/Home [1111111111111111]/MySeries [2222222222222222]/Book.meguru", "all title components strip controls and trailing dots")
for _, stage in ipairs({"mkdir", "open_write", "write", "flush", "close", "rename", "open_read", "read", "close_read", "decode", "verify"}) do
    local broken = filesystem(stage)
    local instance = Pointer:new{ root="/data", fs=broken, json=json }
    saved, err = instance:save(desc)
    expect(saved == nil and type(err) == "string", "classified failure: " .. stage)
    expect(next(broken.files) == nil, "failure removes final and part: " .. stage)
end
for _, stage in ipairs({"mkdir", "open_write", "write", "flush", "close", "rename", "open_read", "read", "close_read"}) do
    local broken = filesystem(stage, true)
    local instance = Pointer:new{root="/data", fs=broken, json=json}
    saved, err = instance:save(desc)
    expect(not saved and type(err) == "string" and next(broken.files) == nil, "filesystem exceptions clean up: " .. stage)
end
for _, failure in ipairs({"throw", "false"}) do
    local uncertain = filesystem()
    local instance = Pointer:new{root="/data", fs=uncertain, json=json, md5=identity_hash}
    local destination = assert(instance:path_for(desc))
    uncertain.rename = function(from, to)
        uncertain.files[to], uncertain.files[from] = uncertain.files[from], nil
        if failure == "throw" then error("rename failed after move") end
        return false
    end
    saved, err = instance:save(desc)
    expect(not saved and err == "pointer_rename_failed", "uncertain rename remains classified: " .. failure)
    expect(uncertain.files[destination] ~= nil and instance:load(destination).chapter_id == desc.chapter_id,
        "uncertain rename preserves the independently verified final for a safe retry: " .. failure)
    for candidate in pairs(uncertain.files) do expect(candidate == destination, "uncertain rename cleans only owned temporary files") end
    uncertain.files[destination] = original_marker
    uncertain.files[destination:gsub("%.meguru$", " [abcdef123456].meguru")] = original_marker
    saved, err = instance:save(collision)
    expect(not saved and err == "pointer_identity_conflict" and uncertain.files[destination] == original_marker,
        "uncertain rename cleanup never removes a preexisting identity collision")
end
for _, mode in ipairs({"race_collision", "part_probe_throw", "final_probe_throw"}) do
    local raced = filesystem()
    local instance = Pointer:new{root="/data", fs=raced, json=json}
    local destination = assert(instance:path_for(desc))
    local rename_failed = false
    local competing_bytes = "a different writer owns this final"
    local exists = raced.exists
    raced.rename = function(_, to)
        raced.files[to] = competing_bytes
        rename_failed = true
        if mode == "final_probe_throw" then raced.files[destination .. ".part"] = nil end
        return false
    end
    raced.exists = function(candidate)
        if rename_failed and ((mode == "part_probe_throw" and candidate == destination .. ".part")
            or (mode == "final_probe_throw" and candidate == destination)) then
            error("existence probe failed")
        end
        return exists(candidate)
    end
    saved, err = instance:save(desc)
    expect(not saved and err == "pointer_rename_failed", "raced rename retains original classified error: " .. mode)
    expect(raced.files[destination] == competing_bytes and raced.files[destination .. ".part"] == nil,
        "uncertain rename preserves competing final and cleans part: " .. mode)
end
for key, bad in pairs({ version=2, source_id="", series_id="", chapter_id="", stream_template="https://srv/0", page_count=100001 }) do
    local invalid = copy(desc); invalid[key] = bad
    expect(pointer:save(invalid) == nil, "reject invalid field " .. key)
end
for _, bytes in ipairs({ 'return {version=1}', 'os.execute("bad")', '[]', '{}' }) do
    fs.files["/bad.meguru"] = bytes
    expect(pointer:load("/bad.meguru") == nil, "untrusted bytes are JSON data only")
end
fs.files["/oversize.meguru"] = string.rep("x", 65537)
expect(pointer:load("/oversize.meguru") == nil, "pointer reads are bounded")
local old_load, old_loadstring, old_loadfile, old_dofile = load, loadstring, loadfile, dofile
local executed = false
local function forbidden() executed = true; error("pointer data must not execute") end
load, loadstring, loadfile, dofile = forbidden, forbidden, forbidden, forbidden
fs.files["/untrusted.meguru"] = 'return {version=1}'
pointer:load("/untrusted.meguru")
load, loadstring, loadfile, dofile = old_load, old_loadstring, old_loadfile, old_dofile
expect(not executed, "pointer bytes never reach Lua code loading functions")
local raw = copy(desc); raw.version = 1
fs.files["/raw.meguru"] = json.encode(raw)
expect(pointer:load("/raw.meguru") == nil, "readback rejects unexpectedly unredacted credentials")
local Settings = require("webdavmanga.settings")
local values = {}
local settings = Settings:new{ default_opds_pointer_root="/data/webdavmanga-streams", store={
    readSetting=function(_, k, fallback) return values[k] or fallback end,
    saveSetting=function(_, k, value) values[k] = value end,
} }
local reader = settings:get_reader()
expect(reader.opds_pointer_root == "/data/webdavmanga-streams" and reader.opds_pointer_per_server == true and reader.opds_cover_enabled == true, "injected data directory and enabled defaults")
expect(settings:set_reader{opds_pointer_root="/books", opds_pointer_per_server=false, opds_cover_enabled=false}, "pointer options can be configured")
for _, value in ipairs({{opds_pointer_root=""}, {opds_pointer_root="bad\0path"}, {opds_pointer_per_server="yes"}, {opds_cover_enabled=1}}) do
    expect(settings:set_reader(value) == nil, "invalid pointer setting rejected")
end
print("rebuild_0405_meguru_pointer_spec: " .. checks .. " checks")
