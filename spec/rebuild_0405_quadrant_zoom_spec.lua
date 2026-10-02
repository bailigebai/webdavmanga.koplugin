local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Quadrant = require("webdavmanga.quadrant_zoom")
local ReaderShell = require("webdavmanga.ui_reader_shell")

local positions = {
    { x = 10, y = 10, id = "top_left" },
    { x = 590, y = 10, id = "top_right" },
    { x = 10, y = 790, id = "bottom_left" },
    { x = 590, y = 790, id = "bottom_right" },
    { x = 299, y = 399, id = "top_left" },
    { x = 300, y = 399, id = "top_right" },
    { x = 299, y = 400, id = "bottom_left" },
    { x = 300, y = 400, id = "bottom_right" },
}
for _, case in ipairs(positions) do
    expect(Quadrant.from_gesture({ pos = { x = case.x, y = case.y } }, 600, 800)
        == case.id, "gesture center boundary must select " .. case.id)
end
expect(Quadrant.from_gesture({ pos1 = { x = 100, y = 100 },
    pos2 = { x = 500, y = 700 } }, 600, 800) == "bottom_right",
    "two endpoints must select the quadrant of their midpoint")
expect(Quadrant.from_gesture({ pos = { x = 10, y = 10 },
    pos1 = { x = 590, y = 790 }, pos2 = { x = 590, y = 790 } },
    600, 800) == "top_left", "gesture.pos must take priority over endpoints")
expect(Quadrant.from_gesture({}, 600, 800) == nil,
    "missing position must not select a quadrant")
expect(Quadrant.from_gesture({ pos1 = { x = 20, y = 20 } }, 600, 800) == nil,
    "one endpoint must not select a quadrant")
expect(Quadrant.from_gesture({ pos = { x = 20, y = 20 } }, 0, 800) == nil
    and Quadrant.from_gesture({ pos = { x = 20, y = 20 } }, 600, -1) == nil,
    "invalid dimensions must not select a quadrant")
expect(Quadrant.from_gesture({ pos = { x = -1, y = 20 } }, 600, 800) == nil
    and Quadrant.from_gesture({ pos = { x = 600, y = 20 } }, 600, 800) == nil,
    "out-of-page positions must not select a quadrant")
expect(Quadrant.from_gesture({ pos = { x = 10 } }, 600, 800) == nil,
    "incomplete primary position must not fall back to endpoints")

local expected = {
    top_left = { x = 0, y = 0, w = 300, h = 400 },
    top_right = { x = 300, y = 0, w = 301, h = 400 },
    bottom_left = { x = 0, y = 400, w = 300, h = 401 },
    bottom_right = { x = 300, y = 400, w = 301, h = 401 },
}
local covered = {}
local pixels = 0
for id, want in pairs(expected) do
    local rect = Quadrant.viewport(601, 801, id)
    expect(rect and rect.x == want.x and rect.y == want.y
        and rect.w == want.w and rect.h == want.h,
        "odd-page viewport must retain remainder for " .. id)
    for y = rect.y, rect.y + rect.h - 1 do
        for x = rect.x, rect.x + rect.w - 1 do
            expect(x >= 0 and x < 601 and y >= 0 and y < 801
                and not covered[y * 601 + x], "viewport must stay in bounds without overlap")
            covered[y * 601 + x] = true
            pixels = pixels + 1
        end
    end
end
expect(pixels == 601 * 801, "four viewports must cover every odd-page pixel")
expect(Quadrant.viewport(601, 801, "unknown") == nil,
    "unknown quadrant must not produce a viewport")

local calls = {}
local gesture = { ges = "two_finger_tap", pos = { x = 500, y = 600 } }
local fallback = ReaderShell:new{
    owner = {
        onTwoFingerTap = function(_self, arg, received)
            calls[#calls + 1] = "two_finger"
            expect(arg and arg.owner == _self and received == gesture,
                "fallback dispatch must identify its source Shell and preserve the gesture")
        end,
        onRightTopDoubleTap = function() calls[#calls + 1] = "emergency" end,
    },
    widget_factory = function(model) return model end,
}
fallback.widget:onGesture(gesture)
expect(table.concat(calls, ",") == "two_finger",
    "two-finger tap must call only the two-finger owner handler")
fallback.widget:onGesture({ ges = "double_tap", pos = { x = 590, y = 10 } })
expect(table.concat(calls, ",") == "two_finger,emergency",
    "double tap must keep the emergency exit route")

local function widget_class()
    local class = {}
    class.__index = class
    function class:new(options)
        local object = options or {}
        setmetatable(object, self)
        if object.init then object:init() end
        return object
    end
    function class:extend(definition)
        local child = definition or {}
        setmetatable(child, { __index = self })
        child.__index = child
        return child
    end
    return class
end
local screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    getSize = function() return { w = 600, h = 800 } end,
}
local modules = {
    device = { screen = screen, input = { group = {} } },
    ["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 0 },
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/geometry"] = { new = function(_self, values) return values end },
    ["ui/gesturerange"] = { new = function(_self, values) return values end },
    ["ui/size"] = { padding = { default = 8 } },
    ["ui/uimanager"] = { setDirty = function() end },
}
for _, name in ipairs({
    "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/container/inputcontainer",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/textwidget",
    "ui/widget/titlebar", "ui/widget/verticalgroup",
}) do
    modules[name] = widget_class()
end
for name, module in pairs(modules) do
    package.loaded[name] = nil
    package.preload[name] = function() return module end
end
local production = ReaderShell:new{
    owner = {
        onTwoFingerTap = function(_self, arg, received)
            calls[#calls + 1] = "production_two_finger"
            expect(arg and arg.owner == _self and received == gesture,
                "production dispatch must identify its source Shell and preserve the gesture")
        end,
        onRightTopDoubleTap = function() calls[#calls + 1] = "production_emergency" end,
    },
    screen = screen,
}
production:show_page({}, {}, "1 / 1", nil, 0.5, true)
local ranges = production.widget.ges_events.TwoFingerTap
expect(ranges and #ranges == 1 and ranges[1].ges == "two_finger_tap",
    "production widget must register one two-finger gesture range")
local range = ranges[1].range()
expect(range.x == 0 and range.y == 0 and range.w == 600 and range.h == 800,
    "two-finger gesture must cover the full page content")
production.widget:onTwoFingerTap(nil, gesture)
expect(calls[#calls] == "production_two_finger",
    "production two-finger route must call only its owner handler")
expect(production.widget.ges_events.DoubleTap[1].ges == "double_tap",
    "production emergency double-tap registration must remain")

print(("rebuild_0405_quadrant_zoom_spec: %d checks passed"):format(checks))
