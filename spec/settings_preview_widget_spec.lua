-- Exercise the production preview adapter with UIManager's CloseWidget event
-- contract. Rendering is stubbed because native Kindle widgets require FFI.
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local stack, widgets, fail_dirty = {}, {}, false
local Class = {}
function Class:new(options)
    local value = setmetatable(options or {}, {__index = self})
    widgets[#widgets + 1] = value
    if value.init then value:init() end
    return value
end
function Class:extend(options) return setmetatable(options or {}, {__index = self}) end
function Class:getSize() return self.dimen or {w = self.width or 40, h = self.height or 40} end
function Class:free()
    if self.frees then return end -- Native widget free() is idempotent.
    self.frees = 1
    for _, child in ipairs(self) do if child.free then child:free() end end
end
function Class:handleEvent(event)
    for _, child in ipairs(self) do
        if child:handleEvent(event) then return true end
    end
    local handler = self["on" .. event]
    if handler then return handler(self) end
end
for _, module in ipairs({"buttondialog", "multiinputdialog", "infomessage", "confirmbox", "button",
    "container/centercontainer", "container/framecontainer", "container/inputcontainer",
    "imagewidget", "linewidget", "overlapgroup", "textwidget", "titlebar", "verticalgroup",
    "verticalspan", "horizontalgroup"}) do package.loaded["ui/widget/" .. module] = Class end
package.loaded["ui/geometry"] = Class
local Image = Class:extend{}
function Image:onCloseWidget() self:free() end
package.loaded["ui/widget/imagewidget"] = Image
package.loaded["ui/font"] = {getFace = function() return {} end}
package.loaded["ffi/blitbuffer"] = {COLOR_WHITE = 1, COLOR_BLACK = 0}
package.loaded["device"] = {screen = {getSize = function() return {w = 600, h = 800} end}}
local manager = {}
function manager:show(widget) stack[#stack + 1] = {widget = widget} end
function manager:close(widget)
    -- KOReader delivers CloseWidget before removing it from the window stack.
    widget:handleEvent("CloseWidget")
    for i = #stack, 1, -1 do if stack[i].widget == widget then table.remove(stack, i) end end
end
function manager:setDirty() if fail_dirty then error("fixture refresh rejected") end end
manager._window_stack = stack
package.loaded["ui/uimanager"] = manager
local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")
local controller = UiSettings:new{settings = Settings:new{store = {readSetting = function(_, _, fallback) return fallback end}},
    client_factory = function() return {} end, async = {}, cache = {}}
local function buffer()
    local value = {frees = 0}
    function value:getWidth() return 600 end
    function value:getHeight() return 800 end
    function value:viewport() return self end
    function value:free() self.frees = self.frees + 1 end
    return value
end
local function open()
    local before, after = buffer(), buffer()
    expect(controller:_publish_filter_preview(controller.ui.show_tone_preview,
        {before_buffer = before, after_buffer = after}, "tone_adjust_preview"), "open production preview")
    return before, after, stack[#stack].widget, controller.filter_preview.handle
end
for _, method in ipairs({"back", "handle", "native", "all"}) do
    local before, after, widget, handle = open()
    if method == "back" then widget:onBack()
    elseif method == "handle" then handle.close()
    elseif method == "native" then manager:close(widget)
    else controller:close_all() end
    expect(widget.frees == 1, "CloseWidget must release preview widget tree")
    expect(before.frees == 1 and after.frees == 1, "native close releases owned images")
    expect(#stack == 0 and not controller.filter_preview, "preview removed from window stack")
    handle.close()
    expect(widget.frees == 1 and before.frees == 1, "duplicate close is idempotent")
end
local before, after = buffer(), buffer()
fail_dirty = true
expect(controller:_publish_filter_preview(controller.ui.show_tone_preview,
    {before_buffer = before, after_buffer = after}, "tone_adjust_preview") == false,
    "refresh failure reported as failed preview")
expect(before.frees == 1 and after.frees == 1, "failed display releases images")
-- show_info is now the sole remaining widget; the failed preview was removed.
expect(#stack == 1 and stack[1].widget.text, "failed preview cannot remain visible")
print(("settings_preview_widget_spec: %d checks"):format(checks))
