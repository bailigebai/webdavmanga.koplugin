local Catalog = require("webdavmanga.opds_catalog")
local Settings = require("webdavmanga.settings")

local values = {}
local store = {
    readSetting = function(_self, key) return values[key] end,
    saveSetting = function(_self, key, value) values[key] = value end,
    flush = function() end,
}
local settings = Settings:new{ store = store }
assert(settings:add_source{ name = "NAS", server_url = "https://nas.example",
    root_path = "/" })
local catalog = Catalog:new{
    settings = settings,
    client_factory = function() return {
        fetch = function(_self, url, auth)
            assert(url == "https://example.test/opds")
            assert(auth.username == "u" and auth.password == "p")
            return { title = "根目录", entries = {} }
        end,
    } end,
}
local first = assert(catalog:save{name = "测试", url = "https://example.test/opds",
    username = "u", password = "p"})
assert(first.id and first.name == "测试")
assert(settings:get_source(first.id).kind == "opds")
assert(catalog:set_active(first.id))
assert(catalog:active().id == first.id)
local feed = assert(catalog:fetch_active())
assert(feed.title == "根目录")
local updated = assert(catalog:save{name = "新名称", url = first.url, id = first.id})
assert(updated.name == "新名称")
assert(#catalog:list() == 1)
assert(catalog:remove(first.id))
assert(catalog:active() == nil)
assert(#settings:get_sources() == 1 and settings:get_sources()[1].kind == "webdav")

local function copy_table(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, child in pairs(value) do copied[key] = copy_table(child) end
    return copied
end

local function durable_store(initial)
    local disk = copy_table(initial or {})
    local store = { values = copy_table(disk), failure = nil }
    function store:readSetting(key, default)
        if self.values[key] == nil then return default end
        return self.values[key]
    end
    function store:saveSetting(key, value) self.values[key] = value end
    function store:flush()
        if self.failure == "throw" then error("simulated disk failure") end
        if self.failure == "false" then return false end
        disk = copy_table(self.values)
        return true
    end
    function store:restart()
        self.values = copy_table(disk)
        self.failure = nil
    end
    return store
end

for _, failure in ipairs({ "false", "throw" }) do
    local sources = durable_store()
    local legacy = durable_store{ catalogs = {
        { id = "old", name = "旧源", url = "https://legacy.example/opds" },
    } }
    local current = Settings:new{ store = sources }
    local importer = Catalog:new{ settings = current, legacy_store = legacy,
        client_factory = function() return {} end }
    sources.failure = failure
    assert(not importer:migrate_legacy_once(),
        "source flush " .. failure .. " must fail migration")
    assert(legacy.values.migrated_to_sources_v1 ~= true,
        "source flush " .. failure .. " must not mark migration complete")
    sources:restart()
    legacy:restart()
    local after_restart = Catalog:new{ settings = Settings:new{ store = sources },
        legacy_store = legacy, client_factory = function() return {} end }
    assert(after_restart:migrate_legacy_once() and #after_restart:list() == 1
        and legacy.values.migrated_to_sources_v1 == true,
        "source flush " .. failure .. " must be retryable after restart")
end

for _, failure in ipairs({ "false", "throw" }) do
    local sources = durable_store()
    local legacy = durable_store{ catalogs = {
        { id = "old", name = "旧源", url = "https://legacy.example/opds" },
    } }
    local importer = Catalog:new{ settings = Settings:new{ store = sources },
        legacy_store = legacy, client_factory = function() return {} end }
    legacy.failure = failure
    assert(not importer:migrate_legacy_once(),
        "marker flush " .. failure .. " must report migration failure")
    assert(legacy.values.migrated_to_sources_v1 ~= true,
        "marker flush " .. failure .. " must leave an in-memory retry path")
    legacy.failure = nil
    assert(importer:migrate_legacy_once() and #importer:list() == 1,
        "marker flush " .. failure .. " must retry without duplicating sources")
    sources:restart()
    legacy:restart()
    assert(legacy.values.migrated_to_sources_v1 == true
        and #Catalog:new{ settings = Settings:new{ store = sources },
            legacy_store = legacy, client_factory = function() return {} end }:list() == 1,
        "marker flush " .. failure .. " must survive restart")
end

print("opds_catalog_spec: passed")
