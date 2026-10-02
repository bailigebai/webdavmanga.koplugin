local Errors = require("webdavmanga.errors")
local Bridge = require("webdavmanga.document_bridge")
local Browser = require("webdavmanga.ui_browser")
local checks, failures = 0, {}
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function case(name, run)
    local ok, err = pcall(run); if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
case("Errors timeout signal", function()
    expect(Errors.stream_reason("async timeout") == "range_timeout", "controlled async timeout needs a stable reason")
    expect(Errors.stream_stage("pdf", "async timeout") == "range_probe", "timeout belongs to the Range probe stage")
    local err = Errors.stream("pdf", "range_probe", "async timeout")
    expect(err.reason == "range_timeout" and err.detail == "pdf:range_timeout",
        "structured timeout must contain only the allowlisted reason")
    expect(Errors.message(err):find("请求超时", 1, true), "timeout must have a distinguishable request-timeout message")
end)
case("timeout redaction", function()
    expect(Errors.stream_reason("async timeout password=secret") == "stream_failed",
        "raw text extending the signal must never be treated as an allowlisted timeout")
    expect(Errors.stream_reason("content_range_missing") == "content_range_missing",
        "other existing failure reasons remain unchanged")
end)
for _, format in ipairs({ "pdf", "epub" }) do
    for _, ui_mode in ipairs({ false, true }) do
        case(format .. (ui_mode and " Browser" or " Bridge"), function()
            local tasks, parts, logs, downloads = {}, {}, {}, 0
            local reported, dialog, retry
            local bridge = Bridge:new{
                cache = { key_for = function(_, _, path) return path end,
                    lookup_record = function() end, paths_for = function()
                        local path = os.tmpname(); parts[#parts + 1] = path; return path .. ".final", path
                    end, discard_part = function() end },
                client_factory = function() return {
                    read_range = function() return nil end,
                    download_document = function() downloads = downloads + 1 end,
                } end,
                async = { run = function(work, done, options)
                    tasks[#tasks + 1] = { work = work, done = done, options = options }
                    return { cancel = function() end }
                end },
                logger = { warn = function(...)
                    local values = {...}; for i, v in ipairs(values) do values[i] = tostring(v) end
                    logs[#logs + 1] = table.concat(values, " ")
                end },
                mupdf_pages = { remote_capability = function() return false end },
                open_reader = function() error("timed-out document must not open") end,
            }
            local entry = { name = "book." .. format, path = "/secret/book." .. format, size = 100, connection = {} }
            if ui_mode then
                local browser = Browser:new{
                    settings = { get_connection = function() return {} end }, settings_ui = {}, directory_store = {},
                    open_reader = function() end,
                    ui = { show_progress = function() return { close = function() end } end,
                        show_info = function() end, confirm = function(_, model) dialog = model; return true end },
                    open_document = function(item, callbacks) return bridge:open(item, callbacks) end,
                }
                browser:_open_document_with_progress(entry, {})
            else
                bridge:open(entry, { on_document_fallback_prompt = function(kind, reason, confirm, structured)
                    reported, retry = structured, confirm
                    expect(kind == format and reason == "range_timeout", "Bridge must retain the timeout classification")
                    return true
                end })
            end
            expect(#tasks == 1, "streaming must start with one deferred inspection")
            tasks[1].done(false, nil, "async timeout")
            tasks[1].options.on_reaped()
            for _, part in ipairs(parts) do os.remove(part) end
            expect(downloads == 0 and #tasks == 1, "timeout must never start an unconfirmed complete download")
            if ui_mode then
                expect(dialog and dialog.text:find("请求超时", 1, true)
                    and not dialog.text:find("PDF 结构", 1, true) and not dialog.text:find("/secret", 1, true)
                    and not dialog.text:find("async timeout", 1, true),
                    "Browser must show the safe timeout message rather than a structure failure or raw details")
                dialog.on_cancel(); dialog.on_confirm()
                expect(#tasks == 1 and downloads == 0, "canceling the timeout prompt must invalidate confirmation")
            else
                expect(reported and reported.reason == "range_timeout" and reported.stream_stage == "range_probe"
                    and type(retry) == "function", "Bridge must pass structured timeout details and explicit retry")
            end
            expect(not table.concat(logs):find("/secret", 1, true), "timeout diagnostics must redact remote paths")
        end)
    end
end
expect(#failures == 0, table.concat(failures, "\n"))
print(("rebuild_0408_stream_timeout_spec: %d checks"):format(checks))
