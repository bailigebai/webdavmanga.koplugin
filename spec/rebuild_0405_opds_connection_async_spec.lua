local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")

local values = {}
local store = {
    readSetting = function(_, key, default)
        if values[key] == nil then return default end
        return values[key]
    end,
    saveSetting = function(_, key, value) values[key] = value end,
    flush = function() return true end,
}
local settings = Settings:new{ store = store }
local forms, messages, jobs = {}, {}, {}
local busy_closed = 0
local deferred, resume = false, nil
local ui = {
    show_opds_connection = function(_, model) forms[#forms + 1] = model end,
    show_info = function(_, text) messages[#messages + 1] = text end,
    show_busy = function() return { close = function() busy_closed = busy_closed + 1 end } end,
}
local controller = UiSettings:new{
    settings = settings, client_factory = function() return {} end,
    opds_client_factory = function() return { fetch = function()
        return { is_atom_feed = true, entries = {{ name = "卷" }} }
    end } end,
    async = { run = function(work, done)
        local job = { work = work, done = done, canceled = false }
        jobs[#jobs + 1] = job
        return { cancel = function() job.canceled = true end }
    end },
    cache = {}, ui = ui,
    network_manager = { willRerunWhenConnected = function(_, start)
        if not deferred then return false end
        resume = start
        return true
    end },
}
local input_a = { name = "A", server_url = "https://a.example/opds",
    server_kind = "auto", username = "", password = "" }
local input_b = { name = "B", server_url = "https://b.example/opds",
    server_kind = "auto", username = "", password = "" }

assert(controller:_show_opds_connection_dialog(nil, nil, true))
local first = forms[#forms]
assert(first.on_test(input_a) and #jobs == 1)
assert(type(first.on_close) == "function" and first.on_close(),
    "closing an OPDS form must invalidate its pending test")
assert(jobs[1].canceled and busy_closed == 1,
    "closing the form must cancel its async handle and busy state")
local messages_before_close = #messages
jobs[1].done(true, { ok = true, server_kind = "kavita" })
assert(#messages == messages_before_close,
    "a completed test must not notify after its form was closed")

assert(controller:_show_opds_connection_dialog(nil, nil, true))
local second = forms[#forms]
assert(second.on_test(input_a) and second.on_test(input_b) and #jobs == 3)
assert(jobs[2].canceled,
    "a newer OPDS test must cancel the older handle")
jobs[3].done(true, { ok = true, server_kind = "komga" })
local messages_after_new = #messages
jobs[2].done(true, { ok = true, server_kind = "kavita" })
assert(#messages == messages_after_new,
    "an out-of-order older result must not notify or overwrite detection")
assert(second.on_save(input_b), "the form must save after the latest test")
local source = settings:get_source(settings:get_active_source_id())
assert(source.server_kind == "komga",
    "an older test must not overwrite the latest detected server kind")

assert(controller:_show_opds_connection_dialog(nil, nil, true))
local third = forms[#forms]
assert(third.on_test(input_a) and #jobs == 4)
assert(third.on_save(input_a) and jobs[4].canceled,
    "saving must cancel the in-flight test")
local messages_after_save = #messages
jobs[4].done(true, { ok = true, server_kind = "kavita" })
assert(#messages == messages_after_save,
    "a completed test must not notify after save")

deferred = true
assert(controller:_show_opds_connection_dialog(nil, nil, true))
local fourth = forms[#forms]
assert(fourth.on_test(input_b) and type(resume) == "function")
local count_before_resume = #jobs
assert(fourth.on_close())
resume()
assert(#jobs == count_before_resume,
    "network-resume callback must not start a closed form's test")

deferred = false
assert(controller:_show_opds_connection_dialog(nil, nil, true))
local fifth = forms[#forms]
assert(fifth.on_test(input_a) and #jobs == count_before_resume + 1)
local shutdown_job = jobs[#jobs]
assert(controller:close_all(), "settings shutdown must close active dialogs")
assert(shutdown_job.canceled,
    "close_all must cancel the active OPDS connection test")
local messages_after_shutdown = #messages
shutdown_job.done(true, { ok = true, server_kind = "kavita" })
assert(#messages == messages_after_shutdown,
    "close_all must suppress late OPDS connection-test messages")

assert(controller:_show_opds_connection_dialog(nil, nil, true))
local prior_form = forms[#forms]
assert(prior_form.on_test(input_a))
local prior_job = jobs[#jobs]
assert(controller:_show_opds_connection_dialog(nil, nil, true))
assert(prior_job.canceled,
    "opening a replacement form must cancel the previous form's test")
local messages_after_replacement = #messages
prior_job.done(true, { ok = true, server_kind = "kavita" })
assert(#messages == messages_after_replacement,
    "a replaced form's late test result must not notify")
local replacement_form = forms[#forms]
assert(replacement_form.on_test(input_b),
    "the replacement form must still be able to run its own test")

print("rebuild_0405_opds_connection_async_spec: passed")
