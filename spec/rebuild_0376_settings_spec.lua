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
local settings = Settings:new{ store = store }
local reader = settings:get_reader()
expect(reader.tone_adjust_enabled == false and reader.tone_adjust_preset == "original"
    and #reader.tone_adjust_custom_presets == 0,
    "brightness and contrast must default to a disabled neutral preset")

local ok, reason = settings:set_reader{ tone_adjust_enabled = "yes" }
expect(ok == nil and reason == "invalid_tone_adjust_enabled",
    "the tone switch must reject non-boolean values")
ok, reason = settings:set_reader{ tone_adjust_preset = "missing" }
expect(ok == nil and reason == "invalid_tone_preset",
    "the selected tone preset must exist")

local added, preset_id = settings:add_tone_preset{
    name = "夜间", brightness = -12, contrast = 135,
}
expect(added == true and preset_id == "custom-1",
    "adding a valid tone preset must allocate a stable custom id")
reader = settings:get_reader()
expect(reader.tone_adjust_preset == "custom-1"
    and reader.tone_adjust_custom_presets[1].brightness == -12,
    "a newly added preset must be selected and persisted")

expect(settings:update_tone_preset("custom-1", {
    name = "纸张", brightness = 8, contrast = 110,
}), "custom tone presets must be editable")
reader = settings:get_reader()
expect(reader.tone_adjust_custom_presets[1].name == "纸张"
    and reader.tone_adjust_custom_presets[1].contrast == 110,
    "updated tone parameters must survive a settings reload")

ok, reason = settings:update_tone_preset("original", {
    name = "错误", brightness = 0, contrast = 100,
})
expect(ok == nil and reason == "cannot_edit_builtin_tone_preset",
    "the immutable original preset must not be editable")
ok, reason = settings:remove_tone_preset("original")
expect(ok == nil and reason == "cannot_delete_builtin_tone_preset",
    "the immutable original preset must not be removable")

expect(settings:remove_tone_preset("custom-1"),
    "a custom tone preset must be removable")
reader = settings:get_reader()
expect(reader.tone_adjust_preset == "original"
    and #reader.tone_adjust_custom_presets == 0,
    "removing the selected preset must restore the neutral preset")

saved.reader = {
    tone_adjust_enabled = true,
    tone_adjust_preset = "missing",
    tone_adjust_custom_presets = {
        { id = "custom-2", name = "有效", brightness = 20, contrast = 90 },
        { id = "bad", name = "无效", brightness = 0, contrast = 100 },
    },
}
reader = settings:get_reader()
expect(reader.tone_adjust_enabled == true and reader.tone_adjust_preset == "original"
    and #reader.tone_adjust_custom_presets == 1,
    "legacy malformed tone settings must sanitize without blocking plugin startup")

print(("rebuild_0376_settings_spec: %d checks"):format(checks))
