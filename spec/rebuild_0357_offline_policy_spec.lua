local Settings = require("webdavmanga.settings")
local OfflineCache = require("webdavmanga.offline_cache")
local UiLibrary = require("webdavmanga.ui_library")
local UiSettings = require("webdavmanga.ui_settings")

local GB = 1024 * 1024 * 1024
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function store()
    local object = { values = {}, flushes = 0 }
    function object:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function object:saveSetting(key, value) self.values[key] = value end
    function object:flush() self.flushes = self.flushes + 1; return true end
    return object
end

local settings_store = store()
local settings = Settings:new{ store = settings_store }
expect(settings:get_offline_refresh_seconds() == 15,
    "offline shelf refresh must default to fifteen seconds")
expect(settings:set_offline_refresh_seconds(1) == true
    and settings:set_offline_refresh_seconds(60) == true,
    "offline shelf refresh must accept the inclusive 1-60 second range")
expect(select(2, settings:set_offline_refresh_seconds(0)) == "invalid_offline_refresh"
    and select(2, settings:set_offline_refresh_seconds(61)) == "invalid_offline_refresh",
    "offline shelf refresh must reject values outside the inclusive range")

local cache_store = store()
local root = "/mnt/us/OfflineManga"
local cache = OfflineCache:new{
    store = cache_store, root_provider = function() return root end,
    disk_usage = function() return { available = 8 * GB, total = 16 * GB, used = 8 * GB } end,
    fs = { make_path = function() return true end }, md5 = function(value) return value end,
}
expect(cache.reserve_bytes == 5 * GB, "offline cache must reserve five GB by default")
expect(select(2, cache:can_store(3 * GB + 1)) == "reserve_space",
    "offline cache must reject writes that consume the five GB reserve")

local scheduled, unscheduled = {}, {}
local scheduler = {
    scheduleIn = function(_self, seconds, callback)
        scheduled[#scheduled + 1] = { seconds = seconds, callback = callback }
        return true
    end,
    unschedule = function(_self, callback) unscheduled[#unscheduled + 1] = callback end,
}
local list_calls, progress_calls = 0, 0
local shelf_cache = {
    root = function() return root end,
    list_mangas = function()
        list_calls = list_calls + 1
        return {{ manga = { name = "离线漫画", path = "/Books/Manga" }, progress = 0.5,
            cover_path = "/mnt/us/OfflineManga/cover.jpg" }}
    end,
}
local grid = {
    view_sequence = 0,
    show = function(self, model) self.model = model; self.view_sequence = self.view_sequence + 1; return true end,
    update_progress = function() progress_calls = progress_calls + 1; return true end,
    cancel = function() end,
}
local library = { ALL = "all", UNCATEGORIZED = "uncategorized" }
local ui_library = UiLibrary:new{
    settings = { get_connection = function() return { server_url = "http://nas", root_path = "/Books" } end },
    library = library, cover_service = {}, cover_grid = grid,
    browser = {}, ui = { close_all = function() end, show_info = function() end },
    offline_cache = shelf_cache,
    identity_provider = function() return "identity" end,
    scheduler = scheduler,
}
expect(ui_library:show_offline_shelf() == true and #scheduled == 1
    and scheduled[1].seconds == 15, "opening offline shelf must schedule one fifteen-second refresh")
expect(ui_library:show_offline_shelf() == true and #scheduled == 2,
    "reopening offline shelf must replace rather than stack its refresh task")
local task = scheduled[#scheduled].callback
task()
expect(list_calls == 3 and progress_calls == 1,
    "refresh task must read the local index and update existing cover progress only")
expect(#scheduled == 3 and #unscheduled >= 1,
    "refresh task must schedule its next run and cancel the prior run")
ui_library:cancel()
expect(#unscheduled >= 2, "leaving the shelf must unschedule its refresh task")

local saved_limit = 5
local saved_refresh = 15
local available = 12 * GB
local flush_mode = "ok"
local shown_model
local ui_settings = UiSettings:new{
    settings = {
        get_offline_root = function() return root end,
        get_offline_limit_gb = function() return saved_limit end,
        set_offline_limit_gb = function(_self, value) saved_limit = tonumber(value); return true end,
        get_offline_refresh_seconds = function() return saved_refresh end,
        set_offline_refresh_seconds = function(_self, value) saved_refresh = tonumber(value); return true end,
        flush = function()
            if flush_mode == "throw" then error("flush failed") end
            return flush_mode == "ok"
        end,
    },
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {},
    offline_cache = { stats = function() return { root = root, available_bytes = available,
        reserve_bytes = 5 * GB, offline_bytes = 0, total_bytes = available, used_bytes = 0 } end },
    offline_manager = { status = function() return { running = false, status = "idle" } end },
    identity_provider = function() return "identity" end,
    ui = { show_offline_cache = function(_self, model) shown_model = model end,
        show_info = function() end },
}
expect(ui_settings:show_offline_cache() == true and shown_model.on_set_limit(7) == true
    and saved_limit == 7, "offline limit must accept available minus five GB")
expect(shown_model.on_set_limit(8) == false and saved_limit == 7,
    "offline limit must reject values that consume the five GB reserve")
flush_mode = "false"
expect(shown_model.on_set_limit(6) == false and saved_limit == 7,
    "offline limit must roll back when settings flush returns false")
flush_mode = "throw"
expect(shown_model.on_set_limit(6) == false and saved_limit == 7,
    "offline limit must roll back when settings flush throws")
flush_mode = "ok"
available = 0
expect(shown_model.on_set_limit(1) == false and saved_limit == 7,
    "unknown or unavailable space must reject offline limit changes")
ui_settings.offline_cache.stats = function() error("stat unavailable") end
expect(shown_model.on_set_limit(1) == false and saved_limit == 7,
    "disk stat errors must reject offline limit changes")
flush_mode = "false"
expect(shown_model.on_set_refresh(10) == false and saved_refresh == 15,
    "refresh interval must roll back when settings flush returns false")
flush_mode = "throw"
expect(shown_model.on_set_refresh(10) == false and saved_refresh == 15,
    "refresh interval must roll back when settings flush throws")
flush_mode = "ok"

root = "/mnt/us/ChangedRoot"
expect(ui_library:show_offline_shelf() == true)
local before_root_cancel = #unscheduled
ui_library:invalidate_offline_shelf()
expect(#unscheduled > before_root_cancel,
    "changing the cache root and invalidating the shelf must cancel refresh")

print(("rebuild_0357_offline_policy_spec: %d checks"):format(checks))
