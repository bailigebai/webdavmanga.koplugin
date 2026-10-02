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
local reader_model, tone_model, editor_model
local ui = {
    show_reader = function(_, model) reader_model = model; return true end,
    show_tone_settings = function(_, model) tone_model = model; return true end,
    show_tone_preset_editor = function(_, model) editor_model = model; return true end,
    show_info = function() return true end,
    confirm = function() return true end,
}
local controller = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {}, ui = ui,
}

controller:show_reader()
expect(reader_model and #reader_model.tone_presets == 1
    and type(reader_model.on_open_tone_settings) == "function",
    "the main reader settings model must expose tone presets and its submenu")
reader_model.on_open_tone_settings()
expect(tone_model and tone_model.enabled == false
    and tone_model.selected_id == "original" and #tone_model.presets == 1,
    "the tone submenu must start disabled on the neutral preset")

tone_model.on_toggle()
expect(settings:get_reader().tone_adjust_enabled == true and tone_model.enabled == true,
    "the tone submenu switch must persist independently")
tone_model.on_add()
expect(editor_model and editor_model.is_new == true
    and editor_model.values.brightness == 0 and editor_model.values.contrast == 100,
    "adding a preset must open a compact neutral editor")
expect(editor_model.on_save{ name = "清晰纸张", brightness = 10, contrast = 115 },
    "a valid tone preset must save from the editor")
local reader = settings:get_reader()
expect(reader.tone_adjust_preset == "custom-1"
    and reader.tone_adjust_custom_presets[1].contrast == 115,
    "the editor must persist and select the new tone preset")

print(("rebuild_0376_tone_ui_spec: %d checks"):format(checks))
