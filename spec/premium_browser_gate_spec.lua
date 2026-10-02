local Browser = require("webdavmanga.ui_browser")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local connection = { kind = "webdav", server_url = "https://nas", username = "reader",
    root_path = "/Books" }
local settings = {
    get_connection = function() return connection end,
    get_browser_path = function() return "/Books" end,
    set_browser_path = function() return true end,
}
local ui = { show_info = function() end, show_menu = function() end,
    show_progress = function() return { close = function() end } end }
local directory_store = { load = function(_, _, callbacks)
    callbacks.on_error({ code = "unexpected_load" })
    return { cancel = function() end }
end }
local requested, continued = 0, 0
local access = {
    can_open = function() return false, "license_required" end,
    can_cache = function() return false, "license_required" end,
}
local browser = Browser:new{
    settings = settings,
    settings_ui = {},
    directory_store = directory_store,
    ui = ui,
    open_reader = function() end,
    premium_access = access,
    request_license = function(continuation)
        requested = requested + 1
        local used = false
        return {
            activate_success = function()
                if used then return end
                used = true
                continuation()
            end,
        }
    end,
}
local manga = { name = "第六本", path = "/Books/sixth", is_folder = true }
local allowed = browser:_premium_gate("open", manga, function() continued = continued + 1 end)
expect(allowed == false and requested == 1 and continued == 0,
    "blocked opening must request a license without starting the original action")
local request = browser._last_license_request
expect(request and type(request.activate_success) == "function",
    "blocked action should retain a cancellable activation request")
request.activate_success()
request.activate_success()
expect(continued == 1, "successful activation must resume the original action once")

local cache_continued = 0
local cache_allowed = browser:_premium_gate("cache", manga, function() cache_continued = cache_continued + 1 end)
expect(cache_allowed == false and requested == 2 and cache_continued == 0,
    "blocked caching must use the cache gate")

print(("premium_browser_gate_spec: %d checks"):format(checks))
