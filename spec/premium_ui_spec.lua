local UiSettings = require("webdavmanga.ui_settings")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local settings = {
    get_sources = function() return {{ id = "nas", name = "NAS", kind = "webdav",
        server_url = "https://nas", root_path = "/Books" }} end,
    get_active_source_id = function() return "nas" end,
    get_reader = function() return { image_engine = "default" } end,
}
local source_model
local license_model
local ui = {
    show_sources = function(_, model) source_model = model end,
    show_license = function(_, model) license_model = model end,
    show_info = function() end,
}
local object = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {},
    ui = ui,
}

object:_show_sources()
expect(source_model and type(source_model.on_license) == "function",
    "connection settings must expose an independent premium license entry")
expect(type(source_model.on_add_opds) == "function"
    and source_model.on_open_opds == nil,
    "connection settings must add OPDS as a source without a separate shelf")
source_model.on_license()
expect(license_model and type(license_model.status) == "function"
    and type(license_model.activate) == "function"
    and type(license_model.clear_local) == "function"
    and type(license_model.error_message) == "function",
    "license dialog model must provide status, activate, clear and error callbacks")
expect(license_model.error_message("service_unavailable")
    == "授权服务暂时不可用，请稍后重试。",
    "license transport errors must be translated instead of exposing raw codes")
expect(type(license_model.on_close) == "function",
    "license dialog model must provide a cancellable close callback")

local continued, calls, clear_calls = 0, 0, 0
local close_count = 0
local gate = {
    status = function() return { authorized = false, state = "inactive" } end,
    activate = function(_, key, callback)
        calls = calls + 1
        expect(key == "ABCD-EFGH-IJKL", "license key should reach the injected activator")
        callback(true)
    end,
    clear_local = function()
        clear_calls = clear_calls + 1
        return true
    end,
}
local gate_ui = {
    show_license = function(_, model)
        model.activate("ABCD-EFGH-IJKL", function(ok)
            if ok then continued = continued + 1 end
        end)
        model.activate("ABCD-EFGH-IJKL", function(ok)
            if ok then continued = continued + 1 end
        end)
        expect(model.clear_local() == true,
            "license dialog clear callback should reach the injected license")
        model.on_close()
        close_count = close_count + 1
    end,
}
local gate_settings = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {},
    ui = gate_ui,
    license = gate,
}
gate_settings:show_license{}
expect(calls == 1 and continued == 1 and clear_calls == 1 and close_count == 1,
    "license activation and clear callbacks must run once and remain cancellable")

local async_model, pending_work, pending_done, cancel_calls = nil, nil, nil, 0
local request_calls, commit_calls, async_callbacks = 0, 0, 0
local async_receipt = { version = 1, product = "webdavmanga-premium" }
local async_license = {
    status = function() return { authorized = false } end,
    prepare_activation = function(_, key)
        expect(key == "2345-6789-ABCD", "async activation must prepare the entered key")
        return { normalized = key, device_id = string.rep("a", 64), key_id = string.rep("b", 64) }
    end,
    request_activation = function()
        request_calls = request_calls + 1
        return async_receipt
    end,
    commit_activation = function(_, value)
        commit_calls = commit_calls + 1
        expect(value == async_receipt, "UI process must commit the worker receipt")
        return true, value
    end,
    clear_local = function() return true end,
}
local async_ui = {
    show_license = function(_, model) async_model = model end,
    show_info = function() end,
}
local async_adapter = {
    run = function(work, done)
        pending_work, pending_done = work, done
        return { cancel = function() cancel_calls = cancel_calls + 1 end }
    end,
}
local async_settings = UiSettings:new{
    settings = settings, client_factory = function() return {} end,
    async = async_adapter, cache = {}, ui = async_ui, license = async_license,
}
async_settings:show_license{}
local async_handle = async_model.activate("2345-6789-ABCD", function(ok, value)
    if ok and value == async_receipt then async_callbacks = async_callbacks + 1 end
end)
expect(type(async_handle) == "table" and request_calls == 0 and commit_calls == 0,
    "network activation must leave the UI callback before blocking work starts")
local work_result = pending_work()
expect(request_calls == 1 and commit_calls == 0,
    "background phase must perform network and signature verification only")
pending_done(true, work_result)
expect(commit_calls == 1 and async_callbacks == 1,
    "successful background activation must commit and callback once on the UI process")

async_model.activate("2345-6789-ABCD", function() async_callbacks = async_callbacks + 1 end)
local canceled_done = pending_done
expect(async_model.cancel_activation() == true and cancel_calls == 1,
    "license dialog must expose cancellation for the active background request")
canceled_done(true, { receipt = async_receipt })
expect(commit_calls == 1 and async_callbacks == 1,
    "a canceled request's late result must not commit or invoke the callback")

local UiLibrary = require("webdavmanga.ui_library")
local manga = { name = "分类第六本", path = "/Books/category-six" }
local access_calls, identify_calls, resume_calls, library_license_requests = 0, 0, 0, 0
local library_access = {
    can_open = function() access_calls = access_calls + 1; return false, "license_required" end,
    can_add = function() return true end,
}
local library_ui = {
    show_choice = function(self, model) self.choice = model end,
    show_menu = function(self, model) self.menu = model end,
    show_info = function() end,
    close_choice = function() end,
    close_menu = function() end,
}
local browser = {
    identify_manga = function() identify_calls = identify_calls + 1 end,
    prepare_resume = function() resume_calls = resume_calls + 1 end,
    prepare_chapter = function() end,
    open_prepared_reader = function() end,
    show_folder_picker = function() end,
}
local library = { ALL = "__all__", UNCATEGORIZED = "__uncategorized__" }
local library_settings = { get_connection = function() return { server_url = "https://nas",
    username = "reader", root_path = "/Books" } end }
local ui_library = UiLibrary:new{
    settings = library_settings,
    library = library,
    cover_service = {},
    cover_grid = {},
    browser = browser,
    ui = library_ui,
    premium_access = library_access,
    request_license = function(continuation)
        library_license_requests = library_license_requests + 1
        return { activate_success = continuation }
    end,
}
ui_library:_open_record({ manga = manga }, library.ALL)
expect(access_calls == 1 and identify_calls == 0,
    "category shelf direct reading must pass through the premium open gate")
ui_library:show_open_choice({ manga = manga }, library.ALL)
expect(access_calls == 2 and resume_calls == 0 and library_license_requests == 2
    and not library_ui.choice,
    "category shelf chapter choice must be gated before preparing a chapter")

print(("premium_ui_spec: %d checks"):format(checks))
