local shown = {}

local function widget_class(kind)
    return { new = function(_, model)
        model = model or {}
        model.kind = kind
        return model
    end }
end

package.preload["ui/widget/buttondialog"] = function() return widget_class("button") end
package.preload["ui/widget/confirmbox"] = function() return widget_class("confirm") end
package.preload["ui/widget/infomessage"] = function() return widget_class("info") end
package.preload["ui/widget/multiinputdialog"] = function()
    local class = widget_class("input")
    local new = class.new
    class.new = function(self, model)
        model = new(self, model)
        model.getFields = function() return { "2345-6789-ABCD" } end
        return model
    end
    return class
end
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) shown[#shown + 1] = widget end }
end
package.preload["webdavmanga.dialog_keyboard"] = function()
    return {
        with_top_button = function(model) return model end,
        show = function() return true end,
        hide = function() return true end,
    }
end
package.preload["webdavmanga.ui_registry"] = function()
    local Registry = {}
    function Registry:new() return setmetatable({}, { __index = self }) end
    function Registry:show(widget) shown[#shown + 1] = widget; return widget end
    function Registry:close() return true end
    return Registry
end

local UiSettings = require("webdavmanga.ui_settings")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function find_button(dialog, text)
    for _, row in ipairs(dialog.buttons or {}) do
        for _, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
end

local function object_with(status, clear_local)
    return UiSettings:new{
        settings = {}, client_factory = function() return {} end,
        async = {}, cache = {}, license = {
            status = function() return status end,
            clear_local = clear_local,
        },
    }
end

local clear_calls = 0
local active = object_with({ authorized = true }, function()
    clear_calls = clear_calls + 1
    return true
end)
active:show_license{}
local dialog = shown[#shown]
local clear_button = find_button(dialog, "清除本机授权（测试）")
expect(clear_button and type(clear_button.callback) == "function",
    "license page must always expose the local clear test action")
clear_button.callback()
local first_confirm = shown[#shown]
expect(first_confirm.kind == "confirm" and type(first_confirm.ok_callback) == "function",
    "authorized clear must require a first confirmation")
first_confirm.ok_callback()
local second_confirm = shown[#shown]
expect(second_confirm ~= first_confirm and second_confirm.kind == "confirm"
    and type(second_confirm.ok_callback) == "function",
    "authorized clear must require a distinct second confirmation")
second_confirm.ok_callback()
expect(clear_calls == 1, "double confirmation must clear exactly once")

shown = {}
local inactive = object_with({ authorized = false }, function()
    error("inactive clear must not mutate storage")
end)
inactive:show_license{}
find_button(shown[#shown], "清除本机授权（测试）").callback()
expect(shown[#shown].kind == "info"
    and shown[#shown].text == "当前未激活，无需清除。",
    "inactive clear action must explain that no mutation is needed")

shown = {}
local activation_cancel_calls = 0
local cancellable = object_with({ authorized = false }, function() return true end)
cancellable:show_license{
    activate = function()
        return { cancel = function() activation_cancel_calls = activation_cancel_calls + 1 end }
    end,
}
local activation_dialog = shown[#shown]
find_button(activation_dialog, "激活").callback()
local progress_dialog = shown[#shown]
expect(progress_dialog.kind == "button"
    and find_button(progress_dialog, "取消验证"),
    "activation must show a cancellable progress dialog instead of a blocking message")
find_button(progress_dialog, "取消验证").callback()
expect(activation_cancel_calls == 1,
    "canceling the progress dialog must cancel the active activation handle")

print(("license_ui_adapter_spec: %d checks"):format(checks))
