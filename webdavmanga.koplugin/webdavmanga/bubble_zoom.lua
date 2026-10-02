-- Bounded speech-region analysis over the already displayed pixels.
-- Standard adaptive thresholding and connected components, independently
-- implemented here; no upstream plugin source or native dependency is used.
local Zoom = {}
local MAX_SIDE = 256

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function luminance(buffer, x, y)
    local pixel = buffer:getPixel(x, y)
    local value = type(pixel) == "number" and pixel or pixel:getColor8().a
    value = tonumber(value)
    if not finite(value) then error("pixel_unavailable") end
    return math.max(0, math.min(255, value))
end

local function detect(buffer, point)
    local width, height = buffer:getWidth(), buffer:getHeight()
    if not finite(width) or not finite(height) or width < 8 or height < 8
        or not point or not finite(point.x) or not finite(point.y)
        or point.x < 0 or point.y < 0 or point.x >= width or point.y >= height then
        return nil, "invalid_point"
    end
    local scale = math.min(1, MAX_SIDE / math.max(width, height))
    local w, h = math.max(1, math.floor(width * scale)), math.max(1, math.floor(height * scale))
    local gray, sums, squares = {}, {}, {}
    local stride = w + 1
    for x = 0, w do sums[x], squares[x] = 0, 0 end
    for y = 0, h - 1 do
        local sum, square = 0, 0
        sums[(y + 1) * stride], squares[(y + 1) * stride] = 0, 0
        for x = 0, w - 1 do
            local value = luminance(buffer, math.floor((x + 0.5) * width / w),
                math.floor((y + 0.5) * height / h))
            gray[y * w + x] = value
            sum, square = sum + value, square + value * value
            local i = (y + 1) * stride + x + 1
            sums[i], squares[i] = sums[i - stride] + sum, squares[i - stride] + square
        end
    end
    local ink, blocked = {}, {}
    -- Integral sums make each local mean/variance constant cost (Sauvola).
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local left, right = math.max(0, x - 7), math.min(w, x + 8)
            local top, bottom = math.max(0, y - 7), math.min(h, y + 8)
            local a, b, c, d = top * stride + left, top * stride + right,
                bottom * stride + left, bottom * stride + right
            local area = (right - left) * (bottom - top)
            local mean = (sums[d] - sums[b] - sums[c] + sums[a]) / area
            local variance = (squares[d] - squares[b] - squares[c] + squares[a]) / area - mean * mean
            local threshold = mean * (0.75 + 0.25 * math.sqrt(math.max(0, variance)) / 128)
            ink[y * w + x] = gray[y * w + x] <= threshold
        end
    end
    -- A one-cell ink expansion closes tiny outline gaps without full-page
    -- morphology or a shape mask. Larger gaps remain a detection failure.
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local closed = false
            for dy = math.max(0, y - 1), math.min(h - 1, y + 1) do
                for dx = math.max(0, x - 1), math.min(w - 1, x + 1) do
                    if ink[dy * w + dx] then closed = true; break end
                end
                if closed then break end
            end
            blocked[y * w + x] = closed
        end
    end
    local px, py = math.floor(point.x * w / width), math.floor(point.y * h / height)
    -- Each paper component is visited once, even when it reaches the page
    -- edge. A hollow letter is not dialogue: require ink away from the outline.
    local seen, candidates = {}, {}
    local function inspect(seed)
        local queue, head = { seed }, 1
        seen[seed] = true
        local min_x, max_x, min_y, max_y = w, 0, h, 0
        local open = false
        local function push(x, y)
            if x < 0 or y < 0 or x >= w or y >= h then return end
            local i = y * w + x
            if not seen[i] and not blocked[i] then seen[i] = true; queue[#queue + 1] = i end
        end
        while head <= #queue do
            local i = queue[head]; head = head + 1
            local x, y = i % w, math.floor(i / w)
            if x == 0 or y == 0 or x == w - 1 or y == h - 1 then open = true end
            min_x, max_x = math.min(min_x, x), math.max(max_x, x)
            min_y, max_y = math.min(min_y, y), math.max(max_y, y)
            push(x-1,y); push(x+1,y); push(x,y-1); push(x,y+1)
        end
        local bw, bh = max_x - min_x + 1, max_y - min_y + 1
        if open or #queue < 36 or bw < 8 or bh < 8 or bw * bh > w * h * 0.65
            or px < min_x - 3 or px > max_x + 3 or py < min_y - 3 or py > max_y + 3 then return end
        local inset_x, inset_y = math.ceil(bw * 0.18), math.ceil(bh * 0.18)
        local letters = 0
        for y = min_y + inset_y, max_y - inset_y do
            for x = min_x + inset_x, max_x - inset_x do
                if ink[y*w+x] then letters = letters + 1 end
            end
        end
        if letters < 4 then return end
        return { min_x=min_x,max_x=max_x,min_y=min_y,max_y=max_y }
    end
    local direct = py*w+px
    if not blocked[direct] then
        local candidate = inspect(direct)
        -- Normal presses on dialogue paper use its actual component. Do not
        -- let an enclosing comic panel replace the selected speech region.
        if candidate then candidates[1] = candidate end
    end
    if #candidates == 0 then
        -- Presses on letters/counters may expose several nested regions.
        -- Refuse ambiguity instead of guessing a character or a panel.
        for y = math.max(0,py-24), math.min(h-1,py+24) do
            for x = math.max(0,px-24), math.min(w-1,px+24) do
                local i = y*w+x
                if not blocked[i] and not seen[i] then
                    local candidate = inspect(i)
                    if candidate then candidates[#candidates+1] = candidate end
                end
            end
        end
    end
    if #candidates ~= 1 then return nil, #candidates > 1 and "ambiguous_bubble" or "no_bubble" end
    local chosen = candidates[1]
    local min_x,max_x,min_y,max_y = chosen.min_x,chosen.max_x,chosen.min_y,chosen.max_y
    local left, top = math.max(0, math.floor((min_x - 3) * width / w)),
        math.max(0, math.floor((min_y - 3) * height / h))
    local right, bottom = math.min(width, math.ceil((max_x + 4) * width / w)),
        math.min(height, math.ceil((max_y + 4) * height / h))
    return { x = left, y = top, w = right - left, h = bottom - top }
end

function Zoom.detect(buffer, point)
    local ok, box, reason = pcall(detect, buffer, point)
    if not ok then return nil, "pixel_unavailable" end
    return box, reason
end

function Zoom.map_point(point, image, width, height)
    if not point or not image or not finite(point.x) or not finite(point.y)
        or not finite(image.x) or not finite(image.y)
        or not finite(width) or not finite(height) or width <= 0 or height <= 0
        or not finite(image.w) or not finite(image.h) or image.w <= 0 or image.h <= 0
        or point.x < image.x or point.y < image.y
        or point.x >= image.x + image.w or point.y >= image.y + image.h then return nil end
    return { x = math.floor((point.x - image.x) * width / image.w),
        y = math.floor((point.y - image.y) * height / image.h) }
end

function Zoom.overlay_rect(box, scale, point, width, height)
    if not box or not finite(box.w) or not finite(box.h) or box.w <= 0 or box.h <= 0
        or not finite(width) or not finite(height) or width <= 0 or height <= 0
        or not point or not finite(point.x) or not finite(point.y) then return nil end
    scale = math.min(tonumber(scale) or 2, width / box.w, height / box.h)
    if not finite(scale) or scale <= 0 then return nil end
    local w, h = math.max(1, math.floor(box.w * scale)), math.max(1, math.floor(box.h * scale))
    return { x = math.max(0, math.min(width - w, math.floor(point.x - w / 2))),
        y = math.max(0, math.min(height - h, math.floor(point.y - h / 2))), w = w, h = h }
end

return Zoom
