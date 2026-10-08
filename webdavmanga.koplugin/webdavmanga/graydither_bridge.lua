-- Optional GrayDither service; all image and refresh processing stays there.
local Bridge = {}
local defaults = {
    graydither_enabled = false,
    graydither_refresh_enabled = false,
    graydither_refresh_interval = 5,
    graydither_refresh_mode = "native",
    graydither_refresh_hold = 0.30,
}

function Bridge.create(reader, shell)
    local loaded, loader = pcall(require, "pluginloader")
    if not loaded or type(loader) ~= "table" or type(loader.getPluginInstance) ~= "function" then return nil end
    local found, plugin = pcall(loader.getPluginInstance, loader, "graydither")
    if not found or type(plugin) ~= "table" or type(plugin.createImageSession) ~= "function" then return nil end
    local store = {}
    function store:readSetting(key, fallback)
        local value = reader.reader_settings and reader.reader_settings[key]
        if value == nil then value = defaults[key] end
        if value == nil then return fallback end
        return value
    end
    function store:saveSetting(key, value)
        assert(defaults[key] ~= nil, "unsupported GrayDither preference")
        assert(reader.shell == shell and not reader.closing and not shell.closed
            and not shell.graydither_owner_closed, "reading session closed")
        local values = {}
        for name, item in pairs(reader.reader_settings or {}) do values[name] = item end
        values[key] = value
        assert(reader:_persist_reader(values), "reading settings could not be saved")
    end
    function store:delSetting(key)
        assert(defaults[key] ~= nil, "unsupported GrayDither preference")
        self:saveSetting(key, defaults[key])
    end
    local ok, session = pcall(plugin.createImageSession, plugin, {
        owner = shell.widget,
        store = store,
        is_ready = function()
            return reader.shell == shell and not reader.closing and not shell.closed
                and not shell.graydither_owner_closed
                and reader.pending_request == nil
                and not (reader.webtoon_session and reader.webtoon_session.busy)
                and not shell.graydither_suspended and shell.current_model ~= nil
                and shell.current_model.kind == "page"
        end,
        redraw = function()
            if reader.shell == shell and not reader.closing and not shell.closed
                and shell.current_model and shell.current_model.kind == "page" then
                shell.ui_manager:setDirty(shell.widget, "partial")
            end
        end,
    })
    if not ok or type(session) ~= "table" then return nil end
    for _, method in ipairs({"attachImage", "settingsChanged", "pause", "resume", "reset",
        "close", "isRefreshManaged", "requestRefresh", "getMenuItems", "showMenu"}) do
        if type(session[method]) ~= "function" then
            if type(session.close) == "function" then pcall(session.close, session) end
            return nil
        end
    end
    return session
end

return Bridge
