local Cache = require("webdavmanga.cache")
local checks, failures = 0, {}
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

-- LuaFileSystem returns nil, error text when stat fails. Exercise the real
-- default adapter too: replacing only fs.size would miss its tuple forwarding.
local function fixture(use_default)
    local files, listed = {}, {}
    local function size(path)
        local file = files[path]
        if file and not file.stat_error then return file.size end
        return nil, "cannot obtain information from file"
    end
    local function exists(path) return files[path] ~= nil end
    local fs = {
        make_path = function() return true end,
        size = size, exists = exists,
        list = function() return listed end,
        rename = function(source, target)
            if not files[source] then return nil, "source missing" end
            files[target], files[source] = files[source], nil
            return true
        end,
        remove = function(path) files[path] = nil; return true end,
    }
    if use_default then
        package.loaded["libs/libkoreader-lfs"] = {
            attributes = function(path, attribute)
                if attribute == "size" then return size(path) end
                if attribute == "mode" then return exists(path) and "file" or nil end
                for _, entry in ipairs(listed) do
                    if entry.path == path then
                        return { mode = "file", size = entry.size, modification = 1 }
                    end
                end
                return nil, "cannot obtain information from file"
            end,
            dir = function()
                local index = 0
                return function()
                    index = index + 1
                    return listed[index] and listed[index].name
                end
            end,
        }
        package.loaded.util = { makePath = fs.make_path }
    end
    local stored = { schema_version = 3, entries = {} }
    local cache = Cache:new{
        root = "/cache", limit_bytes = 1000, unified_quota = true,
        fs = not use_default and fs or nil,
        md5 = function() return string.rep("a", 32) end,
        clock = function() return 100 end,
        store = {
            readSetting = function(_, key, default)
                if stored[key] == nil then return default end
                return stored[key]
            end,
            saveSetting = function(_, key, value) stored[key] = value end,
            flush = function() return true end,
        },
    }
    return cache, files, listed
end

local cases = {
    { "missing active part preserves shelf budget", function(cache)
        cache:paths_for(string.rep("a", 32), "manifest", "writer")
        expect(cache:pending_size() == 0, "an uncreated part occupies zero bytes")
        expect(cache:total_size() == 0, "shelf total tolerates an uncreated part")
        expect(cache:write_budget(100, 0) == 900, "directory load can admit a writer")
        local freed, changed, reason = cache:cleanup_browse(true)
        expect(freed == 0 and changed == false and reason == "below_trigger",
            "periodic bookshelf maintenance tolerates an uncreated part")
    end },
    { "stat failure after directory scan uses auxiliary size", function(cache, files, listed)
        local _, part = cache:paths_for(string.rep("a", 32), "manifest", "writer")
        files[part] = { size = 20 }
        local auxiliary = part .. ".wdm-worker-spool"
        listed[1] = { path = auxiliary, name = auxiliary:match("([^/]+)$"), size = 30 }
        expect(cache:pending_size() == 50, "auxiliary scan size survives a later failed stat")
    end },
    { "unavailable document size keeps existing lookup semantics", function(cache, files)
        local key = string.rep("b", 32)
        local path = "/cache/" .. key .. ".pdf"
        cache.entries[key] = { key = key, path = path, size = 70, kind = "document",
            extension = "pdf", remote_path = "/book.pdf", validated = true, atime = 1 }
        files[path] = { size = 70, stat_error = true }
        expect(cache:lookup_record(key) == path, "unknown stat size preserves a validated document")
        files[path] = nil
        expect(cache:lookup_record(key) == nil and cache.entries[key] == nil,
            "a missing document still invalidates its index")
    end },
    { "missing publish part returns an ordinary cache error", function(cache)
        local _, part = cache:paths_for(string.rep("a", 32), "manifest", "writer")
        local path, err = cache:publish({ kind = "manifest" }, part)
        expect(path == nil and err == "empty_part", "unknown empty part is rejected without throwing")
        expect(next(cache.entries) == nil, "failed publish cannot create a cache entry")
    end },
    { "valid part byte count remains authoritative", function(cache, files)
        local _, part = cache:paths_for(string.rep("a", 32), "manifest", "writer")
        files[part] = { size = 25 }
        expect(cache:pending_size() == 25, "ordinary numeric size is counted")
        expect(cache:write_budget(100, 0) == 875, "ordinary part bytes reduce the budget")
    end },
}

for _, use_default in ipairs({ true, false }) do
    for _, case in ipairs(cases) do
        local cache, files, listed = fixture(use_default)
        local ok, err = pcall(case[2], cache, files, listed)
        if not ok then
            failures[#failures + 1] = (use_default and "default adapter: " or "injected filesystem: ")
                .. case[1] .. ": " .. tostring(err)
        end
    end
end
assert(#failures == 0, table.concat(failures, "\n"))
print(("rebuild_0418_cache_size_spec: %d checks"):format(checks))
