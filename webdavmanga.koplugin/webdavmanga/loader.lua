local Errors = require("webdavmanga.errors")
local ErrorReporter = require("webdavmanga.error_reporter")
local Formats = require("webdavmanga.image_formats")
local MobiPages = require("webdavmanga.mobi_pages")
local RemoteStream = require("webdavmanga.remote_stream")
local ArchivePages = require("webdavmanga.archive_pages")
local MupdfPages = require("webdavmanga.mupdf_pages")
local PdfImageStream = require("webdavmanga.pdf_image_stream")
local ImageProbe = require("webdavmanga.image_probe")

local Loader = {}
Loader.__index = Loader

local priority = { page = 1, cover = 2, prefetch = 3 }
local MOBI_PAGE_BLOCK_SIZE = 256 * 1024

local function connection_snapshot(client)
    if type(client) ~= "table" or type(client.connection) ~= "table" then return nil end
    local copy = {}
    for key, value in pairs(client.connection) do copy[key] = value end
    return copy
end

function Loader:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.client_factory = assert(options.client_factory, "client factory is required")
    object.cache = assert(options.cache, "cache is required")
    object.async = assert(options.async, "async runner is required")
    object.error_reporter = options.error_reporter or ErrorReporter:new{ logger = options.logger }
    object.identity = tostring(options.identity or "")
    object.source_kind_provider = options.source_kind_provider
    object.offline_path_validator = options.offline_path_validator
    object.mobi_pages = options.mobi_pages or MobiPages:new()
    object.archive_pages = options.archive_pages or ArchivePages:new()
    object.mupdf_pages = options.mupdf_pages or MupdfPages:new()
    object.pdf_image_stream = options.pdf_image_stream or PdfImageStream:new()
    object.image_probe = options.image_probe or ImageProbe
    object.direct_local = options.direct_local == true
    object.validate_local_documents = options.validate_local_documents == true
    object.download_limit_provider = options.download_limit_provider
    object.prefetch_count = tonumber(options.prefetch_count) or 3
    object.prefetch_first_pages = tonumber(options.prefetch_first_pages)
    object.prefetch_near_count = tonumber(options.prefetch_near_count)
    object.prefetch_far_count = tonumber(options.prefetch_far_count)
    -- Keep direct Loader users backward-compatible; the plugin settings pass
    -- the user-facing default of two workers explicitly.
    object.prefetch_concurrency = math.max(1, math.min(3,
        math.floor(tonumber(options.prefetch_concurrency) or 1)))
    object.current_queue = {}
    object.cover_queue = {}
    object.prefetch_queue = {}
    object.jobs_by_key = {}
    object.canceled_generations = {}
    object.canceled_cover_generations = {}
    object.canceled_generation_order = {}
    object.canceled_cover_generation_order = {}
    object.cancellation_tombstone_limit = math.max(1,
        math.floor(tonumber(options.cancellation_tombstone_limit) or 128))
    object.active = nil
    object.prefetch_active = {}
    object.prefetch_active_count = 0
    object.job_sequence = 0
    object.transfer_sequence = 0
    object.instance_token = tostring(options.instance_token or {}):gsub("[^%w]", "")
    return object
end

function Loader:prefetch_count_for(index)
    local legacy = math.max(0, math.floor(tonumber(self.prefetch_count) or 0))
    local near = tonumber(self.prefetch_near_count)
    local far = tonumber(self.prefetch_far_count)
    if near == nil and far == nil then return legacy end
    if near == nil then near = legacy end
    if far == nil then far = near end
    near = math.max(0, math.floor(near))
    far = math.max(0, math.floor(far))
    local first_pages = math.max(1,
        math.floor(tonumber(self.prefetch_first_pages) or 10))
    local page = math.floor(tonumber(index) or 1)
    return page <= first_pages and near or far
end

function Loader:_uses_direct_local()
    if type(self.source_kind_provider) == "function" then
        local ok, kind = pcall(self.source_kind_provider)
        if ok then return kind == "local" end
        return false
    end
    return self.direct_local
end

function Loader:_remember_cancellation(values, order, generation)
    if values[generation] then return end
    values[generation] = true
    table.insert(order, generation)
    while #order > self.cancellation_tombstone_limit do
        values[table.remove(order, 1)] = nil
    end
end

function Loader:_cache_key(image, kind)
    return self.cache:key_for(self.identity, image.path,
        kind == "cover" and "cover" or nil)
end

function Loader:_exceeds_limit(image, kind)
    local known_size = tonumber(image and image.size)
    local limit
    if kind == "cover" then
        limit = tonumber(self.cache.cover_limit_bytes)
            or tonumber(self.cache.limit_bytes)
    else
        limit = tonumber(self.cache.limit_bytes)
    end
    return known_size ~= nil and limit ~= nil and known_size > limit
end

function Loader:_queue_for(kind)
    if kind == "page" then return self.current_queue end
    if kind == "cover" then return self.cover_queue end
    return self.prefetch_queue
end

function Loader:_new_job(generation, image, callbacks, kind)
    local key = self:_cache_key(image, kind)
    self.job_sequence = self.job_sequence + 1
    local job = {
        generation = generation,
        image = image,
        key = key,
        extension = Formats.extension(image.name) or "img",
        callbacks = callbacks,
        kind = kind,
        waiters = { {
            generation = generation,
            kind = kind,
            callbacks = callbacks,
        } },
        attempts = 0,
    }
    if image.archive_entry_name and not image.archive_local_path then
        local client_ok, client = pcall(self.client_factory)
        job.archive_connection = client_ok and connection_snapshot(client) or nil
        job.archive_connection_error = not client_ok or not job.archive_connection
    end
    if image.mupdf_remote_path then
        if type(image.mupdf_connection) == "table" then
            job.mupdf_connection = {}
            for key, value in pairs(image.mupdf_connection) do
                job.mupdf_connection[key] = value
            end
        else
            local client_ok, client = pcall(self.client_factory)
            job.mupdf_connection = client_ok and connection_snapshot(client) or nil
            job.mupdf_connection_error = not client_ok or not job.mupdf_connection
        end
    end
    if image.pdf_remote_path then
        if type(image.pdf_connection) == "table" then
            job.pdf_connection = {}
            for key, value in pairs(image.pdf_connection) do
                job.pdf_connection[key] = value
            end
        else
            local client_ok, client = pcall(self.client_factory)
            job.pdf_connection = client_ok and connection_snapshot(client) or nil
            job.pdf_connection_error = not client_ok or not job.pdf_connection
        end
    end
    return job
end

function Loader:_remove_from_queues(job)
    for _, queue in ipairs({ self.current_queue, self.cover_queue, self.prefetch_queue }) do
        for index = #queue, 1, -1 do
            if queue[index] == job then table.remove(queue, index) end
        end
    end
end

function Loader:_clear_active_job(job)
    if self.active == job then
        self.active = nil
        return true
    end
    if self.prefetch_active[job.key] == job then
        self.prefetch_active[job.key] = nil
        self.prefetch_active_count = math.max(0, self.prefetch_active_count - 1)
        return true
    end
    return false
end

function Loader:_is_active_job(job)
    return self.active == job or self.prefetch_active[job.key] == job
end

function Loader:_cancel_active_job(job)
    if not job then return false end
    local transfer = job.transfer
    local handle = transfer and transfer.handle or job.handle
    self:_clear_active_job(job)
    job.transfer = nil
    job.handle = nil
    if handle and handle.cancel then pcall(handle.cancel, handle) end
    return true
end

function Loader:_insert_job(job, first)
    local queue = self:_queue_for(job.kind)
    if first then table.insert(queue, 1, job) else table.insert(queue, job) end
end

function Loader:_recompute_kind(job)
    local best_kind
    for _, waiter in ipairs(job.waiters) do
        if not best_kind or priority[waiter.kind] < priority[best_kind] then
            best_kind = waiter.kind
        end
    end
    job.kind = best_kind
    if job.waiters[1] then
        job.generation = job.waiters[1].generation
        job.callbacks = job.waiters[1].callbacks
    end
    return best_kind
end

function Loader:_add_waiter(job, generation, kind, callbacks)
    local waiter_key = type(callbacks) == "table" and callbacks._waiter_key or nil
    for _, waiter in ipairs(job.waiters) do
        if waiter.generation == generation and waiter.kind == kind
            and (waiter.callbacks == callbacks or (waiter_key ~= nil
                and type(waiter.callbacks) == "table"
                and waiter.callbacks._waiter_key == waiter_key)) then return end
    end
    table.insert(job.waiters, {
        generation = generation,
        kind = kind,
        callbacks = callbacks,
    })
end

function Loader:_enqueue(generation, image, callbacks, kind, first)
    if image.offline_owned == true and type(image.local_path) == "string"
        and type(self.offline_path_validator) == "function"
        and self.offline_path_validator(image) == true then
        if callbacks and callbacks.on_ready then
            callbacks.on_ready(image.local_path, true, image)
        end
        return nil
    end
    local key = self:_cache_key(image, kind)
    local direct_local = self:_uses_direct_local()
    local cached, cached_metadata
    if not direct_local then cached, cached_metadata = self.cache:lookup(key) end
    if cached then
        if callbacks and callbacks.on_ready
            and not self.canceled_generations[generation]
            and not (kind == "cover" and self.canceled_cover_generations[generation]) then
            self.error_reporter:guard("download_page", function()
                return callbacks.on_ready(cached, true, cached_metadata)
            end, nil, nil, { silent = true })
        end
        return nil
    end

    local existing = self.jobs_by_key[key]
    if existing then
        local old_kind = existing.kind
        self:_add_waiter(existing, generation, kind, callbacks)
        self:_recompute_kind(existing)
        if not self:_is_active_job(existing) and old_kind ~= existing.kind then
            self:_remove_from_queues(existing)
            self:_insert_job(existing, first)
        elseif not self:_is_active_job(existing) and first then
            self:_remove_from_queues(existing)
            self:_insert_job(existing, true)
        end
        return existing
    end

    local job = self:_new_job(generation, image, callbacks, kind)
    self.jobs_by_key[key] = job
    self:_insert_job(job, first)
    self:_pump()
    return job
end

function Loader:_keep_only_cover_waiters(job)
    for index = #job.waiters, 1, -1 do
        if job.waiters[index].kind ~= "cover" then table.remove(job.waiters, index) end
    end
    return self:_recompute_kind(job) ~= nil
end

function Loader:_interrupt_active_except(key, keep_cover)
    local active = self.active
    if not active or active.key == key then return false end
    local transfer = active.transfer
    local handle = transfer and transfer.handle or active.handle
    if self.jobs_by_key[active.key] == active then self.jobs_by_key[active.key] = nil end
    self.active = nil
    active.transfer = nil
    active.handle = nil

    if keep_cover and self:_keep_only_cover_waiters(active) then
        active.attempts = math.max(0, active.attempts - 1)
        self.jobs_by_key[active.key] = active
        self:_insert_job(active, true)
    end
    if handle and handle.cancel then handle:cancel() end
    return true
end

function Loader:_remove_waiters(predicate, except_key)
    local jobs = {}
    for _, job in pairs(self.jobs_by_key) do jobs[#jobs + 1] = job end
    for _, job in ipairs(jobs) do
        if job.key ~= except_key then
            local old_kind = job.kind
            for index = #job.waiters, 1, -1 do
                if predicate(job.waiters[index], job) then table.remove(job.waiters, index) end
            end
            local new_kind = self:_recompute_kind(job)
            if not new_kind then
                if job == self.active or self.prefetch_active[job.key] == job then
                    self:_cancel_active_job(job)
                else
                    self:_remove_from_queues(job)
                end
                if self.jobs_by_key[job.key] == job then self.jobs_by_key[job.key] = nil end
            elseif not self:_is_active_job(job) and old_kind ~= new_kind then
                self:_remove_from_queues(job)
                self:_insert_job(job, false)
            end
        end
    end
end

function Loader:request(generation, image, callbacks)
    callbacks = callbacks or {}
    if not self:_uses_direct_local() and self:_exceeds_limit(image) then
        local err = Errors.storage("page_exceeds_cache_limit")
        if callbacks.on_error and not self.canceled_generations[generation] then
            self.error_reporter:guard("download_page", function()
                return callbacks.on_error(err)
            end, nil, nil, { silent = true })
        end
        return nil, err
    end

    local key = self:_cache_key(image)
    self:_interrupt_active_except(key, true)
    self:_remove_waiters(function(waiter)
        return waiter.kind == "page" and waiter.generation == generation
    end, key)
    local job = self:_enqueue(generation, image, callbacks, "page", true)
    self:_pump()
    return job
end

function Loader:request_cover(generation, image, callbacks)
    callbacks = callbacks or {}
    if not self:_uses_direct_local() and self:_exceeds_limit(image, "cover") then
        local err = Errors.storage("page_exceeds_cache_limit")
        if callbacks.on_error and not self.canceled_generations[generation]
            and not self.canceled_cover_generations[generation] then
            self.error_reporter:guard("load_cover", function()
                return callbacks.on_error(err)
            end, nil, nil, { silent = true })
        end
        return nil, err
    end

    local key = self:_cache_key(image, "cover")
    if self.prefetch_concurrency <= 1
        and self.active and self.active.kind == "prefetch"
        and self.active.key ~= key then
        self:_interrupt_active_except(key, false)
    end
    local job = self:_enqueue(generation, image, callbacks, "cover", false)
    self:_pump()
    return job
end

function Loader:prefetch(generation, images, current_index, on_ready,
    transient_count, opening_warmup)
    self:_remove_waiters(function(waiter, job)
        return waiter.kind == "prefetch" and waiter.generation == generation
            and not (job.opening_warmup_generations
                and job.opening_warmup_generations[generation])
    end, self.active and self.active.key or nil)
    local prefetch_count = transient_count == nil
        and self:prefetch_count_for(current_index)
        or math.max(0, math.floor(tonumber(transient_count) or 0))
    local local_index = current_index
    local first_index = type(images) == "table" and tonumber(images.first_index) or nil
    if first_index then local_index = current_index - first_index + 1 end
    local_index = math.max(0, math.floor(tonumber(local_index) or 0))
    local final_index = math.min(#images, local_index + prefetch_count)
    for index = local_index + 1, final_index do
        local image = images[index]
        if Formats.is_image(image.name)
            and (self:_uses_direct_local() or not self:_exceeds_limit(image)) then
            local callbacks
            if type(on_ready) == "function" then
                callbacks = { on_ready = function(path, cached, metadata)
                    return on_ready(image, path, cached, metadata)
                end }
                if opening_warmup then
                    callbacks._waiter_key = "opening_warmup:" .. tostring(generation)
                end
            end
            local job = self:_enqueue(generation, image, callbacks, "prefetch", false)
            if opening_warmup and job then
                job.opening_warmup_generations = job.opening_warmup_generations or {}
                job.opening_warmup_generations[generation] = true
            end
        end
    end
end

function Loader:_next_job()
    if #self.current_queue > 0 then return table.remove(self.current_queue, 1) end
    if #self.cover_queue > 0 then return table.remove(self.cover_queue, 1) end
    return table.remove(self.prefetch_queue, 1)
end

function Loader:_next_primary_job()
    if #self.current_queue > 0 then return table.remove(self.current_queue, 1) end
    if #self.cover_queue > 0 then return table.remove(self.cover_queue, 1) end
    return nil
end

function Loader:_is_current_transfer(job, transfer)
    return (self.active == job or self.prefetch_active[job.key] == job)
        and job.transfer == transfer
end

function Loader:_release_part(job, transfer)
    if not transfer or transfer.part_released then return end
    transfer.part_released = true
    if not transfer.part_path then return end
    if self.cache.discard_part then
        self.cache:discard_part(job.key, job.extension, transfer.token)
    end
end

function Loader:_finish_job(job, transfer, deliver, published, defer_part_release)
    if not self:_is_current_transfer(job, transfer) then return false end
    if not published and not defer_part_release then self:_release_part(job, transfer) end
    if self.jobs_by_key[job.key] == job then self.jobs_by_key[job.key] = nil end
    self:_clear_active_job(job)
    job.transfer = nil
    job.handle = nil
    if deliver then self.error_reporter:guard("download_page", deliver, nil, nil, { silent = true }) end
    self:_pump()
    return true
end

function Loader:_retry_storage(job, transfer, err)
    if not self:_is_current_transfer(job, transfer) then return false end
    local limit = math.max(0, tonumber(self.cache.limit_bytes) or 0)
    local total = self.cache.total_size and self.cache:total_size() or limit
    local reserve = math.min(limit, math.max(1, math.floor(limit * 0.05)))
    local required = math.max(0, limit - total) + reserve
    local freed = self.cache:evict(required, self.cache.protected_keys)
    if freed < reserve then
        self:_finish_job(job, transfer, function() self:_deliver_error(job, err) end)
        return false
    end
    self:_release_part(job, transfer)
    self:_clear_active_job(job)
    job.transfer = nil
    job.handle = nil
    self:_insert_job(job, true)
    self:_pump()
    return true
end

function Loader:_waiter_is_current(waiter)
    return not self.canceled_generations[waiter.generation]
        and not (waiter.kind == "cover"
            and self.canceled_cover_generations[waiter.generation])
end

function Loader:_deliver(job, method, first, second, third)
    for _, waiter in ipairs(job.waiters) do
        local callback = waiter.callbacks and waiter.callbacks[method]
        if callback and self:_waiter_is_current(waiter) then
            local stage = waiter.kind == "cover" and "load_cover" or "download_page"
            self.error_reporter:guard(stage, function()
                return callback(first, second, third)
            end, nil, nil, { silent = true })
        end
    end
end

function Loader:_deliver_error(job, err)
    self:_deliver(job, "on_error", err)
end

function Loader:_pump()
    if self.prefetch_concurrency <= 1 then
        if self.active then return end
        local serial
        if #self.current_queue > 0 or #self.cover_queue > 0 then
            serial = self:_next_primary_job()
        elseif self.prefetch_active_count == 0 then
            serial = self:_next_job()
        end
        if serial then self:_start_job(serial, "primary") end
        return
    end
    if not self.active then
        local primary = self:_next_primary_job()
        if primary then self:_start_job(primary, "primary") end
    end
    while self.prefetch_active_count < self.prefetch_concurrency
        and #self.prefetch_queue > 0 do
        local prefetch = table.remove(self.prefetch_queue, 1)
        self:_start_job(prefetch, "prefetch")
    end
end

function Loader:_start_job(job, slot)
    job.attempts = job.attempts + 1
    self.transfer_sequence = self.transfer_sequence + 1
    local transfer = {
        token = self.instance_token .. "t" .. tostring(self.transfer_sequence),
        attempt = job.attempts,
    }
    if slot == "prefetch" then
        self.prefetch_active[job.key] = job
        self.prefetch_active_count = self.prefetch_active_count + 1
    else
        self.active = job
    end
    job.transfer = transfer
    job.part_token = transfer.token
    local mobi_record = job.image and job.image.mobi_record
    local archive_entry = job.image and job.image.archive_entry_name
    local mupdf_page = job.image and tonumber(job.image.mupdf_page)
    local pdf_image = job.image and job.image.pdf_image == true
    local mobi_remote = mobi_record and type(job.image.mobi_remote_path) == "string"
        and job.image.mobi_remote_path ~= ""
    local direct_local = not mobi_record and not archive_entry and not mupdf_page
        and not pdf_image and self:_uses_direct_local()
    local part_path
    if not direct_local then
        local _final_path
        _final_path, part_path = self.cache:paths_for(job.key, job.extension, transfer.token)
    end
    transfer.part_path = part_path
    -- Non-archive jobs retain the existing start-time client binding. Archive
    -- jobs instead reuse the connection copied when the job entered a queue.
    local client_ok, bound_client = true, nil
    if not mobi_record and not archive_entry and not pdf_image then
        client_ok, bound_client = pcall(self.client_factory)
        if not mupdf_page and client_ok and bound_client and bound_client.direct == true then
            direct_local = true
        elseif not mupdf_page and client_ok and bound_client and bound_client.direct == false then
            direct_local = false
        end
    end
    local download_options
    if job.kind=="cover" and not direct_local and self.download_limit_provider then
        local limit=self.download_limit_provider(job.image,part_path)
        download_options={max_bytes=math.max(0,tonumber(limit) or 0)}
    end
    local handle = self.async.run(function()
        if download_options and download_options.max_bytes<1 then return {error=Errors.storage("cache_limit")} end
        if archive_entry then
            if job.image.archive_local_path then
                local metadata, extract_error = self.archive_pages:extract_local(job.image, part_path)
                if not metadata then return { error = Errors.image_decode(extract_error, "local") } end
                return { metadata = metadata }
            end
            if job.archive_connection_error then
                return { error = Errors.transport("ZIP client initialization failed") }
            end
            local worker_client_ok, worker_client = pcall(self.client_factory, job.archive_connection)
            if not worker_client_ok or not worker_client
                or type(worker_client.read_range) ~= "function" then
                return { error = Errors.transport("ZIP Range client unavailable") }
            end
            local stream = RemoteStream:new{
                size = job.image.archive_source_size,
                exact_reads = true,
                read_range = function(first, last)
                    return worker_client:read_range(job.image.archive_remote_path, first, last)
                end,
            }
            if not stream then
                return { error = Errors.image_decode("invalid_remote_zip_size", "remote") }
            end
            local metadata, extract_error = self.archive_pages:extract_remote(job.image,
                function(offset, count) return stream:read_at(offset, count) end, part_path)
            if not metadata then
                return { error = Errors.image_decode(extract_error, "remote") }
            end
            return { metadata = metadata }
        end
        if mobi_record then
            local metadata, extract_error
            local read_fn = job.image.remote_read_at
            local source_kind = "local"
            if mobi_remote then
                local worker_client_ok, worker_client = pcall(self.client_factory)
                if not worker_client_ok or not worker_client
                    or type(worker_client.read_range) ~= "function" then
                    return { error = Errors.transport("MOBI Range client unavailable") }
                end
                local source_size = tonumber(job.image.mobi_source_size)
                local stream = RemoteStream:new{
                    size = source_size,
                    read_range = function(first, last)
                        return worker_client:read_range(job.image.mobi_remote_path,
                            first, last)
                    end,
                    block_size = job.image.mobi_range_block_size
                        or MOBI_PAGE_BLOCK_SIZE,
                }
                if not stream then
                    return { error = Errors.image_decode("invalid_remote_mobi_size", "remote") }
                end
                read_fn = function(offset, count)
                    return stream:read_at(offset, count)
                end
                source_kind = "remote"
            end
            if type(read_fn) == "function" then
                metadata, extract_error = self.mobi_pages:extract_remote(
                    job.image, read_fn, part_path)
            else
                metadata, extract_error = self.mobi_pages:extract(job.image, part_path)
            end
            if not metadata then
                return { error = Errors.image_decode(extract_error, source_kind) }
            end
            return { metadata = metadata }
        end
        if pdf_image then
            local source_size = tonumber(job.image.pdf_source_size)
            local remote_path = job.image.pdf_remote_path
            if not source_size or source_size < 1 or type(remote_path) ~= "string"
                or remote_path == "" then
                return { error = Errors.image_decode("invalid_remote_pdf_size", "remote") }
            end
            if job.pdf_connection_error then
                return { error = Errors.transport("PDF Range client initialization failed") }
            end
            local worker_ok, worker = pcall(self.client_factory, job.pdf_connection)
            if not worker_ok or not worker or type(worker.read_range) ~= "function" then
                return { error = Errors.transport("PDF Range client unavailable") }
            end
            local offset, length = tonumber(job.image.pdf_image_offset), tonumber(job.image.pdf_image_length)
            local lazy_page = tonumber(job.image.pdf_page_object)
            local exact_range = offset and length and offset >= 0 and length >= 1
                and offset == math.floor(offset) and length == math.floor(length)
                and offset + length <= source_size
            if not exact_range and (not lazy_page or lazy_page < 1
                or lazy_page ~= math.floor(lazy_page)) then
                return { error = Errors.image_decode("invalid_remote_pdf_range", "remote") }
            end
            if not exact_range then
                local stream = RemoteStream:new{
                    size = source_size,
                    read_range = function(first, last)
                        return worker:read_range(remote_path, first, last)
                    end,
                }
                if not stream then
                    return { error = Errors.image_decode("invalid_remote_pdf_size", "remote") }
                end
                local metadata, extract_error = self.pdf_image_stream:extract_remote(
                    job.image, function(first, count) return stream:read_at(first, count) end,
                    part_path)
                if not metadata then
                    if extract_error == "pdf_image_write_failed" then
                        return { error = Errors.storage(extract_error) }
                    end
                    return { error = Errors.image_decode(extract_error or "pdf_image_invalid", "remote") }
                end
                return { metadata = metadata }
            end
            local stream = RemoteStream:new{
                size = source_size,
                exact_reads = true,
                read_range = function(first, last)
                    return worker:read_range(remote_path, first, last)
                end,
            }
            if not stream then return { error = Errors.image_decode("invalid_remote_pdf_size", "remote") } end
            local bytes, read_error = stream:read_at(offset, length)
            if type(bytes) ~= "string" or #bytes ~= length then
                return { error = Errors.image_decode(read_error or "pdf_image_range_failed", "remote") }
            end
            local file = io.open(part_path, "wb")
            if not file then return { error = Errors.storage("pdf_image_write_failed") } end
            local wrote, closed = file:write(bytes), file:close()
            if not wrote or not closed then pcall(os.remove, part_path); return { error = Errors.storage("pdf_image_write_failed") } end
            local metadata, probe_error = self.image_probe.inspect(part_path, "jpg")
            if not metadata then
                pcall(os.remove, part_path)
                return { error = Errors.image_decode(probe_error or "pdf_image_invalid", "remote") }
            end
            metadata.size = #bytes
            return { metadata = metadata }
        end
        if mupdf_page then
            local source_size = tonumber(job.image.mupdf_source_size or job.image.size)
            local remote_path = job.image.mupdf_remote_path
            local metadata, render_error
            if type(remote_path) == "string" and remote_path ~= "" then
                local worker_ok, worker = pcall(self.client_factory, job.mupdf_connection)
                if not worker_ok or not worker or type(worker.read_range) ~= "function" then
                    return { error = Errors.transport("MuPDF Range client unavailable") }
                end
                local stream = RemoteStream:new{
                    size = source_size,
                    read_range = function(first, last)
                        return worker:read_range(remote_path, first, last)
                    end,
                }
                if not stream then
                    return { error = Errors.image_decode("invalid_remote_mupdf_size", "remote") }
                end
                metadata, render_error = self.mupdf_pages:render_remote(job.image,
                    function(offset, count) return stream:read_at(offset, count) end,
                    part_path)
            else
                local local_image = job.image
                -- Shelf local PDF descriptors originate from a validated
                -- document, but validate again before native IO after restart.
                if self.validate_local_documents and job.image.mupdf_source_path then
                    local local_client = self.client_factory()
                    if not local_client.direct or not local_client.resolve_document then
                        return {error=Errors.local_path("local document resolver unavailable")}
                    end
                    local verified = local_client:resolve_document(job.image.mupdf_source_path)
                    if verified ~= job.image.mupdf_source_path then
                        return {error=Errors.local_path("local document source changed")}
                    end
                    local_image = {}
                    for key, value in pairs(job.image) do local_image[key] = value end
                    local_image.local_path, local_image.source_path = verified, verified
                end
                metadata, render_error = self.mupdf_pages:render_local(local_image, part_path)
            end
            if not metadata then
                return { error = Errors.image_decode(render_error or "mupdf_render_failed",
                    remote_path and "remote" or "local") }
            end
            return { metadata = metadata }
        end
        if not client_ok or not bound_client then
            return { error = Errors.transport("client initialization failed") }
        end
        local client = bound_client
        if direct_local then
            if type(client.resolve) ~= "function" then
                return { error = Errors.local_path("direct resolver unavailable") }
            end
            local path, metadata = client:resolve(job.image.path)
            if not path then return { error = metadata } end
            return { direct_path = path, metadata = metadata }
        end
        local metadata, err = client:download(job.image.path, part_path,nil,download_options)
        if not metadata then return { error = err } end
        return { metadata = metadata }
    end, function(ok, result, async_error, async_state)
        if not self:_is_current_transfer(job, transfer) then return end
        local err
        if not ok then
            err = Errors.transport(async_error)
        elseif type(result) ~= "table" then
            err = Errors.transport("empty async result")
        else
            err = result.error
        end

        if err then
            if err.code == "storage" and err.detail~="cache_limit" and transfer.attempt == 1 then
                self:_retry_storage(job, transfer, err)
                return
            end
            self:_finish_job(job, transfer,
                function() self:_deliver_error(job, err) end,
                false, async_state and async_state.reap_pending == true)
            return
        end

        if result.direct_path then
            return self:_finish_job(job, transfer, function()
                self:_deliver(job, "on_ready", result.direct_path, false,
                    result.metadata or { direct = true })
            end)
        end

        local metadata = result.metadata or {}
        local final_path, publish_error = self.cache:publish({
            key = job.key,
            kind = job.kind == "cover" and "cover" or "page",
            remote_path = job.image.path,
            size = metadata.size,
            extension = job.extension,
            etag = metadata.etag,
            modified = job.image.archive_version or metadata.modified,
            format = metadata.format,
            width = metadata.width,
            height = metadata.height,
            mupdf_page = job.image.mupdf_page,
            archive_kind = job.image.archive_kind,
            archive_format = job.image.archive_format,
            archive_remote_path = job.image.archive_remote_path,
            archive_source_size = job.image.archive_source_size,
            archive_entry_name = job.image.archive_entry_name,
            archive_entry_ordinal = job.image.archive_entry_ordinal,
            archive_size = job.image.archive_size,
            archive_entry_offset = job.image.archive_entry_offset,
            pdf_image = job.image.pdf_image == true or nil,
            pdf_remote_path = job.image.pdf_remote_path,
            pdf_source_size = job.image.pdf_source_size,
            pdf_image_offset = job.image.pdf_image_offset,
            pdf_image_length = job.image.pdf_image_length,
            pdf_page_object = job.image.pdf_page_object,
            extension_mismatch = metadata.extension_mismatch == true,
        }, part_path)
        if not final_path then
            local storage_error = Errors.storage(publish_error)
            if publish_error ~= "cache_limit" and transfer.attempt == 1 then
                self:_retry_storage(job, transfer, storage_error)
                return
            end
            self:_finish_job(job, transfer, function() self:_deliver_error(job, storage_error) end)
            return
        end

        self:_finish_job(job, transfer, function()
            self:_deliver(job, "on_ready", final_path, false, metadata)
        end, true)
    end, {
        timeout = 120,
        on_cancelled = function()
            self:_release_part(job, transfer)
        end,
        on_reaped = function()
            self:_release_part(job, transfer)
        end,
        on_callback_error = function(callback_error)
            self.error_reporter:guard("download_page", function()
                error(callback_error, 0)
            end, nil, nil, { silent = true })
        end,
    })
    transfer.handle = handle
    if self:_is_current_transfer(job, transfer) then job.handle = handle end
end

function Loader:cancel_cover_generation(generation)
    self:_remember_cancellation(self.canceled_cover_generations,
        self.canceled_cover_generation_order, generation)
    self:_remove_waiters(function(waiter)
        return waiter.kind == "cover" and waiter.generation == generation
    end)
    self:_pump()
end

function Loader:cancel_generation(generation)
    self:_remember_cancellation(self.canceled_generations,
        self.canceled_generation_order, generation)
    self:_remove_waiters(function(waiter) return waiter.generation == generation end)
    self:_pump()
end

function Loader:cancel_all()
    self.current_queue = {}
    self.cover_queue = {}
    self.prefetch_queue = {}
    self.jobs_by_key = {}
    if self.active then
        self:_cancel_active_job(self.active)
    end
    local active_prefetch = {}
    for _, job in pairs(self.prefetch_active) do
        active_prefetch[#active_prefetch + 1] = job
    end
    for _, job in ipairs(active_prefetch) do
        self:_cancel_active_job(job)
    end
    self.prefetch_active = {}
    self.prefetch_active_count = 0
    self.canceled_generations = {}
    self.canceled_cover_generations = {}
    self.canceled_generation_order = {}
    self.canceled_cover_generation_order = {}
end

return Loader
