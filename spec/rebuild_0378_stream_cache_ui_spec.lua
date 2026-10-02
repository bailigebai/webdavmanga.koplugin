local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local saved = {}
local settings = {
    get_browse_cache = function()
        return { total_mb = 5120, trigger_mb = 3072, retain_mb = 1024,
            interval_minutes = 10 }
    end,
    set_browse_cache = function(_, values) saved.browse = values; return true end,
    flush = function() end,
    get_reader = function() return { cache_limit_mb = 200, cover_cache_limit_mb = 200 } end,
    set_reader = function() return true end,
}
local shown
local ui = {
    show_cache = function(_, model) shown = model end,
    show_info = function() end,
}
local cache = {
    limit_bytes = 200 * 1024 * 1024,
    total_size = function() return 250 end,
    kind_size = function(_, kind) return kind == "cover" and 50 or 0 end,
    kind_count = function() return 1 end,
    protected_size = function() return 0 end,
    stream_size = function() return 125 end,
    stream_policy = function()
        return { total_bytes = 5120 * 1024 * 1024,
            trigger_bytes = 3072 * 1024 * 1024,
            retain_bytes = 1024 * 1024 * 1024,
            check_interval_seconds = 600 }
    end,
    set_stream_policy = function(_, values) saved.stream = values; return true end,
    clear_stream_cache = function() return true, { removed = 2, freed_bytes = 125 } end,
    cleanup_stream = function() return 0, false, "below_trigger" end,
    set_limit_bytes = function() return true end,
}
local UiSettings = require("webdavmanga.ui_settings")
local controller = UiSettings:new{
    settings = settings, client_factory = function() return {} end,
    async = { run = function() end }, cache = cache, ui = ui,
    offline_cache = { stats = function() return { available_bytes = 2048 * 1024 } end },
}

controller:show_cache()
expect(shown and type(shown.on_stream_cache) == "function",
    "main cache view must expose a stream cache action")
shown.on_stream_cache()
expect(shown and shown.kind == "stream" and shown.used_mb == 125 / (1024 * 1024),
    "stream cache view must report page/manifest bytes")
expect(shown.available_mb == 2,
    "stream cache view must expose Kindle available storage")
expect(type(shown.on_set_browse_policy) == "function"
    and type(shown.on_clear) == "function",
    "stream cache view must expose policy and manual clear callbacks")
expect(shown.on_clear() == true,
    "stream cache manual clear must complete through the UI callback")

print(("rebuild_0378_stream_cache_ui_spec: %d checks"):format(checks))
