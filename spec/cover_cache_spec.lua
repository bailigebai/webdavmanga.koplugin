local Cache = require("webdavmanga.cache")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local files = {}
local remove_calls = 0
local function put(path, size)
    files[path] = { size = size }
end
local fs = {
    make_path = function() end,
    exists = function(path) return files[path] ~= nil end,
    size = function(path) return files[path] and files[path].size or nil end,
    rename = function(source, target)
        if not files[source] then return nil, "missing source" end
        files[target] = files[source]
        files[source] = nil
        return true
    end,
    remove = function(path)
        remove_calls = remove_calls + 1
        files[path] = nil
        return true
    end,
    list = function(root)
        local result = {}
        for path, attributes in pairs(files) do
            if path:sub(1, #root + 1) == root .. "/" then
                result[#result + 1] = {
                    path = path, name = path:match("([^/]+)$"), size = attributes.size,
                }
            end
        end
        return result
    end,
}
local stored = { schema_version = 3, entries = {} }
local store = {
    readSetting = function(_, key, default)
        return stored[key] == nil and default or stored[key]
    end,
    saveSetting = function(_, key, value) stored[key] = value end,
    flush = function() end,
}

local cache = Cache:new{
    root = "/cache/covers",
    limit_bytes = 1000,
    cover_limit_bytes = 120,
    store = store,
    fs = fs,
    md5 = function() return string.rep("a", 32) end,
    clock = function() return 10 end,
}
local cover_final, cover_part = cache:paths_for(string.rep("a", 32), "jpg")
put(cover_part, 80)
expect(cache:publish({
    key = string.rep("a", 32), kind = "cover", remote_path = "/cover.jpg",
    extension = "jpg", validated = true, format = "jpeg", width = 20, height = 30,
}, cover_part) == cover_final, "a cover should publish into the shared cache")

local page_key = string.rep("b", 32)
local page_final, page_part = cache:paths_for(page_key, "jpg")
put(page_part, 120)
expect(cache:publish({
    key = page_key, kind = "page", remote_path = "/page.jpg",
    extension = "jpg", validated = true, format = "jpeg", width = 20, height = 30,
}, page_part) == page_final, "a page should publish alongside a cover")
expect(cache:kind_size("cover") == 80 and cache:kind_count("cover") == 1,
    "cover accounting should report bytes and count")
expect(cache:kind_size("page") == 120 and cache:kind_count("page") == 1,
    "page accounting should remain separate")

local quota_cache = Cache:new{
    root = "/cache/quota",
    limit_bytes = 100,
    cover_limit_bytes = 50,
    store = store,
    fs = fs,
    md5 = function() return string.rep("c", 32) end,
    clock = function() return 20 end,
}
local quota_cover, quota_cover_part = quota_cache:paths_for(string.rep("c", 32), "jpg")
put(quota_cover_part, 40)
expect(quota_cache:publish({
    key = string.rep("c", 32), kind = "cover", remote_path = "/quota-cover.jpg",
    extension = "jpg", validated = true, format = "jpeg", width = 20, height = 30,
}, quota_cover_part) == quota_cover, "cover should use its own quota")
local quota_page, quota_page_part = quota_cache:paths_for(string.rep("d", 32), "jpg")
put(quota_page_part, 90)
expect(quota_cache:publish({
    key = string.rep("d", 32), kind = "page", remote_path = "/quota-page.jpg",
    extension = "jpg", validated = true, format = "jpeg", width = 20, height = 30,
}, quota_page_part) == quota_page,
    "page quota should not be reduced by cover bytes")
expect(quota_cache:kind_size("cover") == 40
    and quota_cache:kind_size("page") == 90,
    "cover and page quotas should be accounted independently")
expect(quota_cache:set_cover_limit_bytes(30) == true
    and quota_cache:kind_size("cover") <= 30
    and quota_cache:kind_size("page") == 90,
    "cover quota changes should evict covers without touching pages")

local removes_before = remove_calls
local clear_ok, retained = cache:clear_kind_cache("cover")
expect(clear_ok and retained == 0 and cache:kind_size("cover") == 0
    and cache:kind_count("cover") == 0,
    "cover cleanup should remove cover records")
expect(files[cover_final] == nil and files[page_final] ~= nil
    and remove_calls == removes_before + 1,
    "cover cleanup should remove only plugin-owned cover files")
expect(cache:kind_size("page") == 120 and cache:kind_count("page") == 1,
    "cover cleanup must leave page records untouched")

local clear_pages_ok = cache:clear_except_kind_index("cover")
expect(clear_pages_ok and cache:kind_size("page") == 0
    and files[page_final] ~= nil and remove_calls == removes_before + 1,
    "image index cleanup must leave physical files in place")

print(("cover_cache_spec: %d checks"):format(checks))
