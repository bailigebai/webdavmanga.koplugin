local Browser = require("webdavmanga.ui_browser")
local Settings = require("webdavmanga.settings")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local saved = {}
local store = {
    readSetting = function(_self, key, fallback)
        local value = saved[key]
        return value == nil and fallback or value
    end,
    saveSetting = function(_self, key, value) saved[key] = value end,
    flush = function() return true end,
}
local settings = Settings:new{ store = store }
expect(settings:get_offline_root() == "/mnt/us/Books/WebDAVManga",
    "whole-manga downloads need a safe Kindle default directory")
local invalid, invalid_error = settings:set_offline_root("C:/temp")
expect(invalid == nil and invalid_error == "invalid_offline_root",
    "offline downloads must reject paths outside /mnt/us")
expect(settings:set_offline_root(" /mnt/us/Comics Offline// ") == true
    and settings:get_offline_root() == "/mnt/us/Comics Offline",
    "offline root should be normalized and persisted")

local calls = { cache = 0, enter = 0, navigate = 0 }
local item = {
    callback = function() calls.navigate = calls.navigate + 1 end,
    cache_callback = function() calls.cache = calls.cache + 1 end,
    secondary_callback = function() calls.enter = calls.enter + 1 end,
}
Browser.select_menu_action(item, { x = 0.60 })
Browser.select_menu_action(item, { x = 0.85 })
Browser.select_menu_action(item, { x = 0.20 })
expect(calls.cache == 1 and calls.enter == 1 and calls.navigate == 1,
    "folder rows need independent cache, enter-manga, and navigation hit zones")

local function index(entries)
    return {
        count = function() return #entries end,
        get = function(_self, position) return entries[position] end,
    }
end
local connection = { kind = "webdav", server_url = "http://nas:5005",
    username = "reader", root_path = "/Books" }
local browser = Browser:new{
    settings = {
        get_connection = function() return connection end,
        get_browser_path = function() return "/Books" end,
        set_browser_path = function() return true end,
        flush = function() end,
    },
    settings_ui = {}, directory_store = {}, ui = {},
    open_reader = function() end,
}
local entered, cached = 0, 0
browser.enter_manga = function() entered = entered + 1 end
browser.cache_manga = function() cached = cached + 1 end
local folder = { name = "漫画一", path = "/Books/漫画一", is_folder = true }
local folder_items = browser:_directory_items("/Books", index({ folder }), 1,
    index({}), index({}), 0)
local folder_row = folder_items[5]
expect(folder_row.mandatory == "进入漫画"
    and folder_row.mandatory_func() == "进入漫画"
    and folder_row.cache_callback == nil
    and type(folder_row.secondary_callback) == "function",
    "every child folder must expose only the enter-manga action")
folder_row.secondary_callback()
expect(entered == 1 and cached == 0,
    "the child-folder enter action must not cache the manga")

local direct_items = browser:_directory_items("/Books/漫画一", index({}), 1,
    index({ { name = "001.jpg", path = "/Books/漫画一/001.jpg" } }), index({}), 1)
local direct_row = direct_items[5]
expect(direct_row and direct_row.mandatory == "进入漫画"
    and direct_row.cache_callback == nil
    and type(direct_row.secondary_callback) == "function",
    "a direct-image folder must also expose only the enter-manga action")
direct_row.secondary_callback()
expect(entered == 2 and cached == 0,
    "the direct-folder enter action must not cache the manga")

print(("rebuild_0355_offline_phase2_spec: %d checks"):format(checks))
