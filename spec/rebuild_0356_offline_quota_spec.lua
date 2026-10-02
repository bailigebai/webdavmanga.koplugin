local OfflineManager = require("webdavmanga.offline_manager")

local GB = 1024 * 1024 * 1024
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function index(entries)
    return {
        count = function() return #entries end,
        get = function(_self, position) return entries[position] end,
    }
end

local function fixture(options)
    options = options or {}
    local manga = { name = "配额漫画", path = "/Books/Quota", is_folder = true }
    local chapter1 = { name = "第一话", path = manga.path .. "/01", is_folder = true }
    local chapter2 = { name = "第二话", path = manga.path .. "/02", is_folder = true }
    local image1 = { name = "001.jpg", path = chapter1.path .. "/001.jpg", size = options.first_size }
    local image2 = { name = "002.jpg", path = chapter2.path .. "/002.jpg", size = options.second_size }
    local directories = {
        [manga.path] = { folders = function() return index({ chapter1, chapter2 }) end,
            images = function() return index({}) end, close = function() end },
        [chapter1.path] = { folders = function() return index({}) end,
            images = function() return index({ image1 }) end, close = function() end },
        [chapter2.path] = { folders = function() return index({}) end,
            images = function() return index({ image2 }) end, close = function() end },
    }
    local events, directory_loads, download_calls, publish_calls = {}, 0, 0, 0
    local peak_events = 0
    local function schedule(callback)
        events[#events + 1] = callback
        peak_events = math.max(peak_events, #events)
        return true
    end
    local function drain_scheduler()
        local turns = 0
        while #events > 0 do
            turns = turns + 1
            if turns > 100 then error("scheduler did not settle") end
            table.remove(events, 1)()
        end
    end
    local cache = { saved_jobs = {}, can_store_calls = {}, discarded = {} }
    function cache:save_job(identity, saved_manga, values)
        self.saved_jobs[#self.saved_jobs + 1] = {
            identity = identity, manga = saved_manga, status = values.status,
            total_pages = values.total_pages, total_bytes = values.total_bytes,
            cached_pages = values.cached_pages, cached_bytes = values.cached_bytes,
            downloaded = values.downloaded, failed = values.failed,
            error_code = values.error_code, detail_code = values.detail_code,
            detail_used_bytes = values.detail_used_bytes,
            detail_required_bytes = values.detail_required_bytes,
            detail_limit_bytes = values.detail_limit_bytes,
        }
        return self.saved_jobs[#self.saved_jobs]
    end
    function cache:can_store(required)
        self.can_store_calls[#self.can_store_calls + 1] = required
        if options.can_store then return options.can_store(required) end
        return true
    end
    function cache:lookup(_identity, path)
        return options.cached and options.cached[path] or nil
    end
    function cache:enrich() return {} end
    function cache:plan(_identity, _manga, _chapter, image, _denoised, token)
        return { remote_path = image.path, final_path = "/offline/" .. image.name,
            part_path = "/offline/" .. token .. ".part",
            denoise_path = "/offline/" .. token .. ".denoise.part" }
    end
    function cache:publish(plan)
        publish_calls = publish_calls + 1
        return plan.final_path
    end
    function cache:discard_part(plan)
        self.discarded[plan.part_path] = true
        self.discarded[plan.denoise_path] = true
        return true
    end
    local async = {
        run = function(work, done)
            schedule(function()
                local ok, result = pcall(work)
                done(ok, result, ok and nil or result)
            end)
            return { cancel = function() end }
        end,
    }
    local client = {
        download = function()
            download_calls = download_calls + 1
            return { size = options.actual_size or 1, format = "jpeg", width = 100, height = 200 }
        end,
    }
    local statuses = {}
    local manager = OfflineManager:new{
        directory_store = {
            load = function(_self, path, callbacks)
                directory_loads = directory_loads + 1
                schedule(function() callbacks.on_ready(directories[path]) end)
                return { cancel = function() end }
            end,
        },
        offline_cache = cache,
        client_factory = function() return client end,
        connection_provider = function() return { root_path = "/Books" } end,
        identity_provider = function() return "source-a" end,
        async = async,
        scheduler = schedule,
        on_status = function(summary) statuses[#statuses + 1] = summary end,
    }
    return {
        manga = manga, image1 = image1, image2 = image2, cache = cache,
        manager = manager, statuses = statuses, schedule = schedule,
        drain_scheduler = drain_scheduler,
        directory_loads = function() return directory_loads end,
        download_calls = function() return download_calls end,
        publish_calls = function() return publish_calls end,
        peak_events = function() return peak_events end,
    }
end

local completed
local above_limit = fixture{
    first_size = GB, second_size = GB,
    can_store = function(required)
        if required == 2 * GB then
            return false, "offline_limit", {
                code = "offline_limit", used_bytes = 4 * GB,
                required_bytes = 2 * GB, limit_bytes = 5 * GB,
            }
        end
        return true
    end,
}
local handle = assert(above_limit.manager:start(above_limit.manga, {
    on_complete = function(summary) completed = summary end,
}))
expect(handle and above_limit.cache.saved_jobs[1]
    and above_limit.cache.saved_jobs[1].status == "scanning",
    "cache shelf entry must exist before directory discovery finishes")
above_limit.manga.name = "切换后的漫画"
above_limit.drain_scheduler()
expect(above_limit.directory_loads() == 3,
    "manga root and both chapters must be scanned before downloads")
expect(above_limit.download_calls() == 0,
    "preflight above aggregate limit must not download a page")
expect(completed.status == "limit" and completed.detail.code == "offline_limit"
    and completed.detail.used_bytes == 4 * GB
    and completed.detail.required_bytes == 2 * GB
    and completed.detail.limit_bytes == 5 * GB,
    "aggregate limit must report exact cache accounting")
expect(completed.identity == "source-a" and completed.manga_path == "/Books/Quota"
    and completed.manga.name == "配额漫画",
    "every summary must retain the identity and manga captured at start")
expect(above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].status == "limit"
    and above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].downloaded == 0
    and above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].detail_code == "offline_limit"
    and above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].detail_used_bytes == 4 * GB
    and above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].detail_required_bytes == 2 * GB
    and above_limit.cache.saved_jobs[#above_limit.cache.saved_jobs].detail_limit_bytes == 5 * GB,
    "terminal quota state must persist downloaded count and exact limit detail")

local cached_page = fixture{
    first_size = GB, second_size = GB,
    cached = { ["/Books/Quota/01/001.jpg"] = "/offline/cached.jpg" },
}
local cached_complete
assert(cached_page.manager:start(cached_page.manga, {
    on_complete = function(summary) cached_complete = summary end,
}))
cached_page.drain_scheduler()
expect(cached_page.cache.can_store_calls[1] == GB and cached_complete.cached == 1
    and cached_complete.downloaded == 1,
    "preflight must count only missing known-size pages")
expect(cached_page.download_calls() == 1 and cached_page.publish_calls() == 1,
    "cached pages must be skipped after the complete scan")

local hard_limit = fixture{
    first_size = nil, second_size = nil, actual_size = GB,
    can_store = function(required)
        if required == GB then
            return false, "offline_limit", {
                code = "offline_limit", used_bytes = 4 * GB,
                required_bytes = GB, limit_bytes = 5 * GB,
            }
        end
        return true
    end,
}
local hard_complete
assert(hard_limit.manager:start(hard_limit.manga, {
    on_complete = function(summary) hard_complete = summary end,
}))
hard_limit.drain_scheduler()
expect(hard_limit.download_calls() == 1 and hard_limit.publish_calls() == 0
    and hard_complete.status == "limit" and hard_complete.detail.code == "offline_limit",
    "an unknown-size page must stop at the actual-size hard limit before publish")
expect(hard_limit.cache.discarded["/offline/offline1.part"]
    and hard_limit.cache.discarded["/offline/offline1.denoise.part"],
    "quota rejection must discard both owned part paths")
local seen = {}
for _, summary in ipairs(hard_limit.statuses) do seen[summary.status] = true end
expect(seen.scanning and seen.running and seen.limit and hard_limit.peak_events() <= 1,
    "injected status must receive scanning, progress, and terminal states without a timer")

print(("rebuild_0356_offline_quota_spec: %d checks"):format(checks))
