local OfflineManager = require("webdavmanga.offline_manager")

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

local events = {}
local function schedule(callback) events[#events + 1] = callback end
local function drain(limit)
    local count = 0
    while #events > 0 do
        count = count + 1
        if count > (limit or 500) then error("event loop did not settle") end
        table.remove(events, 1)()
    end
end

local manga = { name = "漫画", path = "/Books/漫画", is_folder = true }
local chapter1 = { name = "第1话", path = manga.path .. "/第1话", is_folder = true }
local chapter2 = { name = "第2话", path = manga.path .. "/第2话", is_folder = true }
local image1 = { name = "001.jpg", path = chapter1.path .. "/001.jpg", size = 100 }
local image2 = { name = "002.webp", path = chapter1.path .. "/002.webp", size = 200 }
local image3 = { name = "001.png", path = chapter2.path .. "/001.png", size = 300 }

local directories = {
    [manga.path] = { folders = function() return index({ chapter1, chapter2 }) end,
        images = function() return index({}) end, close = function() end },
    [chapter1.path] = { folders = function() return index({}) end,
        images = function() return index({ image1, image2 }) end, close = function() end },
    [chapter2.path] = { folders = function() return index({}) end,
        images = function() return index({ image3 }) end, close = function() end },
}
local directory_store = {
    load = function(_self, path, callbacks)
        local canceled = false
        schedule(function()
            if not canceled then callbacks.on_ready(directories[path]) end
        end)
        return { cancel = function() canceled = true end }
    end,
    cancel_all = function() end,
}

local active_workers, peak_workers = 0, 0
local async = {
    run = function(work, callback, options)
        local canceled = false
        schedule(function()
            if canceled then
                if options and options.on_cancelled then options.on_cancelled() end
                return
            end
            active_workers = active_workers + 1
            peak_workers = math.max(peak_workers, active_workers)
            local ok, result = pcall(work)
            active_workers = active_workers - 1
            callback(ok, result, ok and nil or result, {})
        end)
        return { cancel = function() canceled = true end }
    end,
}

local downloaded, published, denoised = {}, {}, {}
local cached = { [image2.path] = "/offline/existing.webp" }
local can_store_calls = 0
local offline_cache = {
    can_store = function()
        can_store_calls = can_store_calls + 1
        return true
    end,
    lookup = function(_self, _identity, path) return cached[path] end,
    enrich = function() return {} end,
    plan = function(_self, _identity, _manga, _chapter, image, wants_denoise, token)
        local suffix = wants_denoise and ".denoise.png" or ".raw"
        return { key = image.path, remote_path = image.path,
            final_path = "/offline/" .. image.name .. suffix,
            part_path = "/offline/" .. token .. ".part",
            denoise_path = "/offline/" .. token .. ".denoise.part",
            denoised = wants_denoise }
    end,
    publish = function(_self, plan, part_path, metadata, applied)
        published[#published + 1] = {
            path = plan.remote_path, part = part_path, applied = applied,
            format = metadata.format,
        }
        cached[plan.remote_path] = plan.final_path
        return plan.final_path
    end,
    discard_part = function() end,
}
local client = {
    download = function(_self, path)
        downloaded[#downloaded + 1] = path
        return { size = 100, format = "jpeg", width = 1200, height = 1600 }
    end,
}
local denoise = {
    process = function(input, output)
        denoised[#denoised + 1] = { input, output }
        return { applied = true, extension = "png" }
    end,
}
local completed
local manager = OfflineManager:new{
    directory_store = directory_store,
    offline_cache = offline_cache,
    client_factory = function() return client end,
    connection_provider = function() return { root_path = "/Books" } end,
    identity_provider = function() return "source-a" end,
    denoise = denoise,
    denoise_enabled_provider = function() return true end,
    async = async,
    scheduler = schedule,
}
assert(manager:start(manga, { on_complete = function(summary) completed = summary end }))
drain()
expect(completed and completed.status == "complete" and completed.total == 3
    and completed.downloaded == 2 and completed.cached == 1,
    "chapter traversal must finish with exact cached and downloaded counts")
expect(downloaded[1] == image1.path and downloaded[2] == image3.path
    and #downloaded == 2,
    "chapter pages must download serially in directory order and skip existing pages")
expect(peak_workers == 1 and #denoised == 2 and #published == 2
    and published[1].applied == true,
    "only one download or denoise worker may run at once")
expect(manager:status().running == false,
    "completed tasks must not remain active")

events, downloaded, published, denoised, cached = {}, {}, {}, {}, {}
local checks_before_stop = 0
offline_cache.can_store = function()
    checks_before_stop = checks_before_stop + 1
    return checks_before_stop <= 2, "reserve_space"
end
local stopped
assert(manager:start(manga, { on_complete = function(summary) stopped = summary end }))
drain()
expect(stopped and stopped.status == "space" and stopped.downloaded == 1
    and #downloaded == 1,
    "the task must stop cleanly as soon as the 1 GB space check fails")

events, downloaded = {}, {}
offline_cache.can_store = function() return true end
local handle = assert(manager:start(manga))
handle:cancel()
drain()
expect(#downloaded == 0 and manager:status().running == false,
    "canceling before the first listing must prevent every download")

events = {}
local silent_completed = false
assert(manager:start(manga, { on_complete = function()
    silent_completed = true
end }))
expect(manager:cancel_all() == true and manager:status().status == "canceled"
    and silent_completed == false,
    "plugin teardown must silently cancel the whole-manga task")

print(("offline_manager_spec: %d checks"):format(checks))
