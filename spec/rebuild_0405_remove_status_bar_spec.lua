local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local saved = { hide_status_bar = true, show_progress_bar = true,
    show_preprocess_success = true }
local writes = 0
local stored_reader
local store = {
    readSetting = function(_, key, default)
        if key == "reader" then return saved end
        return default
    end,
    saveSetting = function(_, key, value)
        writes = writes + 1
        if key == "reader" then stored_reader = value end
    end,
    flush = function() writes = writes + 1 end,
}
local Settings = require("webdavmanga.settings")
local settings = Settings:new{ store = store }
local reader = settings:get_reader()
expect(reader.hide_status_bar == nil, "legacy hidden-status setting must be ignored")
expect(saved.hide_status_bar == true and writes == 0,
    "reading a legacy setting must not rewrite the backing store")
expect(reader.show_progress_bar == true and reader.show_preprocess_success == true,
    "progress bar and preprocess notice settings must remain available")
expect(settings:set_reader{ hide_status_bar = true } == true
    and stored_reader.hide_status_bar == nil,
    "new saves must not reintroduce the removed setting")

local function source(path)
    local file = assert(io.open(path, "rb"))
    local contents = file:read("*a")
    file:close()
    return contents
end

local prefix = (TEST_PLUGIN_ROOT or "webdavmanga.koplugin") .. "/webdavmanga/"
local settings_source = source(prefix .. "settings.lua")
local menu_source = source(prefix .. "ui_settings.lua")
local reader_source = source(prefix .. "ui_reader.lua")
local shell_source = source(prefix .. "ui_reader_shell.lua")
expect(not settings_source:find("invalid_hide_status_bar", 1, true),
    "removed setting must have no validation path")
expect(not menu_source:find("hide_status_bar", 1, true)
    and not menu_source:find("隐藏状态栏", 1, true),
    "settings menu must have no hidden-status row or output")
expect(not reader_source:find("hide_status_bar", 1, true)
    and not reader_source:find("set_status_visible", 1, true)
    and not reader_source:find("restore_status_visibility", 1, true),
    "reader must have no hidden-status setter, menu, or runtime branch")
expect(not shell_source:find("status_visible", 1, true)
    and not shell_source:find("set_status_visible", 1, true)
    and not shell_source:find("restore_status_visibility", 1, true),
    "shell must have no status hiding state, setter, or render branch")
expect(reader_source:find("set_show_progress_bar", 1, true)
    and reader_source:find("set_show_preprocess_success", 1, true)
    and reader_source:find("force_close", 1, true),
    "progress, success notice, and emergency exit must remain reachable")

local ReaderShell = require("webdavmanga.ui_reader_shell")
local shell = ReaderShell:new{
    owner = { force_close = function() end },
    widget_factory = function()
        return { set_model = function() end }
    end,
}
expect(shell.status_visible == nil and shell.set_status_visible == nil
    and shell.restore_status_visibility == nil,
    "shell instance must expose no status hiding state or methods")
expect(shell:show_page({}, {}, nil, {}, 0.5, true, 2) == true
    and shell.current_model.show_progress == true
    and shell.current_model.progress == 0.5,
    "normal progress display must remain available")
expect(shell:show_status("处理成功", 0) == true
    and shell.current_model.status_text == "处理成功",
    "processing success notice must still appear on the page")

print(("rebuild_0405_remove_status_bar_spec: %d checks"):format(checks))
