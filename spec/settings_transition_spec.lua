local checks, failures = 0, {}
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function test(name, body)
    local ok, err = pcall(body)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")
local function fixture()
    local f = {queue = {}, shown = {}, logs = {}}
    for _, name in ipairs({"buttondialog", "multiinputdialog", "infomessage", "confirmbox"}) do
        package.loaded["ui/widget/" .. name] = {new = function(_, model)
            if f.reject and name == "buttondialog" then error("fixture settings layout failure") end
            return model
        end}
    end
    package.loaded["logger"] = {err = function(...) f.logs[#f.logs + 1] = {...} end}
    package.loaded["ui/uimanager"] = {
        show = function(_, model) f.shown[#f.shown + 1] = model end,
        close = function() end,
        nextTick = function(_, callback) f.queue[#f.queue + 1] = callback end,
    }
    local settings = Settings:new{store = {readSetting = function(_, _, fallback) return fallback end,
        saveSetting = function() end, flush = function() return true end}}
    f.controller = UiSettings:new{settings = settings, client_factory = function() return {} end,
        cache = {}, async = {}}
    function f:drain()
        local queued = self.queue
        self.queue = {}
        for _, callback in ipairs(queued) do callback() end
    end
    return f
end
test("deferred reader settings layout failure stays within plugin", function()
    local f = fixture()
    f.controller:show_reader()
    f.shown[#f.shown].buttons[1][1].callback()
    f.reject = true
    local ok = pcall(f.drain, f)
    expect(ok, "deferred settings error escaped to KOReader main loop")
    expect(#f.logs == 1, "deferred failure should be reported once")
end)
test("closed settings cancel deferred transition", function()
    local f = fixture()
    f.controller:show_reader()
    f.shown[#f.shown].buttons[1][1].callback()
    local count = #f.shown
    f.controller:close_all()
    f:drain()
    expect(#f.shown == count, "closed settings reopened from queued transition")
end)
test("gray setting continuation cancelled on close", function()
    local f = fixture()
    f.controller:show_gray_settings()
    f.shown[#f.shown].buttons[1][1].callback()
    local count = #f.shown
    f.controller:close_all()
    f:drain()
    expect(#f.shown == count, "gray settings reopened after close all")
end)
test("tone setting continuation cancelled on close", function()
    local f = fixture()
    f.controller:show_tone_settings()
    f.shown[#f.shown].buttons[1][1].callback()
    local count = #f.shown
    f.controller:close_all()
    f:drain()
    expect(#f.shown == count, "tone settings reopened after close all")
end)
test("new settings supersede queued navigation", function()
    local f = fixture()
    f.controller:show_reader()
    f.shown[#f.shown].buttons[1][1].callback()
    f.controller:show_tone_settings()
    local count = #f.shown
    f:drain()
    expect(#f.shown == count, "old navigation obscures newer settings")
end)
for _, scheduling in ipairs({"missing", "reject", "throw"}) do
    test("synchronous fallback remains guarded: " .. scheduling, function()
        local f = fixture()
        local manager = package.loaded["ui/uimanager"]
        if scheduling == "missing" then manager.nextTick = nil
        elseif scheduling == "reject" then manager.nextTick = function() return false end
        else manager.nextTick = function() error("fixture scheduling failed") end end
        f.controller:show_reader()
        local button = f.shown[#f.shown].buttons[1][1]
        f.reject = true
        expect(pcall(button.callback), "fallback exception escaped to native button")
        expect(#f.logs == 1, "fallback failure is reported once")
    end)
end
assert(#failures == 0, table.concat(failures, "\n"))
print(("settings_transition_spec: %d checks"):format(checks))
