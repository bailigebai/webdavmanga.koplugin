local Diagnostics = {}
Diagnostics.__index = Diagnostics

local function default_decoder(path)
    local widget
    local ok = xpcall(function()
        local ImageWidget = require("ui/widget/imagewidget")
        widget = ImageWidget:new{ file = path, width = 32, height = 32 }
        local size = widget:getSize()
        if type(size) ~= "table" or type(size.w) ~= "number" or size.w <= 0
            or type(size.h) ~= "number" or size.h <= 0
            or widget._is_straight_alpha == false then
            error("image has no usable size")
        end
    end, function() return "image_decode_failed" end)
    if widget and widget.free then
        pcall(function() widget:free() end)
    end
    if ok then return true end
    return nil, "image_decode_failed"
end

function Diagnostics:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.sample_root = assert(options.sample_root, "sample root is required")
    object.samples = options.samples or require("resources.format_samples.manifest")
    object.decoder = options.decoder or default_decoder
    return object
end

function Diagnostics:run()
    local results = {}
    for _, sample in ipairs(self.samples) do
        local ok = self.decoder(self.sample_root .. "/" .. sample.filename)
        results[#results + 1] = {
            id = sample.id,
            label = sample.label,
            filename = sample.filename,
            note = sample.note,
            ok = ok == true,
            detail = ok == true and nil or "image_decode_failed",
        }
    end
    return results
end

function Diagnostics.summary(results)
    local lines = { "图片格式兼容性检测" }
    for _, result in ipairs(results) do
        local status = result.ok and "通过" or "失败"
        local note = result.note and ("（" .. result.note .. "）") or ""
        lines[#lines + 1] = result.label .. "：" .. status .. note
    end
    return table.concat(lines, "\n")
end

return Diagnostics
