local Cache = require("webdavmanga.cache")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local files = {
    ["/cache/old.jpg"] = 40,
    ["/cache/protected.jpg"] = 20,
    ["/cache/complete.cbz"] = 60,
    ["/cache/failed.jpg"] = 30,
}
local failed_path = "/cache/failed.jpg"
local fs = {
    make_path = function() return true end,
    exists = function(path) return files[path] ~= nil end,
    size = function(path) return files[path] end,
    remove = function(path)
        if path == failed_path then return nil, "disk_error" end
        files[path] = nil
        return true
    end,
    list = function() return {} end,
}
local stored = {}
local store = {
    readSetting = function(_, key, default)
        if stored[key] == nil then return default end
        return stored[key]
    end,
    saveSetting = function(_, key, value) stored[key] = value end,
    flush = function() end,
}
local cache = Cache:new{
    root = "/cache", limit_bytes = 1024, store = store, fs = fs,
    md5 = function(value) return value end,
    cache_key_validator = function() return true end,
}
cache.entries = {
    old = { key = "old", kind = "page", remote_path = "/book.cbz#zip/1",
        path = "/cache/old.jpg", size = 40 },
    protected = { key = "protected", kind = "cover", remote_path = "/book.cbz#zip/1",
        path = "/cache/protected.jpg", size = 20 },
    document = { key = "document", kind = "document", remote_path = "/book.cbz",
        path = "/cache/complete.cbz", size = 60 },
    failed = { key = "failed", kind = "page", remote_path = "/book.cbz#zip/2",
        path = failed_path, size = 30 },
}
cache:set_protected({ protected = true })

local ok, retained, failed = cache:clear_matching_cache(function(record)
    return (record.kind == "page" or record.kind == "cover")
        and record.remote_path:sub(1, 14) == "/book.cbz#zip/"
end)
expect(not ok and failed == 1, "file deletion failures must be reported")
expect(retained == 20, "protected generated files must be accounted as retained")
expect(cache.entries.old == nil and files["/cache/old.jpg"] == nil,
    "matching generated pages must be removed from disk and index")
expect(cache.entries.failed and files[failed_path],
    "failed deletion must keep the record for capacity accounting")
expect(cache.entries.protected and files["/cache/protected.jpg"],
    "protected generated files must remain")
expect(cache.entries.document and files["/cache/complete.cbz"],
    "complete document cache must never be removed by page invalidation")
expect(stored.entries == cache.entries, "successful removals must flush the updated index")

print(("rebuild_0374_cache_invalidation_spec: %d checks"):format(checks))
