local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local shown, closed, progress_dialog_model
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, model) return model end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, model) return model end }
end
package.preload["ui/widget/menu"] = function()
    return { new = function(_, model) return model end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown = widget end,
        close = function(_, widget) closed = widget end,
        setDirty = function() end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, model)
        progress_dialog_model = model
        return model
    end }
end
package.preload["ui/widget/progresswidget"] = function()
    return { new = function(_, model)
        function model:setPercentage(value) self.percentage = value end
        return model
    end }
end
package.preload["device"] = function()
    return { screen = {
        getWidth = function() return 1264 end,
        getHeight = function() return 1680 end,
        scaleBySize = function(_, value) return value end,
    } }
end

local connection = {
    kind = "webdav", server_url = "http://nas", root_path = "/Books",
    username = "u", password = "p",
}
local canceled = 0
local Browser = require("webdavmanga.ui_browser")
local browser = Browser:new{
    settings = {
        get_connection = function() return connection end,
        get_browser_path = function() return "/Books" end,
    },
    settings_ui = {}, directory_store = {}, open_reader = function() end,
    open_document = function(_entry, callbacks)
        if callbacks.on_open_handle then
            callbacks.on_open_handle{
                cancel = function() canceled = canceled + 1; return true end,
            }
        end
        return true
    end,
}

expect(browser:_open_document_with_progress({
    path = "/Books/book.mobi", name = "book.mobi", size = 200000,
}, {}) == true, "remote MOBI opening must start")
local cancel_button = progress_dialog_model and progress_dialog_model.buttons
    and progress_dialog_model.buttons[1]
    and progress_dialog_model.buttons[1][1]
expect(cancel_button and cancel_button.text == "取消打开",
    "opening progress must show an explicit cancel button")
expect(cancel_button.callback() == true,
    "the cancel button must consume the tap")
expect(canceled == 1,
    "the cancel button must cancel the active document request")
expect(closed == shown,
    "the cancel button must close the blocking progress dialog")

local worker_canceled, open_handle = 0, nil
local Bridge = require("webdavmanga.document_bridge")
local bridge = Bridge:new{
    cache = {
        key_for = function() return "book-key" end,
        lookup_record = function() return nil end,
    },
    client_factory = function()
        return {
            connection = connection,
            read_range = function() return "mobi", {
                ["Content-Range"] = "bytes 0-3/200000",
            } end,
        }
    end,
    async = { run = function()
        return { cancel = function() worker_canceled = worker_canceled + 1 end }
    end },
    mobi_pages = {},
    open_reader = function() return true end,
}
expect(bridge:open({
    path = "/Books/book.mobi", name = "book.mobi", size = 200000,
    file_kind = "document", connection = connection,
}, {
    on_open_handle = function(handle) open_handle = handle end,
}) == true, "remote MOBI indexing must start")
expect(open_handle and type(open_handle.cancel) == "function",
    "document bridge must expose the active MOBI request to the progress UI")
expect(open_handle:cancel() == true and worker_canceled == 1,
    "canceling the exposed request must terminate the MOBI worker")
expect(next(bridge.pending_mobi) == nil,
    "canceling MOBI indexing must remove the pending request")

local async_runs, download_canceled, discarded = 0, 0, 0
local fallback_handles = {}
local fallback_confirm
local fallback_bridge = Bridge:new{
    cache = {
        key_for = function() return "fallback-key" end,
        lookup_record = function() return nil end,
        paths_for = function()
            return "/cache/book.mobi", "/cache/book.mobi.part"
        end,
        discard_part = function() discarded = discarded + 1 end,
    },
    client_factory = function()
        return {
            connection = connection,
            read_range = function() return nil, nil, "range unavailable" end,
            download_document = function()
                return { size = 200000, format = "mobi" }
            end,
        }
    end,
    async = { run = function(_worker, done)
        async_runs = async_runs + 1
        if async_runs == 1 then
            done(true, { error = "not_image_mobi" }, nil, {})
            return { cancel = function() end }
        end
        return { cancel = function() download_canceled = download_canceled + 1 end }
    end },
    mobi_pages = {},
    open_reader = function() return true end,
}
expect(fallback_bridge:open({
    path = "/Books/text.mobi", name = "text.mobi", size = 200000,
    file_kind = "document", connection = connection,
}, {
    on_open_handle = function(handle)
        fallback_handles[#fallback_handles + 1] = handle
    end,
    on_document_fallback_prompt = function(format, reason, retry)
        expect(format == "mobi" and reason == "not_image_mobi", "MOBI fallback must remain classified")
        fallback_confirm = retry
        return true
    end,
}) == true, "MOBI fallback download must start")
expect(#fallback_handles == 1 and async_runs == 1 and fallback_confirm,
    "MOBI fallback must wait for explicit confirmation before scheduling a complete download")
fallback_confirm(); fallback_confirm()
expect(#fallback_handles == 2,
    "the progress UI must receive the replacement fallback download handle")
expect(fallback_handles[2]:cancel() == true and download_canceled == 1,
    "canceling after fallback must terminate the complete download")
expect(next(fallback_bridge.pending) == nil and discarded == 1,
    "canceling a fallback download must clear its request and partial file")

print(("rebuild_0369_mobi_cancel_spec: %d checks"):format(checks))
