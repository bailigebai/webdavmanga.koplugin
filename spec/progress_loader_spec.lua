local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local progress_values = {}
local progress_flushes = 0
local progress_store = {
    readSetting = function(_self, key, default)
        if progress_values[key] == nil then return default end
        return progress_values[key]
    end,
    saveSetting = function(_self, key, value) progress_values[key] = value end,
    flush = function() progress_flushes = progress_flushes + 1 end,
}

local Progress = require("webdavmanga.progress")
local progress = Progress:new{ store = progress_store, md5 = function(value) return "hash:" .. value end }
local chapter_id = progress:chapter_id(
    { server_url = "https://nas/dav", username = " reader ", root_path = "/漫画" },
    { path = "/漫画/A" }, { path = "/漫画/A/第1话" })
expect(chapter_id == "hash:https://nas/dav\0reader\0/漫画\0/漫画/A\0/漫画/A/第1话",
    "chapter identity should include server, username, root, manga, and chapter")

progress:save(chapter_id, "/漫画/A/第1话/010.jpg", 10)
local moved_images = {}
for index = 1, 12 do
    moved_images[index] = { path = "/漫画/A/第1话/" .. string.format("%03d.jpg", index - 1) }
end
expect(progress:resolve(chapter_id, moved_images) == 11,
    "exact image path should win after files are inserted")
expect(progress_flushes == 1, "progress save should flush")

progress:save("fallback", "/missing.jpg", 99)
expect(progress:resolve("fallback", moved_images) == 12, "numeric fallback should clamp high")
progress:save("low", "/missing.jpg", -3)
expect(progress:resolve("low", moved_images) == 1, "numeric fallback should clamp low")
expect(progress:resolve("new", moved_images) == 1, "new chapter should start at first page")
expect(progress:resolve("empty", {}) == nil, "empty chapter should not resolve")

local function chapter_index(images)
    return {
        count = function() return #images end,
        find = function(_self, path, hint)
            if images[hint] and images[hint].path == path then return hint end
            for index, image in ipairs(images) do
                if image.path == path then return index end
            end
            return nil
        end,
    }
end

local indexed_images = chapter_index(moved_images)
progress.records.legacy_segment = {
    image_path = moved_images[6].path,
    index = 2,
}
local resolved = progress:resolve("legacy_segment", indexed_images,
    { whole = true })
expect(resolved.index == 6 and resolved.segment == "whole",
    "legacy progress without a segment should resolve by ChapterIndex path as whole")

progress:save("split_segment", moved_images[8].path, 8, "right")
resolved = progress:resolve("split_segment", indexed_images,
    { right = true, left = true })
expect(resolved.index == 8 and resolved.segment == "right",
    "a saved split segment should survive when the current page supports it")
resolved = progress:resolve("split_segment", indexed_images, { whole = true })
expect(resolved.index == 8 and resolved.segment == "whole",
    "an invalid saved split segment should collapse without changing physical index")
resolved = progress:resolve("split_segment", indexed_images)
expect(resolved.index == 8 and resolved.segment == "whole",
    "missing valid segment metadata should fall back safely to whole")

progress:save("invalid_segment", moved_images[3].path, 3, "center")
expect(progress.records.invalid_segment.segment == "whole",
    "unknown segments should be normalized before they are persisted")
resolved = progress:resolve("missing_path", indexed_images,
    { whole = true })
expect(resolved.index == 1 and resolved.segment == "whole",
    "a new indexed chapter should start at a whole first page")
expect(progress:resolve("empty_index", chapter_index({}), { whole = true }) == nil,
    "an empty ChapterIndex should not resolve a position")

local history_connection = {
    server_url = "https://nas/dav", username = " reader ",
    password = "must-not-be-stored", root_path = "/漫画",
}
local history_manga = { name = "漫画 A", path = "/漫画/A" }
local history_chapters = {
    { name = "第1话", path = "/漫画/A/第1话", is_folder = true,
      password = "must-not-be-stored" },
    { name = "第2话", path = "/漫画/A/第2话" },
}
progress.clock = function() return 1700000000 end
progress:save(chapter_id, "/漫画/A/第2话/008.jpg", 8, {
    connection = history_connection,
    manga = history_manga,
    chapter = history_chapters[2],
    chapters = history_chapters,
    total = 20,
    layout = "chapters",
    cover_hint = {
        chapter = history_chapters[1],
        password = "must-not-be-stored",
    },
})
local history = progress:list_history(history_connection)
expect(#history == 1 and history[1].manga.name == "漫画 A"
    and history[1].chapter.name == "第2话",
    "a rendered manga page should create one resumable history record")
expect(history[1].index == 8 and history[1].total == 20
    and history[1].updated_at == 1700000000,
    "history should retain page progress and last-read time")
expect(history[1].connection.password == nil and history[1].connection.username == "reader",
    "history must exclude passwords and normalize the account identity")
local stored_history
for _, record in pairs(progress_values.history) do
    if record.manga and record.manga.path == history_manga.path then stored_history = record end
end
expect(stored_history and stored_history.chapters == nil,
    "new history records must not duplicate the full sibling chapter table")
expect(progress.records[chapter_id].segment == "whole" and history[1].segment == "whole",
    "the legacy save call shape should persist an explicit whole segment")
expect(history[1].layout == "chapters",
    "history should retain the recognized manga layout")
expect(history[1].cover_hint.chapter.path == history_chapters[1].path
    and history[1].cover_hint.chapter.is_folder,
    "history should retain the sanitized cover chapter")
expect(history[1].cover_hint.password == nil
    and history[1].cover_hint.chapter.password == nil,
    "history cover hints must exclude credentials")

progress.clock = function() return 1700000010 end
progress:save(chapter_id, "/漫画/A/第2话/009.jpg", 9, "right", {
    connection = history_connection,
    manga = history_manga,
    chapter = history_chapters[2],
    chapters = history_chapters,
    total = 20,
})
history = progress:list_history(history_connection)
expect(#history == 1 and history[1].index == 9 and history[1].updated_at == 1700000010,
    "reading the same manga should update rather than duplicate its history")
expect(history[1].segment == "right",
    "the new save call shape should retain split segment history")
progress:save(chapter_id, "/漫画/A/第2话/009.jpg", 9, "left", {
    connection = history_connection,
    manga = history_manga,
    chapter = history_chapters[2],
    total = 20,
})
history = progress:list_history(history_connection)
expect(history[1].segment == "left",
    "history should preserve either recognized split segment")

local newer_manga = { name = "漫画 B", path = "/漫画/B" }
local newer_chapter = { name = "第1话", path = "/漫画/B/第1话" }
progress.clock = function() return 1700000020 end
progress:save("chapter-b", newer_chapter.path .. "/001.jpg", 1, {
    connection = history_connection,
    manga = newer_manga,
    chapter = newer_chapter,
    chapters = { newer_chapter },
    total = 10,
})
history = progress:list_history(history_connection)
expect(#history == 2 and history[1].manga.name == "漫画 B"
    and history[2].manga.name == "漫画 A",
    "history should sort the most recently read manga first")
expect(history[1].layout == nil and history[1].cover_hint == nil,
    "legacy history records without cover fields should remain readable")

local other_history = progress:list_history{
    server_url = "https://nas/dav", username = "someone-else", root_path = "/漫画",
}
expect(#other_history == 0, "history should be isolated by WebDAV account")
expect(progress:remove_history(history_connection, history_manga.path),
    "one manga history record should be removable")
expect(#progress:list_history(history_connection) == 1,
    "removed history should no longer be listed while unrelated history remains")
expect(progress:remove_history(history_connection, newer_manga.path)
    and #progress:list_history(history_connection) == 0,
    "the remaining manga history should be independently removable")

local State = require("webdavmanga.state")
local state = State:new()
local generation1 = state:begin_chapter{ chapter = "one" }
expect(generation1 == 1 and state:is_current(generation1), "first chapter generation")
local generation2 = state:begin_chapter{ chapter = "two" }
expect(generation2 == 2 and not state:is_current(generation1)
    and state:is_current(generation2), "new chapter should invalidate old generation")
state:leave_chapter()
expect(not state:is_current(generation2) and state.current == nil,
    "leaving chapter should invalidate active generation")

local scheduled = {}
local scheduler = {
    scheduleIn = function(_self, _delay, callback)
        scheduled[#scheduled + 1] = callback
    end,
}
local Async = require("webdavmanga.async")
local async_result
local fallback_work_ran = false
local async_handle = Async.run(function() fallback_work_ran = true end,
    function(ok, _result, err) async_result = ok and "unexpected" or err end,
    { scheduler = scheduler, ffiutil = false })
expect(#scheduled == 1 and async_result == nil, "fallback should schedule instead of run inline")
scheduled[1]()
expect(not fallback_work_ran and async_result == "background subprocess unavailable",
    "missing subprocess support should fail recoverably instead of blocking the UI thread")

local canceled_called = false
local fallback_cancel_cleaned = false
local canceled_handle = Async.run(function() return "late" end,
    function() canceled_called = true end,
    { scheduler = scheduler, ffiutil = false,
        on_cancelled = function() fallback_cancel_cleaned = true end })
canceled_handle:cancel()
scheduled[2]()
expect(not canceled_called, "cancel should suppress delayed fallback callback")
expect(fallback_cancel_cleaned, "cancel should notify fallback cleanup exactly once")
expect(async_handle.cancel ~= nil, "async handle should always be cancellable")

local reap_scheduled = {}
local reap_checks = 0
local terminate_count = 0
local terminated = false
local subprocess_pipe_reads = 0
local subprocess_cancel_cleaned = false
local subprocess_async = Async.run(function() return "never delivered" end, function() end, {
    scheduler = {
        scheduleIn = function(_self, _delay, callback)
            reap_scheduled[#reap_scheduled + 1] = callback
        end,
    },
    ffiutil = {
        runInSubProcess = function() return 99, 88 end,
        writeToFD = function() end,
        readAllFromFD = function()
            subprocess_pipe_reads = subprocess_pipe_reads + 1
            expect(terminated and reap_checks >= 2,
                "loader cancellation must not read before subprocess completion")
            return ""
        end,
        getNonBlockingReadSize = function() return 0 end,
        isSubProcessDone = function()
            reap_checks = reap_checks + 1
            return terminated and reap_checks >= 2
        end,
        terminateSubProcess = function()
            terminate_count = terminate_count + 1
            terminated = true
        end,
    },
    on_cancelled = function() subprocess_cancel_cleaned = true end,
})
subprocess_async:cancel()
expect(subprocess_pipe_reads == 0,
    "loader cancellation callback should return before reading the pipe")
local reap_index = 1
while reap_index <= #reap_scheduled do
    local callback = reap_scheduled[reap_index]
    reap_index = reap_index + 1
    callback()
end
expect(terminate_count == 1 and reap_checks >= 2,
    "canceling a subprocess should keep polling until the killed child is reaped")
expect(subprocess_pipe_reads == 1,
    "loader cancellation should drain the pipe exactly once after reap")
expect(subprocess_cancel_cleaned,
    "subprocess cleanup should run only after the killed child is reaped")

local files = {}
local cache_metadata = {}
local published = {}
local published_records = {}
local published_kinds = {}
local evict_count = 0
local last_evict_required
local last_evict_protected
local evict_result = 100
local publish_failure
local discarded_parts = {}
local cache = {
    limit_bytes = 200,
    protected_keys = { protected = true },
    key_for = function(_self, identity, path) return identity .. "|" .. path end,
    lookup = function(_self, key) return files[key], cache_metadata[key] end,
    paths_for = function(_self, key, extension)
        return "/cache/" .. key:gsub("[^%w]", "_") .. "." .. extension,
            "/cache/" .. key:gsub("[^%w]", "_") .. "." .. extension .. ".part"
    end,
    publish = function(_self, record, part_path)
        if publish_failure then return nil, publish_failure end
        local final = part_path:gsub("%.part$", "")
        files[record.key] = final
        cache_metadata[record.key] = {
            size = record.size,
            etag = record.etag,
            modified = record.modified,
            format = record.format,
            width = record.width,
            height = record.height,
        }
        published[#published + 1] = record.remote_path
        published_records[#published_records + 1] = record
        published_kinds[record.remote_path] = record.kind
        return final
    end,
    remove = function(_self, key)
        files[key] = nil
        cache_metadata[key] = nil
        return true
    end,
    discard_part = function(_self, key, extension, token)
        discarded_parts[#discarded_parts + 1] = { key = key, extension = extension, token = token }
        return true
    end,
    total_size = function() return 200 end,
    evict = function(_self, required, protected_keys)
        evict_count = evict_count + 1
        last_evict_required = required
        last_evict_protected = protected_keys
        return evict_result
    end,
}

local async_tasks = {}
local fake_async = {
    run = function(work, done, options)
        local task = { work = work, done = done, canceled = false }
        async_tasks[#async_tasks + 1] = task
        return { cancel = function()
            task.canceled = true
            for index, queued in ipairs(async_tasks) do
                if queued == task then table.remove(async_tasks, index); break end
            end
            if options and options.on_cancelled then options.on_cancelled() end
        end }
    end,
}

local download_order = {}
local page8_attempts = 0
local client = {
    download = function(_self, path)
        download_order[#download_order + 1] = path
        if path == "/8.jpg" then
            page8_attempts = page8_attempts + 1
            if page8_attempts == 1 then
                return nil, { code = "storage" }
            end
        end
        return {
            size = 10, etag = '"ok"', format = "jpeg", width = 8, height = 12,
        }
    end,
}

local function run_next_async()
    local task = table.remove(async_tasks, 1)
    expect(task ~= nil, "an async task should be queued")
    local ok, result = pcall(task.work)
    task.done(ok, ok and result or nil, ok and nil or result)
end

local images = {}
for index = 1, 12 do
    images[index] = { name = index .. ".jpg", path = "/" .. index .. ".jpg" }
end

local Loader = require("webdavmanga.loader")
local loader = Loader:new{
    client_factory = function() return client end,
    cache = cache,
    async = fake_async,
    identity = "server",
    prefetch_count = 3,
}

files["server|/2.jpg"] = "/cache/2.jpg"
cache_metadata["server|/2.jpg"] = {
    size = 10, format = "jpeg", width = 8, height = 12,
}
local hit_path, hit_was_cached, hit_metadata
loader:request(7, images[2], {
    on_ready = function(path, was_cached, metadata)
        hit_path, hit_was_cached, hit_metadata = path, was_cached, metadata
    end,
})
expect(hit_path == "/cache/2.jpg" and hit_was_cached == true
    and hit_metadata.format == "jpeg" and hit_metadata.width == 8,
    "cache hit should return immediately with validation metadata")
expect(#async_tasks == 0, "cache hit should not queue download")

loader:prefetch(7, images, 4)
expect(#async_tasks == 1, "only one prefetch should run at once")
local page9_ready, page9_metadata
loader:request(7, images[9], {
    on_ready = function(path, _was_cached, metadata)
        page9_ready, page9_metadata = path, metadata
    end,
})
expect(#async_tasks == 1, "current request should interrupt active prefetch without running concurrently")
expect(#discarded_parts == 1 and discarded_parts[1].token ~= nil,
    "interrupted transfer should discard its unique part file after cancellation")
run_next_async()
expect(download_order[1] == "/9.jpg", "current page should replace the active prefetch immediately")
expect(page9_ready and page9_ready:find("9_jpg")
    and page9_metadata.format == "jpeg" and page9_metadata.width == 8
    and published_records[#published_records].format == "jpeg"
    and published_records[#published_records].height == 12,
    "publication and callback should retain verified image metadata")
expect(published_kinds["/9.jpg"] == "page",
    "a current-page publication should use the page cache kind")

loader:prefetch(7, images, 9)
expect(#loader.prefetch_queue == 3 and loader.prefetch_queue[1].image == images[10]
    and loader.prefetch_queue[3].image == images[12],
    "jumping should discard unstarted prefetch pages from the old location")
while #async_tasks > 0 do run_next_async() end
expect(download_order[2] == "/6.jpg" and download_order[3] == "/10.jpg"
    and download_order[4] == "/11.jpg" and download_order[5] == "/12.jpg",
    "already-active prefetch may finish, then new adjacent pages should win")
expect(published_kinds["/10.jpg"] == "page",
    "a prefetch publication should use the page cache kind")

local stale_ready = false
loader:request(8, images[1], { on_ready = function() stale_ready = true end })
loader:cancel_generation(8)
local reopened_ready = false
loader:request(9, images[1], { on_ready = function() reopened_ready = true end })
run_next_async()
expect(not stale_ready, "canceled generation should suppress UI callback")
expect(published[#published] == "/1.jpg", "reopened chapter should download the canceled page afresh")
expect(reopened_ready, "reopened chapter should complete after prior generation cancellation")

local page8_ready
local page8_job = loader:request(9, images[8], {
    on_ready = function(path) page8_ready = path end,
})
local page8_first_token = page8_job.part_token
run_next_async()
expect(evict_count == 1 and #async_tasks == 1,
    "storage failure should force eviction and queue exactly one retry")
expect(page8_job.part_token ~= page8_first_token
    and discarded_parts[#discarded_parts].token == page8_first_token,
    "storage retry should use a new transfer token and clean the failed transfer part")
expect(last_evict_required < cache.limit_bytes,
    "storage retry should free a bounded reserve instead of wiping the entire cache")
expect(last_evict_protected == cache.protected_keys,
    "storage retry must preserve the displayed and adjacent page set")
run_next_async()
expect(page8_attempts == 2 and page8_ready ~= nil, "storage retry should succeed once")

local decode_retry_ready = false
local decode_ready_count = 0
loader:request(10, images[4], { on_ready = function()
    decode_ready_count = decode_ready_count + 1
    if decode_ready_count == 1 then
        cache:remove("server|/4.jpg")
        loader:request(10, images[4], {
            on_ready = function() decode_retry_ready = true end,
        })
    end
end })
run_next_async()
expect(#async_tasks == 1,
    "an on_ready decode rejection should be able to enqueue a fresh download")
run_next_async()
expect(decode_retry_ready, "fresh download requested by on_ready should complete")

loader:request(11, images[3], { on_ready = function() error("UI callback exploded") end })
loader:prefetch(11, images, 6)
run_next_async()
expect(#async_tasks == 1,
    "a failing delivery callback must not stall the remaining loader queue")
run_next_async()

for index = 13, 15 do
    images[index] = { name = index .. ".jpg", path = "/" .. index .. ".jpg" }
end
loader:prefetch(12, images, 12)
loader:request(12, images[14], {})
loader:request(12, images[15], {})
expect(#loader.current_queue == 0 and loader.active and loader.active.image == images[15],
    "the newest rapid jump should promote and start a page already queued for prefetch")
run_next_async()
expect(download_order[#download_order] == "/15.jpg",
    "rapid current-page requests should interrupt older current and prefetch transfers")

images[16] = { name = "16.jpg", path = "/16.jpg" }
loader:request(12, images[16], {})
local active_before_stop = async_tasks[1]
expect(active_before_stop ~= nil, "stop cancellation test needs one active download")
loader:cancel_all()
expect(active_before_stop.canceled == true,
    "cancel_all should terminate the active async download handle")
table.remove(async_tasks, 1)

images[17] = { name = "17.jpg", path = "/17.jpg" }
local original_download = client.download
client.download = function(_self, path)
    if path == "/17.jpg" then return nil, { code = "storage" } end
    return original_download(_self, path)
end
evict_result = 0
local protected_error
loader:request(13, images[17], {
    on_error = function(err) protected_error = err end,
})
run_next_async()
expect(protected_error and protected_error.code == "storage" and #async_tasks == 0,
    "storage recovery should fail cleanly when protected pages prevent reserve eviction")

images[18] = { name = "18.jpg", path = "/18.jpg", size = cache.limit_bytes + 1 }
local oversize_error
loader:request(14, images[18], {
    on_error = function(err) oversize_error = err end,
})
expect(oversize_error and oversize_error.code == "storage" and #async_tasks == 0,
    "a page known to exceed the cache limit should fail before downloading a part file")
images[19] = { name = "19.jpg", path = "/19.jpg", size = cache.limit_bytes + 1 }
loader:prefetch(15, images, 18)
expect(#async_tasks == 0 and #loader.prefetch_queue == 0,
    "prefetch should silently skip pages already known to exceed the cache limit")

images[20] = { name = "20.jpg", path = "/20.jpg" }
publish_failure = "cache_limit"
local evictions_before_unknown_oversize = evict_count
local unknown_oversize_error
loader:request(16, images[20], {
    on_error = function(err) unknown_oversize_error = err end,
})
run_next_async()
expect(unknown_oversize_error and unknown_oversize_error.code == "storage"
    and evict_count == evictions_before_unknown_oversize and #async_tasks == 0,
    "an oversized page discovered after download should not evict cache or download twice")

publish_failure = nil
evict_result = 100
client.download = original_download

local priority_images = {
    { name = "priority-1.jpg", path = "/priority-1.jpg" },
    { name = "priority-2.jpg", path = "/priority-2.jpg" },
    { name = "priority-3.jpg", path = "/priority-3.jpg" },
    { name = "priority-4.jpg", path = "/priority-4.jpg" },
}
local first_cover = { name = "cover-first.jpg", path = "/cover-first.jpg" }
local second_cover = { name = "cover-second.jpg", path = "/cover-second.jpg" }
local current_page = { name = "current-priority.jpg", path = "/current-priority.jpg" }

loader:prefetch(20, priority_images, 1)
local interrupted_prefetch = async_tasks[1]
loader:request_cover("covers:1", first_cover, {})
expect(interrupted_prefetch.canceled,
    "a visible cover should interrupt an active prefetch")
run_next_async()
expect(download_order[#download_order] == first_cover.path,
    "a visible cover should run before queued prefetch")
expect(published_kinds[first_cover.path] == "cover",
    "a visible-cover publication should use the cover cache kind")

local resumed_prefetch = async_tasks[1]
loader:request_cover("covers:2", second_cover, {})
expect(resumed_prefetch.canceled,
    "a second visible cover should interrupt the next active prefetch")
local interrupted_cover = async_tasks[1]
local second_cover_ready = false
loader:request(21, current_page, {})
expect(interrupted_cover.canceled,
    "a current page should interrupt an active cover")
run_next_async()
expect(download_order[#download_order] == current_page.path,
    "a current page should remain the highest-priority download")
if #async_tasks > 0 then
    run_next_async()
    second_cover_ready = published[#published] == second_cover.path
end
expect(second_cover_ready,
    "a cover interrupted by a current page should resume afterward")
loader:cancel_all()

local uninterrupted_page = { name = "reader-active.jpg", path = "/reader-active.jpg" }
local queued_cover = { name = "cover-queued.jpg", path = "/cover-queued.jpg" }
local page_ready = false
local queued_cover_ready = false
loader:request(22, uninterrupted_page, {
    on_ready = function() page_ready = true end,
})
local active_page_task = async_tasks[1]
loader:request_cover("covers:3", queued_cover, {
    on_ready = function() queued_cover_ready = true end,
})
expect(not active_page_task.canceled and loader.active
    and loader.active.image == uninterrupted_page,
    "a cover request must never interrupt an active current page")
run_next_async()
expect(page_ready and #async_tasks == 1,
    "finishing the current page should start the waiting visible cover")
run_next_async()
expect(queued_cover_ready,
    "the visible cover queued behind a current page should be delivered")

local shared_image = { name = "shared.jpg", path = "/shared.jpg" }
local shared_cover_ready = false
local shared_reader_ready = false
local shared_downloads_before = #download_order
loader:request_cover("covers:shared", shared_image, {
    on_ready = function() shared_cover_ready = true end,
})
local shared_task = async_tasks[1]
loader:request(23, shared_image, {
    on_ready = function() shared_reader_ready = true end,
})
loader:cancel_cover_generation("covers:shared")
expect(not shared_task.canceled and loader.active ~= nil,
    "canceling a cover waiter should leave a same-path reader request active")
run_next_async()
expect(shared_reader_ready and not shared_cover_ready
    and #download_order == shared_downloads_before + 1,
    "same-path cover and reader requests should share one download and fan out safely")

local duplicate_cover = { name = "cover-duplicate.jpg", path = "/cover-duplicate.jpg" }
local duplicate_first_ready = false
local duplicate_second_ready = false
local duplicate_downloads_before = #download_order
loader:request_cover("covers:duplicate", duplicate_cover, {
    on_ready = function() duplicate_first_ready = true end,
})
loader:request_cover("covers:duplicate", duplicate_cover, {
    on_ready = function() duplicate_second_ready = true end,
})
run_next_async()
expect(duplicate_first_ready and duplicate_second_ready
    and #download_order == duplicate_downloads_before + 1,
    "same-generation cover waiters should fan out from one download")

local canceled_cover = { name = "cover-canceled.jpg", path = "/cover-canceled.jpg" }
local canceled_cover_ready = false
loader:request_cover("covers:canceled", canceled_cover, {
    on_ready = function() canceled_cover_ready = true end,
})
local canceled_cover_task = async_tasks[1]
loader:cancel_cover_generation("covers:canceled")
expect(canceled_cover_task.canceled and loader.active == nil and not canceled_cover_ready,
    "canceling an active cover generation should stop its cover-only transfer")

local promotion_blocker = { name = "promotion-blocker.jpg", path = "/promotion-blocker.jpg" }
local promoted_cover = { name = "cover-promoted.jpg", path = "/cover-promoted.jpg" }
local promoted_cover_ready = false
local promoted_page_ready = false
loader:request(24, promotion_blocker, {})
loader:request_cover("covers:promoted", promoted_cover, {
    on_ready = function() promoted_cover_ready = true end,
})
local promoted_downloads_before = #download_order
loader:request(25, promoted_cover, {
    on_ready = function() promoted_page_ready = true end,
})
expect(loader.active and loader.active.image == promoted_cover
    and loader.active.kind == "page" and #loader.cover_queue == 0,
    "a current request should promote a same-path queued cover job")
run_next_async()
expect(promoted_cover_ready and promoted_page_ready
    and #download_order == promoted_downloads_before + 1,
    "a promoted cover job should download once and fan out to both waiters")

local failed_cover = { name = "cover-failed.jpg", path = "/cover-failed.jpg" }
local after_failure = { name = "cover-after-failure.jpg", path = "/cover-after-failure.jpg" }
local cover_error
local after_failure_ready = false
client.download = function(_self, path, part_path)
    if path == failed_cover.path then return nil, { code = "auth" } end
    return original_download(_self, path, part_path)
end
loader:request_cover("covers:failure", failed_cover, {
    on_error = function(err) cover_error = err end,
})
loader:request_cover("covers:failure", after_failure, {
    on_ready = function() after_failure_ready = true end,
})
local discarded_before_http_error = #discarded_parts
run_next_async()
expect(cover_error and cover_error.code == "auth" and #async_tasks == 1,
    "a cover failure should be delivered without stalling the cover queue")
local failed_cover_discard = discarded_parts[#discarded_parts]
expect(#discarded_parts == discarded_before_http_error + 1
    and failed_cover_discard.key == cache:key_for("server", failed_cover.path)
    and failed_cover_discard.token ~= nil,
    "an ordinary HTTP failure must release and delete its owned partial file")
run_next_async()
expect(after_failure_ready,
    "a cover queued after a failed cover should still complete")
client.download = original_download

local invalid_image = { name = "invalid-download.jpg", path = "/invalid-download.jpg" }
local after_invalid = { name = "after-invalid.jpg", path = "/after-invalid.jpg" }
local invalid_error
local after_invalid_ready = false
local published_before_invalid = #published
client.download = function(_self, path, part_path)
    if path == invalid_image.path then
        return nil, { code = "decode", detail = "unknown_image_signature" }
    end
    return original_download(_self, path, part_path)
end
loader:request_cover("covers:validation", invalid_image, {
    on_error = function(err) invalid_error = err end,
})
loader:request_cover("covers:validation", after_invalid, {
    on_ready = function() after_invalid_ready = true end,
})
run_next_async()
expect(invalid_error and invalid_error.code == "decode"
    and #published == published_before_invalid and #async_tasks == 1,
    "a rejected image part must never publish and must release the next queued job")
run_next_async()
expect(after_invalid_ready,
    "the loader queue should continue after image validation rejects a download")
client.download = original_download

local generation_page = { name = "generation-page.jpg", path = "/generation-page.jpg" }
local generation_cover = { name = "generation-cover.jpg", path = "/generation-cover.jpg" }
loader:request(26, generation_page, {})
local generation_task = async_tasks[1]
loader:request_cover(26, generation_cover, {})
loader:prefetch(26, priority_images, 1)
loader:cancel_generation(26)
expect(generation_task.canceled and loader.active == nil
    and #loader.current_queue == 0 and #loader.cover_queue == 0
    and #loader.prefetch_queue == 0,
    "cancel_generation should remove its page, cover, and prefetch waiters")

local shutdown_cover = { name = "cover-shutdown.jpg", path = "/cover-shutdown.jpg" }
local shutdown_queued = { name = "cover-shutdown-queued.jpg", path = "/cover-shutdown-queued.jpg" }
loader:request_cover("covers:shutdown", shutdown_cover, {})
local shutdown_task = async_tasks[1]
loader:request_cover("covers:shutdown", shutdown_queued, {})
loader:cancel_all()
expect(shutdown_task.canceled and loader.active == nil
    and #loader.current_queue == 0 and #loader.cover_queue == 0
    and #loader.prefetch_queue == 0 and next(loader.jobs_by_key) == nil,
    "cancel_all should stop active cover work and clear every priority queue")

local bounded_loader = Loader:new{
    client_factory = function() return client end,
    cache = cache,
    async = fake_async,
    identity = "bounded-server",
    cancellation_tombstone_limit = 32,
}
for index = 1, 4096 do
    bounded_loader:cancel_generation("page:" .. tostring(index))
    bounded_loader:cancel_cover_generation("cover:" .. tostring(index))
end
local function entry_count(values)
    local count = 0
    for _ in pairs(values) do count = count + 1 end
    return count
end
expect(entry_count(bounded_loader.canceled_generations) == 32
    and entry_count(bounded_loader.canceled_cover_generations) == 32
    and not bounded_loader.canceled_generations["page:1"]
    and not bounded_loader.canceled_cover_generations["cover:1"]
    and bounded_loader.canceled_generations["page:4096"]
    and bounded_loader.canceled_cover_generations["cover:4096"],
    "large cancellation bursts should retain only a bounded recent tombstone window")
bounded_loader:cancel_all()
expect(next(bounded_loader.canceled_generations) == nil
    and next(bounded_loader.canceled_cover_generations) == nil,
    "cancel_all should reclaim all cancellation tombstones after transfer invalidation")

local race_parts = {}
local race_published = {}
local race_discarded = {}
local race_cache = {
    limit_bytes = 200,
    key_for = function(_self, identity, path) return identity .. "|" .. path end,
    lookup = function() return nil end,
    paths_for = function(_self, key, extension, token)
        local final_path = "/race/" .. key:gsub("[^%w]", "_") .. "." .. extension
        local part_path = final_path .. "." .. tostring(token) .. ".part"
        return final_path, part_path
    end,
    publish = function(_self, record, part_path)
        if not race_parts[part_path] then return nil, "missing_part" end
        race_parts[part_path] = nil
        race_published[#race_published + 1] = {
            key = record.key,
            remote_path = record.remote_path,
            part_path = part_path,
        }
        return "/race/published/" .. record.key:gsub("[^%w]", "_")
    end,
    discard_part = function(_self, key, extension, token)
        local final_path = "/race/" .. key:gsub("[^%w]", "_") .. "." .. extension
        local part_path = final_path .. "." .. tostring(token) .. ".part"
        race_parts[part_path] = nil
        race_discarded[#race_discarded + 1] = part_path
        return true
    end,
    total_size = function() return 0 end,
    evict = function() return 200 end,
}
local delayed_tasks = {}
local delayed_async = {
    run = function(work, done, options)
        local task = {
            work = work,
            done = done,
            on_cancelled = options and options.on_cancelled,
            on_reaped = options and options.on_reaped,
            on_callback_error = options and options.on_callback_error,
            canceled = false,
        }
        delayed_tasks[#delayed_tasks + 1] = task
        return { cancel = function()
            task.canceled = true
        end }
    end,
}
local race_downloads = {}
local race_client = {
    download = function(_self, path, part_path)
        race_downloads[#race_downloads + 1] = { path = path, part_path = part_path }
        race_parts[part_path] = true
        return { size = 10, etag = '"race"' }
    end,
}
local race_callback_reports = {}
local race_loader = Loader:new{
    client_factory = function() return race_client end,
    cache = race_cache,
    async = delayed_async,
    identity = "race-server",
    prefetch_count = 1,
    instance_token = "race",
    error_reporter = {
        guard = function(_self, stage, callback, fallback, _cleanup, report_options)
            local ok, result = pcall(callback)
            if ok then return result end
            race_callback_reports[#race_callback_reports + 1] = {
                stage = stage, error = result,
                silent = report_options and report_options.silent,
            }
            return fallback
        end,
    },
}
local reap_error
local timeout_page = { name = "timeout.jpg", path = "/timeout.jpg" }
race_loader:request(26, timeout_page, {
    on_error = function(err) reap_error = err end,
})
local timeout_task = delayed_tasks[1]
timeout_task.work()
local timeout_part = race_downloads[1].part_path
timeout_task.done(false, nil, "async timeout", { reap_pending = true })
expect(reap_error and race_loader.active == nil and race_parts[timeout_part]
    and #race_discarded == 0,
    "timeout should finish the UI job without releasing a part still owned by the child")
expect(type(timeout_task.on_callback_error) == "function",
    "loader should connect Async callback exceptions to its shared reporter")
timeout_task.on_callback_error("timeout callback diagnostic")
expect(#race_callback_reports == 1
    and race_callback_reports[1].stage == "download_page"
    and race_callback_reports[1].silent == true
    and tostring(race_callback_reports[1].error):find("timeout callback diagnostic", 1, true),
    "loader callback exceptions should be silently retained in the shared diagnostic stream")
timeout_task.on_reaped()
timeout_task.on_reaped()
expect(not race_parts[timeout_part] and #race_discarded == 1
    and race_discarded[1] == timeout_part,
    "timeout part ownership should release exactly once after positive reap")

local http_error
local http_page = { name = "http.jpg", path = "/http.jpg" }
race_loader:request(26, http_page, {
    on_error = function(err) http_error = err end,
})
local http_task = delayed_tasks[2]
http_task.work()
local http_part = race_downloads[2].part_path
http_task.done(true, { error = { code = "transport", message = "HTTP 500" } })
expect(http_error and not race_parts[http_part] and #race_discarded == 2,
    "a completed HTTP error should still release its part immediately")

local race_cover = { name = "race-cover.jpg", path = "/race-cover.jpg" }
local race_page = { name = "race-page.jpg", path = "/race-page.jpg" }
local race_cover_ready = false
race_loader:request_cover("covers:race", race_cover, {
    on_ready = function() race_cover_ready = true end,
})
local old_cover_task = delayed_tasks[3]
local old_cover_result = old_cover_task.work()
race_loader:request(27, race_page, {})
expect(old_cover_task.canceled,
    "the race fixture should hold the interrupted cover cancellation callback")
local race_page_task = delayed_tasks[4]
local race_page_result = race_page_task.work()
race_page_task.done(true, race_page_result, nil)
local resumed_cover_task = delayed_tasks[5]
local resumed_cover_result = resumed_cover_task.work()
local old_cover_part = race_downloads[3].part_path
local resumed_cover_part = race_downloads[5].part_path
expect(old_cover_part ~= resumed_cover_part,
    "each resumed transfer should receive a distinct immutable part token")
old_cover_task.done(true, old_cover_result, nil)
old_cover_task.done(false, nil, "stale transfer error")
old_cover_task.on_cancelled()
local race_cover_key = race_cache:key_for("race-server", race_cover.path)
expect(race_loader.active and race_loader.active.image == race_cover
    and race_loader.jobs_by_key[race_cover_key] == race_loader.active
    and race_parts[resumed_cover_part] and not race_cover_ready,
    "stale success, error, and cancel callbacks must not finish or clean the resumed transfer")
expect(#race_discarded == 3 and race_discarded[3] == old_cover_part,
    "the delayed cancellation callback should discard only its own transfer part")
resumed_cover_task.done(true, resumed_cover_result, nil)
expect(race_cover_ready and race_loader.active == nil
    and race_loader.jobs_by_key[race_cover_key] == nil
    and race_published[#race_published].part_path == resumed_cover_part,
    "the resumed cover should publish and deliver normally after stale callbacks")

local window_async_tasks = {}
local window_loader = Loader:new{
    client_factory = function() return race_client end,
    cache = {
        limit_bytes = 200,
        key_for = function(_self, identity, path) return identity .. "|" .. path end,
        lookup = function() return nil end,
        paths_for = function(_self, key)
            return "/window/" .. key, "/window/" .. key .. ".part"
        end,
        total_size = function() return 0 end,
        evict = function() return 200 end,
    },
    async = {
        run = function(work, done, options)
            window_async_tasks[#window_async_tasks + 1] = {
                work = work, done = done, options = options,
            }
            return { cancel = function() end }
        end,
    },
    identity = "window",
    prefetch_count = 1,
}
local physical_window = {
    { name = "100.jpg", path = "/100.jpg" },
    { name = "101.jpg", path = "/101.jpg" },
    { name = "102.jpg", path = "/102.jpg" },
    first_index = 100,
}
window_loader:prefetch(30, physical_window, 101)
expect(window_loader.active and window_loader.active.image == physical_window[3]
    and #window_async_tasks == 1,
    "loader prefetch should consume a bounded ChapterIndex window using the physical index")

print(("progress_loader_spec: %d checks"):format(checks))
