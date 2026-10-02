local ErrorReporter = require("webdavmanga.error_reporter")

local MemoryTransfer = {}

local function schedule(scheduler, delay, callback)
    if not scheduler or type(scheduler.scheduleIn) ~= "function" then return false end
    local ok, result = pcall(scheduler.scheduleIn, scheduler, delay or 0, callback)
    return ok and result ~= false
end

local function default_read(fd, count)
    local ffi = require("ffi")
    local buffer = ffi.new("char[?]", count)
    local read = tonumber(ffi.C.read(fd, buffer, count))
    if not read or read < 0 then return nil, "pipe read failed" end
    return ffi.string(buffer, read)
end

local function clean_error(value)
    local text = ErrorReporter.sanitize(value or "memory transfer failed")
    text = text:gsub("[\r\n]", " ")
    return #text > 500 and text:sub(1, 500) or text
end

function MemoryTransfer.run(work, done, options)
    options = options or {}
    local scheduler = options.scheduler
    if not scheduler then
        local ok, manager = pcall(require, "ui/uimanager")
        if ok then scheduler = manager end
    end
    local ffiutil = options.ffiutil
    if ffiutil == nil then
        local ok, value = pcall(require, "ffi/util")
        ffiutil = ok and value or false
    end
    local read_from_fd = options.read_from_fd or default_read
    local maximum = math.floor(tonumber(options.maximum_bytes) or 64 * 1024 * 1024)
    local handle = { canceled = false }
    local settled, closed = false, false
    local cancelled_notified = false

    local function notify_cancelled()
        if cancelled_notified or not handle.canceled then return end
        cancelled_notified = true
        if type(options.on_cancelled) == "function" then
            pcall(options.on_cancelled)
        end
    end

    local function settle(ok, body, err)
        if settled then return end
        settled = true
        if not handle.canceled and type(done) == "function" then
            pcall(done, ok, body, err)
        end
    end
    local function unavailable(message)
        local callback = function()
            settle(false, nil, message)
        end
        if not schedule(scheduler, 0, callback) then callback() end
    end
    if maximum < 1 or maximum > 128 * 1024 * 1024 then
        unavailable("invalid maximum image size")
        function handle:cancel()
            self.canceled = true
            notify_cancelled()
        end
        return handle
    end
    if not scheduler or not ffiutil
        or type(ffiutil.runInSubProcess) ~= "function"
        or type(ffiutil.writeToFD) ~= "function"
        or type(ffiutil.getNonBlockingReadSize) ~= "function"
        or type(ffiutil.isSubProcessDone) ~= "function"
        or type(ffiutil.readAllFromFD) ~= "function"
        or type(ffiutil.terminateSubProcess) ~= "function" then
        unavailable("background subprocess unavailable")
        function handle:cancel()
            self.canceled = true
            notify_cancelled()
        end
        return handle
    end

    local function child_entry(_pid, write_fd)
        local ok, body, detail = pcall(work)
        local header
        if not ok then
            header = "ERR " .. clean_error(body) .. "\n"
            body = ""
        elseif type(body) ~= "string" then
            header = "ERR " .. clean_error(detail) .. "\n"
            body = ""
        elseif #body > maximum then
            header = "ERR response exceeds maximum image size\n"
            body = ""
        else
            header = "OK " .. tostring(#body) .. "\n"
        end
        local function write(value)
            for offset = 1, #value, 4096 do
                if ffiutil.writeToFD(write_fd, value:sub(offset, offset + 4095), false)
                    ~= true then return false end
            end
            return true
        end
        if write(header) then write(body) end
        pcall(ffiutil.writeToFD, write_fd, "", true)
    end

    local launched, pid, read_fd = pcall(ffiutil.runInSubProcess,
        child_entry, true)
    if not launched or not pid or not read_fd then
        unavailable("background subprocess unavailable")
        function handle:cancel()
            self.canceled = true
            notify_cancelled()
        end
        return handle
    end
    handle.pid, handle.fd = pid, read_fd
    local chunks, size = {}, 0
    local now = options.now or os.time
    local started_at = now()
    local timeout = tonumber(options.timeout) or 120
    local poll_interval = tonumber(options.poll_interval) or 0.05

    local function append(chunk)
        if type(chunk) ~= "string" or chunk == "" then return true end
        size = size + #chunk
        if size > maximum + 520 then return false end
        chunks[#chunks + 1] = chunk
        return true
    end
    local function close_pipe()
        if closed or not handle.fd then return "" end
        closed = true
        local fd = handle.fd
        handle.fd = nil
        local ok, tail = pcall(ffiutil.readAllFromFD, fd)
        return ok and tail or ""
    end
    local function terminate()
        if handle.pid then pcall(ffiutil.terminateSubProcess, handle.pid) end
    end
    local reap
    reap = function()
        if not handle.pid then close_pipe(); return true end
        local ok, process_done = pcall(ffiutil.isSubProcessDone, handle.pid)
        if ok and process_done then
            handle.pid = nil
            close_pipe()
            notify_cancelled()
            return true
        end
        return schedule(scheduler, poll_interval, reap)
    end
    local function abort(message)
        terminate()
        settle(false, nil, message)
        if not schedule(scheduler, poll_interval, reap) then
            pcall(ffiutil.isSubProcessDone, handle.pid, true)
            handle.pid = nil
            close_pipe()
        end
    end
    function handle:cancel()
        if self.canceled then return end
        self.canceled = true
        terminate()
        if not self.pid then
            close_pipe()
            notify_cancelled()
        end
    end

    local poll
    poll = function()
        if handle.canceled then
            local ok, process_done = pcall(ffiutil.isSubProcessDone, handle.pid)
            if ok and process_done then
                handle.pid = nil
                close_pipe()
                notify_cancelled()
            else
                schedule(scheduler, poll_interval, poll)
            end
            return
        end
        if now() - started_at > timeout then
            abort("memory transfer timeout")
            return
        end
        while handle.fd do
            local ok, readable = pcall(ffiutil.getNonBlockingReadSize, handle.fd)
            readable = ok and tonumber(readable) or 0
            if not readable or readable <= 0 then break end
            local read_ok, chunk, read_error = pcall(read_from_fd,
                handle.fd, math.min(readable, 64 * 1024))
            if not read_ok or not chunk then
                abort(clean_error(read_ok and read_error or chunk))
                return
            end
            if not append(chunk) then
                abort("response exceeds maximum image size")
                return
            end
        end
        local status_ok, process_done = pcall(ffiutil.isSubProcessDone, handle.pid)
        if not status_ok then
            abort("subprocess status failed")
            return
        end
        if not process_done then
            if not schedule(scheduler, poll_interval, poll) then
                abort("UI scheduler unavailable")
            end
            return
        end
        handle.pid = nil
        if not append(close_pipe()) then
            settle(false, nil, "response exceeds maximum image size")
            return
        end
        local payload = table.concat(chunks)
        local header_end = payload:find("\n", 1, true)
        if not header_end then
            settle(false, nil, "malformed memory transfer")
            return
        end
        local header, body = payload:sub(1, header_end - 1), payload:sub(header_end + 1)
        local expected = tonumber(header:match("^OK (%d+)$"))
        if expected then
            if expected ~= #body or expected > maximum then
                settle(false, nil, "incomplete memory transfer")
            else
                settle(true, body, nil)
            end
            return
        end
        settle(false, nil, header:match("^ERR (.*)$") or "malformed memory transfer")
    end
    if not schedule(scheduler, options.delay or 0, poll) then
        abort("UI scheduler unavailable")
    end
    return handle
end

return MemoryTransfer
