local ImageFormats = require("webdavmanga.image_formats")
local NaturalSort = require("webdavmanga.natural_sort")

local GrayEnhance = {}

local BUILTINS = {
    { id = "original", name = "原图", builtin = true },
    { id = "clear", name = "清晰", black = 40, white = 238, gamma = 1.20, builtin = true },
    { id = "strong", name = "强力", black = 55, white = 228, gamma = 1.30, builtin = true },
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function finite_number(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

local function integer_in_range(value, minimum, maximum)
    value = finite_number(value)
    if not value or value ~= math.floor(value)
        or value < minimum or value > maximum then
        return nil
    end
    return value
end

local function number_in_range(value, minimum, maximum)
    value = finite_number(value)
    if not value or value < minimum or value > maximum then return nil end
    return value
end

local function copy_preset(preset)
    local copy = {}
    for key, value in pairs(preset or {}) do copy[key] = value end
    return copy
end

local function clean_name(value)
    value = trim(value)
    if value == "" or value:find("[%c]", 1) or #value > 40 then return nil end
    return value
end

local function clean_id(value)
    value = trim(value)
    if value == "" or not value:match("^custom%-[%w_%-]+$") then return nil end
    return value
end

function GrayEnhance.builtin_presets()
    local result = {}
    for index, preset in ipairs(BUILTINS) do result[index] = copy_preset(preset) end
    return result
end

function GrayEnhance.normalize_custom(raw, fallback_id)
    if type(raw) ~= "table" then return nil, "invalid_gray_preset" end
    local id = clean_id(raw.id or fallback_id)
    local name = clean_name(raw.name)
    local black = integer_in_range(raw.black, 0, 254)
    local white = integer_in_range(raw.white, 1, 255)
    local gamma = number_in_range(raw.gamma, 0.10, 5.00)
    if not id or not name or not black or not white or not gamma
        or black >= white then
        return nil, "invalid_gray_preset"
    end
    return {
        id = id,
        name = name,
        black = black,
        white = white,
        gamma = math.floor(gamma * 100 + 0.5) / 100,
        builtin = false,
    }
end

function GrayEnhance.sanitize_custom_presets(values)
    if type(values) ~= "table" then return {} end
    local result, used = {}, {}
    local function append(raw, fallback_id)
        local preset = GrayEnhance.normalize_custom(raw, fallback_id)
        if preset and not used[preset.id] then
            used[preset.id] = true
            result[#result + 1] = preset
        end
    end
    if #values > 0 then
        for index, raw in ipairs(values) do append(raw, "custom-" .. tostring(index)) end
    else
        local keys = {}
        for key in pairs(values) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do append(values[key], key) end
    end
    return result
end

function GrayEnhance.all_presets(custom_values)
    local result = GrayEnhance.builtin_presets()
    for _, preset in ipairs(GrayEnhance.sanitize_custom_presets(custom_values)) do
        result[#result + 1] = preset
    end
    return result
end

function GrayEnhance.find(preset_id, custom_values)
    preset_id = trim(preset_id)
    for _, preset in ipairs(BUILTINS) do
        if preset.id == preset_id then return copy_preset(preset) end
    end
    for _, preset in ipairs(GrayEnhance.sanitize_custom_presets(custom_values)) do
        if preset.id == preset_id then return preset end
    end
    return nil
end

function GrayEnhance.is_valid_id(preset_id, custom_values)
    return GrayEnhance.find(preset_id, custom_values) ~= nil
end

function GrayEnhance.next_custom_id(custom_values)
    local used = {}
    for _, preset in ipairs(GrayEnhance.sanitize_custom_presets(custom_values)) do
        used[preset.id] = true
    end
    local number = 1
    while used["custom-" .. tostring(number)] do number = number + 1 end
    return "custom-" .. tostring(number)
end

function GrayEnhance.normalize_sample_path(value)
    local path = trim(value):gsub("\\", "/")
    if path == "" then return "" end
    if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then return nil end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
    end
    if path ~= "/" then path = path:gsub("/+$", "") end
    return path
end

function GrayEnhance.build_lut(preset)
    if not preset or preset.id == "original" then return nil end
    local black = integer_in_range(preset.black, 0, 254)
    local white = integer_in_range(preset.white, 1, 255)
    local gamma = number_in_range(preset.gamma, 0.10, 5.00)
    if not black or not white or not gamma or black >= white then return nil end
    local lut, span = {}, white - black
    for value = 0, 255 do
        local output
        if value <= black then
            output = 0
        elseif value >= white then
            output = 255
        else
            local normalized = (value - black) / span
            -- Match KOReadingEnhancer: gamma > 1 darkens the middle tones
            -- after the black/white points have been stretched.
            output = math.floor(math.pow(normalized, gamma) * 255 + 0.5)
        end
        lut[value] = math.max(0, math.min(255, output))
    end
    return lut
end

local MAX_WORK_BYTES = 40 * 1024 * 1024
local MAX_PIXELS = 8 * 1024 * 1024

local function native_layout(buffer, ffi, BB)
    if type(buffer) ~= "cdata" then return nil, "gray_unsupported_buffer" end
    local step
    if ffi.istype("BlitBuffer8", buffer) and buffer:getType() == BB.TYPE_BB8 then
        step = 1
    elseif ffi.istype("BlitBuffer8A", buffer) and buffer:getType() == BB.TYPE_BB8A then
        step = 2
    elseif ffi.istype("BlitBufferRGB24", buffer) and buffer:getType() == BB.TYPE_BBRGB24 then
        step = 3
    elseif ffi.istype("BlitBufferRGB32", buffer) and buffer:getType() == BB.TYPE_BBRGB32 then
        step = 4
    else
        return nil, "gray_unsupported_buffer"
    end
    -- Physical dimensions also cover rotated pages and cropped viewports.
    local width, height, stride = tonumber(buffer.w), tonumber(buffer.h), tonumber(buffer.stride)
    if not width or not height or not stride or width < 1 or height < 1
        or stride < width * step or buffer.data == nil then
        return nil, "gray_invalid_buffer"
    end
    if width * height > MAX_PIXELS or width * height * step * 2 > MAX_WORK_BYTES then
        return nil, "gray_image_too_large"
    end
    return { width = width, height = height, stride = stride, step = step }
end

local function map_pixels(raw, stride, layout, lut, inverse)
    local step, width, height = layout.step, layout.width, layout.height
    local line_bytes = width * step
    for row = 0, height - 1 do
        local line = raw + row * stride
        if step == 1 then
            for offset = 0, line_bytes - 1 do line[offset] = lut[line[offset]] end
        elseif step == 2 then
            for offset = 0, line_bytes - 1, 2 do line[offset] = lut[line[offset]] end
        else
            for offset = 0, line_bytes - 1, step do
                local red, green, blue = line[offset], line[offset + 1], line[offset + 2]
                if inverse then red, green, blue = 255 - red, 255 - green, 255 - blue end
                local luminance = math.floor(0.299 * red + 0.587 * green + 0.114 * blue + 0.5)
                local value = lut[inverse and (255 - luminance) or luminance]
                line[offset], line[offset + 1], line[offset + 2] = value, value, value
            end
        end
    end
end

local function apply_native(buffer, values, disposable, ffi, BB)
    local layout, reason = native_layout(buffer, ffi, BB)
    if not layout then return false, reason end
    local inverse = buffer:getInverse() == 1
    local lut = ffi.new("uint8_t[256]")
    for value = 0, 255 do
        local mapped = tonumber(values[value])
        if not mapped or mapped ~= math.floor(mapped) or mapped < 0 or mapped > 255 then
            return false, "invalid_gray_lut"
        end
        lut[value] = inverse and (255 - values[255 - value]) or mapped
    end

    local step, width, height = layout.step, layout.width, layout.height
    local line_bytes = width * step
    local raw = ffi.cast("uint8_t*", buffer.data)
    if disposable == true then
        map_pixels(raw, layout.stride, layout, lut, inverse)
        return true
    end
    -- Work on a compact temporary copy. Padding and alpha stay unchanged;
    -- unsupported formats/allocation/processing failures leave the original intact.
    local work = ffi.new("uint8_t[?]", line_bytes * height)
    for row = 0, height - 1 do
        ffi.copy(work + row * line_bytes, raw + row * layout.stride, line_bytes)
    end
    local original = ffi.string(work, line_bytes * height)
    local backup = ffi.cast("const uint8_t*", original)
    map_pixels(work, line_bytes, layout, lut, inverse)
    local committed, commit_error = pcall(function()
        for row = 0, height - 1 do
            ffi.copy(raw + row * layout.stride, work + row * line_bytes, line_bytes)
        end
    end)
    if not committed then
        -- Do not depend on the failed copy helper during rollback.
        for row = 0, height - 1 do
            for column = 0, line_bytes - 1 do
                raw[row * layout.stride + column] = backup[row * line_bytes + column]
            end
        end
        return false, "gray_processing_failed", tostring(commit_error)
    end
    -- Keep the string backing the rollback pointer alive through the commit.
    assert(#original == line_bytes * height)
    return true
end

function GrayEnhance.apply_lut(buffer, values, disposable)
    if type(values) ~= "table" then return false, "invalid_gray_lut" end
    local ffi_ok, ffi = pcall(require, "ffi")
    local bb_ok, BB = pcall(require, "ffi/blitbuffer")
    if not ffi_ok or not bb_ok then return false, "gray_native_unavailable" end
    local ok, result, detail, diagnostic = pcall(
        apply_native, buffer, values, disposable == true, ffi, BB)
    if not ok then return false, "gray_processing_failed", tostring(result) end
    return result, detail, diagnostic
end

function GrayEnhance.apply(buffer, preset)
    if not preset or preset.id == "original" then return true end
    local black = integer_in_range(preset.black, 0, 254)
    local white = integer_in_range(preset.white, 1, 255)
    local gamma = number_in_range(preset.gamma, 0.10, 5.00)
    if not black or not white or not gamma or black >= white then
        return false, "invalid_gray_preset"
    end
    return GrayEnhance.apply_lut(buffer, GrayEnhance.build_lut(preset), false)
end

function GrayEnhance.error_message(reason)
    local messages = {
        gray_unsupported_buffer = "此图片的解码类型暂不支持快速增强",
        gray_invalid_buffer = "图片缓冲无效",
        gray_image_too_large = "图片超过安全处理上限",
        gray_native_unavailable = "当前 KOReader 缺少快速图像处理接口",
        invalid_gray_preset = "增强参数无效",
        invalid_gray_lut = "图像查找表无效",
        gray_processing_failed = "图像处理失败，可能是内存不足或接口异常",
    }
    return messages[reason] or "图像处理异常"
end

function GrayEnhance.first_image_in_directory(directory, dependencies)
    local path = GrayEnhance.normalize_sample_path(directory)
    if not path or path == "" then return nil, "invalid_gray_sample_path" end
    dependencies = dependencies or {}
    local lfs = dependencies.lfs
    if not lfs then
        local loaded, module = pcall(require, "libs/libkoreader-lfs")
        if not loaded then return nil, "gray_sample_filesystem_unavailable" end
        lfs = module
    end
    local mode = type(lfs.attributes) == "function" and lfs.attributes(path, "mode") or nil
    if mode == "file" then
        return ImageFormats.is_supported(path) and path or nil, "gray_sample_not_image"
    end
    if mode ~= "directory" or type(lfs.dir) ~= "function" then
        return nil, "gray_sample_directory_unreadable"
    end
    local called, iterator, state = pcall(lfs.dir, path)
    if not called or type(iterator) ~= "function" then
        return nil, "gray_sample_directory_unreadable"
    end
    local files = {}
    for name in iterator, state do
        if name and name ~= "." and name ~= ".." and ImageFormats.is_supported(name) then
            local full = path == "/" and ("/" .. name) or (path .. "/" .. name)
            local is_file = type(lfs.attributes) ~= "function"
                or lfs.attributes(full, "mode") == "file"
            if is_file then files[#files + 1] = { name = name, path = full } end
        end
    end
    NaturalSort.sort(files, function(item) return item.name end)
    return files[1] and files[1].path or nil, "gray_sample_not_found"
end

GrayEnhance.copy_preset = copy_preset
return GrayEnhance
