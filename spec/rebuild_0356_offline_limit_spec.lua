local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local values = {}
local store = {
    readSetting = function(_self, key, default)
        local value = values[key]
        return value == nil and default or value
    end,
    saveSetting = function(_self, key, value) values[key] = value end,
    flush = function() return true end,
}
local settings = Settings:new{ store = store }

expect(settings:get_offline_limit_gb() == 5, "offline total limit defaults to 5 GB")
expect(settings:set_offline_limit_gb(1) == true)
expect(settings:get_offline_limit_gb() == 1)
expect(settings:set_offline_limit_gb(20) == true)
expect(select(2, settings:set_offline_limit_gb(0)) == "invalid_offline_limit")
expect(select(2, settings:set_offline_limit_gb(21)) == "invalid_offline_limit")
expect(select(2, settings:set_offline_limit_gb(1.5)) == "invalid_offline_limit")

local shown
local controller = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = {},
    cache = {},
    offline_cache = { stats = function()
        return { root = "/mnt/us/Books/WebDAVManga", offline_bytes = 0,
            manga_bytes = 0, total_bytes = 0, used_bytes = 0,
            available_bytes = 20 * 1024 * 1024 * 1024,
            reserve_bytes = 5 * 1024 * 1024 * 1024 }
    end },
    offline_manager = { status = function()
        return { running = false, status = "idle" }
    end },
    ui = {
        show_offline_cache = function(_self, model) shown = model end,
        show_info = function() end,
    },
}

controller:show_offline_cache()
expect(shown.limit_gb == 20 and type(shown.on_set_limit) == "function")
expect(shown.on_set_limit("6") == true and settings:get_offline_limit_gb() == 6)
expect(shown.on_set_limit("0") == false)

print(("rebuild_0356_offline_limit_spec: %d checks"):format(checks))
