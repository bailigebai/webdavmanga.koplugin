local PanelDetector = {}

local function invoke(backend, method, ...)
    local fn = backend and backend[method]
    if type(fn) ~= "function" then return nil, "panel_detection_failed" end
    local ok, result, err = pcall(fn, backend, ...)
    if not ok then return nil, "panel_detection_failed" end
    return result, err
end

local function stable_id(x, y, w, h)
    return ("%.9f:%.9f:%.9f:%.9f"):format(x, y, w, h)
end

local function finite_number(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge
        or value == -math.huge then return nil end
    return value
end

local function valid_result(result)
    if type(result) ~= "table" or type(result.boxes) ~= "table" then return false end
    local width = finite_number(result.width)
    local height = finite_number(result.height)
    if not width or not height or width <= 0 or height <= 0 then return false end
    local count = 0
    for index, box in pairs(result.boxes) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0
            or type(box) ~= "table"
            or not finite_number(box.x) or not finite_number(box.y)
            or not finite_number(box.w) or not finite_number(box.h) then
            return false
        end
        count = count + 1
    end
    for index = 1, count do
        if result.boxes[index] == nil then return false end
    end
    return true
end

local function filter_and_normalize(boxes, width, height, experimental)
    width, height = tonumber(width), tonumber(height)
    if type(boxes) ~= "table" or not width or not height
        or width <= 0 or height <= 0 then return {} end

    local accepted = {}
    for _, box in ipairs(boxes) do
        local x, y = tonumber(box.x), tonumber(box.y)
        local w, h = tonumber(box.w), tonumber(box.h)
        if x and y and w and h and w > 0 and h > 0 then
            local left, top = math.max(0, x), math.max(0, y)
            local right = math.min(width, x + w)
            local bottom = math.min(height, y + h)
            w, h = right - left, bottom - top
            local large_enough = experimental
                and w >= width * 0.05 and h >= height * 0.05
                and w * h >= width * height * 0.02
                or not experimental and w >= width / 8 and h >= height / 8
            if large_enough then
                accepted[#accepted + 1] = {
                    x = left / width,
                    y = top / height,
                    w = w / width,
                    h = h / height,
                }
            end
        end
    end

    if experimental then
        local outer = {}
        for index, panel in ipairs(accepted) do
            local contained = false
            for other_index, other in ipairs(accepted) do
                if index ~= other_index
                    and panel.x >= other.x and panel.y >= other.y
                    and panel.x + panel.w <= other.x + other.w
                    and panel.y + panel.h <= other.y + other.h
                    and (panel.w < other.w or panel.h < other.h) then
                    contained = true
                    break
                end
            end
            if not contained then outer[#outer + 1] = panel end
        end
        accepted = outer
    end

    for _, panel in ipairs(accepted) do
        panel.id = stable_id(panel.x, panel.y, panel.w, panel.h)
    end
    return accepted
end

function PanelDetector.sort(panels, direction)
    local geometry = require("webdavmanga.panel_geometry")
    local boxes, result = {}, {}
    for _,p in ipairs(panels or {}) do
        -- The reference geometry uses pixel tolerances. Convert normalized
        -- ordering frames, never their padded/protected display rectangles.
        boxes[#boxes+1]={x=p.x*10000,y=p.y*10000,w=p.w*10000,h=p.h*10000,id=p.id,original=p}
    end
    geometry.sortReadingOrder(boxes,direction=="manga" and "manga" or "comic")
    for _,p in ipairs(boxes) do result[#result+1]=p.original end
    return result
end

local function default_backend()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, "leptonica_unavailable" end
    if not pcall(require, "ffi/leptonica_h") then
        return nil, "leptonica_unavailable"
    end
    pcall(ffi.cdef, [[
        PIX *pixRead(const char *filename);
        PIX *pixReadMem(const l_uint8 *data, size_t size);
        PIX *pixScaleToSize(PIX *pixs, l_int32 wd, l_int32 hd);
        PIX *pixCreate(l_int32 width, l_int32 height, l_int32 depth);
        l_ok pixSetPixel(PIX *pix, l_int32 x, l_int32 y, l_uint32 val);
    ]])
    pcall(ffi.cdef,
        "PIX *pixConvertTo8(PIX *pixs, l_int32 cmapflag);")
    local loaded, lept = pcall(ffi.loadlib, "leptonica", "6")
    if not loaded then return nil, "leptonica_unavailable" end

    local function destroy(kind, value)
        if value == nil then return end
        pcall(function()
            local holder = ffi.new(kind .. " *[1]")
            holder[0] = value
            if kind == "PIX" then lept.pixDestroy(holder)
            elseif kind == "BOX" then lept.boxDestroy(holder)
            else lept.boxaDestroy(holder) end
        end)
    end

    return {
        connected_components = function(_, raster, threshold, connectivity)
            raster = raster or {}
            local decoded, scaled, crop_box, clipped
            local gray, inverted, binary, components
            local result, reason
            local worked = pcall(function()
                local dark = false
                if raster.buffer then
                    -- Never decode a large original again for native detection.
                    -- Borrow the displayed page and bound the native allocation.
                    local buffer = raster.buffer
                    local bw, bh = finite_number(buffer:getWidth()), finite_number(buffer:getHeight())
                    local mw, mh = finite_number(raster.max_width), finite_number(raster.max_height)
                    if not bw or not bh or not mw or not mh or bw < 1 or bh < 1
                        or mw < 1 or mh < 1 then error('invalid_native_raster') end
                    local scale = math.min(1, 960 / bw, 960 / bh, mw / bw, mh / bh)
                    local w, h = math.max(1, math.floor(bw * scale)), math.max(1, math.floor(bh * scale))
                    decoded = lept.pixCreate(w, h, 8)
                    if decoded == nil then error('native_raster_allocation_failed') end
                    local dark_edges, edges = 0, 0
                    for y = 0, h - 1 do for x = 0, w - 1 do
                        local pixel = buffer:getPixel(math.min(bw - 1, math.floor((x + .5) * bw / w)),
                            math.min(bh - 1, math.floor((y + .5) * bh / h)))
                        local gray = finite_number(type(pixel) == 'number' and pixel or pixel:getColor8().a)
                        if not gray then error('invalid_native_pixel') end
                        gray = math.max(0, math.min(255, math.floor(gray)))
                        if lept.pixSetPixel(decoded, x, y, gray) ~= 0 then error('native_pixel_write_failed') end
                        if x == 0 or y == 0 or x == w - 1 or y == h - 1 then
                            edges = edges + 1
                            if gray < 128 then dark_edges = dark_edges + 1 end
                        end
                    end end
                    dark = dark_edges > edges / 2
                elseif type(raster.path) == "string" and raster.path ~= "" then
                    decoded = lept.pixRead(raster.path)
                elseif type(raster.bytes) == "string" and raster.bytes ~= "" then
                    decoded = lept.pixReadMem(
                        ffi.cast("const l_uint8 *", raster.bytes), #raster.bytes)
                end
                if decoded == nil then
                    reason = "panel_raster_decode_failed"
                    return
                end

                local source_width = tonumber(lept.pixGetWidth(decoded))
                local source_height = tonumber(lept.pixGetHeight(decoded))
                local max_width = tonumber(raster.max_width)
                local max_height = tonumber(raster.max_height)
                if not source_width or not source_height
                    or not max_width or not max_height
                    or source_width <= 0 or source_height <= 0
                    or max_width <= 0 or max_height <= 0 then
                    reason = "panel_detection_failed"
                    return
                end

                local scale = math.min(1, max_width / source_width,
                    max_height / source_height)
                local target_width = math.max(1, math.floor(source_width * scale))
                local target_height = math.max(1, math.floor(source_height * scale))
                local working = decoded
                if scale < 1 then
                    scaled = lept.pixScaleToSize(decoded, target_width, target_height)
                    if scaled == nil then
                        reason = "panel_detection_failed"
                        return
                    end
                    working = scaled
                end

                if type(raster.crop) == "table" then
                    local crop = raster.crop
                    local crop_x, crop_y = finite_number(crop.x), finite_number(crop.y)
                    local crop_w, crop_h = finite_number(crop.w), finite_number(crop.h)
                    if not crop_x or not crop_y or not crop_w or not crop_h then
                        reason = "panel_detection_failed"
                        return
                    end
                    local scaled_width = tonumber(lept.pixGetWidth(working))
                    local scaled_height = tonumber(lept.pixGetHeight(working))
                    local x = math.floor(math.max(0, math.min(1, crop_x))
                        * scaled_width)
                    local y = math.floor(math.max(0, math.min(1, crop_y))
                        * scaled_height)
                    local right = math.ceil(math.max(0,
                        math.min(1, crop_x + crop_w)) * scaled_width)
                    local bottom = math.ceil(math.max(0,
                        math.min(1, crop_y + crop_h)) * scaled_height)
                    if right <= x or bottom <= y then
                        reason = "panel_detection_failed"
                        return
                    end
                    crop_box = lept.boxCreate(x, y, right - x, bottom - y)
                    clipped = crop_box ~= nil
                        and lept.pixClipRectangle(working, crop_box, nil) or nil
                    if clipped == nil then
                        reason = "panel_detection_failed"
                        return
                    end
                    working = clipped
                end

                if tonumber(lept.pixGetDepth(working)) == 32 then
                    gray = lept.pixConvertRGBToGrayFast(working)
                elseif tonumber(lept.pixGetDepth(working)) == 8 then
                    gray = lept.pixClone(working)
                else
                    gray = lept.pixConvertTo8(working, 0)
                end
                inverted = gray ~= nil and (dark and lept.pixClone(gray) or lept.pixInvert(nil, gray)) or nil
                binary = inverted ~= nil
                    and lept.pixThresholdToBinary(inverted, threshold) or nil
                -- Connected components treat 1 as ink, not the page background.
                if binary ~= nil then lept.pixInvert(binary, binary) end
                components = binary ~= nil
                    and lept.pixConnCompBB(binary, connectivity) or nil
                if components == nil then
                    reason = "panel_detection_failed"
                    return
                end

                local boxes = {}
                local count = tonumber(lept.boxaGetCount(components)) or 0
                if count > 4096 then reason = 'too_many_panels'; return end
                local x = ffi.new("l_int32[1]")
                local y = ffi.new("l_int32[1]")
                local w = ffi.new("l_int32[1]")
                local h = ffi.new("l_int32[1]")
                for index = 0, count - 1 do
                    if lept.boxaGetBoxGeometry(components, index, x, y, w, h) == 0 then
                        boxes[#boxes + 1] = {
                            x = tonumber(x[0]),
                            y = tonumber(y[0]),
                            w = tonumber(w[0]),
                            h = tonumber(h[0]),
                        }
                    end
                end
                result = {
                    boxes = boxes,
                    width = tonumber(lept.pixGetWidth(working)),
                    height = tonumber(lept.pixGetHeight(working)),
                }
            end)

            destroy("BOXA", components)
            destroy("PIX", binary)
            destroy("PIX", inverted)
            destroy("PIX", gray)
            destroy("PIX", clipped)
            destroy("BOX", crop_box)
            destroy("PIX", scaled)
            destroy("PIX", decoded)

            if not worked then return nil, "panel_detection_failed" end
            if not result then return nil, reason or "panel_detection_failed" end
            return result
        end,
    }
end

function PanelDetector.detect(raster, options)
    options = options or {}
    if raster and raster.buffer and not options.backend then
        local panels,reason=require("webdavmanga.panel_analysis").detect(raster,options)
        if not panels then return nil,reason end
        return PanelDetector.sort(panels,options.direction or "normal")
    end
    return PanelDetector.detect_native(raster, options)
end

function PanelDetector.detect_native(raster, options)
    options = options or {}
    local backend, backend_err = options.backend, nil
    if not backend then backend, backend_err = default_backend() end
    if not backend then return nil, backend_err or "leptonica_unavailable" end
    local result, err = invoke(
        backend, "connected_components", raster, 50, 8)
    if not result then return nil, err or "panel_detection_failed" end
    local ok, panels, process_err = pcall(function()
        if not valid_result(result) then return nil, "panel_detection_failed" end
        local filtered = filter_and_normalize(
            result.boxes, result.width, result.height,
            options.experimental == true)
        if #filtered == 0 then return nil, "no_panels" end
        if #filtered > 64 then return nil, "too_many_panels" end
        return PanelDetector.sort(filtered, options.direction or "normal")
    end)
    if not ok then return nil, "panel_detection_failed" end
    return panels, process_err
end

return PanelDetector
