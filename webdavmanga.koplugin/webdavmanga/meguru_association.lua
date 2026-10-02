local Document = require("webdavmanga.meguru_document")
local Association = {}
local installed = setmetatable({}, { __mode = "k" })
local registered = setmetatable({}, { __mode = "k" })
local messages = {
    missing_source = "此指针的 OPDS 连接不存在，请先恢复连接设置。",
    reader_unavailable = "OPDS 阅读入口暂不可用。",
    credentials_unavailable = "无法从连接设置恢复凭据。",
    invalid_stream_template = "指针的页面模板无效。",
    invalid_page_count = "指针的页数无效。",
    pointer_read_failed = "无法读取指针文件。",
    history_write_failed = "漫画已打开，但无法保存到阅读历史。",
}
local function show_error(reason)
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
        text = messages[reason] or "无法打开此 OPDS 指针，请检查文件和连接设置。",
    })
end

function Association.install(options)
    options = options or {}
    local registry = options.document_registry or require("document/documentregistry")
    local reader = options.reader_ui or require("apps/reader/readerui")
    local history = options.read_history or require("readhistory")
    if type(options.open_pointer) ~= "function" or type(reader.showReader) ~= "function" then
        return nil, "reader_unavailable"
    end
    if not registered[registry] then
        registry:addProvider("meguru", "application/x-webdavmanga-meguru", Document, 1)
        registered[registry] = true
    end
    local state = installed[reader]
    if not state then
        state = { original = reader.showReader }
        installed[reader] = state
        reader.showReader = function(...)
            local first, second = ...
            local path = type(first) == "string" and first or second
            if type(path) ~= "string" or not path:lower():match("%.meguru$") then
                return state.original(...)
            end
            local accepted, displayed, recorded = false, false, false
            local function record_display()
                displayed = true
                if not accepted or recorded then return end
                recorded = true
                local recorded, result = pcall(state.history.addItem, state.history, path)
                -- addItem normally returns nil. A failed history write must not
                -- undo an already successful handoff or retry either operation.
                if not recorded or result == false then
                    state.show_error(messages.history_write_failed, "history_write_failed")
                end
            end
            local called, opened, reason = pcall(state.open_pointer, path, record_display)
            if called and opened == true then
                accepted = true
                if displayed then record_display() end
                return true
            end
            reason = called and reason or "pointer_open_failed"
            -- Only known, fixed messages cross the UI boundary; exception text may
            -- include transport credentials. FileManager has not been closed.
            state.show_error(messages[reason] or "无法打开此 OPDS 指针，请检查文件和连接设置。", reason)
            return false, reason
        end
    end
    state.open_pointer, state.history = options.open_pointer, history
    state.show_error = options.show_error or function(_, reason) show_error(reason) end
    return true
end

return Association
