local KeyboardCompat = {}

-- Bump this when the repair logic changes.  A migration must be able to
-- recover devices that still carry an older marker but have the global
-- virtual keyboard disabled again.
local REPAIR_VERSION = 2
local REPAIR_KEY = "koreader_virtual_keyboard_repair"

local function call_method(object, method, ...)
    if type(object) ~= "table" or type(object[method]) ~= "function" then return nil end
    local ok, result = pcall(object[method], object, ...)
    if not ok then return nil end
    return result
end

local function is_target_device(device)
    if type(device) ~= "table" or device.model ~= "KindlePaperWhite6" then
        return false
    end
    return call_method(device, "isTouchDevice") == true
end

function KeyboardCompat.ensure(options)
    options = options or {}
    local device = options.device
    local global_settings = options.global_settings
    local plugin_store = options.plugin_store
    if not is_target_device(device) then return false, "not_target" end
    if type(global_settings) ~= "table" then return false, "settings_unavailable" end

    local repaired = call_method(plugin_store, "readSetting", REPAIR_KEY, 0)
    if tonumber(repaired) and tonumber(repaired) >= REPAIR_VERSION then
        return false, "already_repaired"
    end

    local enabled = call_method(global_settings, "isTrue", "virtual_keyboard_enabled") == true
    if not enabled then
        if type(global_settings.makeTrue) == "function" then
            local ok = pcall(global_settings.makeTrue, global_settings,
                "virtual_keyboard_enabled")
            if not ok then return false, "enable_failed" end
        elseif type(global_settings.saveSetting) == "function" then
            local ok = pcall(global_settings.saveSetting, global_settings,
                "virtual_keyboard_enabled", true)
            if not ok then return false, "enable_failed" end
        else
            return false, "settings_read_only"
        end
        call_method(global_settings, "flush")
    end

    if type(plugin_store) == "table" and type(plugin_store.saveSetting) == "function" then
        pcall(plugin_store.saveSetting, plugin_store, REPAIR_KEY, REPAIR_VERSION)
        call_method(plugin_store, "flush")
    end
    return not enabled, enabled and "already_enabled" or "enabled"
end

KeyboardCompat.REPAIR_KEY = REPAIR_KEY
KeyboardCompat.REPAIR_VERSION = REPAIR_VERSION

return KeyboardCompat
