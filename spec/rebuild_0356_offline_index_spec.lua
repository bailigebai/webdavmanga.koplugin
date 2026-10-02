local OfflineCache = require("webdavmanga.offline_cache")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function memory_store(initial)
    local store = { values = initial or {}, flushes = 0 }
    function store:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:saveSetting(key, value) self.values[key] = value end
    function store:flush() self.flushes = self.flushes + 1 end
    return store
end

local files, directories, renames, removals = {}, {}, 0, 0
local fs = {}
function fs.make_path(path) directories[path] = true; return true end
function fs.exists(path) return files[path] ~= nil end
function fs.size(path) return files[path] end
function fs.rename(source, target)
    renames = renames + 1
    if not files[source] then return nil, "missing" end
    files[target], files[source] = files[source], nil
    return true
end
function fs.remove(path) removals = removals + 1; files[path] = nil; return true end

local function stable_md5(value)
    local sum = #value
    for index = 1, #value do
        sum = (sum * 33 + value:byte(index)) % 0xffffffff
    end
    return ("%032x"):format(sum)
end

local GB = 1024 * 1024 * 1024
local store = memory_store()
local cache = OfflineCache:new{
    store = store,
    root_provider = function() return "/mnt/us/Offline" end,
    limit_bytes_provider = function() return 5 * GB end,
    fs = fs,
    disk_usage = function()
        return { total = 32 * GB, used = 2 * GB, available = 30 * GB }
    end,
    md5 = stable_md5,
}

local manga = { name = "Manga 2", path = "/Manga/Manga 2" }
local chapter = {
    name = "Chapter 01", path = manga.path .. "/Chapter 01", offline_position = 1,
}
local page2 = {
    name = "002.jpg", path = chapter.path .. "/002.jpg",
    size = 100, offline_position = 2,
}

local job = assert(cache:save_job("source-a", manga, {
    status = "scanning", total_pages = 0, total_bytes = 0,
    downloaded = 3, detail_code = "offline_limit",
    detail_used_bytes = 4 * GB, detail_required_bytes = GB,
    detail_limit_bytes = 5 * GB, injected = { unsafe = true },
}))
expect(job.status == "scanning" and job.schema_version == 2
    and job.downloaded == 3 and job.detail_code == "offline_limit"
    and job.detail_used_bytes == 4 * GB and job.detail_required_bytes == GB
    and job.detail_limit_bytes == 5 * GB and job.injected == nil
    and store.values.jobs ~= nil,
    "schema-2 jobs must persist only whitelisted scalar terminal metadata")

local plan2 = assert(cache:plan(
    "source-a", manga, chapter, page2, false, "task1"))
files[plan2.part_path] = 100
assert(cache:publish(plan2, plan2.part_path,
    { size = 100, format = "jpeg", width = 100, height = 200 }, false))
local malformed_remote = "/Manga/malformed.jpg"
local malformed_key = cache:key_for("source-a", malformed_remote)
store.values.entries[malformed_key] = 42

local lookup_ok, lookup_value = pcall(
    cache.lookup, cache, "source-a", malformed_remote)
expect(lookup_ok and lookup_value == nil,
    "lookup must ignore a non-table persisted entry")
store.values.entries[malformed_key] = 42
local owns_ok, owns_value = pcall(cache.owns_local_path, cache,
    "source-a", malformed_remote, "/mnt/us/Offline/forged.jpg")
expect(owns_ok and owns_value == false,
    "path ownership must reject a non-table persisted entry")
store.values.entries[malformed_key] = 42
local stats_ok, safe_stats = pcall(cache.stats, cache)
expect(stats_ok and safe_stats.offline_bytes == 100,
    "statistics must skip a non-table persisted entry")

local mangas = cache:list_mangas("source-a")
expect(#mangas == 1 and mangas[1].cached_pages == 1,
    "the shelf must group valid cached pages by manga")
expect(mangas[1].total_pages == 2 and mangas[1].progress == 0.5
    and mangas[1].cover_path ~= nil,
    "scan order must provide stable progress and the first cached cover")
local unavailable, incomplete = cache:reader_model("source-a", manga.path)
expect(unavailable == nil and incomplete == "incomplete",
    "a scanning job must not open as a trusted offline manga")

local page1 = {
    name = "001.jpg", path = chapter.path .. "/001.jpg",
    size = 90, offline_position = 1,
}
local plan1 = assert(cache:plan(
    "source-a", manga, chapter, page1, false, "task2"))
files[plan1.part_path] = 90
assert(cache:publish(plan1, plan1.part_path,
    { size = 90, format = "jpeg", width = 100, height = 200 }, false))
assert(cache:save_job("source-a", manga, {
    status = "complete", total_pages = 2, total_bytes = 190,
    cached_pages = 2, cached_bytes = 190, failed = 0,
}))

local model = assert(cache:reader_model("source-a", manga.path))
expect(model.status == "complete" and model.cached_pages == 2
    and model.total_pages == 2 and model.progress == 1
    and model.cover_path == plan1.final_path,
    "a complete job must expose trustworthy counts and the first ordered cover")
expect(#model.chapters == 1 and model.chapters[1].path == chapter.path
    and model.chapters[1].images[1].path == page1.path
    and model.chapters[1].images[2].path == page2.path,
    "reader chapters and pages must follow persisted offline positions")
expect(model.chapters[1].images[1].offline_owned == true
    and model.chapters[1].images[1].local_path:sub(1, 16) == "/mnt/us/Offline/"
    and model.chapters[1].images[1].size == 90
    and model.chapters[1].images[1].format == "jpeg",
    "reader images must retain remote paths and validated local metadata")

local job_key
for key, saved_job in pairs(store.values.jobs) do
    if saved_job.manga_path == manga.path then job_key = key end
end
local complete_job = store.values.jobs[job_key]
store.values.jobs[job_key] = {
    schema_version = 2, status = "complete", failed = 0,
    total_pages = 2, cached_pages = 2, manga_path = manga.path,
}
local partial_model, partial_error = cache:reader_model("source-a", manga.path)
expect(partial_model == nil and partial_error == "incomplete",
    "a partial or mismatched persisted job must never authorize offline reading")
store.values.jobs[job_key] = complete_job

expect(cache:owns_local_path("source-a", page1.path, plan1.final_path)
    and not cache:owns_local_path("source-b", page1.path, plan1.final_path)
    and not cache:owns_local_path("source-a", page2.path, plan1.final_path),
    "local ownership must require an exact indexed identity and path triple")
files[plan1.final_path] = nil
expect(not cache:owns_local_path("source-a", page1.path, plan1.final_path),
    "a missing file must no longer be claimed as offline-owned")
files[plan1.final_path] = 90

local legacy_remote = "/Legacy/Chapter 10/10.jpg"
local legacy_key = stable_md5("source-legacy\0" .. legacy_remote)
local legacy_local = "/mnt/us/Offline/Legacy/Chapter 10/10-"
    .. legacy_key:sub(1, 8) .. ".jpg"
files[legacy_local] = 80
local legacy_store = memory_store({ schema_version = 1, entries = {
    [legacy_key] = {
        namespace = "webdavmanga-offline-v1", owned = true,
        key = legacy_key, identity = "source-legacy",
        remote_path = legacy_remote, manga_path = "/Legacy",
        manga_name = "Legacy", root = "/mnt/us/Offline",
        local_path = legacy_local, size = 80, extension = "jpg",
        format = "jpeg", width = 100, height = 200,
    },
} })
local legacy = OfflineCache:new{
    store = legacy_store,
    root_provider = function() return "/mnt/us/Offline" end,
    limit_bytes_provider = function() return 5 * GB end,
    fs = fs,
    disk_usage = function() return { available = 30 * GB } end,
    md5 = stable_md5,
}
expect(#legacy:list_mangas("source-legacy") == 1 and files[legacy_local] == 80,
    "schema-1 entries must remain visible and must not delete their files")
local legacy_model, legacy_error = legacy:reader_model("source-legacy", "/Legacy")
expect(legacy_model == nil and legacy_error == "incomplete",
    "a legacy entry without a complete job must not open offline")
expect(legacy:owns_local_path("source-legacy", legacy_remote, legacy_local),
    "a valid legacy index entry may still prove file ownership")

local retry_manga = { name = "Legacy", path = "/Legacy" }
local retry_chapter = {
    name = "Chapter 10", path = "/Legacy/Chapter 10", offline_position = 1,
}
local retry_page = {
    name = "10.jpg", path = legacy_remote, size = 80,
}
local OfflineManager = require("webdavmanga.offline_manager")
local function index(items)
    return { count = function() return #items end,
        get = function(_self, position) return items[position] end }
end
local retry_events, retry_loads, retry_downloads = {}, {}, 0
local retry_manager = OfflineManager:new{
    offline_cache = legacy,
    directory_store = { load = function(_self, path, callbacks)
        retry_loads[#retry_loads + 1] = path
        callbacks.on_ready({
            folders = index(path == retry_manga.path and { retry_chapter } or {}),
            images = index(path == retry_chapter.path and { retry_page } or {}),
        })
        return { cancel = function() end }
    end },
    client_factory = function() return { download = function()
        retry_downloads = retry_downloads + 1
        return nil, "unexpected_download"
    end } end,
    connection_provider = function() return {} end,
    identity_provider = function() return "source-legacy" end,
    scheduler = function(callback) retry_events[#retry_events + 1] = callback end,
    async = { run = function(work, done)
        local ok, result = pcall(work)
        done(ok, result)
        return { cancel = function() end }
    end },
}
local function retry()
    assert(retry_manager:start(retry_manga))
    while #retry_events > 0 do table.remove(retry_events, 1)() end
    return retry_manager:status()
end
local before_renames, before_removals = renames, removals
local retry_summary = retry()
expect(retry_summary.status == "complete" and retry_downloads == 0
    and #retry_loads == 2 and retry_loads[2] == "/Legacy/Chapter 10",
    "a real legacy retry must scan the manga and chapter without downloading cached pages")
local migrated = legacy:reader_model("source-legacy", "/Legacy")
expect(migrated and migrated.chapters[1].images[1].local_path == legacy_local,
    "a real legacy retry must enrich the old indexed file into a readable model")
local migrated_record = legacy_store.values.entries[legacy_key]
expect(files[legacy_local] == 80 and renames == before_renames and removals == before_removals
    and migrated_record.image_name == "10.jpg" and migrated_record.page_position == 1
    and migrated_record.chapter_position == 1 and migrated_record.chapter_path == retry_chapter.path,
    "legacy enrichment must preserve the exact file and populate scan ordering metadata")
local enrichment_values = {}
for key, value in pairs(migrated_record) do enrichment_values[key] = value end
enrichment_values.local_path = "/mnt/us/personal/forged.jpg"
enrichment_values.size = 999
assert(legacy:enrich("source-legacy", legacy_remote, enrichment_values))
expect(legacy:lookup("source-legacy", legacy_remote) == legacy_local
    and legacy_store.values.entries[legacy_key].size == 80,
    "enrichment must only accept known ordering and name fields")
enrichment_values.page_position = 0
expect(not legacy:enrich("source-legacy", legacy_remote, enrichment_values)
    and not legacy:enrich("source-other", legacy_remote, migrated_record)
    and not legacy:enrich("source-legacy", legacy_remote .. ".other", migrated_record),
    "enrichment must reject invalid ordering and nonmatching identities or remote paths")
legacy.root_provider = function() return "/mnt/us/Other" end
expect(not legacy:enrich("source-legacy", legacy_remote, migrated_record),
    "enrichment must reject a file outside the current offline root")
legacy.root_provider = function() return "/mnt/us/Offline" end
retry_page.name = nil
local failed_retry = retry()
expect(failed_retry.status ~= "complete" and failed_retry.failed == 1
    and legacy:reader_model("source-legacy", "/Legacy") == nil
    and retry_downloads == 0 and files[legacy_local] == 80,
    "a failed legacy enrichment must not mark the job complete or redownload the old file")

local quota_store = memory_store({ entries = {
    [legacy_key] = legacy_store.values.entries[legacy_key],
} })
local quota = OfflineCache:new{
    store = quota_store,
    root_provider = function() return "/mnt/us/Offline" end,
    limit_bytes_provider = function() return 100 end,
    fs = fs,
    disk_usage = function() return { available = 10 * GB } end,
    md5 = stable_md5,
}
expect(quota:can_store(20) == true,
    "aggregate quota must allow an exact limit")
local allowed, quota_error, detail = quota:can_store(21)
expect(not allowed and quota_error == "offline_limit"
    and detail.code == "offline_limit" and detail.used_bytes == 80
    and detail.required_bytes == 21 and detail.limit_bytes == 100,
    "aggregate quota failures must include stable accounting details")
expect(quota:stats().limit_bytes == 100,
    "cache statistics must expose the configured aggregate limit")

local selected_root, disk_root = "/mnt/us/Offline", nil
assert(quota:save_job("source-legacy", retry_manga, {
    status = "complete", total_pages = 1, cached_pages = 1, failed = 0,
}))
expect(quota:reader_model("source-legacy", "/Legacy") ~= nil,
    "the retained quota entry must be readable before switching its configured root")
quota.root_provider = function() return selected_root end
quota.disk_usage = function(path)
    disk_root = path
    return { available = 10 * GB }
end
selected_root = "/mnt/us/OfflineNew"
local moved_allowed, moved_error, moved_detail = quota:can_store(21)
expect(not moved_allowed and moved_error == "offline_limit"
    and moved_detail.used_bytes == 80 and quota:can_store(20) == true,
    "changing the offline root must retain old-root bytes in aggregate quota")
expect(quota:lookup("source-legacy", legacy_remote) == nil
    and not quota:owns_local_path("source-legacy", legacy_remote, legacy_local)
    and quota:reader_model("source-legacy", "/Legacy") == nil,
    "old-root entries must not authorize current-root lookup or reading")
expect(quota:stats().offline_bytes == 80 and disk_root == selected_root
    and quota_store.values.entries[legacy_key] ~= nil,
    "old-root lookup must retain quota records and query space at the current destination")
selected_root = "/mnt/us/Offline"
expect(quota:lookup("source-legacy", legacy_remote) == legacy_local
    and quota:reader_model("source-legacy", "/Legacy") ~= nil,
    "switching back must recover the original indexed page without a retry or download")

local reserve = OfflineCache:new{
    store = memory_store(),
    root_provider = function() return "/mnt/us/Offline" end,
    limit_bytes_provider = function() return 5 * GB end,
    fs = fs,
    disk_usage = function() return { available = GB + 9 } end,
    md5 = stable_md5,
}
local reserve_ok, reserve_error = reserve:can_store(10)
expect(not reserve_ok and reserve_error == "reserve_space",
    "the 5 GB free-space reserve must remain independent")

local repeated_root, repeated_limit = "/mnt/us/A", 100
local repeated_store = memory_store()
local function reopen_repeated()
    return OfflineCache:new{
        store = repeated_store, root_provider = function() return repeated_root end,
        limit_bytes_provider = function() return repeated_limit end,
        fs = fs, disk_usage = function() return { available = 10 * GB } end,
        md5 = stable_md5,
    }
end
local repeated = reopen_repeated()
local repeated_manga = { name = "Repeated", path = "/Repeated" }
local repeated_chapter = { name = "Chapter", path = "/Repeated/1", offline_position = 1 }
local repeated_page = { name = "001.jpg", path = "/Repeated/1/001.jpg", offline_position = 1 }
local repeated_paths = {}
local function publish_repeated()
    local plan = assert(repeated:plan("source-a", repeated_manga,
        repeated_chapter, repeated_page, false, "repeat"))
    files[plan.part_path] = 40
    local path, err = repeated:publish(plan, plan.part_path,
        { size = 40, format = "jpeg", width = 100, height = 200 }, false)
    if path then
        assert(repeated:save_job("source-a", repeated_manga, {
            status = "complete", total_pages = 1, cached_pages = 1, failed = 0,
        }))
    end
    return path, err, plan
end
repeated_paths.A = assert(publish_repeated())
repeated_root = "/mnt/us/B"
expect(repeated:lookup("source-a", repeated_page.path) == nil,
    "another root must not reuse a different destination's cached file")
repeated_paths.B = assert(publish_repeated())
repeated_root = "/mnt/us/C"
local allow_third, third_error, third_detail = repeated:can_store(40)
expect(not allow_third and third_error == "offline_limit" and third_detail.used_bytes == 80
    and repeated:stats().offline_bytes == 80,
    "two retained copies of the same remote page must block a third copy above quota")
local rejected, rejected_error, rejected_plan = publish_repeated()
expect(rejected == nil and rejected_error == "offline_limit"
    and files[rejected_plan.final_path] == nil
    and files[repeated_paths.A] == 40 and files[repeated_paths.B] == 40,
    "publishing a third copy must enforce actual bytes without touching retained files")
repeated:discard_part(rejected_plan)
repeated_limit = 120
repeated_paths.C = assert(publish_repeated())
assert(repeated:save_job("source-a", repeated_manga, {
    status = "complete", total_pages = 1, cached_pages = 1, failed = 0,
}))
repeated = reopen_repeated()
expect(repeated:stats().offline_bytes == 120 and repeated:can_store(1) == false,
    "all three retained copies must count after reopening the persisted cache")
for _, root_name in ipairs({ "A", "B", "C" }) do
    repeated_root = "/mnt/us/" .. root_name
    local path = repeated:lookup("source-a", repeated_page.path)
    local model = repeated:reader_model("source-a", repeated_manga.path)
    local shelf = repeated:list_mangas("source-a")
    expect(path == repeated_paths[root_name] and model
        and model.chapters[1].images[1].local_path == path
        and #shelf == 1 and shelf[1].cached_pages == 1 and shelf[1].cover_path == path
        and repeated:owns_local_path("source-a", repeated_page.path, path),
        "each root must recover its own copy for lookup, reading, ownership, and shelf")
end
repeated_limit = 160
local rename_count = renames
local overwritten, overwrite_error, overwrite_plan = publish_repeated()
expect(overwritten == nil and overwrite_error == "offline_file_exists"
    and renames == rename_count and files[repeated_paths.C] == 40,
    "publishing to an existing final path must never overwrite its retained file")
repeated:discard_part(overwrite_plan)
repeated_page.name = "renamed.jpg"
local previous_c = repeated_paths.C
repeated_paths.C = assert(publish_repeated())
local revised_shelf = repeated:list_mangas("source-a")
expect(repeated:stats().offline_bytes == 160 and files[previous_c] == 40
    and repeated_paths.C ~= previous_c and #revised_shelf == 1
    and revised_shelf[1].cached_pages == 1 and revised_shelf[1].cover_path == repeated_paths.C
    and not repeated:owns_local_path("source-a", repeated_page.path, previous_c),
    "replacing a page's local name must retain old bytes without duplicating the readable page")
local _revised_path, revised_record = repeated:lookup("source-a", repeated_page.path)
revised_record.image_name = "renamed.jpg"
assert(repeated:enrich("source-a", repeated_page.path, revised_record))
repeated = reopen_repeated()
expect(repeated:stats().offline_bytes == 160
    and repeated:reader_model("source-a", repeated_manga.path).chapters[1].images[1].local_path
        == repeated_paths.C,
    "root-scoped enrichment must preserve the active file and retained quota after restart")
files[repeated_paths.B] = nil
expect(reopen_repeated():stats().offline_bytes == 120,
    "retained records whose actual files disappeared must not count as occupied space")

local legacy_root = "/mnt/us/Offline"
local legacy_copies = OfflineCache:new{
    store = memory_store({ entries = { [legacy_key] = migrated_record } }),
    root_provider = function() return legacy_root end,
    limit_bytes_provider = function() return 100 end,
    fs = fs, disk_usage = function() return { available = 10 * GB } end, md5 = stable_md5,
}
legacy_root = "/mnt/us/LegacyNew"
local legacy_copy_plan = assert(legacy_copies:plan("source-legacy", retry_manga,
    retry_chapter, { name = "10.jpg", path = legacy_remote, offline_position = 1 }, false, "copy"))
files[legacy_copy_plan.part_path] = 20
assert(legacy_copies:publish(legacy_copy_plan, legacy_copy_plan.part_path,
    { size = 20, format = "jpeg", width = 100, height = 200 }, false))
legacy_root = "/mnt/us/Offline"
expect(legacy_copies:stats().offline_bytes == 100
    and legacy_copies:lookup("source-legacy", legacy_remote) == legacy_local,
    "new root-scoped entries must preserve legacy canonical records and their original lookup")

local lifecycle_root = "/mnt/us/JobsA"
local lifecycle_store, lifecycle_events = memory_store(), {}
local lifecycle_downloads, lifecycle_workers, lifecycle_peak = 0, 0, 0
local switch_during_download, interrupted_part = false, nil
local lifecycle_manga = { name = "Lifecycle", path = "/Lifecycle" }
local lifecycle_page = { name = "001.jpg", path = "/Lifecycle/001.jpg", size = 40 }
local function reopen_lifecycle()
    return OfflineCache:new{
        store = lifecycle_store, root_provider = function() return lifecycle_root end,
        limit_bytes_provider = function() return 100 end, fs = fs, md5 = stable_md5,
        disk_usage = function() return { available = 10 * GB } end,
    }
end
local lifecycle_cache = reopen_lifecycle()
local lifecycle_manager = OfflineManager:new{
    offline_cache = lifecycle_cache,
    directory_store = { load = function(_self, _path, callbacks)
        lifecycle_events[#lifecycle_events + 1] = function()
            callbacks.on_ready({ folders = index({}), images = index({ lifecycle_page }) })
        end
        return { cancel = function() end }
    end },
    client_factory = function() return { download = function(_self, _remote, part)
        lifecycle_downloads = lifecycle_downloads + 1
        files[part] = 40
        if switch_during_download then
            interrupted_part = part
            lifecycle_root = "/mnt/us/JobsE"
        end
        return { size = 40, format = "jpeg", width = 100, height = 200 }
    end } end,
    connection_provider = function() return {} end,
    identity_provider = function() return "source-a" end,
    scheduler = function(callback) lifecycle_events[#lifecycle_events + 1] = callback end,
    async = { run = function(work, done)
        lifecycle_events[#lifecycle_events + 1] = function()
            lifecycle_workers = lifecycle_workers + 1
            lifecycle_peak = math.max(lifecycle_peak, lifecycle_workers)
            local ok, result = pcall(work)
            lifecycle_workers = lifecycle_workers - 1
            done(ok, result)
        end
        return { cancel = function() end }
    end },
}
for _, case in ipairs({ { "A", "complete", 1 }, { "B", "complete", 2 }, { "C", "limit", 2 } }) do
    lifecycle_root = "/mnt/us/Jobs" .. case[1]
    assert(lifecycle_manager:start(lifecycle_manga))
    local concurrent, concurrent_error = lifecycle_manager:start(lifecycle_manga)
    expect(concurrent == nil and concurrent_error == "busy",
        "root-isolated jobs must still share the manager's single-task constraint")
    while #lifecycle_events > 0 do table.remove(lifecycle_events, 1)() end
    expect(lifecycle_manager:status().status == case[2] and lifecycle_downloads == case[3],
        "A/B must complete and C must hit shared quota before any third-root download")
end
lifecycle_cache = reopen_lifecycle()
for _, case in ipairs({ { "A", "complete", true }, { "B", "complete", true }, { "C", "limit", false } }) do
    lifecycle_root = "/mnt/us/Jobs" .. case[1]
    local shelf = lifecycle_cache:list_mangas("source-a")
    local model = lifecycle_cache:reader_model("source-a", lifecycle_manga.path)
    expect(#shelf == 1 and shelf[1].status == case[2] and (model ~= nil) == case[3],
        "a third-root limit must not replace completed jobs in earlier roots after restart")
    expect(lifecycle_cache:stats().offline_bytes == 80
        and #lifecycle_cache:list_mangas("source-other") == 0,
        "root-isolated completion must retain aggregate bytes and connection isolation")
end
expect(lifecycle_peak == 1 and lifecycle_downloads == 2,
    "job isolation must preserve serial downloads and zero downloads for the limited root")
local switched_manga = { name = "Switched", path = "/Switched" }
lifecycle_root = "/mnt/us/JobsA"
assert(lifecycle_manager:start(switched_manga))
lifecycle_root = "/mnt/us/JobsB"
while #lifecycle_events > 0 do table.remove(lifecycle_events, 1)() end
local leaked_job = false
for _, item in ipairs(lifecycle_cache:list_mangas("source-a")) do
    if item.manga.path == switched_manga.path then leaked_job = true end
end
expect(lifecycle_manager:status().status == "canceled" and not leaked_job
    and lifecycle_downloads == 2,
    "changing destination during a task must stop it without writing its status to the new root")
lifecycle_root = "/mnt/us/JobsA"
local canceled_original = false
for _, item in ipairs(reopen_lifecycle():list_mangas("source-a")) do
    if item.manga.path == switched_manga.path then canceled_original = item.status == "canceled" end
end
expect(canceled_original, "a destination change must persist cancellation at the task's original root")
switch_during_download = true
lifecycle_manager.offline_cache.limit_bytes_provider = function() return 200 end
lifecycle_root = "/mnt/us/JobsD"
assert(lifecycle_manager:start(switched_manga))
while #lifecycle_events > 0 do table.remove(lifecycle_events, 1)() end
expect(lifecycle_manager:status().status == "canceled" and interrupted_part
    and files[interrupted_part] == nil
    and lifecycle_manager.offline_cache:stats().offline_bytes == 80,
    "a destination change during download must clean only its owned old-root part and not publish it")

local old_job_key = stable_md5("source-a\0/Lifecycle")
local function old_job()
    return { schema_version = 2, key = old_job_key, identity = "source-a",
        manga_path = "/Lifecycle", manga_name = "Lifecycle", status = "complete",
        total_pages = 1, cached_pages = 1, failed = 0 }
end
local function open_old_jobs(old_store)
    return OfflineCache:new{
        store = old_store, root_provider = function() return lifecycle_root end,
        fs = fs, md5 = stable_md5, disk_usage = function() return { available = 10 * GB } end,
    }
end
local old_entries = {}
for key, record in pairs(lifecycle_store.values.entries) do
    if record.root == "/mnt/us/JobsA" then old_entries[key] = record end
end
local old_store = memory_store({ entries = old_entries, jobs = { [old_job_key] = old_job() } })
lifecycle_root = "/mnt/us/JobsB"
local old_cache = open_old_jobs(old_store)
expect(#old_cache:list_mangas("source-a") == 0,
    "a legacy complete job must bind to its uniquely owned page root rather than the selected root")
lifecycle_root = "/mnt/us/JobsA"
expect(old_cache:list_mangas("source-a")[1].status == "complete"
    and old_cache:reader_model("source-a", "/Lifecycle") ~= nil,
    "a legacy canonical job must remain readable after migration to its proven root")
old_cache = open_old_jobs(old_store)
expect(old_cache:reader_model("source-a", "/Lifecycle") ~= nil,
    "legacy job root migration must persist across cache restart")

local empty_old_job = old_job()
empty_old_job.status, empty_old_job.total_pages, empty_old_job.cached_pages = "canceled", 0, 0
local empty_old_store = memory_store({ jobs = { [old_job_key] = empty_old_job } })
local empty_old_cache = open_old_jobs(empty_old_store)
expect(empty_old_cache:list_mangas("source-a")[1].status == "canceled",
    "a legacy job without any cached pages must remain visible in its migration destination")
lifecycle_root = "/mnt/us/JobsB"
expect(#open_old_jobs(empty_old_store):list_mangas("source-a") == 0,
    "a migrated zero-page canonical job must not follow later root switches")

local ambiguous_store = memory_store({ entries = lifecycle_store.values.entries,
    jobs = { [old_job_key] = old_job() } })
local ambiguous_cache = open_old_jobs(ambiguous_store)
for _, root_name in ipairs({ "A", "B" }) do
    lifecycle_root = "/mnt/us/Jobs" .. root_name
    expect(ambiguous_cache:reader_model("source-a", "/Lifecycle") == nil
        and ambiguous_cache:list_mangas("source-a")[1].status == "incomplete",
        "a rootless legacy job with multiple possible roots must not authorize either copy")
end

print(("rebuild_0356_offline_index_spec: %d checks"):format(checks))
