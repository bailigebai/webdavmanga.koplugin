local PreparedPages = {}
PreparedPages.__index = PreparedPages

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

function PreparedPages:new(options)
    options = options or {}
    return setmetatable({
        loader = assert(options.loader, "loader is required"),
        cache = assert(options.cache, "cache is required"),
        async = assert(options.async, "async runner is required"),
        page_processor = options.page_processor or require("webdavmanga.page_processor"),
        queue = {}, active = nil, sequence = 0, canceled = {}, epochs = {},
    }, self)
end

function PreparedPages:cache_key(image, profile)
    return self.cache:key_for(self.loader.identity,
        tostring(image.path) .. "#prepared/" .. tostring(profile.id))
end

function PreparedPages:_deliver(job, path, cached, metadata)
    if self.canceled[job.generation] then return end
    for _, callbacks in ipairs(job.waiters) do
        if callbacks and callbacks.on_ready then callbacks.on_ready(path, cached, metadata) end
    end
end

function PreparedPages:_fallback(job, reason)
    local metadata = copy(job.raw_metadata)
    metadata.processing_error = reason
    self:_deliver(job, job.raw_path, job.raw_cached, metadata)
end

function PreparedPages:_discard(job)
    if self.cache.discard_part then
        self.cache:discard_part(job.key, "png", job.token)
    end
end

function PreparedPages:_finish_cancel(job)
    if self.active ~= job then return end
    self:_discard(job)
    self.active = nil
    self:_pump()
end

function PreparedPages:_pump()
    if self.active then return end
    local job = table.remove(self.queue, 1)
    while job and self.canceled[job.generation] do
        self:_discard(job)
        job = table.remove(self.queue, 1)
    end
    if not job then return end
    self.active = job
    local _final_path, part_path = self.cache:paths_for(job.key, "png", job.token)
    job.part_path = part_path
    local function canceled()
        self:_finish_cancel(job)
    end
    job.handle = self.async.run(function()
        local metadata, reason = self.page_processor.process(
            job.raw_path, part_path, job.profile)
        return { metadata = metadata, error = reason }
    end, function(ok, result, async_error)
        if self.active ~= job then return end
        self.active = nil
        if self.canceled[job.generation] then
            self:_discard(job)
        elseif not ok or type(result) ~= "table" or not result.metadata then
            self:_discard(job)
            self:_fallback(job, type(result) == "table" and result.error
                or async_error or "processing_failed")
        else
            local metadata = result.metadata
            metadata.prepared = true
            metadata.prepared_key = job.key
            local path, publish_error = self.cache:publish({
                key = job.key, kind = "page",
                remote_path = tostring(job.image.path) .. "#prepared/" .. job.profile.id,
                size = metadata.size, extension = "png", validated = true,
                format = "png", width = metadata.width, height = metadata.height,
                crop = metadata.crop,
                crop_checked = metadata.crop_checked, crop_reason = metadata.crop_reason,
                crop_processed = metadata.crop_checked,
            }, part_path)
            if path then self:_deliver(job, path, false, metadata)
            else self:_discard(job); self:_fallback(job, publish_error or "publish_failed") end
        end
        self:_pump()
    end, { timeout = 120, on_cancelled = canceled, on_reaped = canceled })
end

function PreparedPages:_enqueue(generation, image, profile, raw_path, raw_cached,
    raw_metadata, callbacks, kind)
    local key = self:cache_key(image, profile)
    local cached, metadata = self.cache:lookup(key)
    if cached then
        metadata = copy(metadata)
        metadata.prepared = true
        metadata.prepared_key = key
        local hit = { generation = generation, waiters = { callbacks } }
        return self:_deliver(hit, cached, true, metadata)
    end
    if self.active and self.active.key == key then
        local waiter_key = type(callbacks) == "table" and callbacks._waiter_key or nil
        if waiter_key then
            for _, waiter in ipairs(self.active.waiters) do
                if type(waiter) == "table" and waiter._waiter_key == waiter_key then return end
            end
        end
        self.active.waiters[#self.active.waiters + 1] = callbacks
        return
    end
    for index, queued in ipairs(self.queue) do
        if queued.key == key then
            local waiter_key = type(callbacks) == "table" and callbacks._waiter_key or nil
            if waiter_key then
                for _, waiter in ipairs(queued.waiters) do
                    if type(waiter) == "table" and waiter._waiter_key == waiter_key then return end
                end
            end
            queued.waiters[#queued.waiters + 1] = callbacks
            if kind == "current" and queued.kind ~= "current" then
                queued.kind = "current"
                table.remove(self.queue, index)
                table.insert(self.queue, 1, queued)
            end
            return
        end
    end
    self.sequence = self.sequence + 1
    local job = {
        generation = generation, image = image, profile = profile,
        raw_path = raw_path, raw_cached = raw_cached, raw_metadata = raw_metadata,
        key = key, token = "prepared-" .. tostring(self.sequence),
        waiters = { callbacks }, kind = kind,
    }
    if kind == "current" then table.insert(self.queue, 1, job)
    else table.insert(self.queue, job) end
    if kind == "current" and self.active and self.active.kind == "prefetch"
        and self.active.key ~= key then
        self.active.canceled = true
        if self.active.handle and self.active.handle.cancel then self.active.handle:cancel() end
    else
        self:_pump()
    end
end

function PreparedPages:request(generation, image, profile, callbacks)
    callbacks = callbacks or {}
    if not profile then return self.loader:request(generation, image, callbacks) end
    self.canceled[generation] = nil
    local epoch = self.epochs[generation] or 0
    if type(profile) == "table" then
        local key = self:cache_key(image, profile)
        local cached, metadata = self.cache:lookup(key)
        if cached then
            metadata = copy(metadata)
            metadata.prepared = true
            metadata.prepared_key = key
            if callbacks.on_ready then callbacks.on_ready(cached, true, metadata) end
            return
        end
    end
    return self.loader:request(generation, image, {
        on_ready = function(path, cached_raw, raw_metadata)
            if self.canceled[generation]
                or (self.epochs[generation] or 0) ~= epoch then return end
            raw_metadata = raw_metadata or {}
            image.width = tonumber(raw_metadata.width) or image.width
            image.height = tonumber(raw_metadata.height) or image.height
            local resolved = type(profile) == "function" and profile(image) or profile
            if not resolved then
                if callbacks.on_ready then callbacks.on_ready(path, cached_raw, raw_metadata) end
                return
            end
            self:_enqueue(generation, image, resolved, path, cached_raw,
                raw_metadata, callbacks, "current")
        end,
        on_error = callbacks.on_error,
    })
end

function PreparedPages:prefetch(generation, images, current_index, profile_provider,
    on_profile_ready, on_processed, transient_count, opening_warmup)
    self.canceled[generation] = nil
    local epoch = self.epochs[generation] or 0
    return self.loader:prefetch(generation, images, current_index,
        function(image, path, cached, metadata)
            if self.canceled[generation]
                or (self.epochs[generation] or 0) ~= epoch then return end
            metadata = metadata or {}
            image.width = tonumber(metadata.width) or image.width
            image.height = tonumber(metadata.height) or image.height
            local profile = profile_provider and profile_provider(image)
            if profile then
                if on_profile_ready then on_profile_ready(image, profile) end
                local callbacks
                if on_processed then
                    callbacks = {
                        on_ready = function(path, cached, ready_metadata)
                            on_processed(image, path, cached, ready_metadata)
                        end,
                    }
                    if opening_warmup then
                        callbacks._waiter_key = "opening_warmup:" .. tostring(generation)
                    end
                end
                self:_enqueue(generation, image, profile, path, cached,
                    metadata, callbacks, "prefetch")
            end
        end, transient_count, opening_warmup)
end

function PreparedPages:cancel_processing(generation)
    self.epochs[generation] = (self.epochs[generation] or 0) + 1
    for index = #self.queue, 1, -1 do
        if self.queue[index].generation == generation then
            self:_discard(self.queue[index])
            table.remove(self.queue, index)
        end
    end
    if self.active and self.active.generation == generation then
        if self.active.handle and self.active.handle.cancel then self.active.handle:cancel()
        else self:_finish_cancel(self.active) end
    end
end

function PreparedPages:cancel_generation(generation)
    self.canceled[generation] = true
    self:cancel_processing(generation)
    if self.loader.cancel_generation then self.loader:cancel_generation(generation) end
end

function PreparedPages:cancel_all()
    if self.loader.cancel_all then self.loader:cancel_all() end
    for _, job in ipairs(self.queue) do self:_discard(job) end
    self.queue = {}
    if self.active then
        if self.active.handle and self.active.handle.cancel then self.active.handle:cancel()
        else self:_finish_cancel(self.active) end
    end
end

return PreparedPages
