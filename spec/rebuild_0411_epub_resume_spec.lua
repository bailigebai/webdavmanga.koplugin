local fixture = dofile("spec/rebuild_0411_epub_opening_spec.lua")
local ArchivePages = require("webdavmanga.archive_pages")
local Async = require("webdavmanga.async")
local Reader = require("webdavmanga.ui_reader")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, field in pairs(value) do result[key] = copy(field) end
    return result
end

for _, kind in ipairs({ "direct", "xhtml", "svg" }) do
    local opened, err, _, expected, bytes = fixture.inspect(kind, 25,
        { page_limit = 3, source_version = "size:etag1", generation = "reader-7" }, true)
    expect(opened and not err and opened.index:count() == 3 and opened.continuation,
        kind .. " creates a resumable opening")
    local reads, snapshots = {}, {}
    local descriptor = { size = #bytes, read_at = function(offset, length)
        reads[#reads + 1] = { offset, length }
        return bytes:sub(offset + 1, offset + length)
    end }
    local resumed, reason = ArchivePages:new():inspect_remote(descriptor, "epub", "/book.epub", {
        continuation = copy(opened.continuation), start_page = 4,
        source_version = "size:etag1", generation = "reader-7",
        progress_interval = 5, on_progress = function(index, total)
            snapshots[#snapshots + 1] = index:count()
            expect(total == 25, kind .. " snapshot retains actual spine total")
            return true
        end,
    })
    expect(resumed and not reason and resumed.index:count() == 25
        and resumed.incomplete == false, kind .. " resume completes catalog")
    for position = 1, 25 do
        expect(resumed.index:get(position).archive_entry_name == expected[position],
            kind .. " final index preserves spine order at " .. position)
    end
    local want = {}
    for page = 4, 20 do want[#want + 1] = page end
    want[#want + 1] = 25
    expect(#snapshots == #want, kind .. " publishes every page to 20 then every five")
    for position, page in ipairs(want) do
        expect(snapshots[position] == page, kind .. " snapshot " .. position)
    end
    if kind == "direct" then
        expect(#reads == 0, "direct-image resume reads no EOCD, directory, container or OPF")
    else
        expect(#reads == 66, "wrapper resume reads only pages four to twenty-five")
        for _, read in ipairs(reads) do
            expect(read[2] < #bytes, kind .. " resume never downloads complete source")
        end
    end

    local cases = {
        { "source version", function(value) value.source_version = "new-etag" end },
        { "generation", function(value) value.generation = "old-reader" end },
        { "cursor", function(value) value.next_cursor = 1 end },
        { "entry", function(value) value.entries[1].archive_local_offset = -1 end },
    }
    for _, case in ipairs(cases) do
        local tampered = copy(opened.continuation)
        case[2](tampered)
        local touched = 0
        local rejected, reject_reason = ArchivePages:new():inspect_remote({
            size = #bytes, read_at = function() touched = touched + 1; return nil end,
        }, "epub", "/book.epub", {
            continuation = tampered, start_page = 4,
            source_version = "size:etag1", generation = "reader-7",
        })
        expect(rejected == nil and reject_reason == "epub_continuation_invalid"
            and touched == 0, case[1] .. " fails before any range read")
    end
end

-- Exercise the bridge with an asynchronous queue and real BookIndex/part
-- validation. The range client and image extractor are the external doubles.
local Bridge = require("webdavmanga.document_bridge")
local encoded, serial, oversized_encode, continuation_encodes = {}, 0, false, 0
package.preload.json = function() return {
    encode = function(value)
        if type(value) == "table" and value.next_cursor == 4 then
            continuation_encodes = continuation_encodes + 1
        end
        if oversized_encode and type(value) == "table" and value.next_cursor == 4 then
            return string.rep("x", 8 * 1024 * 1024 + 1)
        end
        serial = serial + 1
        local bytes = '{"id":' .. serial .. '}'
        encoded[bytes] = copy(value)
        return bytes
    end,
    decode = function(bytes) return copy(encoded[bytes]) end,
} end
local JPEG = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
    0, 1, 0, 1, 1, 1, 0x11, 0, 0xFF, 0xD9)
local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes)); assert(file:close())
end
local function fixture_bridge(options)
    local state = { tasks = {}, scheduled = {}, records = {}, files = {},
        inspected = {}, extracted = 0, growth = 0, range_reads = 0, opens = 0 }
    local bytes = fixture.book("direct", 25, true,
        options and options.manifest == "legacy-alias")
    local cache = {
        key_for = function(_, identity, path, kind)
            return identity .. "|" .. path .. "|" .. tostring(kind or "")
        end,
        paths_for = function(_, key, extension, token)
            local path = os.tmpname() .. "." .. extension .. "." .. token
            state.files[#state.files + 1] = path
            if extension == "manifest" then state.manifest_part = path end
            return path .. ".final", path
        end,
        lookup_record = function(_, key)
            local record = state.records[key]
            return record and record.path, record
        end,
        clear_matching_cache = function() return true end,
        discard_part = function() return true end,
        publish = function(_, record, part)
            if state.fail_publish_key == record.key then
                return nil, "injected_publish_failure"
            end
            local path = part .. ".final"
            assert(os.rename(part, path))
            record.path = path
            state.records[record.key] = record
            state.files[#state.files + 1] = path
            return path
        end,
        remove = function(_, key)
            if state.fail_remove_key == key then return false end
            local record = state.records[key]
            if record then os.remove(record.path); state.records[key] = nil end
            return true
        end,
    }
    local pages = {
        inspect_remote = function(_, descriptor, kind, path, options)
            if state.inspect_exception then error(state.inspect_exception) end
            if state.inspect_error then return nil, state.inspect_error end
            state.inspected[#state.inspected + 1] = options
            if options and options.continuation then
                if state.background_error then return nil, state.background_error end
                local result, err = ArchivePages:new():inspect_remote({
                    size = #bytes,
                    read_at = function(offset, length)
                        return bytes:sub(offset + 1, offset + length)
                    end,
                }, kind, path, options)
                return result, err
            end
            local result, err = ArchivePages:new():inspect_remote({ size = #bytes,
                read_at = function(offset, length)
                    return bytes:sub(offset + 1, offset + length)
                end,
            }, kind, path, options)
            if result and result.continuation and state.continuation_mutator then
                state.continuation_mutator(result.continuation)
            end
            return result, err
        end,
        extract_remote = function(_, _, _, target)
            state.extracted = state.extracted + 1
            write(target, JPEG)
            return { format = "jpeg", width = 1, height = 1, size = #JPEG }
        end,
    }
    local bridge = Bridge:new{
        cache = cache, identity = "identity", archive_pages = pages,
        logger = { warn = function(...)
            state.logs = state.logs or {}
            local fields = {}
            for _, value in ipairs({...}) do fields[#fields + 1] = tostring(value) end
            state.logs[#state.logs + 1] = table.concat(fields, " ")
        end },
        client_factory = function() return {
            read_range = function(_, _, first, last)
                state.range_reads = state.range_reads + 1
                return bytes:sub(first + 1, last + 1),
                    { ["content-range"] = ("bytes %d-%d/%d"):format(first, last, #bytes) }
            end,
        } end,
        async = { run = function(work, done, async_options)
            state.async_calls = (state.async_calls or 0) + 1
            if options and options.real_background_once and state.async_calls == 3 then
                return options.real_background_once(work, done,
                    async_options or {}, state)
            end
            local task = { work = work, done = done, options = async_options or {} }
            state.tasks[#state.tasks + 1] = task
            return { cancel = function() task.canceled = true end }
        end },
        scheduler = {
            scheduleIn = function(_, _, callback)
                state.scheduled[#state.scheduled + 1] = callback
                return true
            end,
            unschedule = function(_, callback)
                for i = #state.scheduled, 1, -1 do
                    if state.scheduled[i] == callback then table.remove(state.scheduled, i) end
                end
                return true
            end,
        },
        file_size = function(path)
            local file = io.open(path, "rb")
            if not file then return 0 end
            local size = file:seek("end"); file:close(); return size
        end,
        open_reader = function(context)
            state.opens = state.opens + 1
            if options and options.reader_error then error(options.reader_error) end
            if options and options.reader_result ~= nil then return options.reader_result end
            state.context = context
            context.stream_state.on_index_growth = function(generation)
                if generation == context.stream_state.generation then
                    state.growth = state.growth + 1
                end
            end
            return true
        end,
    }
    state.entry = { name = "book.epub", path = "/book.epub",
        size = #bytes, etag = "v1", modified = "m1", connection = {} }
    state.continuation_mutator = options and options.continuation_mutator
    state.inspect_exception = options and options.inspect_exception
    state.inspect_error = options and options.inspect_error
    state.callbacks = { on_error = function(error_value) state.error = error_value end,
        on_closed = function() state.returned = (state.returned or 0) + 1 end,
        on_open_handle = function(handle) state.handle = handle end,
        on_document_fallback_prompt = function(format, reason, retry)
            state.fallbacks = (state.fallbacks or 0) + 1
            state.fallback = { format = format, reason = reason, retry = retry }
        end }
    function state:run(position, async_state)
        local task = assert(self.tasks[position])
        local ok, result = pcall(task.work)
        task.done(ok, result, ok and nil or result, async_state)
        return result
    end
    function state:fail_pending(position, reason)
        local task = assert(self.tasks[position])
        task.done(false, nil, reason, { reap_pending = true })
    end
    function state:reap(position)
        local task = assert(self.tasks[position])
        if task.options and task.options.on_reaped then task.options.on_reaped() end
    end
    function state:close()
        if self.handle then self.handle.cancel() end
        for _, path in ipairs(self.files) do os.remove(path) end
    end
    if options and options.manifest then
        local entry = state.entry
        local source = { size = #bytes, read_at = function(offset, length)
            return bytes:sub(offset + 1, offset + length)
        end }
        local book = assert(ArchivePages:new():inspect_remote(source, "epub", entry.path))
        local value = assert(book.index:to_table())
        local version = #bytes .. ":2:v1:m1"
        for _, page in ipairs(value.items) do
            page.etag, page.archive_version = entry.etag, version
            if options.manifest ~= "modern" then
                page.archive_spine_position = nil
                page.path = entry.path .. "#zip/" .. page.archive_entry_ordinal
            end
        end
        if options.manifest == "late-alias" then value.items[5] = copy(value.items[4]) end
        expect(require("webdavmanga.book_index").from_table(value) ~= nil,
            "historical scalar-valid catalog fixture")
        local key = cache:key_for("identity\0book-index", entry.path .. "\0" .. version)
        local path = os.tmpname()
        write(path, require("json").encode(value))
        state.files[#state.files + 1] = path
        state.records[key] = { key = key, kind = "manifest", path = path }
        -- Unrelated cache records must survive an invalid book catalog.
        state.records.unrelated = { key = "unrelated", kind = "page", path = "other-book" }
    end
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    return bridge, state
end

for _, catalog in ipairs({ "legacy-alias", "late-alias", "legacy-unique", "modern" }) do
    local _, state = fixture_bridge{ manifest = catalog }
    state:run(1)
    if state.tasks[2] then state:run(2) end
    if state.context and not state.context.stream_state.complete then state:run(3) end
    local context, rebuilt = state.context, #state.inspected > 0
    local unrelated = state.records.unrelated
    state:close()
    expect(context and state.fallback == nil and state.error == nil,
        catalog .. " cached catalog opens without a full-download prompt")
    expect(rebuilt == (catalog == "legacy-alias" or catalog == "late-alias"),
        "rebuild only catalogs with ambiguous logical page paths: " .. catalog)
    expect(context.chapter_index:count() == 25 and context.stream_state.complete,
        catalog .. " retains every reading page")
    local seen = {}
    for _, page in ipairs(context.chapter_index.items) do
        expect(not seen[page.path], catalog .. " publishes distinct logical pages")
        seen[page.path] = true
    end
    expect(unrelated and unrelated.path == "other-book", "unrelated book cache is preserved")
end

for _, reader_case in ipairs({
    { name = "rejects", options = { reader_result = false } },
    { name = "throws", options = { reader_error = "injected Reader failure" } },
}) do
    local _, state = fixture_bridge(reader_case.options)
    state:run(1)
    local continuation = state.manifest_part .. ".continuation"
    local unrelated = os.tmpname() .. ".unrelated"
    write(unrelated, "keep")
    state:run(2)
    expect(state.context == nil and #state.tasks == 2,
        "Reader " .. reader_case.name .. " before EPUB background start")
    expect(io.open(continuation, "rb") == nil,
        "Reader " .. reader_case.name .. " removes the task continuation part")
    local unrelated_file = io.open(unrelated, "rb")
    expect(unrelated_file ~= nil,
        "Reader " .. reader_case.name .. " cleanup preserves unrelated files")
    if unrelated_file then unrelated_file:close() end
    os.remove(unrelated)
    state:close()
end

do
    local _, state = fixture_bridge()
    local first = state:run(1)
    expect(state.inspected[1] and state.inspected[1].page_limit == 3,
        "bridge requests three EPUB pages for opening")
    expect(#state.tasks == 2, "bridge stages opening pages in a second owned worker: "
        .. tostring(#state.tasks) .. " / " .. tostring(state.error and state.error.reason)
        .. " / " .. tostring(state.error and state.error.code)
        .. " / " .. tostring(first and first.error))
    state:run(2)
    expect(state.context and state.context.chapter_index:count() == 3
        and state.extracted == 3, "Reader opens only after three staged pages publish")
    local persisted = state.manifest_part and io.open(state.manifest_part .. ".continuation", "rb")
    expect(persisted ~= nil,
        "resumable metadata is persisted in this task's part")
    if persisted then persisted:close() end
    expect(#state.tasks == 3, "background child starts after Reader opens")
    state:run(3)
    expect(state.inspected[2] and state.inspected[2].continuation
        and state.inspected[2].start_page == 4,
        "background child receives validated continuation from page four")
    expect(state.context.chapter_index:count() == 25
        and state.context.stream_state.complete == true
        and state.growth > 0, "catalog replacement notifies the existing Reader hook")
    state:close()
end

-- The production Reader must cancel progressive work through its unconditional
-- close lifecycle. on_return is navigation-only and is deliberately skipped by
-- plugin teardown and connection switching.
for _, close_reason in ipairs({ "plugin_teardown", "connection_switch", "reopen" }) do
    local _, state = fixture_bridge()
    state:run(1); state:run(2)
    local reader = setmetatable({
        context = state.context, generation = 91, request_serial = 0,
        state = { is_current = function(_, generation) return generation == 91 end,
            leave_chapter = function() return true end },
        ui = { close_shell = function() return true end,
            schedule = function(_, callback) callback(); return true end },
        shell = {}, loader = { cancel_generation = function() return true end },
        cache = { set_protected = function() return true end },
        prepared_cache_keys = {}, return_to_root = function() state.root = true end,
        return_to = state.context.source_context.on_return,
        _reset_quadrant_zoom = function() end,
    }, { __index = Reader })
    local old_index = state.context.chapter_index
    expect(reader:force_close(close_reason) == true,
        close_reason .. " uses the real Reader close path")
    expect(state.tasks[3].canceled == true and state.returned == nil,
        close_reason .. " cancels background work without navigation")
    local before = old_index:count()
    state:run(3)
    expect(old_index:count() == before,
        close_reason .. " ignores delayed background completion")
    state:close()
end

do
    local _, state = fixture_bridge()
    state:run(1); state:run(2)
    local reader = setmetatable({
        context = state.context, generation = 92, request_serial = 0,
        state = { is_current = function(_, generation) return generation == 92 end,
            leave_chapter = function() return true end },
        ui = { close_shell = function() return true end,
            schedule = function(_, callback) callback(); return true end },
        shell = {}, loader = { cancel_generation = function() return true end },
        cache = { set_protected = function() return true end },
        prepared_cache_keys = {}, return_to = state.context.source_context.on_return,
        _reset_quadrant_zoom = function() end,
    }, { __index = Reader })
    reader:force_close("back")
    reader:force_close("back")
    expect(state.tasks[3].canceled == true and state.returned == 1,
        "normal return cancels once and invokes navigation once")
    state:close()
end

do
    local _, state = fixture_bridge()
    state:run(1); state:run(2)
    local stream = assert(state.context.stream_state)
    local task_count = #state.tasks
    state:fail_pending(3, "async timeout")
    expect(stream.retry() == false and #state.tasks == task_count,
        "reap-pending timeout refuses retry before the old child exits")
    state.context.source_context.on_close()
    state:reap(3)
    expect(stream.phase == "close" and stream.retry() == false
        and #state.tasks == task_count,
        "close during reap prevents retry and ignores the late reap")
    state:close()
end

do
    local _, state = fixture_bridge()
    state.background_error = "range_timeout"
    state:run(1); state:run(2); state:run(3)
    local stream = assert(state.context.stream_state)
    expect(stream.phase == "failed" and stream.available_pages == 3
        and type(stream.retry) == "function"
        and type(stream.complete_download) == "function",
        "background failure preserves readable pages and publishes recovery actions")
    local continuation_after_failure = io.open(state.manifest_part .. ".continuation", "rb")
    expect(continuation_after_failure ~= nil,
        "retryable EPUB failure keeps its task-owned continuation")
    if continuation_after_failure then continuation_after_failure:close() end
    local task_count = #state.tasks
    expect(stream.retry() == true and stream.retry() == false
        and #state.tasks == task_count + 1 and stream.phase == "retry",
        "retry is single-flight and repeated taps cannot start another job")
    state.background_error = nil
    local retry_result = state:run(task_count + 1)
    expect(stream.phase == "complete" and stream.complete == true
        and stream.available_pages == 3,
        "successful retry completes the catalog without claiming unread pages: "
            .. tostring(stream.phase) .. "/" .. tostring(stream.complete)
            .. "/" .. tostring(stream.available_pages) .. "/" .. tostring(stream.error)
            .. "/" .. tostring(retry_result and retry_result.error))
    stream.phase, stream.complete, stream.error = "failed", false, "range_timeout"
    stream.complete_download()
    stream.complete_download()
    expect(state.fallbacks == 1
        and state.fallback and state.fallback.format == "epub",
        "complete-download recovery reuses one existing explicit prompt")
    state:close()
end

for _, pending_reason in ipairs({
    "async timeout", "subprocess status failed", "UI scheduler unavailable",
}) do
    local _, state = fixture_bridge()
    state:run(1); state:run(2)
    local stream = assert(state.context.stream_state)
    local continuation = state.manifest_part .. ".continuation"
    local task_count = #state.tasks
    state:fail_pending(3, pending_reason)
    expect(stream.phase == "failed" and stream.retry_pending == true,
        pending_reason .. " exposes failed-but-reaping state")
    expect(stream.retry() == false and stream.retry() == false
        and #state.tasks == task_count,
        pending_reason .. " refuses repeated retry taps before reap")
    state:reap(3)
    local preserved = io.open(continuation, "rb")
    expect(preserved ~= nil,
        pending_reason .. " reap preserves the continuation required by retry")
    if preserved then preserved:close() end
    expect(stream.retry_pending == false and stream.retry() == true
        and #state.tasks == task_count + 1,
        pending_reason .. " permits exactly one retry after reap")
    state:reap(3)
    local still_preserved = io.open(continuation, "rb")
    expect(still_preserved ~= nil,
        pending_reason .. " duplicate old reap cannot delete the new attempt input")
    if still_preserved then still_preserved:close() end
    state:run(task_count + 1)
    expect(stream.phase == "complete" and stream.complete == true
        and stream.error == nil,
        pending_reason .. " retry succeeds after the old child is reaped")
    state:close()
end

do
    local order, terminated, reads = {}, 0, 0
    local _, state = fixture_bridge({
        real_background_once = function(work, done, async_options)
            local original_reaped = async_options.on_reaped
            local real_options = copy(async_options)
            real_options.scheduler = { scheduleIn = function() return false end }
            real_options.poll_interval = 0
            real_options.ffiutil = {
                runInSubProcess = function() return 87, 88 end,
                writeToFD = function() return true end,
                readAllFromFD = function()
                    reads = reads + 1
                    return ""
                end,
                isSubProcessDone = function() return true end,
                getNonBlockingReadSize = function() return 0 end,
                terminateSubProcess = function() terminated = terminated + 1 end,
            }
            real_options.on_reaped = function()
                order[#order + 1] = "reaped"
                if original_reaped then original_reaped() end
            end
            return Async.run(work, function(...)
                order[#order + 1] = "done"
                return done(...)
            end, real_options)
        end,
    })
    state:run(1); state:run(2)
    local stream = assert(state.context.stream_state)
    expect(order[1] == "reaped" and order[2] == "done"
        and terminated == 1 and reads == 1,
        "real Async scheduler failure delivers synchronous reap before done")
    expect(stream.phase == "failed" and stream.error ~= nil
        and stream.retry_pending == false,
        "reap-before-done still records the background failure")
    expect(stream.retry() == true and #state.tasks == 3,
        "settled reap-before-done attempt leaves no zombie and permits retry")
    state:run(3)
    expect(stream.phase == "complete" and stream.complete == true
        and stream.error == nil,
        "retry succeeds after the real reap-before-done ordering")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local original = {}
    for key, record in pairs(state.records) do
        if record.kind == "page" then original[record.remote_path] = { key = key, path = record.path } end
    end
    local opening_index = state.context.chapter_index
    local first, second, third = original[opening_index:get(1).path],
        original[opening_index:get(2).path], original[opening_index:get(3).path]
    expect(first and second and third, "fixture has three opening cache records")
    os.remove(second.path)
    state.records[second.key] = nil
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    expect(#state.tasks == 5, "partial cache stages only its missing opening page")
    state:run(5)
    expect(state.context and state.context.chapter_index:count() == 25
        and state.extracted == 4 and state.records[first.key].path == first.path
        and state.records[third.key].path == third.path
        and state.records[second.key],
        "partial cache combines verified old pages with one newly published page")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1); state:run(2); state:run(3)
    local before = state.opens
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    expect(state.opens == before + 1 and #state.tasks == 4
        and state.extracted == 3,
        "fully verified cache opens without staging or re-extraction")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local index = state.context.chapter_index
    local keys = {}
    for position = 1, 3 do
        keys[position] = "identity|" .. index:get(position).path .. "|"
    end
    local first_path, old_second_path, third_path =
        state.records[keys[1]].path, state.records[keys[2]].path,
        state.records[keys[3]].path
    write(old_second_path, "damaged image bytes")
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    state:run(5)
    expect(state.opens == 2 and state.extracted == 4
        and state.records[keys[1]] and state.records[keys[1]].path == first_path
        and state.records[keys[3]] and state.records[keys[3]].path == third_path
        and state.records[keys[2]] and state.records[keys[2]].path ~= old_second_path,
        "same-version corrupt opening image is replaced without touching valid neighbors")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local index = state.context.chapter_index
    local keys = {}
    for position = 1, 3 do
        keys[position] = "identity|" .. index:get(position).path .. "|"
    end
    local first_path, old_second_path, third_path =
        state.records[keys[1]].path, state.records[keys[2]].path,
        state.records[keys[3]].path
    write(old_second_path, "damaged image bytes")
    state.fail_publish_key = keys[2]
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    state:run(5)
    expect(state.opens == 1 and state.extracted == 4
        and state.records[keys[1]] and state.records[keys[1]].path == first_path
        and state.records[keys[3]] and state.records[keys[3]].path == third_path
        and state.records[keys[2]] == nil,
        "failed corrupt-page replacement preserves both valid cached neighbors")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local second_key = "identity|" .. state.context.chapter_index:get(2).path .. "|"
    local record = state.records[second_key]
    local old_path = record.path
    record.modified = "unverified-source-version"
    write(old_path, "damaged image bytes")
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    if #state.tasks > 4 then state:run(5) end
    expect(state.opens == 1 and not state.fallbacks
        and state.records[second_key] == record
        and state.records[second_key].path == old_path,
        "unknown-version damaged record is not evicted or silently replaced")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local index = state.context.chapter_index
    local keys = {}
    for position = 1, 3 do
        keys[position] = "identity|" .. index:get(position).path .. "|"
    end
    local first_path, second_record, third_path =
        state.records[keys[1]].path, state.records[keys[2]],
        state.records[keys[3]].path
    write(second_record.path, "damaged image bytes")
    state.fail_remove_key = keys[2]
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4)
    expect(state.opens == 1 and #state.tasks == 4 and not state.fallbacks
        and state.records[keys[1]].path == first_path
        and state.records[keys[2]] == second_record
        and state.records[keys[3]].path == third_path,
        "failed targeted eviction stops before extraction and preserves other records")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1); state:run(2); state:run(3)
    local index = state.context.chapter_index
    local keys = {}
    for position = 1, 3 do
        keys[position] = "identity|" .. index:get(position).path .. "|"
    end
    local first_path, third_path = state.records[keys[1]].path,
        state.records[keys[3]].path
    os.remove(state.records[keys[2]].path)
    state.records[keys[2]] = nil
    state.fail_publish_key = keys[2]
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    state:run(4); state:run(5)
    expect(state.records[keys[1]] and state.records[keys[1]].path == first_path
        and state.records[keys[3]] and state.records[keys[3]].path == third_path
        and state.records[keys[2]] == nil,
        "failed partial-cache publish preserves previously valid cached pages")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1); state:run(2); state:run(3)
    local index = state.context.chapter_index
    local first_key = "identity|" .. index:get(1).path .. "|"
    local second_key = "identity|" .. index:get(2).path .. "|"
    state.records[second_key].path = state.records[first_key].path
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    local before = state.opens
    state:run(4)
    expect(state.opens == before and #state.tasks == 4,
        "two cached opening records cannot reuse one image path")
    state:close()
end

do
    local bridge, state = fixture_bridge()
    state:run(1)
    state:run(2)
    state:run(3)
    local manifest
    for _, record in pairs(state.records) do
        if record.kind == "manifest" then manifest = record end
    end
    expect(manifest ~= nil, "completed EPUB has a cached manifest")
    local file = assert(io.open(manifest.path, "rb"))
    local manifest_bytes = file:read("*a"); file:close()
    local value = copy(encoded[manifest_bytes])
    value.items[2] = copy(value.items[1])
    write(manifest.path, require("json").encode(value))
    state.handle.cancel()
    bridge:_open_archive(state.entry, nil, state.entry.path, state.callbacks)
    local before = state.opens
    state:run(4)
    expect(state.opens == before + 1 and not state.fallback and not state.error,
        "ambiguous cached catalog is reparsed before reusing valid opening images")
    expect(state.context.chapter_index:get(1).path ~= state.context.chapter_index:get(2).path,
        "rebuilt catalog never publishes the duplicate logical page")
    state:close()
end

for _, corruption in ipairs({ "corrupt", "oversized", "mismatch" }) do
    local _, state = fixture_bridge()
    state:run(1)
    state:run(2)
    local path = state.manifest_part .. ".continuation"
    if corruption == "corrupt" then write(path, "not json")
    elseif corruption == "oversized" then write(path, string.rep("x", 8 * 1024 * 1024 + 1))
    else
        local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close()
        local stale = copy(encoded[value]); stale.source_version = "older-etag"
        write(path, require("json").encode(stale))
    end
    local before = state.range_reads
    state:run(3)
    expect(state.range_reads == before and state.context.chapter_index:count() == 3
        and state.context.stream_state.complete == false,
        corruption .. " continuation fails without rereading or stale index growth")
    expect(io.open(path, "rb") == nil,
        corruption .. " continuation part is removed after failure")
    state:close()
end

do
    oversized_encode = true
    local _, state = fixture_bridge()
    state:run(1)
    oversized_encode = false
    expect(state.context == nil and #state.tasks == 1 and next(state.records) == nil,
        "oversized opening continuation fails before staging or publication")
    expect(io.open(state.manifest_part .. ".continuation", "rb") == nil,
        "oversized opening continuation leaves no task metadata part")
    state:close()
end

for _, field in ipairs({ "entries", "remote_path" }) do
    local before = continuation_encodes
    local _, state = fixture_bridge({ continuation_mutator = function(value)
        if field == "entries" then
            local long_name = string.rep("a", 4096)
            for position = 1, 2200 do
                value.entries[position] = { name = long_name }
            end
        else
            value.remote_path = string.rep("b", 8 * 1024 * 1024 + 1)
        end
    end })
    state:run(1)
    expect(continuation_encodes == before and state.context == nil
        and #state.tasks == 1 and next(state.records) == nil,
        field .. " over budget fails before invoking the JSON encoder")
    state:close()
end

do
    local _, state = fixture_bridge()
    state:run(1)
    state:run(2)
    local path = state.manifest_part .. ".continuation"
    local active = io.open(path, "rb")
    expect(active ~= nil, "active Reader owns a continuation part")
    if active then active:close() end
    state.handle.cancel()
    expect(io.open(path, "rb") == nil,
        "Reader close cancels the background job and removes its continuation")
    local before = state.range_reads
    state:run(3)
    expect(state.context.chapter_index:count() == 3 and state.range_reads == before,
        "late background completion after Reader close cannot grow the old index")
    state:close()
end

do
    local _, state = fixture_bridge{
        inspect_exception = "/private/account/archive_pages.lua:1172: https://secret@example.invalid/book.epub",
    }
    state:run(1)
    local logs = table.concat(state.logs or {}, "\n")
    expect(state.fallback and state.fallback.format == "epub",
        "EPUB parser exception still uses the explicit download prompt")
    expect(logs:find("index_exception epub archive_pages stream_failed line=1172", 1, true),
        "EPUB parser exception records only a safe source location")
    expect(not logs:find("private", 1, true)
        and not logs:find("secret", 1, true)
        and not logs:find("example.invalid", 1, true),
        "EPUB parser exception never logs source path or remote credentials")
    state:close()
end

do
    local _, state = fixture_bridge{
        inspect_exception = "/private/account/remote_stream.lua:88: https://secret@example.invalid/book.epub",
    }
    state:run(1)
    local logs = table.concat(state.logs or {}, "\n")
    expect(logs:find("index_exception epub archive_pages stream_failed", 1, true),
        "an exception outside the known modules remains distinguishable")
    expect(not logs:find("secret", 1, true)
        and not logs:find("example.invalid", 1, true),
        "unknown-module exception diagnostics never expose remote credentials")
    state:close()
end

do
    local _, state = fixture_bridge{
        inspect_error = "https://secret@example.invalid/book.epub",
    }
    state:run(1)
    local logs = table.concat(state.logs or {}, "\n")
    expect(logs:find("index_return_error epub archive_pages stream_failed", 1, true),
        "EPUB parser return errors have a distinct safe diagnostic stage")
    expect(not logs:find("secret", 1, true)
        and not logs:find("example.invalid", 1, true),
        "EPUB parser return diagnostics never expose remote credentials")
    state:close()
end

for _, reason in ipairs({
    "epub_continuation_invalid", "epub_continuation_too_large",
    "epub_continuation_write_failed",
}) do
    local _, state = fixture_bridge{ inspect_error = reason }
    state:run(1)
    local logs = table.concat(state.logs or {}, "\n")
    expect(state.fallback == nil and state.error and state.error.reason == reason,
        reason .. " reports the operational failure without suggesting a full download")
    expect(logs:find("index_return_error epub archive_pages " .. reason, 1, true),
        reason .. " stays identifiable in safe diagnostics")
    state:close()
end

do
    local _, state = fixture_bridge()
    state:fail_pending(1, "subprocess payload exceeds 8388608 bytes")
    local logs = table.concat(state.logs or {}, "\n")
    expect(logs:find("index_async_failure epub archive_pages stream_failed", 1, true),
        "EPUB child-process failure has a distinct safe diagnostic stage")
    expect(not logs:find("8388608", 1, true),
        "EPUB child-process diagnostics do not echo raw error text")
    state:close()
end

print(("rebuild_0411_epub_resume_spec: %d checks"):format(checks))
