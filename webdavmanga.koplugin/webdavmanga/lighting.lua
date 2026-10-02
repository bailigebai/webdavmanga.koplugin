-- Safe adapter around KOReader's device frontlight API.
-- Keeping this behind an injected object makes settings usable in host tests
-- and avoids loading device-specific modules until the feature is requested.
local Lighting = {}
Lighting.__index = Lighting

local function call(object, method, ...)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, result = pcall(object[method], object, ...)
    if not ok then return nil end
    return result
end

function Lighting:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.device = options.device
    if not object.device then
        local ok, device = pcall(require, "device")
        if ok then object.device = device end
    end
    object.powerd = options.powerd
    if not object.powerd and object.device then
        object.powerd = call(object.device, "getPowerDevice")
    end
    return object
end

function Lighting:capabilities()
    local device, powerd = self.device, self.powerd
    local has_frontlight = call(device, "hasFrontlight") == true
    local has_warmth = has_frontlight and call(device, "hasNaturalLight") == true
    local intensity_min = tonumber(powerd and powerd.fl_min) or 0
    local intensity_max = tonumber(powerd and powerd.fl_max) or 0
    local warmth_min = tonumber(powerd and powerd.fl_warmth_min) or 0
    local warmth_max = 100
    return {
        supported = has_frontlight and intensity_max > intensity_min,
        has_warmth = has_warmth,
        intensity_min = math.floor(intensity_min),
        intensity_max = math.floor(intensity_max),
        warmth_min = warmth_min,
        warmth_max = warmth_max,
    }
end

function Lighting:get()
    local capabilities = self:capabilities()
    local powerd = self.powerd
    local intensity = tonumber(call(powerd, "frontlightIntensity"))
    if not intensity then intensity = capabilities.intensity_min end
    local warmth
    if capabilities.has_warmth then
        warmth = tonumber(call(powerd, "frontlightWarmth")) or capabilities.warmth_min
    end
    return {
        supported = capabilities.supported,
        has_warmth = capabilities.has_warmth,
        intensity = math.floor(intensity),
        intensity_min = capabilities.intensity_min,
        intensity_max = capabilities.intensity_max,
        warmth = warmth and math.floor(warmth) or nil,
        warmth_min = capabilities.warmth_min,
        warmth_max = capabilities.warmth_max,
    }
end

function Lighting:set_intensity(value)
    local state = self:get()
    value = tonumber(value)
    if not state.supported or not value or value ~= math.floor(value)
        or value < state.intensity_min or value > state.intensity_max then
        return false, "invalid_frontlight_intensity"
    end
    if type(self.powerd.setIntensity) ~= "function" then
        return false, "frontlight_unavailable"
    end
    local ok, result = pcall(self.powerd.setIntensity, self.powerd, value)
    if not ok then return false, "frontlight_unavailable" end
    -- KOReader returns false when the requested value is already active;
    -- that is still a successful save from the user's perspective.
    return true
end

function Lighting:set_warmth(value)
    local state = self:get()
    value = tonumber(value)
    if not state.has_warmth or not value or value ~= math.floor(value)
        or value < state.warmth_min or value > state.warmth_max then
        return false, state.has_warmth and "invalid_frontlight_warmth" or "warmth_unavailable"
    end
    if type(self.powerd.setWarmth) ~= "function" then
        return false, "warmth_unavailable"
    end
    local ok, result = pcall(self.powerd.setWarmth, self.powerd, value)
    if not ok then return false, "warmth_unavailable" end
    return true
end

return Lighting
