local ErrorReporter = require("webdavmanga.error_reporter")

local Async = {}

local function serialize(value)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind ~= "table" then return "nil" end
    local fields = {}
    for key, item in pairs(value) do
        if type(key) == "string" or type(key) == "number" then
            fields[#fields + 1] = "[" .. serialize(key) .. "]=" .. serialize(item)
        end
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function deserialize(value)
    if type(value) ~= "string" or value == "" then return nil end
    local loader = loadstring or load
    local chunk = loader("return " .. value)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    return ok and result or nil
end

local function sanitize(error_value)
    local text = ErrorReporter.sanitize(error_value or "unknown error")
    return #text > 500 and text:sub(1, 500) or text
end

local function callback_traceback(error_value)
    local message = tostring(error_value or "unknown callback error")
    if debug and type(debug.traceback) == "function" then
        local ok, traceback = pcall(debug.traceback, message, 2)
        if ok then return traceback end
    end
    return message
end

local function get_scheduler(options)
    if options.scheduler then return options.scheduler end
    local ok, manager = pcall(require, "ui/uimanager")
    return ok and manager or nil
end

local function get_ffiutil(options)
    if options.ffiutil ~= nil then return options.ffiutil end
    local ok, value = pcall(require, "ffi/util")
    return ok and value or false
end

local function schedule(scheduler, delay, callback)
    if not scheduler or type(scheduler.scheduleIn) ~= "function" then return false end
    local ok, result = pcall(scheduler.scheduleIn,
        scheduler, delay or 0, callback)
    return ok and result ~= false
end

function Async.run(work, done, options)
    options = options or {}
    local scheduler = get_scheduler(options)
    local ffiutil = get_ffiutil(options)
    local handle = { canceled = false }
    local settled = false
    local cancel_notified = false
    local reap_notified = false
    local reap_notification_needed = false
    local function report_callback_error(callback_error)
        handle.callback_error = callback_error
        if type(options.on_callback_error) == "function" then
            local reported, reporting_error = pcall(options.on_callback_error, callback_error)
            if reported then return end
            callback_error = tostring(callback_error)
                .. "\ncallback error reporter failed: " .. tostring(reporting_error)
        end
        local logger = options.logger
        if logger == nil then
            local loaded, default_logger = pcall(require, "logger")
            if loaded then logger = default_logger end
        end
        if logger and type(logger.err) == "function" then
            pcall(logger.err, "WebDavManga async callback failed:",
                sanitize(callback_error))
        end
    end
    local function settle(ok, result, err, state)
        if settled then return end
        settled = true
        if done and not handle.canceled then
            local callback_ok, callback_error = xpcall(function()
                done(ok, result, err, state)
            end, callback_traceback)
            if not callback_ok then report_callback_error(callback_error) end
        end
    end
    local function notify_cancelled()
        if cancel_notified then return end
        cancel_notified = true
        if options.on_cancelled then pcall(options.on_cancelled) end
    end
    local function notify_reaped()
        if reap_notified or not reap_notification_needed then return end
        reap_notified = true
        if options.on_reaped then pcall(options.on_reaped) end
    end

    local scheduler_available = scheduler
        and type(scheduler.scheduleIn) == "function"
    local subprocess_available = scheduler_available
        and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
        and type(ffiutil.getNonBlockingReadSize) == "function"

    if not subprocess_available then
        function handle:cancel()
            if self.canceled then return end
            self.canceled = true
            notify_cancelled()
        end
        local function unavailable()
            if handle.canceled then return end
            settle(false, nil, "background subprocess unavailable")
        end
        if not schedule(scheduler, options.delay or 0, unavailable) then
            unavailable()
        end
        return handle
    end

    local max_payload_bytes = options.max_payload_bytes
    if max_payload_bytes == nil then
        max_payload_bytes = 8192
    else
        max_payload_bytes = tonumber(max_payload_bytes)
    end
    if not max_payload_bytes
        or max_payload_bytes ~= max_payload_bytes
        or max_payload_bytes == math.huge
        or max_payload_bytes == -math.huge
        or max_payload_bytes < 97
        or max_payload_bytes ~= math.floor(max_payload_bytes) then
        function handle:cancel()
            if self.canceled then return end
            self.canceled = true
            notify_cancelled()
        end
        local function invalid_limit()
            if handle.canceled then return end
            settle(false, nil,
                "max_payload_bytes must be an integer of at least 97")
        end
        if not schedule(scheduler, options.delay or 0, invalid_limit) then
            invalid_limit()
        end
        return handle
    end
    local function child_entry(_pid, write_fd)
        local ok, result = pcall(work)
        local payload = serialize(ok
            and { ok = true, result = result }
            or { ok = false, error = sanitize(result) })
        if #payload > max_payload_bytes then
            payload = serialize({
                ok = false,
                error = "subprocess payload exceeds "
                    .. tostring(max_payload_bytes) .. " bytes",
                error_code = "payload_too_large",
            })
        end
        pcall(ffiutil.writeToFD, write_fd, payload, true)
    end

    local launch_ok, pid, read_fd = pcall(ffiutil.runInSubProcess,
        child_entry, true)
    if not launch_ok or not pid then
        return Async.run(work, done, {
            scheduler = scheduler, ffiutil = false, delay = options.delay,
            timeout = options.timeout, poll_interval = options.poll_interval,
            on_cancelled = options.on_cancelled,
            on_reaped = options.on_reaped,
            on_callback_error = options.on_callback_error,
            logger = options.logger,
            max_payload_bytes = max_payload_bytes,
        })
    end

    handle.pid, handle.fd = pid, read_fd
    local poll_interval = tonumber(options.poll_interval) or 0.125
    local termination_requested = false
    local pipe_output
    local function read_finished_pipe()
        if not handle.fd then return pipe_output end
        local fd = handle.fd
        handle.fd = nil
        local ok, raw = pcall(ffiutil.readAllFromFD, fd)
        if ok then pipe_output = raw end
        return pipe_output
    end
    local reap_later
    reap_later = function()
        if not handle.pid then return true end
        local ok, process_done = pcall(ffiutil.isSubProcessDone, handle.pid)
        if ok and process_done then
            handle.pid = nil
            read_finished_pipe()
            if handle.canceled then notify_cancelled() end
            notify_reaped()
            return true
        elseif scheduler and scheduler.scheduleIn then
            schedule(scheduler, poll_interval, reap_later)
        end
        return false
    end
    local function terminate_and_reap()
        if not handle.pid then return true end
        if not termination_requested and ffiutil.terminateSubProcess then
            termination_requested = true
            pcall(ffiutil.terminateSubProcess, handle.pid)
        end
        if schedule(scheduler, poll_interval, reap_later) then return false end
        return reap_later() == true
    end
    function handle:cancel()
        if self.canceled then return end
        self.canceled = true
        if self.pid then
            reap_notification_needed = true
            terminate_and_reap()
        else
            notify_cancelled()
        end
    end

    local started_at = os.time()
    local timeout = tonumber(options.timeout) or 60
    local function fail_scheduler()
        reap_notification_needed = true
        local reaped = terminate_and_reap()
        settle(false, nil, "UI scheduler unavailable", { reap_pending = not reaped })
    end
    local function poll()
        if handle.canceled then return reap_later() end
        if os.difftime(os.time(), started_at) > timeout then
            reap_notification_needed = true
            terminate_and_reap()
            settle(false, nil, "async timeout", { reap_pending = true })
            return
        end
        local ok, process_done = pcall(ffiutil.isSubProcessDone, handle.pid)
        if not ok then
            reap_notification_needed = true
            terminate_and_reap()
            settle(false, nil, "subprocess status failed", { reap_pending = true })
            return
        end
        if not process_done then
            local readable_ok, readable = pcall(ffiutil.getNonBlockingReadSize,
                handle.fd)
            if readable_ok and tonumber(readable) and tonumber(readable) > 0 then
                read_finished_pipe()
            end
            if not schedule(scheduler, poll_interval, poll) then fail_scheduler() end
            return
        end
        handle.pid = nil
        local decoded = deserialize(read_finished_pipe())
        if type(decoded) ~= "table" then
            settle(false, nil, "malformed subprocess output")
        elseif decoded.ok then
            settle(true, decoded.result, nil)
        else
            settle(false, nil, decoded.error or "subprocess failed")
        end
    end
    if not schedule(scheduler, options.delay or 0, poll) then fail_scheduler() end
    return handle
end

return Async
