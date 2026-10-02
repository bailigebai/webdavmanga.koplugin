local DialogKeyboard = require("webdavmanga.dialog_keyboard")

local UiRegistry = {}
UiRegistry.__index = UiRegistry

function UiRegistry:new(ui_manager)
    return setmetatable({
        ui_manager = assert(ui_manager, "UI manager is required"),
        widgets = setmetatable({}, { __mode = "k" }),
    }, self)
end

function UiRegistry:show(widget, ...)
    if not widget then return self.ui_manager:show(widget, ...) end
    self.widgets[widget] = true
    local ok, result = pcall(self.ui_manager.show, self.ui_manager, widget, ...)
    if not ok then
        self.widgets[widget] = nil
        error(result, 0)
    end
    return result
end

function UiRegistry:close(widget, ...)
    if widget then
        self.widgets[widget] = nil
        DialogKeyboard.hide(widget)
    end
    return self.ui_manager:close(widget, ...)
end

function UiRegistry:close_all()
    local pending, seen = {}, {}
    local stack = self.ui_manager._window_stack
    if type(stack) == "table" then
        for index = #stack, 1, -1 do
            local window = stack[index]
            local widget = window and window.widget
            if widget and self.widgets[widget] and not seen[widget] then
                seen[widget] = true
                pending[#pending + 1] = widget
            end
        end
    else
        for widget in pairs(self.widgets) do pending[#pending + 1] = widget end
    end

    self.widgets = setmetatable({}, { __mode = "k" })
    for _, widget in ipairs(pending) do
        DialogKeyboard.hide(widget)
        pcall(self.ui_manager.close, self.ui_manager, widget)
    end
    return true
end

return UiRegistry
