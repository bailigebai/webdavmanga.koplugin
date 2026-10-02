local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Diagnostics = require("webdavmanga.format_diagnostics")

local attempted = {}
local diagnostics = Diagnostics:new{
    sample_root = "/plugin/resources/format_samples",
    samples = {
        { id = "jpg", label = "JPG", filename = "baseline.jpg" },
        { id = "webp", label = "WebP", filename = "lossy.webp" },
        { id = "gif", label = "GIF", filename = "static.gif", note = "只验证静态首帧" },
    },
    decoder = function(path)
        attempted[#attempted + 1] = path
        if path:match("webp$") then return nil, "decoder exploded: private path" end
        return true
    end,
}

local results = diagnostics:run()
expect(#results == 3 and #attempted == 3, "one failure must not stop later samples")
expect(results[1].ok and not results[2].ok and results[3].ok, "per-format status")
expect(results[2].detail == "image_decode_failed"
    and not tostring(results[2].detail):find("private path", 1, true),
    "public results must replace decoder details with a generic failure code")
expect(Diagnostics.summary(results):find("WebP：失败", 1, true), "Chinese failure line")
expect(not Diagnostics.summary(results):find("private path", 1, true), "decoder details stay out of UI")
expect(Diagnostics.summary(results):find("GIF：通过（只验证静态首帧）", 1, true),
    "GIF static-frame limitation should be shown")

local widgets = {}
package.preload["resources.format_samples.manifest"] = function()
    return {
        { id = "ready", label = "Ready", filename = "ready.png" },
        { id = "checkerboard", label = "Checkerboard", filename = "checkerboard.png" },
        { id = "broken-size", label = "Broken size", filename = "broken-size.png" },
        { id = "throws", label = "Throws", filename = "throws.png" },
    }
end
package.preload["ui/widget/imagewidget"] = function()
    return {
        new = function(_self, options)
            local widget = { options = options, freed = false }
            if options.file:match("checkerboard") then
                widget._is_straight_alpha = false
            end
            function widget:getSize()
                if options.file:match("throws") then error("private decoder detail") end
                if options.file:match("broken%-size") then return { w = 0, h = 32 } end
                return { w = 32, h = 32 }
            end
            function widget:free() self.freed = true end
            widgets[#widgets + 1] = widget
            return widget
        end,
    }
end

local default_results = Diagnostics:new{ sample_root = "/plugin/resources/format_samples" }:run()
expect(default_results[1].ok and not default_results[2].ok
    and not default_results[3].ok and not default_results[4].ok,
    "default decoder should use Geom dimensions and reject checkerboard, empty, and thrown decodes")
expect(default_results[2].detail == "image_decode_failed"
    and default_results[4].detail == "image_decode_failed",
    "default decoder failures should stay generic")
expect(#widgets == 4 and widgets[1].freed and widgets[2].freed
    and widgets[3].freed and widgets[4].freed
    and widgets[1].options.width == 32 and widgets[1].options.height == 32,
    "default decoder should render 32x32 and free every constructed widget")

print(("format_diagnostics_spec: %d checks"):format(checks))
