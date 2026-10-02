local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local saved = {}
local store = {
    readSetting = function(_, key, default)
        return saved[key] == nil and default or saved[key]
    end,
    saveSetting = function(_, key, value) saved[key] = value end,
    flush = function() return true end,
}

local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")
local settings = Settings:new{ store = store }
local tone_model
local sample_model
local preview_model
local saved_notifications = 0
local ui = {
    show_reader = function() return true end,
    show_tone_settings = function(_, model) tone_model = model; return true end,
    show_tone_sample_path = function(_, model) sample_model = model; return true end,
    show_tone_preview = function(_, model) preview_model = model; return true end,
    show_tone_preset_editor = function() return true end,
    show_info = function() return true end,
    confirm = function() return true end,
}
local controller = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {}, ui = ui,
    on_reader_saved = function() saved_notifications = saved_notifications + 1 end,
}

expect(settings:get_reader().tone_adjust_sample_path == "",
    "tone sample path must default to empty")
local ok, reason = settings:set_tone_sample_path("/mnt/us/Books/ToneSamples")
expect(ok == true and reason == nil
    and settings:get_reader().tone_adjust_sample_path == "/mnt/us/Books/ToneSamples",
    "tone sample path must be normalized and persisted")
ok, reason = settings:set_tone_sample_path("relative/path")
expect(ok == nil and reason == "invalid_tone_sample_path",
    "tone sample path must reject non-absolute paths")

controller:show_tone_settings()
expect(tone_model and tone_model.sample_path == "/mnt/us/Books/ToneSamples"
    and type(tone_model.on_sample_path) == "function"
    and type(tone_model.on_preview) == "function",
    "tone settings must expose sample path and preview actions")
tone_model.on_sample_path()
expect(sample_model and sample_model.value == "/mnt/us/Books/ToneSamples",
    "tone sample path dialog must receive the saved value")
tone_model.on_toggle()
controller:show_tone_settings()
expect(type(tone_model.on_preview) == "function",
    "tone preview action must remain available after enabling")

local added, preset_id = settings:add_tone_preset{
    name = "明显", brightness = 24, contrast = 150,
}
expect(added == true and preset_id == "custom-1", "tone preset setup")
controller:show_tone_settings()
expect(tone_model.on_select("custom-1") == true and saved_notifications > 0,
    "selecting a tone preset must notify the active reader to reload")

print(("rebuild_0377_tone_preview_spec: %d checks"):format(checks))
