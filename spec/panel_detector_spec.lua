local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Detector = require("webdavmanga.panel_detector")

local function new_matrix(width, height, value)
    local matrix = {}
    for y = 1, height do
        matrix[y] = {}
        for x = 1, width do matrix[y][x] = value end
    end
    return matrix
end

local function fill(matrix, x, y, width, height, value)
    for row = y, y + height - 1 do
        for column = x, x + width - 1 do matrix[row][column] = value end
    end
end

local function ring(matrix, x, y, width, height, value)
    fill(matrix, x, y, width, 1, value)
    fill(matrix, x, y + height - 1, width, 1, value)
    fill(matrix, x, y, 1, height, value)
    fill(matrix, x + width - 1, y, 1, height, value)
end

local calls = {}
local saw_black, saw_gray, saw_white = false, false, false
local component_count = 0
local backend = {
    connected_components = function(_, raster, threshold, connectivity)
        assert(threshold == 50, "detector must use threshold 50")
        assert(connectivity == 8, "detector must use 8-connectivity")
        calls[#calls + 1] = {
            raster = raster,
            threshold = threshold,
            connectivity = connectivity,
        }
        local matrix = assert(raster.matrix, "synthetic raster needs a matrix")
        local rows = #matrix
        local columns = #(matrix[1] or {})
        local visited = {}
        local boxes = {}
        local function foreground(y, x)
            local tone = assert(matrix[y] and matrix[y][x],
                "synthetic pixels must form a rectangle")
            assert(tone >= 0 and tone <= 255,
                "synthetic pixels must be grayscale bytes")
            return tone < threshold
        end
        for y, row in ipairs(matrix) do
            assert(#row == columns, "synthetic pixels must form a rectangle")
            visited[y] = {}
            for x = 1, columns do
                local tone = row[x]
                saw_black = saw_black or tone == 0
                saw_gray = saw_gray or tone > 0 and tone < 255
                saw_white = saw_white or tone == 255
            end
        end
        for start_y = 1, rows do
            for start_x = 1, columns do
                if not visited[start_y][start_x]
                    and foreground(start_y, start_x) then
                    local queue_x, queue_y = { start_x }, { start_y }
                    local head = 1
                    visited[start_y][start_x] = true
                    local left, right = start_x, start_x
                    local top, bottom = start_y, start_y
                    while head <= #queue_x do
                        local x, y = queue_x[head], queue_y[head]
                        head = head + 1
                        left, right = math.min(left, x), math.max(right, x)
                        top, bottom = math.min(top, y), math.max(bottom, y)
                        for dy = -1, 1 do
                            for dx = -1, 1 do
                                local next_x, next_y = x + dx, y + dy
                                local neighbor = (dx ~= 0 or dy ~= 0)
                                    and (connectivity == 8 or dx == 0 or dy == 0)
                                    and next_x >= 1 and next_x <= columns
                                    and next_y >= 1 and next_y <= rows
                                if neighbor and not visited[next_y][next_x]
                                    and foreground(next_y, next_x) then
                                    visited[next_y][next_x] = true
                                    queue_x[#queue_x + 1] = next_x
                                    queue_y[#queue_y + 1] = next_y
                                end
                            end
                        end
                    end
                    boxes[#boxes + 1] = {
                        x = left - 1,
                        y = top - 1,
                        w = right - left + 1,
                        h = bottom - top + 1,
                    }
                end
            end
        end
        local cell_width = raster.width / columns
        local cell_height = raster.height / rows
        for _, box in ipairs(boxes) do
            box.x, box.y = box.x * cell_width, box.y * cell_height
            box.w, box.h = box.w * cell_width, box.h * cell_height
        end
        component_count = #boxes
        return {
            boxes = boxes,
            width = raster.width,
            height = raster.height,
        }
    end,
}

local main_matrix = new_matrix(20, 20, 255)
fill(main_matrix, 1, 1, 8, 8, 0)
fill(main_matrix, 12, 1, 8, 8, 40)
fill(main_matrix, 1, 12, 20, 8, 0)
local raster = {
    width = 1000,
    height = 1000,
    matrix = main_matrix,
}

local ltr = assert(Detector.detect(raster, {
    direction = "normal",
    backend = backend,
}))
expect(#ltr == 3 and ltr[1].x < ltr[2].x and ltr[3].y > ltr[1].y,
    "standard panels must be grouped top-to-bottom and sorted left-to-right")
expect(ltr[1].x == 0 and ltr[1].y == 0
    and ltr[1].w == 0.4 and ltr[1].h == 0.4,
    "panel geometry must be normalized to the cropped physical page")
expect(saw_black and saw_gray and saw_white,
    "synthetic pixels must cover black, gray, and white tones")

local rtl = assert(Detector.detect(raster, {
    direction = "manga",
    backend = backend,
}))
expect(rtl[1].x > rtl[2].x and calls[1].threshold == 50
    and calls[1].connectivity == 8,
    "manga panels must reverse only the horizontal order")

local ids = {}
for _, panel in ipairs(ltr) do
    ids[panel.id] = true
end
for _, panel in ipairs(rtl) do
    expect(ids[panel.id],
        "direction changes must retain each physical panel id")
end

local overlap_rows = Detector.sort({
    { id = "left", x = 0.1, y = 0.10, w = 0.2, h = 0.20 },
    { id = "right", x = 0.6, y = 0.20, w = 0.2, h = 0.20 },
    { id = "below", x = 0.1, y = 0.50, w = 0.8, h = 0.20 },
}, "normal")
expect(overlap_rows[1].id == "left" and overlap_rows[2].id == "right"
    and overlap_rows[3].id == "below",
    "overlapping vertical intervals must share a row")

local experimental_matrix = new_matrix(21, 20, 255)
ring(experimental_matrix, 1, 1, 11, 10, 0)
fill(experimental_matrix, 4, 4, 4, 4, 40)
fill(experimental_matrix, 18, 1, 3, 4, 40)
fill(experimental_matrix, 18, 12, 1, 9, 0)
local experimental = assert(Detector.detect({
    width = 2100,
    height = 2000,
    matrix = experimental_matrix,
}, { experimental = true, backend = backend }))
expect(#experimental == 2 and experimental[1].x == 0
    and experimental[2].x > 0.8,
    "experimental filtering must accept 2 percent areas and remove contained boxes")

local separated_matrix = new_matrix(5, 5, 255)
separated_matrix[1][1] = 40
separated_matrix[5][5] = 40
local separated = assert(Detector.detect({
    width = 5,
    height = 5,
    matrix = separated_matrix,
}, { backend = backend }))
expect(#separated == 2,
    "separated pixels with the same gray value must remain separate components")

local diagonal_matrix = new_matrix(5, 5, 255)
diagonal_matrix[1][1] = 40
diagonal_matrix[2][2] = 40
diagonal_matrix[3][3] = 40
local diagonal = assert(Detector.detect({
    width = 5,
    height = 5,
    matrix = diagonal_matrix,
}, { backend = backend }))
expect(#diagonal == 1 and diagonal[1].w == 0.6 and diagonal[1].h == 0.6,
    "diagonally touching pixels must form one 8-connected component")

local blank, blank_reason = Detector.detect({
    width = 100,
    height = 100,
    matrix = new_matrix(4, 4, 255),
}, { backend = backend })
expect(blank == nil and blank_reason == "no_panels",
    "blank pages must not produce a fake panel")

local too_many = new_matrix(130, 130, 255)
for line = 0, 12 do
    local offset = -18 + line * 3
    local first_x = math.max(1, 1 - offset)
    for segment = 0, 4 do
        local start_x = first_x + segment * 22
        for step = 0, 19 do
            local x = start_x + step
            too_many[x + offset][x] = 0
        end
    end
end
local panels, reason = Detector.detect({
    width = 130,
    height = 130,
    matrix = too_many,
}, { experimental = true, backend = backend })
expect(panels == nil and reason == "too_many_panels",
    "more than 64 valid panels must fall back")
expect(component_count == 65,
    "the limit fixture must contain exactly 65 disconnected components")

local failed, failed_reason = Detector.detect({}, {
    backend = {
        connected_components = function()
            return nil, "panel_raster_decode_failed"
        end,
    },
})
expect(failed == nil and failed_reason == "panel_raster_decode_failed",
    "backend failures must preserve stable error codes")

local function expect_malformed_backend_failure(name, malformed_backend)
    local ok, value, err = pcall(Detector.detect, {}, {
        backend = malformed_backend,
    })
    expect(ok and value == nil and err == "panel_detection_failed",
        name .. " must return panel_detection_failed without raising")
end

expect_malformed_backend_failure("a throwing backend", {
    connected_components = function()
        error("injected raw backend error")
    end,
})
expect_malformed_backend_failure("a non-table backend result", {
    connected_components = function() return "invalid" end,
})
expect_malformed_backend_failure("a hostile backend result", {
    connected_components = function()
        return setmetatable({}, {
            __index = function() error("injected result access error") end,
        })
    end,
})
expect_malformed_backend_failure("a non-table component box", {
    connected_components = function()
        return { boxes = { 42 }, width = 100, height = 100 }
    end,
})
expect_malformed_backend_failure("a sparse component array", {
    connected_components = function()
        return {
            boxes = { [2] = { x = 0, y = 0, w = 50, h = 50 } },
            width = 100,
            height = 100,
        }
    end,
})
expect_malformed_backend_failure("a non-finite component box", {
    connected_components = function()
        return {
            boxes = { { x = 0 / 0, y = 0, w = 50, h = 50 } },
            width = 100,
            height = 100,
        }
    end,
})

local saved_ffi = package.loaded.ffi
local saved_ffi_preload = package.preload.ffi
local saved_header = package.loaded["ffi/leptonica_h"]
local saved_header_preload = package.preload["ffi/leptonica_h"]
local crop_box
local source = { width = 400, height = 200, depth = 8 }
local lept = {}
function lept.pixRead() return source end
function lept.pixGetWidth(pix) return pix.width end
function lept.pixGetHeight(pix) return pix.height end
function lept.pixGetDepth(pix) return pix.depth end
function lept.pixScaleToSize(_, width, height)
    return { width = width, height = height, depth = 8 }
end
function lept.boxCreate(x, y, w, h)
    crop_box = { x = x, y = y, w = w, h = h }
    return crop_box
end
function lept.pixClipRectangle(_, box)
    return { width = box.w, height = box.h, depth = 8 }
end
function lept.pixClone(pix)
    return { width = pix.width, height = pix.height, depth = pix.depth }
end
function lept.pixInvert(_, pix) return pix end
function lept.pixThresholdToBinary(pix) return pix end
function lept.pixConnCompBB() return {} end
function lept.boxaGetCount() return 0 end
function lept.pixDestroy() end
function lept.boxDestroy() end
function lept.boxaDestroy() end

package.loaded.ffi = nil
package.loaded["ffi/leptonica_h"] = nil
package.preload.ffi = function()
    return {
        cast = function(_, value) return value end,
        cdef = function() end,
        loadlib = function() return lept end,
        new = function() return { [0] = 0 } end,
    }
end
package.preload["ffi/leptonica_h"] = function() return true end
local crop_ok, crop_result, crop_reason = pcall(Detector.detect, {
    path = "synthetic.png",
    max_width = 200,
    max_height = 100,
    crop = { x = 0.1, y = 0.1, w = 0.8, h = 0.8 },
})
package.loaded.ffi = saved_ffi
package.preload.ffi = saved_ffi_preload
package.loaded["ffi/leptonica_h"] = saved_header
package.preload["ffi/leptonica_h"] = saved_header_preload
expect(crop_ok and crop_result == nil and crop_reason == "no_panels"
    and crop_box and crop_box.x == 20 and crop_box.y == 10
    and crop_box.w == 160 and crop_box.h == 80,
    "normalized crop coordinates must map to the scaled physical page")

print(("panel_detector_spec: %d checks"):format(checks))
