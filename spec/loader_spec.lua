local Loader = require("webdavmanga.loader")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local image = { name = "001.jpg", path = "/mnt/us/Comics/001.jpg", size = 300 * 1024 * 1024 }
local cache_calls = { lookup = 0, paths = 0, publish = 0, discard = 0 }
local cache = {
    limit_bytes = 200 * 1024 * 1024,
    cover_limit_bytes = 500 * 1024 * 1024,
    key_for = function(_self, identity, path) return identity .. "|" .. path end,
    lookup = function() cache_calls.lookup = cache_calls.lookup + 1 end,
    paths_for = function() cache_calls.paths = cache_calls.paths + 1; return "/cache/final", "/cache/part" end,
    publish = function() cache_calls.publish = cache_calls.publish + 1; return "/cache/final" end,
    discard_part = function() cache_calls.discard = cache_calls.discard + 1 end,
}
local client_calls = { resolve = 0, download = 0 }
local client = {
    resolve = function(_self, path)
        client_calls.resolve = client_calls.resolve + 1
        return path, { direct = true, format = "jpeg", width = 1200, height = 1600 }
    end,
    download = function()
        client_calls.download = client_calls.download + 1
        return nil, { code = "unexpected_download" }
    end,
}
local async = {
    run = function(work, callback)
        local ok, result = pcall(work)
        callback(ok, result, ok and nil or result, {})
        return { cancel = function() end }
    end,
}
local ready_path, ready_metadata
local loader = Loader:new{
    client_factory = function() return client end,
    cache = cache,
    async = async,
    identity = "local",
    source_kind_provider = function() return "local" end,
    prefetch_count = 2,
}
expect(loader:_exceeds_limit(image, "cover") == false
    and loader:_exceeds_limit(image, "page") == true,
    "cover requests must use the independent cover quota")
assert(loader:request(1, image, {
    on_ready = function(path, was_cached, metadata)
        ready_path, ready_metadata = path, metadata
        expect(was_cached == false, "direct local pages are not reported as cache hits")
    end,
    on_error = function() error("direct local resolve should succeed") end,
}))
expect(ready_path == image.path and ready_metadata.direct == true
    and client_calls.resolve == 1 and client_calls.download == 0,
    "local page requests should resolve and render the original file")
expect(cache_calls.lookup == 0 and cache_calls.paths == 0 and cache_calls.publish == 0
    and cache_calls.discard == 0,
    "direct local page requests must not touch the plugin cache")
expect(loader:request(1, { name = "002.jpg", path = "/mnt/us/Comics/002.jpg" }, {})
    and client_calls.resolve == 2,
    "a second local page should use the same direct path")

local prefetched_image, prefetched_path
loader:prefetch(2, {
    { name = "002.jpg", path = "/mnt/us/Comics/002.jpg" },
    { name = "003.jpg", path = "/mnt/us/Comics/003.jpg" },
}, 1, function(item, path)
    prefetched_image, prefetched_path = item, path
end)
expect(prefetched_image and prefetched_image.name == "003.jpg"
    and prefetched_path == "/mnt/us/Comics/003.jpg",
    "prefetch must expose each ready raw page to optional processing consumers")

print(("loader_spec: %d checks"):format(checks))
