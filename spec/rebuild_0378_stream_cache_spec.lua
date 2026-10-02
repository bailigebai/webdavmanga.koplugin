local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local saved = {}
local files = {
    ["/cache/page.jpg"] = true,
    ["/cache/index.manifest"] = true,
    ["/cache/cover.jpg"] = true,
    ["/cache/book.pdf"] = true,
}
local removed = {}
local fs = {
    make_path = function() return true end,
    exists = function(path) return files[path] == true end,
    size = function(path)
        local sizes = {
            ["/cache/page.jpg"] = 100,
            ["/cache/index.manifest"] = 25,
            ["/cache/cover.jpg"] = 50,
            ["/cache/book.pdf"] = 200,
        }
        return sizes[path]
    end,
    remove = function(path)
        removed[path] = true
        files[path] = nil
        return true
    end,
    list = function() return function() return nil end end,
}
local store = {
    readSetting = function(_, key, default)
        return saved[key] == nil and default or saved[key]
    end,
    saveSetting = function(_, key, value) saved[key] = value end,
    flush = function() return true end,
}

local Cache = require("webdavmanga.cache")
local cache = Cache:new{
    root = "/cache", limit_bytes = 1000, store = store, fs = fs,
    md5 = function(value) return string.rep("a", 32) end,
    clock = function() return 100 end,
}
cache.entries = {
    page = { key = string.rep("1", 32), kind = "page", remote_path = "/p",
        path = "/cache/page.jpg", size = 100, extension = "jpg", validated = true,
        format = "jpeg", width = 10, height = 10, atime = 1 },
    manifest = { key = string.rep("2", 32), kind = "manifest", remote_path = "/m",
        path = "/cache/index.manifest", size = 25, extension = "manifest", validated = true,
        atime = 2 },
    cover = { key = string.rep("3", 32), kind = "cover", remote_path = "/c",
        path = "/cache/cover.jpg", size = 50, extension = "jpg", validated = true,
        format = "jpeg", width = 10, height = 10, atime = 3 },
    document = { key = string.rep("4", 32), kind = "document", remote_path = "/d",
        path = "/cache/book.pdf", size = 200, extension = "pdf", validated = true,
        format = "pdf", atime = 4 },
}
cache.protected_keys = { page = true }

expect(cache:stream_size() == 125, "stream size must include page and manifest only")
local policy = cache:stream_policy()
expect(policy.total_bytes == cache:browse_policy().total_bytes,
    "stream policy must reuse the existing browse policy")
local ok = cache:set_stream_policy{total_bytes = 1024, trigger_bytes = 512,
    retain_bytes = 128, check_interval_seconds = 60}
expect(ok == true and cache:browse_policy().total_bytes == 1024,
    "stream policy must update the shared browse policy")

local cleared, summary = cache:clear_stream_cache()
expect(cleared == true and summary.removed == 1,
    "manual stream clear must remove only unprotected page/manifest records")
expect(removed["/cache/page.jpg"] ~= true and removed["/cache/index.manifest"] == true,
    "manual stream clear must keep protected page and clear manifest")
expect(removed["/cache/cover.jpg"] ~= true and removed["/cache/book.pdf"] ~= true,
    "stream clear must never remove cover or complete document records")
expect(cache:stream_size() == 100,
    "stream size must reflect the protected page after clear")

print(("rebuild_0378_stream_cache_spec: %d checks"):format(checks))
