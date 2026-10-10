local AutoCrop = {}

AutoCrop.enhance_fields = {
    {key="auto_crop_enhance_enabled", default=false},
    {key="auto_crop_border_width", default=2, minimum=0, maximum=10},
    {key="auto_crop_min_area", default=4, minimum=1, maximum=100},
    {key="auto_crop_padding_percent", default=1, minimum=0, maximum=5},
}

function AutoCrop.valid_enhance_option(key, value)
    for _, field in ipairs(AutoCrop.enhance_fields) do
        if field.key == key then
            if type(field.default) == "boolean" then return type(value) == "boolean" end
            return type(value) == "number" and value == value
                and value >= field.minimum and value <= field.maximum
                and value == math.floor(value)
        end
    end
    return false
end

function AutoCrop.normalize_enhance(settings)
    for _, field in ipairs(AutoCrop.enhance_fields) do
        if not AutoCrop.valid_enhance_option(field.key, settings[field.key]) then
            settings[field.key] = field.default
        end
    end
end

function AutoCrop.validate_enhance(settings)
    for _, field in ipairs(AutoCrop.enhance_fields) do
        if not AutoCrop.valid_enhance_option(field.key, settings[field.key]) then return false end
    end
    return true
end

function AutoCrop.options(settings)
    settings = settings or {}
    return {
        threshold = settings.auto_crop_threshold,
        max_percent = settings.auto_crop_max_percent,
        enhanced = settings.auto_crop_enhance_enabled == true,
        border_width = settings.auto_crop_border_width,
        min_area = settings.auto_crop_min_area,
        padding_percent = settings.auto_crop_padding_percent,
    }
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function AutoCrop.strength_from_threshold(threshold)
    threshold = math.floor(clamp(tonumber(threshold) or 242, 200, 255))
    return math.floor((255 - threshold) * 100 / 55 + 0.5)
end

function AutoCrop.threshold_from_strength(strength)
    strength = math.floor(clamp(tonumber(strength) or 0, 0, 100))
    return math.floor(255 - strength * 55 / 100 + 0.5)
end

local function read_member(object, name)
    if not object then return nil end
    local ok, member = pcall(function() return object[name] end)
    if not ok then return nil end
    if type(member) == "function" then
        local called, value = pcall(member, object)
        return called and value or nil
    end
    return member
end

local function numeric_member(object, name)
    return tonumber(read_member(object, name))
end

local function pixel_luminance(pixel)
    if not pixel then return nil end
    if type(pixel) == "number" then return pixel end
    local red = numeric_member(pixel, "getR") or numeric_member(pixel, "r")
    local green = numeric_member(pixel, "getG") or numeric_member(pixel, "g")
    local blue = numeric_member(pixel, "getB") or numeric_member(pixel, "b")
    if red and green and blue then
        return 0.299 * red + 0.587 * green + 0.114 * blue
    end
    local color8 = read_member(pixel, "getColor8")
    if type(color8) == "number" then return color8 end
    return numeric_member(color8, "a")
        or numeric_member(color8, "value")
        or numeric_member(pixel, "a")
end

local function read_pixel(buffer, x, y)
    if type(buffer.getPixel) == "function" then
        local ok, pixel = pcall(buffer.getPixel, buffer, x, y)
        if ok then return pixel end
    end
    if type(buffer.getPixelP) == "function" then
        local ok, pointer = pcall(buffer.getPixelP, buffer, x, y)
        if ok and pointer then
            local value_ok, value = pcall(function() return pointer[0] end)
            if value_ok then return value end
        end
    end
    return nil
end

local function percentile(values, fraction)
    if #values == 0 then return nil end
    local index = math.floor((#values - 1) * fraction + 1.5)
    index = math.max(1, math.min(#values, index))
    return values[index]
end

local function dimensions(buffer)
    local width = numeric_member(buffer, "getWidth") or numeric_member(buffer, "w")
    local height = numeric_member(buffer, "getHeight") or numeric_member(buffer, "h")
    if not width or not height or width < 3 or height < 3 then return nil end
    return math.floor(width), math.floor(height)
end

local function grid_dimensions(width, height)
    -- ponytail: cap sampling at 160x160; full-resolution scans add cost without
    -- improving a margin decision on an e-ink page.
    local scale = math.min(1, 160 / math.max(width, height))
    return math.max(8, math.min(160, math.floor(width * scale + 0.5))),
        math.max(8, math.min(160, math.floor(height * scale + 0.5)))
end

local function build_grid(buffer, options)
    options = options or {}
    local width, height = dimensions(buffer)
    if not width then return nil, "invalid_buffer" end
    local grid_width, grid_height = grid_dimensions(width, height)
    local grid = {}
    for gy = 0, grid_height - 1 do
        local row = {}
        grid[gy] = row
        for gx = 0, grid_width - 1 do
            local x = math.min(width - 1,
                math.floor((gx + 0.5) * width / grid_width))
            local y = math.min(height - 1,
                math.floor((gy + 0.5) * height / grid_height))
            local value = pixel_luminance(read_pixel(buffer, x, y))
            if not value then return nil, "invalid_buffer" end
            value = clamp(value, 0, 255)
            row[gx] = value
        end
    end

    local edge = {}
    for gy = 0, grid_height - 1 do
        for gx = 0, grid_width - 1 do
            if gx == 0 or gy == 0
                or gx == grid_width - 1 or gy == grid_height - 1 then
                edge[#edge + 1] = grid[gy][gx]
            end
        end
    end
    table.sort(edge)
    local background = percentile(edge, 0.85)
    if background < 160 then return nil, "dark_edge" end
    local delta = clamp(255 - clamp(options.threshold or 242, 160, 254), 6, 72)
    local paper_count = 0
    for _, value in ipairs(edge) do
        if math.abs(background - value) < delta then paper_count = paper_count + 1 end
    end
    if paper_count / #edge < 0.65 then return nil, "full_bleed" end
    local ink = {}
    for gy = 0, grid_height - 1 do
        ink[gy] = {}
        for gx = 0, grid_width - 1 do
            local value = grid[gy][gx]
            ink[gy][gx] = background - value >= delta
        end
    end

    -- A 3x3 majority filter removes isolated scanner dust while preserving ink.
    local filtered, content_count = {}, 0
    for gy = 0, grid_height - 1 do
        filtered[gy] = {}
        for gx = 0, grid_width - 1 do
            local count = 0
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local row = ink[gy + dy]
                    if row and row[gx + dx] then count = count + 1 end
                end
            end
            filtered[gy][gx] = count >= 4
            if filtered[gy][gx] then content_count = content_count + 1 end
        end
    end
    if content_count / (grid_width * grid_height) < 0.01 then
        return nil, "near_blank"
    end
    return {
        width = width, height = height,
        grid_width = grid_width, grid_height = grid_height,
        ink = filtered,
        background = background, delta = delta,
    }
end

local function find_bbox(raster, y_start, y_finish)
    local left, top = raster.grid_width, raster.grid_height
    local right, bottom = -1, -1
    for gy = y_start or 0, y_finish or raster.grid_height - 1 do
        local row = raster.ink[gy]
        for gx = 0, raster.grid_width - 1 do
            if row[gx] then
                left, right = math.min(left, gx), math.max(right, gx)
                top, bottom = math.min(top, gy), math.max(bottom, gy)
            end
        end
    end
    if right < left or bottom < top then return nil end
    return left, top, right, bottom
end

-- A content line needs a neighboring ink sample, so isolated scanner dust
-- cannot stop refinement. Match the coarse 1% minimum content requirement.
local function line_has_content(buffer, raster, vertical, position)
    local length = vertical and raster.height or raster.width
    local samples = math.min(160, length)
    local previous, previous_counted, content = false, false, 0
    for index = 0, samples - 1 do
        local along = math.min(length - 1, math.floor((index + 0.5) * length / samples))
        local x, y = along, position
        if vertical then x, y = position, along end
        local value = pixel_luminance(read_pixel(buffer, x, y))
        if not value then return nil end
        local ink = raster.background - value >= raster.delta
        if ink and previous then
            content = content + (previous_counted and 1 or 2)
        end
        previous_counted, previous = ink and previous, ink
    end
    return content / samples >= 0.01
end

local function refine_edge(buffer, raster, cell, vertical, reverse)
    local size = vertical and raster.width or raster.height
    local cells = vertical and raster.grid_width or raster.grid_height
    -- The first coarse content sample brackets the native transition within
    -- one grid cell. Binary refinement keeps even very large pages bounded.
    local low = math.max(0, math.floor((cell - 0.5) * size / cells) - 1)
    local high = math.min(size - 1, math.ceil((cell + 0.5) * size / cells) + 1)
    for _ = 1, 20 do
        if low >= high then break end
        local middle = math.floor((low + high) / 2)
        local position = reverse and size - 1 - middle or middle
        local content = line_has_content(buffer, raster, vertical, position)
        if content == nil then return nil end
        if content then high = middle else low = middle + 1 end
    end
    -- If dimensions exceed the search budget, retaining the outer bound
    -- leaves paper instead of risking removal of content.
    return low
end

-- Connected components are bounded to a 320-pixel analysis image. Keep edge
-- artwork; only a long line wholly inside the narrow outside band is noise.
-- This works on the borrowed display buffer without global document hooks.
local function enhanced_crop(buffer, options)
    local width, height = dimensions(buffer)
    if not width then return nil, "invalid_buffer" end
    local scale = math.min(1, 320 / math.max(width, height))
    local gw, gh = math.max(3, math.floor(width * scale)), math.max(3, math.floor(height * scale))
    local gray, histogram = {}, {}
    for gy = 0, gh - 1 do
        local y = math.floor(gy * (height - 1) / (gh - 1))
        for gx = 0, gw - 1 do
            local x = math.floor(gx * (width - 1) / (gw - 1))
            local value = pixel_luminance(read_pixel(buffer, x, y))
            if not value or value ~= value then return nil, "invalid_buffer" end
            value = math.floor(clamp(value, 0, 255))
            gray[gy * gw + gx + 1] = value
            histogram[value] = (histogram[value] or 0) + 1
        end
    end
    -- Whole-page paper estimate tolerates a dark scanner frame at the edges.
    local seen, background = 0, 255
    for value = 0, 255 do
        seen = seen + (histogram[value] or 0)
        if seen >= gw * gh * .85 then background = value; break end
    end
    if background < 160 then return nil, "dark_edge" end
    local delta = clamp(255 - clamp(options.threshold or 242, 160, 254), 6, 72)
    local ink = {}
    for i = 1, #gray do
        if background - gray[i] >= delta then ink[i] = true end
    end
    gray = nil
    local border = math.floor(clamp(options.border_width or 2, 0, 10))
    local minimum = math.floor(clamp(options.min_area or 4, 1, 100))
    local boxes, small, pixels = {}, {}, 0
    local components = 0
    for id = 1, gw * gh do
        if ink[id] then
            components = components + 1
            if components > 4096 then return nil, "too_many_components" end
            local queue, head = {id}, 1
            ink[id] = nil
            local left, top, right, bottom, interior = gw, gh, 0, 0, false
            while head <= #queue do
                local at = queue[head]
                head = head + 1
                local x, y = (at - 1) % gw, math.floor((at - 1) / gw)
                left, top = math.min(left, x), math.min(top, y)
                right, bottom = math.max(right, x + 1), math.max(bottom, y + 1)
                if x >= border and y >= border and x < gw - border and y < gh - border then
                    interior = true
                end
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local nx, ny = x + dx, y + dy
                        if nx >= 0 and nx < gw and ny >= 0 and ny < gh then
                            local next_id = ny * gw + nx + 1
                            if ink[next_id] then
                                ink[next_id] = nil
                                queue[#queue + 1] = next_id
                            end
                        end
                    end
                end
            end
            local edge_line = border > 0 and not interior
                and (right - left >= gw * .5 or bottom - top >= gh * .5)
            if not edge_line then
                local box = {left, top, right, bottom}
                if #queue >= minimum then
                    boxes[#boxes + 1] = box
                    pixels = pixels + #queue
                else small[#small + 1] = box end
            end
        end
    end
    if #boxes == 0 or pixels < gw * gh * .01 then return nil, "near_blank" end
    local left, top, right, bottom = gw, gh, 0, 0
    for _, b in ipairs(boxes) do
        left, top = math.min(left, b[1]), math.min(top, b[2])
        right, bottom = math.max(right, b[3]), math.max(bottom, b[4])
    end
    -- Small punctuation beside the retained content must not become dust.
    local reach = math.max(2, math.ceil(math.max(gw, gh) * .01))
    for _, b in ipairs(small) do
        if b[3] >= left - reach and b[1] <= right + reach
            and b[4] >= top - reach and b[2] <= bottom + reach then
            left, top = math.min(left, b[1]), math.min(top, b[2])
            right, bottom = math.max(right, b[3]), math.max(bottom, b[4])
        end
    end
    local padding = clamp(options.padding_percent or 1, 0, 5) / 100
    -- Expand outwards by a sampling cell before applying user padding.
    left = math.max(0, math.floor((left - 1) * width / gw - width * padding))
    top = math.max(0, math.floor((top - 1) * height / gh - height * padding))
    right = math.min(width, math.ceil((right + 1) * width / gw + width * padding))
    bottom = math.min(height, math.ceil((bottom + 1) * height / gh + height * padding))
    local maximum = clamp(options.max_percent or 15, 0, 30) / 100
    if right - left < width * .35 or bottom - top < height * .35
        or left > width * maximum or width - right > width * maximum
        or top > height * maximum or height - bottom > height * maximum then
        return nil, "unsafe_box"
    end
    if left < 2 and top < 2 and width - right < 2 and height - bottom < 2 then
        return nil, "no_margin"
    end
    return {x=left, y=top, w=right-left, h=bottom-top, width=right-left, height=bottom-top}, "enhanced_crop"
end

function AutoCrop.detect(buffer, options)
    options = options or {}
    if not buffer then return nil, "invalid_buffer" end
    if options.enhanced == true then return enhanced_crop(buffer, options) end
    local raster, reason = build_grid(buffer, options)
    if not raster then return nil, reason end
    local left, top, right, bottom = find_bbox(raster)
    if not left then return nil, "near_blank" end
    local max_percent = clamp(options.max_percent or 15, 0, 30)
    local left_crop = refine_edge(buffer, raster, left, true, false)
    local top_crop = refine_edge(buffer, raster, top, false, false)
    local right_crop = refine_edge(buffer, raster, raster.grid_width - 1 - right, true, true)
    local bottom_crop = refine_edge(buffer, raster, raster.grid_height - 1 - bottom, false, true)
    if not left_crop or not top_crop or not right_crop or not bottom_crop then
        return nil, "invalid_buffer"
    end
    local width = raster.width - left_crop - right_crop
    local height = raster.height - top_crop - bottom_crop
    if width < raster.width * 0.35 or height < raster.height * 0.35
        or left_crop > raster.width * max_percent / 100
        or right_crop > raster.width * max_percent / 100
        or top_crop > raster.height * max_percent / 100
        or bottom_crop > raster.height * max_percent / 100 then
        return nil, "unsafe_box"
    end
    if left_crop < 2 and top_crop < 2 and right_crop < 2 and bottom_crop < 2 then
        return nil, "no_margin"
    end
    return { x = left_crop, y = top_crop, w = width, h = height,
        width = width, height = height }, "cropped"
end

function AutoCrop.detect_page_number(buffer, options)
    options = options or {}
    if not buffer then return nil end
    local raster = build_grid(buffer)
    if not raster then return nil end
    local max_percent = clamp(options.max_percent, 0, 15)
    if max_percent <= 0 then return nil end
    local first_row = math.max(1, raster.grid_height
        - math.ceil(raster.grid_height * max_percent / 100))
    local top, run = nil, 0
    for gy = raster.grid_height - 1, first_row, -1 do
        local ink_count = 0
        for gx = 0, raster.grid_width - 1 do
            if raster.ink[gy][gx] then ink_count = ink_count + 1 end
        end
        local ratio = ink_count / raster.grid_width
        if ratio >= 0.01 and ratio <= 0.25 then
            run = run + 1
            top = gy
        elseif run > 0 then
            break
        end
    end
    if run < 2 or not top then return nil end
    local y = math.floor(top * raster.height / raster.grid_height)
    if y <= raster.height * 0.75 then return nil end
    return { x = 0, y = y, w = raster.width, h = raster.height - y,
        width = raster.width, height = raster.height - y }
end

function AutoCrop.remove_page_number(crop, strip, width, height)
    if type(strip) ~= "table" then return crop end
    width, height = tonumber(width), tonumber(height)
    if not width or not height then return crop end
    local result = crop and {
        x = crop.x, y = crop.y, w = crop.w, h = crop.h,
        width = crop.width, height = crop.height,
    } or { x = 0, y = 0, w = width, h = height,
        width = width, height = height }
    local bottom = math.min(result.y + result.h, tonumber(strip.y) or height)
    if bottom <= result.y or bottom - result.y < height * 0.35 then return crop end
    result.h, result.height = bottom - result.y, bottom - result.y
    return result
end

return AutoCrop
