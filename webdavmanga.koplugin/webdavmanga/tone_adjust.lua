local ToneAdjust = {}

local ORIGINAL = {
    id = "original", name = "原图", brightness = 0, contrast = 100, builtin = true,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function integer(value, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function valid_name(value)
    value = trim(value)
    if value == "" or #value > 40 or value:find("[%c]", 1) then return nil end
    return value
end

function ToneAdjust.normalize_custom(value, fallback_id)
    if type(value) ~= "table" then return nil, "invalid_tone_preset" end
    local id = trim(value.id or fallback_id)
    local name = valid_name(value.name)
    local brightness = integer(value.brightness, -100, 100)
    local contrast = integer(value.contrast, 0, 200)
    if not id:match("^custom%-%d+$") or not name
        or brightness == nil or contrast == nil then
        return nil, "invalid_tone_preset"
    end
    return {
        id = id, name = name, brightness = brightness, contrast = contrast, builtin = false,
    }
end

function ToneAdjust.sanitize_custom_presets(values)
    if type(values) ~= "table" then return {} end
    local result, used = {}, {}
    for index, value in ipairs(values) do
        local preset = ToneAdjust.normalize_custom(value, "custom-" .. tostring(index))
        if preset and not used[preset.id] then
            used[preset.id] = true
            result[#result + 1] = preset
        end
    end
    return result
end

function ToneAdjust.all_presets(values)
    local result = { copy(ORIGINAL) }
    for _, preset in ipairs(ToneAdjust.sanitize_custom_presets(values)) do
        result[#result + 1] = preset
    end
    return result
end

function ToneAdjust.find(id, values)
    id = trim(id)
    if id == ORIGINAL.id then return copy(ORIGINAL) end
    for _, preset in ipairs(ToneAdjust.sanitize_custom_presets(values)) do
        if preset.id == id then return preset end
    end
end

function ToneAdjust.is_valid_id(id, values)
    return ToneAdjust.find(id, values) ~= nil
end

function ToneAdjust.next_custom_id(values)
    local used = {}
    for _, preset in ipairs(ToneAdjust.sanitize_custom_presets(values)) do
        used[preset.id] = true
    end
    local number = 1
    while used["custom-" .. tostring(number)] do number = number + 1 end
    return "custom-" .. tostring(number)
end

function ToneAdjust.build_lut(value)
    value = value or ORIGINAL
    local brightness = integer(value.brightness, -100, 100)
    local contrast = integer(value.contrast, 0, 200)
    if brightness == nil or contrast == nil then return nil end
    local offset = brightness * 255 / 100
    local factor = contrast / 100
    local lut = {}
    for input = 0, 255 do
        local output = math.floor((input - 127.5) * factor + 127.5 + offset + 0.5)
        lut[input] = math.max(0, math.min(255, output))
    end
    return lut
end

function ToneAdjust.combine_lut(first, second)
    if type(first) ~= "table" then return second end
    if type(second) ~= "table" then return first end
    local result = {}
    for input = 0, 255 do result[input] = second[first[input]] end
    return result
end

function ToneAdjust.fingerprint(gray, tone)
    gray = gray or {}
    tone = tone or ORIGINAL
    return table.concat({
        tostring(gray.black or 0), tostring(gray.white or 255),
        tostring(gray.gamma or 1), tostring(tone.brightness or 0),
        tostring(tone.contrast or 100),
    }, ":")
end

ToneAdjust.copy_preset = copy
return ToneAdjust
