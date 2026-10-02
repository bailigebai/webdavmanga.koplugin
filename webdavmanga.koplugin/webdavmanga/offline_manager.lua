local Denoise = require("webdavmanga.denoise")

local OfflineManager = {}
OfflineManager.__index = OfflineManager

local function copy_table(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function directory_index(directory, name)
    if type(directory) ~= "table" then return nil end
    local value = directory[name]
    return type(value) == "function" and value(directory) or value
end

local function copy_index(index)
    local result = {}
    local count = math.max(0, math.floor(tonumber(index and index:count()) or 0))
    for position = 1, count do
        local item = index:get(position)
        if type(item) == "table" and type(item.path) == "string" then
            result[#result + 1] = copy_table(item)
        end
    end
    return result
end

local function default_scheduler(callback)
    local ok, manager = pcall(require, "ui/uimanager")
    if ok and type(manager.scheduleIn) == "function" then
        return manager:scheduleIn(0, callback)
    end
    callback()
    return true
end

function OfflineManager:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.directory_store = assert(options.directory_store, "directory store is required")
    object.offline_cache = assert(options.offline_cache, "offline cache is required")
    object.client_factory = assert(options.client_factory, "client factory is required")
    object.connection_provider = assert(options.connection_provider, "connection provider is required")
    object.identity_provider = assert(options.identity_provider, "identity provider is required")
    object.denoise = options.denoise or Denoise
    object.denoise_enabled_provider = options.denoise_enabled_provider or function() return false end
    object.async = assert(options.async, "async runner is required")
    object.scheduler = options.scheduler or default_scheduler
    object.on_status = options.on_status
    object.sequence = 0
    object.active = nil
    object.last_summary = { running = false, status = "idle", total = 0,
        downloaded = 0, cached = 0, failed = 0 }
    return object
end

function OfflineManager:_is_active(task)
    if self.active ~= task or task.canceled == true or task.finished == true then return false end
    if task.root and self.offline_cache:root() ~= task.root then
        self:_finish(task, "canceled", "offline_root_changed")
        return false
    end
    return true
end

function OfflineManager:_schedule(task, callback)
    local function guarded()
        if self:_is_active(task) then callback() end
    end
    local ok, result
    if type(self.scheduler) == "function" then
        ok, result = pcall(self.scheduler, guarded)
    elseif self.scheduler and type(self.scheduler.scheduleIn) == "function" then
        ok, result = pcall(self.scheduler.scheduleIn, self.scheduler, 0, guarded)
    end
    if not ok or result == false or (type(self.scheduler) ~= "function"
        and not (self.scheduler and type(self.scheduler.scheduleIn) == "function")) then
        guarded()
    end
end

function OfflineManager:_notify_progress(task)
    if type(task.callbacks.on_progress) == "function" then
        pcall(task.callbacks.on_progress, copy_table(task.summary))
    end
    if type(self.on_status) == "function" then
        pcall(self.on_status, copy_table(task.summary))
    end
end

function OfflineManager:_save_job(task)
    if type(self.offline_cache.save_job) ~= "function" then return end
    local detail = task.summary.detail
    pcall(self.offline_cache.save_job, self.offline_cache, task.identity, task.manga, {
        status = task.summary.status,
        total_pages = task.summary.total,
        total_bytes = task.summary.total_bytes,
        cached_pages = task.summary.cached + task.summary.downloaded,
        cached_bytes = task.summary.cached_bytes + task.summary.downloaded_bytes,
        downloaded = task.summary.downloaded,
        failed = task.summary.failed,
        error_code = type(detail) == "table" and detail.code or detail,
        detail_code = type(detail) == "table" and detail.code or nil,
        detail_used_bytes = type(detail) == "table" and detail.used_bytes or nil,
        detail_required_bytes = type(detail) == "table" and detail.required_bytes or nil,
        detail_limit_bytes = type(detail) == "table" and detail.limit_bytes or nil,
    }, task.root)
end

function OfflineManager:_finish(task, status, detail, silent)
    if task.finished then return false end
    task.finished = true
    task.summary.running = false
    task.summary.status = status
    task.summary.detail = detail
    if task.directory_handle and task.directory_handle.cancel then
        pcall(task.directory_handle.cancel, task.directory_handle)
    end
    if task.worker_handle and task.worker_handle.cancel then
        pcall(task.worker_handle.cancel, task.worker_handle)
    end
    task.directory_handle = nil
    task.worker_handle = nil
    if task.plan then self.offline_cache:discard_part(task.plan) end
    task.plan = nil
    if self.active == task then self.active = nil end
    self:_save_job(task)
    self.last_summary = copy_table(task.summary)
    if not silent then self:_notify_progress(task) end
    if not silent and type(task.callbacks.on_complete) == "function" then
        pcall(task.callbacks.on_complete, copy_table(task.summary))
    end
    return true
end

function OfflineManager:_load_directory(task, path, on_ready, on_error)
    if not self:_is_active(task) then return end
    local settled = false
    local handle
    local callbacks = {
        on_ready = function(directory)
            settled = true
            if not self:_is_active(task) then
                if directory and directory.close then pcall(directory.close, directory) end
                return
            end
            task.directory_handle = nil
            on_ready(directory)
        end,
        on_error = function(err)
            settled = true
            if not self:_is_active(task) then return end
            task.directory_handle = nil
            on_error(err)
        end,
    }
    local ok, result = pcall(self.directory_store.load,
        self.directory_store, path, callbacks)
    if not ok then return on_error(result) end
    handle = result
    if not settled and self:_is_active(task) then task.directory_handle = handle end
end

function OfflineManager:_advance_image(task)
    task.image_position = task.image_position + 1
    self:_notify_progress(task)
    self:_schedule(task, function() self:_process_image(task) end)
end

function OfflineManager:_download_image(task, chapter, image)
    local wants_denoise = task.denoise_enabled == true
    local plan, plan_error = self.offline_cache:plan(task.identity,
        task.manga, chapter, image, wants_denoise, task.token)
    if not plan then
        task.summary.failed = task.summary.failed + 1
        task.summary.last_error = plan_error
        return self:_advance_image(task)
    end
    task.plan = plan
    local client_factory, denoise = self.client_factory, self.denoise
    local handle = self.async.run(function()
        local client = client_factory(task.connection)
        local metadata, download_error = client:download(image.path, plan.part_path)
        if not metadata then return { error = download_error } end
        if wants_denoise then
            local filtered, filter_error = denoise.process(plan.part_path, plan.denoise_path)
            if filtered and filtered.applied then
                return { metadata = metadata, applied = true,
                    publish_path = plan.denoise_path }
            end
            return { metadata = metadata, applied = false,
                publish_path = plan.part_path, denoise_error = tostring(filter_error or "denoise_failed") }
        end
        return { metadata = metadata, applied = false, publish_path = plan.part_path }
    end, function(ok, result, async_error)
        if not self:_is_active(task) or task.plan ~= plan then return end
        task.worker_handle = nil
        task.plan = nil
        if not ok or type(result) ~= "table" or result.error then
            self.offline_cache:discard_part(plan)
            task.summary.failed = task.summary.failed + 1
            task.summary.last_error = result and result.error or async_error
            return self:_advance_image(task)
        end
        local metadata = copy_table(result.metadata)
        local actual_size = math.max(0, tonumber(metadata.size) or tonumber(image.size) or 0)
        local enough, space_error, detail = self.offline_cache:can_store(actual_size)
        if not enough then
            self.offline_cache:discard_part(plan)
            return self:_finish(task,
                space_error == "offline_limit" and "limit"
                    or (space_error == "reserve_space" and "space" or "error"),
                detail or space_error)
        end
        if result.applied then metadata.format = "png" end
        local published, publish_error = self.offline_cache:publish(plan,
            result.publish_path, metadata, result.applied == true)
        self.offline_cache:discard_part(plan)
        if not published then
            if publish_error == "reserve_space" then
                return self:_finish(task, "space", publish_error)
            end
            task.summary.failed = task.summary.failed + 1
            task.summary.last_error = publish_error
        else
            task.summary.downloaded = task.summary.downloaded + 1
            task.summary.downloaded_bytes = task.summary.downloaded_bytes + actual_size
            if wants_denoise and not result.applied then
                task.summary.denoise_failed = (task.summary.denoise_failed or 0) + 1
            elseif result.applied then
                task.summary.denoised = (task.summary.denoised or 0) + 1
            end
        end
        self:_advance_image(task)
    end, {
        timeout = 180,
        on_cancelled = function() self.offline_cache:discard_part(plan) end,
        on_reaped = function() self.offline_cache:discard_part(plan) end,
    })
    task.worker_handle = handle
end

function OfflineManager:_process_image(task)
    if not self:_is_active(task) then return end
    local image = task.images and task.images[task.image_position]
    if not image then
        task.images = nil
        return self:_schedule(task, function() self:_next_batch(task) end)
    end
    if image.offline_cached then
        return self:_advance_image(task)
    end
    local known_size = math.max(0, tonumber(image.size) or 0)
    if known_size > 0 and (task.summary.cached > 0 or task.summary.downloaded > 0) then
        local enough, space_error, detail = self.offline_cache:can_store(known_size)
        if not enough then
            return self:_finish(task,
                space_error == "offline_limit" and "limit"
                    or (space_error == "reserve_space" and "space" or "error"),
                detail or space_error)
        end
    end
    self:_download_image(task, task.current_chapter, image)
end

function OfflineManager:_start_batch(task, chapter, images)
    task.current_chapter = chapter
    task.images = images
    task.image_position = 1
    self:_schedule(task, function() self:_process_image(task) end)
end

function OfflineManager:_next_batch(task)
    if not self:_is_active(task) then return end
    task.batch_position = task.batch_position + 1
    local batch = task.chapter_batches[task.batch_position]
    local chapter = batch and batch.chapter
    if not chapter then return self:_finish(task, "complete") end
    self:_start_batch(task, chapter, batch.images)
end

function OfflineManager:_begin_downloads(task)
    local missing_bytes = 0
    for _, batch in ipairs(task.chapter_batches) do
        for _, image in ipairs(batch.images) do
            task.summary.total = task.summary.total + 1
            task.summary.total_bytes = task.summary.total_bytes
                + math.max(0, tonumber(image.size) or 0)
            local cached, record = self.offline_cache:lookup(task.identity, image.path)
            if cached then
                local ok, enriched, enrich_error = pcall(self.offline_cache.enrich,
                    self.offline_cache, task.identity, image.path, {
                        manga_path = task.manga.path, manga_name = task.manga.name,
                        chapter_path = batch.chapter.path, chapter_name = batch.chapter.name,
                        chapter_position = batch.chapter.offline_position,
                        page_position = image.offline_position, image_name = image.name,
                    })
                if not ok or not enriched then
                    task.summary.failed = task.summary.failed + 1
                    return self:_finish(task, "error",
                        ok and enrich_error or "cache_enrichment_failed")
                end
                record = enriched
                image.offline_cached = true
                task.summary.cached = task.summary.cached + 1
                task.summary.cached_bytes = task.summary.cached_bytes
                    + math.max(0, tonumber(record and record.size) or tonumber(image.size) or 0)
            else
                missing_bytes = missing_bytes + math.max(0, tonumber(image.size) or 0)
            end
        end
    end
    local enough, space_error, detail = self.offline_cache:can_store(missing_bytes)
    if not enough then
        return self:_finish(task,
            space_error == "offline_limit" and "limit"
                or (space_error == "reserve_space" and "space" or "error"),
            detail or space_error)
    end
    task.summary.status = "running"
    self:_save_job(task)
    self:_notify_progress(task)
    task.batch_position = 0
    self:_next_batch(task)
end

function OfflineManager:_scan_next_chapter(task)
    if not self:_is_active(task) then return end
    task.scan_position = task.scan_position + 1
    local chapter = task.chapters[task.scan_position]
    if not chapter then return self:_begin_downloads(task) end
    chapter.offline_position = task.scan_position
    self:_load_directory(task, chapter.path, function(directory)
        local images = copy_index(directory_index(directory, "images"))
        if directory and directory.close then pcall(directory.close, directory) end
        for position, image in ipairs(images) do image.offline_position = position end
        task.chapter_batches[#task.chapter_batches + 1] = { chapter = chapter, images = images }
        self:_schedule(task, function() self:_scan_next_chapter(task) end)
    end, function(err)
        task.summary.failed = task.summary.failed + 1
        task.summary.last_error = err
        self:_schedule(task, function() self:_scan_next_chapter(task) end)
    end)
end

function OfflineManager:_discover(task)
    self:_load_directory(task, task.manga.path, function(directory)
        local images = copy_index(directory_index(directory, "images"))
        local chapters = copy_index(directory_index(directory, "folders"))
        if directory and directory.close then pcall(directory.close, directory) end
        if #images > 0 then
            local chapter = copy_table(task.manga)
            chapter.direct_images = true
            chapter.offline_position = 1
            for position, image in ipairs(images) do image.offline_position = position end
            task.chapter_batches[#task.chapter_batches + 1] = { chapter = chapter, images = images }
            return self:_begin_downloads(task)
        end
        task.chapters = chapters
        if #chapters == 0 then return self:_finish(task, "empty") end
        self:_schedule(task, function() self:_scan_next_chapter(task) end)
    end, function(err)
        self:_finish(task, "error", err)
    end)
end

function OfflineManager:start(manga, callbacks)
    if self.active then return nil, "busy" end
    if type(manga) ~= "table" or type(manga.path) ~= "string" then
        return nil, "invalid_manga"
    end
    local connection_ok, connection = pcall(self.connection_provider)
    local identity_ok, identity = pcall(self.identity_provider)
    if not connection_ok or not connection or not identity_ok then
        return nil, "missing_connection"
    end
    self.sequence = self.sequence + 1
    local task = {
        token = "offline" .. tostring(self.sequence), manga = copy_table(manga),
        connection = copy_table(connection), identity = tostring(identity or ""),
        root = type(self.offline_cache.root) == "function" and self.offline_cache:root() or nil,
        callbacks = callbacks or {}, canceled = false, finished = false,
        denoise_enabled = self.denoise_enabled_provider() == true,
        chapter_batches = {}, scan_position = 0,
        summary = { running = true, status = "scanning", total = 0,
            total_bytes = 0, downloaded = 0, downloaded_bytes = 0,
            cached = 0, cached_bytes = 0, failed = 0,
            identity = tostring(identity or ""), manga_path = manga.path,
            manga = copy_table(manga), manga_name = manga.name },
    }
    task.summary.root = task.root
    self.active = task
    self.last_summary = copy_table(task.summary)
    local handle = {}
    handle.cancel = function(_handle)
        if task.finished then return true end
        task.canceled = true
        return self:_finish(task, "canceled")
    end
    task.public_handle = handle
    self:_save_job(task)
    self:_notify_progress(task)
    self:_discover(task)
    return handle
end

function OfflineManager:cancel(silent)
    local task = self.active
    if not task then return false end
    task.canceled = true
    return self:_finish(task, "canceled", nil, silent == true)
end

function OfflineManager:cancel_all()
    return self:cancel(true)
end

function OfflineManager:status()
    if self.active then return copy_table(self.active.summary) end
    return copy_table(self.last_summary)
end

return OfflineManager
