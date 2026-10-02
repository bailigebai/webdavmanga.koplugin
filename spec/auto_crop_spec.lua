local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local AutoCrop = require("webdavmanga.auto_crop")

local function buffer(width, height, pixel)
    return {
        getWidth = function() return width end,
        getHeight = function() return height end,
        getPixel = function(_, x, y) return pixel(x, y) end,
    }
end

local page = buffer(100, 160, function(x, y)
    if x >= 12 and x < 88 and y >= 16 and y < 144 then return 24 end
    return 226
end)
local crop = assert(AutoCrop.detect(page, { max_percent = 20, samples = 32 }))
expect(crop.x >= 10 and crop.y >= 14 and crop.w <= 80 and crop.h <= 132,
    "light page margins should be cropped")

local dirty_gray = buffer(100, 160, function(x, y)
    if x >= 10 and x < 90 and y >= 12 and y < 148 then return 30 end
    return ((x + y) % 17 == 0) and 185 or 214
end)
expect(AutoCrop.detect(dirty_gray, { max_percent = 20, samples = 32 }) ~= nil,
    "gray paper and sparse edge noise must still crop")

local numbered = buffer(100, 160, function(x, y)
    if y >= 148 and y < 154 and x >= 46 and x < 55 then return 0 end
    if x >= 8 and x < 92 and y >= 8 and y < 145 then return 20 end
    return 250
end)
local number_crop = assert(AutoCrop.detect_page_number(numbered, { max_percent = 12 }))
expect(number_crop.y > 140 and number_crop.h < 20,
    "only the bottom page-number strip should be returned")

expect(AutoCrop.detect(buffer(100, 160, function() return 12 end), {}) == nil,
    "solid dark pages must not be treated as white-margin pages")

print(("auto_crop_spec: %d checks passed"):format(checks))
