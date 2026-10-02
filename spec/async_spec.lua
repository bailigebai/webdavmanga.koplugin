local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Async = require("webdavmanga.async")

local function queued_scheduler()
    local queue = {}
    local scheduler = {
        scheduleIn = function(_self, _delay, callback)
            queue[#queue + 1] = callback
        end,
    }
    local function run_one()
        local callback = table.remove(queue, 1)
        expect(callback ~= nil, "scheduler should have a queued callback")
        callback()
    end
    local function run_all(limit)
        local remaining = limit or 100
        while #queue > 0 and remaining > 0 do
            remaining = remaining - 1
            run_one()
        end
        expect(#queue == 0, "scheduler should drain without an endless poll loop")
    end
    return scheduler, queue, run_one, run_all
end

local function fake_process(overrides)
    local state = {
        done = false,
        readable = 512,
        reads = 0,
        status_checks = 0,
        terminated = 0,
        writes = {},
    }
    local child_entry
    local ffiutil = {
        runInSubProcess = function(entry)
            child_entry = entry
            return 77, 88
        end,
        writeToFD = function(_fd, payload)
            state.writes[#state.writes + 1] = payload
            return true
        end,
        getNonBlockingReadSize = function() return state.readable end,
        isSubProcessDone = function()
            state.status_checks = state.status_checks + 1
            return state.done
        end,
        readAllFromFD = function()
            state.reads = state.reads + 1
            return state.output or "{[\"ok\"]=true,[\"result\"]=7}"
        end,
        terminateSubProcess = function()
            state.terminated = state.terminated + 1
        end,
    }
    for key, value in pairs(overrides or {}) do ffiutil[key] = value end
    return state, ffiutil, function()
        return child_entry
    end
end

do
    local scheduler, _queue, run_one, run_all = queued_scheduler()
    local state, ffiutil = fake_process()
    local deliveries = 0
    local handle = Async.run(function() return 7 end, function()
        deliveries = deliveries + 1
    end, { ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0 })

    run_one()
    expect(state.reads == 1 and deliveries == 0,
        "readable bytes must drain before exit to unblock the bounded child write, without delivery")
    handle:cancel()
    expect(state.reads == 1 and state.terminated == 1,
        "cancel must terminate without rereading the drained pipe")
    state.done = true
    run_all()
    expect(state.reads == 1 and deliveries == 0,
        "canceled work should be reaped once without delivery")
end

do
    local scheduler, queue, run_one = queued_scheduler()
    local state, ffiutil = fake_process()
    local deliveries = 0
    local delivered_value
    Async.run(function() return 7 end, function(ok, value)
        deliveries = deliveries + 1
        if ok then delivered_value = value end
    end, { ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0 })

    state.done = true
    run_one()
    expect(state.reads == 1 and deliveries == 1 and delivered_value == 7,
        "completed subprocess output should be read and delivered exactly once")
    expect(#queue == 0, "completion should not leave another delivery poll queued")
end

do
    local scheduler, _queue, run_one = queued_scheduler()
    local state, ffiutil = fake_process()
    state.output = "this is not serialized Lua"
    local deliveries = 0
    local delivered_error
    Async.run(function() return 7 end, function(ok, _value, err)
        deliveries = deliveries + 1
        if not ok then delivered_error = err end
    end, { ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0 })

    state.done = true
    run_one()
    expect(deliveries == 1 and delivered_error == "malformed subprocess output",
        "malformed child output should fail exactly once")
end

do
    local scheduler, queue, run_one, run_all = queued_scheduler()
    local state, ffiutil = fake_process()
    local deliveries = 0
    local delivered_error
    local cancelled = 0
    local reaped = 0
    local delivery_state
    Async.run(function() return "late" end, function(ok, _value, err, state_info)
        deliveries = deliveries + 1
        if not ok then delivered_error = err end
        delivery_state = state_info
    end, {
        ffiutil = ffiutil,
        scheduler = scheduler,
        poll_interval = 0,
        timeout = -1,
        on_cancelled = function() cancelled = cancelled + 1 end,
        on_reaped = function() reaped = reaped + 1 end,
    })

    run_one()
    expect(deliveries == 1 and delivered_error == "async timeout",
        "timeout should settle the operation exactly once")
    expect(delivery_state and delivery_state.reap_pending == true and reaped == 0,
        "timeout delivery should identify that subprocess ownership remains pending")
    expect(state.reads == 0 and state.terminated == 1,
        "timeout should terminate without reading an unfinished child pipe")
    state.done = true
    run_all()
    expect(deliveries == 1 and state.reads == 1 and cancelled <= 1 and reaped == 1,
        "timeout reaping must not redeliver or reread child output")
    run_all()
    expect(reaped == 1, "post-reap notification should be idempotent")
    expect(#queue == 0, "timeout reaping should drain all scheduled callbacks")
end


do
    local scheduler, _queue, run_one, run_all = queued_scheduler()
    local status_calls = 0
    local state
    local ffiutil
    state, ffiutil = fake_process{
        isSubProcessDone = function()
            status_calls = status_calls + 1
            if status_calls == 1 then error("simulated status failure") end
            return state.done
        end,
    }
    local delivered_state
    local reaped = 0
    Async.run(function() return "late" end, function(_ok, _value, _err, state_info)
        delivered_state = state_info
    end, {
        ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0,
        on_reaped = function() reaped = reaped + 1 end,
    })
    run_one()
    expect(delivered_state and delivered_state.reap_pending and reaped == 0,
        "status failure should settle before releasing subprocess ownership")
    state.done = true
    run_all()
    expect(reaped == 1 and state.reads == 1,
        "status failure should notify cleanup only after a positive reap")
end

do
    local scheduler, _queue, run_one, run_all = queued_scheduler()
    local state, ffiutil = fake_process()
    local callback_errors = {}
    Async.run(function() return "late" end, function()
        error("timeout done callback exploded")
    end, {
        ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0, timeout = -1,
        on_reaped = function() state.reaped = (state.reaped or 0) + 1 end,
        on_callback_error = function(err) callback_errors[#callback_errors + 1] = err end,
    })
    local boundary_ok = pcall(run_one)
    expect(boundary_ok and state.terminated == 1 and state.reads == 0
        and (state.reaped or 0) == 0 and #callback_errors == 1
        and tostring(callback_errors[1]):find("timeout done callback exploded", 1, true),
        "a throwing timeout callback must be diagnosed without preventing terminate/reap")
    state.done = true
    run_all()
    run_all()
    expect(state.reads == 1 and state.reaped == 1 and #callback_errors == 1,
        "throwing timeout callback cleanup should read and notify exactly once after reap")
end

do
    local scheduler, _queue, run_one, run_all = queued_scheduler()
    local state
    local ffiutil
    local status_calls = 0
    state, ffiutil = fake_process{
        isSubProcessDone = function()
            status_calls = status_calls + 1
            if status_calls == 1 then error("simulated status failure") end
            return state.done
        end,
    }
    local callback_errors, reaped = {}, 0
    Async.run(function() return "late" end, function()
        error("status done callback exploded")
    end, {
        ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0,
        on_reaped = function() reaped = reaped + 1 end,
        on_callback_error = function(err) callback_errors[#callback_errors + 1] = err end,
    })
    local boundary_ok = pcall(run_one)
    expect(boundary_ok and state.terminated == 1 and state.reads == 0
        and reaped == 0 and #callback_errors == 1
        and tostring(callback_errors[1]):find("status done callback exploded", 1, true),
        "a throwing status-failure callback must be diagnosed without preventing reap")
    state.done = true
    run_all()
    run_all()
    expect(state.reads == 1 and reaped == 1 and #callback_errors == 1,
        "throwing status-failure callback cleanup should be positive-reap gated and idempotent")
end

do
    local scheduler, queue, run_one, run_all = queued_scheduler()
    local state, ffiutil = fake_process()
    local callback_errors = {}
    Async.run(function() return 7 end, function()
        error("completed done callback exploded")
    end, {
        ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0,
        on_callback_error = function(err) callback_errors[#callback_errors + 1] = err end,
    })
    state.done = true
    local boundary_ok = pcall(run_one)
    expect(boundary_ok and state.reads == 1 and state.terminated == 0
        and #callback_errors == 1 and #queue == 0,
        "a throwing normal completion callback must not escape or leave process resources")
    run_all()
    expect(state.reads == 1 and #callback_errors == 1,
        "throwing normal completion callback must not cause duplicate read or reporting")
end

do
    local scheduler, _queue, _run_one, run_all = queued_scheduler()
    local state, ffiutil = fake_process()
    local cancelled, reaped = 0, 0
    local handle = Async.run(function() return "late" end, function() end, {
        ffiutil = ffiutil,
        scheduler = scheduler,
        poll_interval = 0,
        on_cancelled = function() cancelled = cancelled + 1 end,
        on_reaped = function() reaped = reaped + 1 end,
    })

    handle:cancel()
    handle:cancel()
    expect(cancelled == 0 and state.terminated == 1,
        "cancel notification should wait for reap and terminate only once")
    state.done = true
    run_all()
    expect(cancelled == 1 and state.reads == 1 and reaped == 1,
        "reaped cancellation should notify, read and release exactly once")
end

do
    local scheduler, _queue, run_one = queued_scheduler()
    local state, ffiutil, get_child_entry = fake_process()
    local delivered_error
    Async.run(function() return string.rep("x", 9000) end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, { ffiutil = ffiutil, scheduler = scheduler, poll_interval = 0 })

    get_child_entry()(77, 99)
    expect(#state.writes == 1 and #state.writes[1] <= 8192
        and state.writes[1]:find("payload_too_large", 1, true) ~= nil,
        "child payload written to the pipe must be bounded to 8192 bytes")
    state.output = state.writes[1]
    state.done = true
    run_one()
    expect(delivered_error == "subprocess payload exceeds 8192 bytes",
        "oversized results should deliver the bounded payload error")
end

do
    local scheduler, queue, run_one = queued_scheduler()
    local work_ran = false
    local delivered_error
    Async.run(function()
        work_ran = true
        return 7
    end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, { ffiutil = false, scheduler = scheduler })

    expect(not work_ran and delivered_error == nil and #queue == 1,
        "missing subprocess support must not run work synchronously")
    run_one()
    expect(not work_ran and delivered_error == "background subprocess unavailable",
        "missing subprocess support should fail asynchronously")
end

do
    local subprocess_starts = 0
    local status_checks = 0
    local work_ran = false
    local delivered_error
    local handle = Async.run(function()
        work_ran = true
        return 7
    end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, {
        scheduler = false,
        ffiutil = {
            runInSubProcess = function()
                subprocess_starts = subprocess_starts + 1
                return 77, 88
            end,
            writeToFD = function() return true end,
            getNonBlockingReadSize = function() return 0 end,
            isSubProcessDone = function()
                status_checks = status_checks + 1
                if status_checks > 1 then
                    error("poll recursed without a scheduler")
                end
                return false
            end,
            readAllFromFD = function()
                error("unfinished child pipe must not be read")
            end,
            terminateSubProcess = function() end,
        },
    })

    expect(handle and handle.cancel and not work_ran,
        "missing scheduler should return a cancellable handle without running work")
    expect(subprocess_starts == 0 and status_checks == 0,
        "missing scheduler must not start or recursively poll an unfinished child")
    expect(delivered_error == "background subprocess unavailable",
        "missing scheduler should use the unavailable result path")
end

for _, max_payload_bytes in ipairs({ 16, 96 }) do
    local scheduler, queue, run_one = queued_scheduler()
    local subprocess_starts = 0
    local work_ran = false
    local delivered_error
    Async.run(function()
        work_ran = true
        return string.rep("x", 100)
    end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, {
        scheduler = scheduler,
        max_payload_bytes = max_payload_bytes,
        ffiutil = {
            runInSubProcess = function()
                subprocess_starts = subprocess_starts + 1
                return 77, 88
            end,
            writeToFD = function() return true end,
            getNonBlockingReadSize = function() return 0 end,
            isSubProcessDone = function() return false end,
            readAllFromFD = function()
                error("invalid payload limit must not create a child pipe")
            end,
        },
    })

    expect(subprocess_starts == 0 and not work_ran and delivered_error == nil,
        "too-small payload limit must be rejected before subprocess startup")
    expect(#queue == 1,
        "too-small payload limit rejection should be scheduled asynchronously")
    run_one()
    expect(delivered_error == "max_payload_bytes must be an integer of at least 97",
        "too-small payload limit should report the supported hard boundary")
end

for _, max_payload_bytes in ipairs({ math.huge, -math.huge, 0 / 0 }) do
    local scheduler, queue, run_one = queued_scheduler()
    local subprocess_starts = 0
    local work_ran = false
    local delivered_error
    Async.run(function()
        work_ran = true
        return string.rep("x", 100)
    end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, {
        scheduler = scheduler,
        max_payload_bytes = max_payload_bytes,
        ffiutil = {
            runInSubProcess = function()
                subprocess_starts = subprocess_starts + 1
                return 77, 88
            end,
            writeToFD = function() return true end,
            getNonBlockingReadSize = function() return 0 end,
            isSubProcessDone = function() return false end,
            readAllFromFD = function()
                error("non-finite payload limit must not create a child pipe")
            end,
        },
    })

    expect(subprocess_starts == 0 and not work_ran and delivered_error == nil,
        "non-finite payload limit must be rejected before subprocess startup")
    expect(#queue == 1,
        "non-finite payload limit rejection should be scheduled asynchronously")
    run_one()
    expect(delivered_error == "max_payload_bytes must be an integer of at least 97",
        "non-finite payload limit should use the invalid-limit contract")
end

do
    local scheduler, _queue, run_one = queued_scheduler()
    local state, ffiutil, get_child_entry = fake_process()
    local delivered_error
    Async.run(function() return string.rep("x", 100) end, function(ok, _value, err)
        if not ok then delivered_error = err end
    end, {
        ffiutil = ffiutil,
        scheduler = scheduler,
        poll_interval = 0,
        max_payload_bytes = 97,
    })

    get_child_entry()(77, 99)
    expect(#state.writes == 1 and #state.writes[1] == 97,
        "minimum valid payload limit should fit its overflow envelope exactly")
    state.output = state.writes[1]
    state.done = true
    run_one()
    expect(delivered_error == "subprocess payload exceeds 97 bytes",
        "minimum valid payload limit should deliver the bounded overflow error")
end

print(("async_spec: %d checks"):format(checks))
