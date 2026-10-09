local shown, closed = {}, {}

local UIManager = {
    show = function(_self, widget) shown[#shown + 1] = widget end,
    close = function(_self, widget) closed[#closed + 1] = widget end,
}
package.preload["webdavmanga.ui_background"]=function() return {new=function(model)
    model.kind="plugin_background";return model
end} end

package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/confirmbox"] = function()
    return {
        new = function(_self, model)
            model.kind = "confirm"
            return model
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_self, model) return model end }
end
package.preload["ui/widget/menu"] = function()
    local Menu = {}
    function Menu.getItemFontSize() return 20 end
    function Menu:new(model)
        function model:onClose()
            return self.close_callback()
        end
        local close_callback = function() return model:onClose() end
        model.title_bar = {
            close_callback = close_callback,
            right_icon_tap_callback = close_callback,
            right_button = { callback = close_callback },
        }
        return model
    end
    return Menu
end

local Browser = require("webdavmanga.ui_browser")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local function last_shown(predicate)
    for index = #shown, 1, -1 do
        if predicate(shown[index]) then return shown[index] end
    end
end

local root = "/漫画"
local nested = root .. "/子目录"
local close_count, cancel_count = 0, 0

local function empty_index()
    return {
        count = function() return 0 end,
        iterator = function() return {}, 1 end,
    }
end

local directory = {
    folders = function() return empty_index() end,
    images = function() return empty_index() end,
    documents = function() return empty_index() end,
    file_count = function() return 0 end,
    close = function() close_count = close_count + 1 end,
}

local directory_store = {
    load = function(_self, _path, callbacks)
        callbacks.on_ready(directory)
        return {
            cancel = function() cancel_count = cancel_count + 1 end,
        }
    end,
}

local connection = {
    kind = "webdav",
    server_url = "https://nas",
    username = "reader",
    root_path = root,
}
local settings = {
    get_connection = function() return connection end,
    is_configured = function() return true end,
    get_browser_path = function() return nested end,
    set_browser_path = function() return true end,
    flush = function() end,
}

local browser = Browser:new{
    settings = settings,
    settings_ui = { show_connection = function() end },
    directory_store = directory_store,
    open_reader = function() end,
}

browser:show_library(false, nested)
local nested_menu = last_shown(function(widget) return widget.title_bar ~= nil end)
local shown_before_close = #shown
local closed_before_close = #closed

nested_menu.title_bar.right_button.callback()
local confirm = last_shown(function(widget) return widget.kind == "confirm" end)
expect(#shown == shown_before_close + 1
    and confirm
    and tostring(confirm.text):find("关闭", 1, true),
    "the bookshelf top-right close button must show a close confirmation")
expect(#closed == closed_before_close and browser.current_path == nested,
    "requesting close must keep the current bookshelf visible until confirmation")

confirm.ok_callback()
expect(closed[#closed-1] == nested_menu and closed[#closed].kind=="plugin_background",
    "confirming close must dismiss both the bookshelf menu and its background")
expect(cancel_count > 0 and close_count > 0,
    "confirming close must cancel active browsing and release directory handles")

browser:show_library(false, nested)
local back_menu = last_shown(function(widget) return widget.title_bar ~= nil end)
local shown_before_back = #shown
back_menu.close_callback()
local parent_menu = last_shown(function(widget) return widget.title_bar ~= nil end)
expect(#shown >= shown_before_back + 1
    and parent_menu
    and parent_menu.title == "漫画书架"
    and parent_menu.subtitle == root,
    "hardware Back must still navigate to the parent bookshelf without close confirmation")

print(("browser_close_spec: %d checks"):format(checks))
