local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local PreparedPages = require("webdavmanga.prepared_pages")

local records, discarded = {}, {}
local cache = {
    key_for = function(_, identity, path) return identity .. "|" .. path end,
    lookup = function(_, key)
        local record = records[key]
        return record and record.path, record
    end,
    paths_for = function(_, key) return "/cache/" .. key .. ".png", "/part/" .. key end,
    publish = function(_, record, part)
        local path = "/cache/" .. record.key .. ".png"
        record.path, record.size = path, 100
        records[record.key] = record
        return path
    end,
    discard_part = function(_, key) discarded[#discarded + 1] = key end,
}

local raw_requests, raw_prefetches = {}, {}
local loader = { identity = "source" }
function loader:request(generation, image, callbacks)
    raw_requests[#raw_requests + 1] = image.path
    callbacks.on_ready("/raw" .. image.path, true, {
        format = "jpeg", width = image.width or 900, height = image.height or 1200,
    })
end
function loader:prefetch(generation, images, current_index, on_ready)
    for index = current_index + 1, #images do
        raw_prefetches[#raw_prefetches + 1] = images[index].path
        on_ready(images[index], "/raw" .. images[index].path, true, {
            format = "jpeg", width = images[index].width or 900,
            height = images[index].height or 1200,
        })
    end
end
local loader_generation_cancels = 0
function loader:cancel_generation() loader_generation_cancels = loader_generation_cancels + 1 end
function loader:cancel_all() end

local pending, active_workers, peak_workers = {}, 0, 0
local async = {}
function async.run(work, done, options)
    active_workers = active_workers + 1
    peak_workers = math.max(peak_workers, active_workers)
    local task = { work = work, done = done, options = options, canceled = false }
    function task:cancel()
        if self.canceled then return end
        self.canceled = true
        active_workers = active_workers - 1
        if self.options.on_cancelled then self.options.on_cancelled() end
    end
    function task:complete(ok)
        if self.canceled then return end
        active_workers = active_workers - 1
        local result = self.work()
        self.done(ok ~= false, result, ok == false and "worker_failed" or nil)
    end
    pending[#pending + 1] = task
    return task
end

local process_fail = false
local processor = {
    process = function(raw_path, part_path, profile)
        if process_fail then return nil, "process_failed" end
        return {
            format = "png", width = profile.target_width,
            height = profile.target_height, size = 100,
        }
    end,
}

local pages = PreparedPages:new{
    loader = loader, cache = cache, async = async, page_processor = processor,
}
local image = { path = "/001.jpg", width = 1000, height = 1400 }
local profile = { id = "profile-a", target_width = 1000, target_height = 1400, lut = {} }

local off_path
pages:request(1, image, nil, { on_ready = function(path) off_path = path end })
expect(off_path == "/raw/001.jpg" and #pending == 0,
    "disabled processing must delegate directly to the unchanged Loader path")

local processed_path, processed_metadata
pages:request(1, image, profile, {
    on_ready = function(path, _, metadata)
        processed_path, processed_metadata = path, metadata
    end,
})
expect(processed_path == nil and #pending == 1 and active_workers == 1,
    "a cache miss must start one background processor")
pending[1]:complete()
expect(processed_path and processed_path:find("profile%-a"),
    "the foreground callback must receive the published derivative")
expect(processed_metadata and processed_metadata.prepared_key
    == pages:cache_key(image, profile),
    "prepared callbacks must identify the exact derivative cache record")

local request_count = #raw_requests
local cached_path
pages:request(1, image, profile, { on_ready = function(path) cached_path = path end })
expect(cached_path == processed_path and #raw_requests == request_count,
    "a derivative cache hit must not request or process the raw page again")
local optional_callback_ok = pcall(function()
    pages:request(1, image, profile, {})
end)
expect(optional_callback_ok,
    "a derivative cache hit must tolerate a canceled caller with no ready callback")

local images = {
    image,
    { path = "/002.jpg", width = 1000, height = 1400 },
    { path = "/003.jpg", width = 1000, height = 1400 },
}
pages:prefetch(2, images, 1, function() return profile end)
expect(active_workers == 1 and peak_workers == 1,
    "multiple downloaded neighbors must still use exactly one processor")
local first_prefetch_task = pending[#pending]
first_prefetch_task:complete()
local second_prefetch_task = pending[#pending]
expect(first_prefetch_task ~= second_prefetch_task,
    "prefetch neighbors must be represented by separate serial jobs")

local current_path
pages:request(2, { path = "/010.jpg", width = 1000, height = 1400 }, profile, {
    on_ready = function(path) current_path = path end,
})
expect(second_prefetch_task.canceled == true and active_workers == 1,
    "an unrelated active prefetch processor must yield to the current page")
local current_task = pending[#pending]
current_task:complete()
expect(current_path ~= nil and peak_workers == 1,
    "the current page must finish without overlapping processors")

process_fail = true
local fallback_path, fallback_metadata
pages:request(3, { path = "/bad.jpg", width = 1000, height = 1400 }, profile, {
    on_ready = function(path, _, metadata)
        fallback_path, fallback_metadata = path, metadata
    end,
})
pending[#pending]:complete()
expect(fallback_path == "/raw/bad.jpg"
    and fallback_metadata.processing_error == "process_failed",
    "processing failure must return the intact raw page with a typed diagnostic")

process_fail = false
pages:request(4, { path = "/cancel.jpg", width = 1000, height = 1400 }, profile, {})
local canceled_task = pending[#pending]
pages:cancel_generation(4)
expect(canceled_task.canceled == true and #discarded > 0,
    "generation cancellation must terminate work and discard its temporary file")

local deferred_image = { path = "/unknown.jpg" }
local deferred_profile_seen, deferred_path
pages:request(5, deferred_image, function(ready_image)
    deferred_profile_seen = ready_image.width == 900 and ready_image.height == 1200
    return profile
end, { on_ready = function(path) deferred_path = path end })
pending[#pending]:complete()
expect(deferred_profile_seen and deferred_path ~= nil
    and deferred_image.width == 900 and deferred_image.height == 1200,
    "pages without directory dimensions must build their profile after raw metadata arrives")

local prefetch_profile_ready = false
local unknown_prefetch = {
    { path = "/known.jpg", width = 900, height = 1200 },
    { path = "/unknown-prefetch.jpg" },
}
pages:prefetch(7, unknown_prefetch, 1, function(ready_image)
    expect(ready_image.width == 900 and ready_image.height == 1200,
        "prefetch profiles must use dimensions learned from the downloaded image")
    return profile
end, function(ready_image, ready_profile)
    prefetch_profile_ready = ready_image == unknown_prefetch[2]
        and ready_profile == profile
end)
expect(prefetch_profile_ready,
    "prefetch must notify the reader when a derivative cache key becomes knowable")
pending[#pending]:complete()

local restart_image = { path = "/restart.jpg", width = 900, height = 1200 }
pages:request(6, restart_image, profile, {})
local obsolete_task = pending[#pending]
pages:cancel_processing(6)
expect(obsolete_task.canceled == true and loader_generation_cancels == 1,
    "settings changes must cancel processing without canceling the Loader generation")
pages:request(6, restart_image, profile, {})
expect(pending[#pending] ~= obsolete_task and pending[#pending].canceled == false,
    "the same chapter generation must accept a fresh task after settings change")

print(("rebuild_0376_prepared_pages_spec: %d checks"):format(checks))
