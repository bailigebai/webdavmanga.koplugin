local BookIndex = require("webdavmanga.book_index")
local Loader = require("webdavmanga.loader")
local PreparedPages = require("webdavmanga.prepared_pages")
local Reader = require("webdavmanga.ui_reader")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local items = {}
for position = 1, 25 do
    items[position] = { name = ("%03d.jpg"):format(position),
        path = "/book/" .. position .. ".jpg" }
end
local index = BookIndex.from_items(items)

do
    local opening = BookIndex.from_items({ items[1], items[2], items[3] })
    local stream_state = { generation = "stream-a", warm_target = 20 }
    local calls = {}
    local growing_reader = setmetatable({
        context = { chapter_index = opening, stream_state = stream_state },
        reader_settings = { image_prefetch_enabled = true },
        generation = 31, current_index = 1,
        state = { is_current = function(_, generation) return generation == 31 end },
        loader = {
            prefetch_count_for = function() return 2 end,
            prefetch = function(_, _, window, _, _, limit)
                calls[#calls + 1] = { count = #window, limit = limit }
            end,
        },
    }, { __index = Reader })
    growing_reader:_bind_stream_index_growth()
    expect(type(stream_state.on_index_growth) == "function",
        "reader entry registers an index-growth notification")
    assert(opening:replace_items({ unpack(items, 1, 20) }, "stream-a"))
    stream_state.on_index_growth("stream-a")
    expect(#calls == 1 and calls[1].count == 18 and calls[1].limit == 17,
        "index growth from three to twenty automatically queues the missing warmup")
    local late = stream_state.on_index_growth
    growing_reader.closing = true
    assert(opening:replace_items({ unpack(items, 1, 25) }, "stream-a"))
    late("stream-a")
    expect(#calls == 1, "close ignores a delayed index-growth notification")
    growing_reader.closing = false
    growing_reader.generation = 32
    late("stream-a")
    expect(#calls == 1, "replacement reader generation ignores old growth notification")
end

local prefetch_calls = {}
local active = true
local reader = setmetatable({
    context = { chapter_index = index, stream_state = { warm_target = 20 } },
    reader_settings = { image_prefetch_enabled = true, prefetch_near_count = 2 },
    generation = 7, request_serial = 1,
    state = { is_current = function(_, generation) return active and generation == 7 end },
    loader = {
        identity = "book", prefetch_count_for = function() return 2 end,
        prefetch = function(_, generation, window, current, on_ready, limit)
            prefetch_calls[#prefetch_calls + 1] = {
                generation = generation, window = window, current = current,
                on_ready = on_ready, limit = limit }
        end,
    },
}, { __index = Reader })
reader:_prefetch(1)
expect(#prefetch_calls == 1 and prefetch_calls[1].limit == 19
    and #prefetch_calls[1].window == 20,
    "stream entry widens this one prefetch window through page 20")
do
    local high_limit, high_window
    local high_setting = setmetatable({
        context = { chapter_index = index, stream_state = { warm_target = 20 } },
        reader_settings = { image_prefetch_enabled = true },
        generation = 7, state = reader.state,
        loader = {
            prefetch_count_for = function() return 25 end,
            prefetch = function(_, _, window, _, _, limit)
                high_limit, high_window = limit, window
            end,
        },
    }, { __index = Reader })
    high_setting:_prefetch(1)
    expect(high_limit == 19 and #high_window == 20,
        "stream opening never adds page 21+ to its warmup window")
end
reader:_prefetch(2)
expect(#prefetch_calls == 2 and prefetch_calls[2].limit == nil
    and #prefetch_calls[2].window <= 5,
    "later reading uses the ordinary user prefetch radius")
reader.context.stream_state = nil
reader:_prefetch(1)
expect(#prefetch_calls == 3 and prefetch_calls[3].limit == nil
    and #prefetch_calls[3].window <= 3
    and prefetch_calls[3].on_ready == nil,
    "ordinary books retain the user prefetch setting")
reader.context.stream_state = { warm_target = 20 }
reader.closing = true
reader:_prefetch(1)
expect(#prefetch_calls == 3, "closing reader queues no new warmup")
reader.closing = false
active = false
reader:_prefetch(1)
expect(#prefetch_calls == 3, "replaced generation queues no stale warmup")

do
    local passed_limit, on_profile_ready, on_processed, protected = nil, nil, nil, 0
    local processing_reader = setmetatable({
        context = { chapter_index = index, stream_state = { warm_target = 20 } },
        reader_settings = { image_prefetch_enabled = true },
        generation = 9, current_index = 1, prepared_cache_keys = {},
        state = { is_current = function(_, generation) return generation == 9 end },
        loader = { prefetch_count_for = function() return 2 end },
        prepared_pages = {
            prefetch = function(_, _, _, _, _, profile_ready, processed, limit)
                on_profile_ready, on_processed, passed_limit = profile_ready, processed, limit
            end,
            cache_key = function() return "prepared" end,
        },
        _processing_enabled = function() return true end,
        _processing_profile = function() return { key = "profile" } end,
        _protect = function() protected = protected + 1 end,
    }, { __index = Reader })
    processing_reader:_prefetch(1)
    expect(passed_limit == 19, "processed stream warmup passes the transient limit through")
    processing_reader.generation = 10
    on_profile_ready(items[4], {})
    on_processed(items[4], "path", false, { prepared = true })
    expect(protected == 0 and processing_reader.prepared_cache_keys[items[4].path] == nil,
        "late processed callbacks cannot mutate replacement reader state")
end

local tasks = {}
local opening_cached = false
local loader = Loader:new{
    cache = {
        key_for = function(_, _, path) return path end,
        lookup = function(_, key)
            if opening_cached and (key == items[2].path or key == items[3].path) then
                return key .. ".cached"
            end
            return nil
        end,
        paths_for = function(_, key) return key .. ".final", key .. ".part" end,
        limit_bytes = 1000000,
    },
    client_factory = function() return { direct = false } end,
    async = { run = function(work, done)
        tasks[#tasks + 1] = { work = work, done = done }
        return { cancel = function() end }
    end },
    identity = "book", source_kind_provider = function() return "remote" end,
    prefetch_count = 2, prefetch_concurrency = 2,
}
loader:prefetch(1, index:window(1, 24), 1)
expect(#loader.prefetch_queue + loader.prefetch_active_count == 2
    and loader.prefetch_concurrency == 2,
    "default Loader prefetch remains capped by user count and concurrency")
loader:cancel_generation(1)
opening_cached = true
loader:prefetch(2, index:window(1, 24), 1, nil, 19, true)
expect(#loader.prefetch_queue + loader.prefetch_active_count == 17
    and loader.prefetch_concurrency == 2,
    "with three opening pages cached, warmup queues pages 4 through 20: "
        .. tostring(#loader.prefetch_queue + loader.prefetch_active_count))
expect(loader.jobs_by_key[items[4].path] ~= nil
    and loader.jobs_by_key[items[20].path] ~= nil
    and loader.jobs_by_key[items[21].path] == nil,
    "page 21 and later never enter the high-priority opening warmup")
loader:prefetch(2, index:window(2, 2), 2)
expect(loader.jobs_by_key[items[4].path] ~= nil
    and loader.jobs_by_key[items[20].path] ~= nil,
    "ordinary page-two prefetch preserves unfinished opening warmup jobs")
loader:request(2, items[21], {})
expect(loader.active and loader.active.image.path == items[21].path
    and loader.active.kind == "page" and loader.prefetch_active_count <= 2,
    "foreground page request takes the primary slot ahead of warmup")
loader:cancel_generation(2)
expect(#loader.prefetch_queue == 0 and loader.prefetch_active_count == 0,
    "closed generation cancels outstanding warmup jobs")

do
    local pending = {}
    local cache = {
        key_for = function(_, _, path) return path end,
        lookup = function() return nil end,
        paths_for = function(_, key) return key .. ".final", key .. ".part" end,
        limit_bytes = 1000000,
    }
    local raw = Loader:new{
        cache = cache, identity = "bounded", prefetch_count = 2,
        prefetch_concurrency = 1,
        source_kind_provider = function() return "remote" end,
        client_factory = function() return { direct = false } end,
        async = { run = function(work, done)
            pending[#pending + 1] = { work = work, done = done }
            return { cancel = function() end }
        end },
    }
    local prepared = PreparedPages:new{
        loader = raw, cache = cache,
        async = { run = function() return { cancel = function() end } end },
    }
    local opening = BookIndex.from_items({ items[1], items[2], items[3] })
    local stream = { generation = "bounded-stream", warm_target = 20 }
    local bounded = setmetatable({
        context = { chapter_index = opening, stream_state = stream },
        reader_settings = { image_prefetch_enabled = true,
            gray_enhance_enabled = true },
        generation = 73, current_index = 1, prepared_cache_keys = {},
        state = { is_current = function(_, generation) return generation == 73 end },
        loader = raw, prepared_pages = prepared,
        _processing_enabled = function() return true end,
        _processing_profile = function() return { id = "gray" } end,
        _protect = function() return true end,
        _note_preprocess_success = function() return true end,
    }, { __index = Reader })
    bounded:_bind_stream_index_growth()
    for count = 4, 20 do
        assert(opening:replace_items({ unpack(items, 1, count) }, "bounded-stream"))
        for _ = 1, 6 do stream.on_index_growth("bounded-stream") end
    end
    local page4 = assert(raw.jobs_by_key[items[4].path])
    expect(#page4.waiters == 1,
        "real Loader/PreparedPages keeps one opening-warmup waiter per page")
    expect(raw.jobs_by_key[items[20].path] ~= nil
        and raw.jobs_by_key[items[21].path] == nil,
        "growth queues only newly available pages through twenty")
end

-- Exercise the production Reader -> Loader -> PreparedPages success boundary.
-- The state double only owns the contiguous-prefix rule; removing either Reader
-- success callback makes these assertions fail.
do
    local jpeg = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
    local files, records, raw_tasks, prepared_tasks = {}, {}, {}, {}
    local function write(path, bytes)
        local file = assert(io.open(path, "wb"))
        assert(file:write(bytes)); assert(file:close())
    end
    local cache = {
        key_for = function(_, _, path) return path end,
        lookup = function(_, key)
            local record = records[key]
            return record and record.path, record
        end,
        paths_for = function(_, key, extension, token)
            local path = os.tmpname() .. "." .. tostring(extension) .. "." .. tostring(token)
            files[#files + 1] = path
            return path .. ".final", path
        end,
        publish = function(_, record, path)
            local final = path .. ".final"
            assert(os.rename(path, final))
            record.path = final; records[record.key] = record; files[#files + 1] = final
            return final
        end,
        discard_part = function() return true end,
        limit_bytes = 1000000,
    }
    local raw = Loader:new{
        cache = cache, identity = "readable", prefetch_count = 2,
        prefetch_concurrency = 2, source_kind_provider = function() return "remote" end,
        client_factory = function() return {
            direct = false,
            download = function(_, _, target)
                write(target, jpeg)
                return { format = "jpeg", width = 1, height = 1, size = #jpeg }
            end,
        } end,
        async = { run = function(work, done, options)
            raw_tasks[#raw_tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end },
    }
    local prepared = PreparedPages:new{
        loader = raw, cache = cache,
        page_processor = { process = function(_, target)
            write(target, jpeg)
            return { format = "png", width = 1, height = 1, size = #jpeg }
        end },
        async = { run = function(work, done, options)
            prepared_tasks[#prepared_tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end },
    }
    local readable = { [1] = true, [2] = true, [3] = true }
    local stream = { generation = "readable-stream", warm_target = 20,
        available_pages = 3, phase = "complete", complete = true }
    stream.mark_ready = function(position, generation)
        if generation ~= stream.generation then return false end
        readable[position] = true
        while readable[stream.available_pages + 1] do
            stream.available_pages = stream.available_pages + 1
        end
        return true
    end
    local opening = BookIndex.from_items(items)
    local live_generation = 73
    local integrated = setmetatable({
        context = { chapter_index = opening, stream_state = stream },
        reader_settings = { image_prefetch_enabled = true, gray_enhance_enabled = true },
        generation = live_generation, current_index = 1, prepared_cache_keys = {},
        state = { is_current = function(_, generation)
            return generation == live_generation
        end },
        loader = raw, prepared_pages = prepared,
        _processing_enabled = function() return true end,
        _processing_profile = function() return { id = "gray" } end,
        _protect = function() return true end,
        _note_preprocess_success = function() return true end,
    }, { __index = Reader })
    local function finish(task, ok, err)
        if ok == false then return task.done(false, nil, err or "network failed") end
        local worked, result = pcall(task.work)
        return task.done(worked, result, worked and nil or result)
    end
    integrated:_prefetch(1, { first = 4, last = 5 })
    expect(#raw_tasks == 2, "real Loader starts page four and five warmup")
    finish(raw_tasks[2]); finish(prepared_tasks[1])
    expect(stream.available_pages == 3,
        "PreparedPages page five success cannot cross the page-four gap")
    finish(raw_tasks[1]); finish(prepared_tasks[2])
    expect(stream.available_pages == 5,
        "real Loader and PreparedPages success advances the contiguous prefix")

    integrated:_prefetch(1, { first = 6, last = 6 })
    finish(raw_tasks[3], false, "network failed")
    expect(stream.available_pages == 5,
        "failed Loader preparation never advances readable pages")
    integrated:_prefetch(1, { first = 6, last = 6 })
    finish(raw_tasks[4]); finish(prepared_tasks[3], false, "processing failed")
    expect(stream.available_pages == 5,
        "failed PreparedPages processing never advances readable pages")
    integrated:_prefetch(1, { first = 6, last = 6 })
    live_generation, integrated.generation = 74, 74
    finish(prepared_tasks[4])
    expect(stream.available_pages == 5,
        "replacement Reader generation ignores late prepared success")
    for _, path in ipairs(files) do os.remove(path) end
end

-- Foreground page delivery must use the same processed-image readiness rule
-- as warmup. Real Loader and PreparedPages are kept; only network/process
-- execution is queued so each boundary can be observed deterministically.
do
    local jpeg = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
    local files, records, raw_tasks, prepared_tasks = {}, {}, {}, {}
    local process_error, fail_publish
    local function write(path, bytes)
        local file = assert(io.open(path, "wb"))
        assert(file:write(bytes)); assert(file:close())
    end
    local cache = {
        key_for = function(_, _, path) return path end,
        lookup = function(_, key)
            local record = records[key]
            return record and record.path, record
        end,
        paths_for = function(_, key, extension, token)
            local path = os.tmpname() .. "." .. tostring(extension) .. "." .. tostring(token)
            files[#files + 1] = path
            return path .. ".final", path
        end,
        publish = function(_, record, path)
            if fail_publish then return nil, "injected_publish_failure" end
            local final = path .. ".final"
            assert(os.rename(path, final))
            record.path = final; records[record.key] = record; files[#files + 1] = final
            return final
        end,
        discard_part = function() return true end,
        limit_bytes = 1000000,
    }
    local raw = Loader:new{
        cache = cache, identity = "foreground-readable", prefetch_count = 2,
        prefetch_concurrency = 1, source_kind_provider = function() return "remote" end,
        client_factory = function() return {
            direct = false,
            download = function(_, _, target)
                write(target, jpeg)
                return { format = "jpeg", width = 1, height = 1, size = #jpeg }
            end,
        } end,
        async = { run = function(work, done, options)
            raw_tasks[#raw_tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end },
    }
    local prepared = PreparedPages:new{
        loader = raw, cache = cache,
        page_processor = { process = function(_, target)
            if process_error then return nil, process_error end
            write(target, jpeg)
            return { format = "png", width = 1, height = 1, size = #jpeg }
        end },
        async = { run = function(work, done, options)
            prepared_tasks[#prepared_tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end },
    }
    local readable = { [1] = true, [2] = true, [3] = true }
    local stream = { generation = "foreground-stream", warm_target = 20,
        available_pages = 3, phase = "complete", complete = true }
    stream.mark_ready = function(position, generation)
        if generation ~= stream.generation then return false end
        readable[position] = true
        while readable[stream.available_pages + 1] do
            stream.available_pages = stream.available_pages + 1
        end
        return true
    end
    local live_generation = 73
    local displayed = {}
    local foreground = setmetatable({
        context = { chapter_index = BookIndex.from_items(items), stream_state = stream },
        reader_settings = { image_prefetch_enabled = true, gray_enhance_enabled = true },
        generation = live_generation, request_serial = 0, current_index = 3,
        position = { index = 3, segment = "whole" }, page_buffer = {}, shell = {},
        pending_request = nil, state = { is_current = function(_, generation)
            return generation == live_generation
        end },
        loader = raw, prepared_pages = prepared,
        _processing_enabled = function() return true end,
        _processing_profile = function() return { id = "gray" } end,
        _reset_quadrant_zoom = function() return true end,
        _render_ready = function(_, path, position, _segment, _serial, _generation, metadata)
            displayed[#displayed + 1] = { path = path, position = position, metadata = metadata }
            return true
        end,
    }, { __index = Reader })
    local function finish(task)
        local worked, result = pcall(task.work)
        return task.done(worked, result, worked and nil or result)
    end

    foreground:request_page(4)
    finish(raw_tasks[1])
    process_error = "processing_failed"
    finish(prepared_tasks[1])
    process_error = nil
    expect(#displayed == 1 and displayed[1].metadata.processing_error
        and stream.available_pages == 3,
        "foreground processing fallback displays raw image without advancing readable pages")
    foreground:request_page(4)
    finish(prepared_tasks[2])
    expect(stream.available_pages == 4,
        "successful foreground retry advances the processed readable prefix")

    foreground:request_page(5)
    finish(raw_tasks[2])
    fail_publish = true
    finish(prepared_tasks[3])
    fail_publish = false
    expect(displayed[#displayed].metadata.processing_error
        and stream.available_pages == 4,
        "foreground prepared publish failure displays fallback without advancing")
    foreground:request_page(5)
    finish(prepared_tasks[4])
    expect(stream.available_pages == 5,
        "foreground retry after publish failure can advance")

    foreground:request_page(6)
    finish(raw_tasks[3])
    prepared:cancel_generation(live_generation)
    local displayed_before_cancel = #displayed
    finish(prepared_tasks[5])
    expect(#displayed == displayed_before_cancel and stream.available_pages == 5,
        "canceled foreground processing cannot display or advance")

    foreground.pending_request = nil
    live_generation, foreground.generation = 74, 74
    foreground:request_page(6)
    live_generation, foreground.generation = 75, 75
    finish(prepared_tasks[6])
    expect(stream.available_pages == 5,
        "stale foreground processed completion cannot advance")
    foreground.pending_request = nil
    foreground:request_page(6)
    expect(stream.available_pages == 6,
        "current generation may reuse the valid prepared page and advance")

    foreground.context.stream_state = nil
    foreground:request_page(7)
    finish(raw_tasks[4])
    process_error = "ordinary_processing_failed"
    finish(prepared_tasks[7])
    process_error = nil
    expect(displayed[#displayed].position == 7
        and displayed[#displayed].metadata.processing_error,
        "ordinary non-stream foreground keeps displaying processing fallback")
    for _, path in ipairs(files) do os.remove(path) end
end

print(("rebuild_0411_warmup_spec: %d checks"):format(checks))
