local Errors = require("webdavmanga.errors")
local Formats = require("webdavmanga.image_formats")
local ImageProbe = require("webdavmanga.image_probe")
local MemoryTransfer = require("webdavmanga.memory_transfer")

local MemoryPages = {}
MemoryPages.__index = MemoryPages

local DOCUMENT_MARKERS = {
    "mobi_record", "archive_entry_name", "mupdf_page", "pdf_image",
}

function MemoryPages.eligible(image, source_kind)
    if type(image) ~= "table" or not Formats.is_image(image.name or image.path) then
        return false
    end
    if image.opds_page == true then return true end
    if source_kind ~= "webdav" and source_kind ~= "nodeshare"
        and source_kind ~= "local" then return false end
    for _, key in ipairs(DOCUMENT_MARKERS) do
        if image[key] ~= nil and image[key] ~= false then return false end
    end
    return true
end

local function release(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end

function MemoryPages:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.transfer = options.transfer or MemoryTransfer
    object.client_factory = assert(options.client_factory, "client factory is required")
    object.connection_provider = assert(options.connection_provider,
        "connection provider is required")
    object.read_provider = options.read_provider
    object.on_bytes = options.on_bytes
    object.process_buffer = options.process_buffer
    object.renderer = options.renderer
    object.image_probe = options.image_probe or ImageProbe
    object.open_file = options.open_file or io.open
    object.maximum_bytes = math.floor(tonumber(options.maximum_bytes)
        or 64 * 1024 * 1024)
    object.maximum_buffer_bytes = math.floor(tonumber(options.maximum_buffer_bytes)
        or 48 * 1024 * 1024)
    object.scheduler = options.scheduler
    object.queue = {}
    object.buffers = {}
    object.active = nil
    object.generation = nil
    return object
end

function MemoryPages:_renderer()
    if self.renderer then return self.renderer end
    local ok, renderer = pcall(require, "ui/renderimage")
    if ok then self.renderer = renderer end
    return self.renderer
end

function MemoryPages:_release_all(except_path)
    for path, cached in pairs(self.buffers) do
        if path ~= except_path then
            release(cached.buffer)
            self.buffers[path] = nil
        end
    end
end

function MemoryPages:buffer_count()
    local count = 0
    for _ in pairs(self.buffers) do count = count + 1 end
    return count
end

function MemoryPages:buffer_bytes()
    local bytes = 0
    for _, cached in pairs(self.buffers) do
        bytes = bytes + (tonumber(cached.bytes) or 0)
    end
    return bytes
end

function MemoryPages:_read_local(client, image)
    local path, metadata = client:resolve(image.path)
    if not path then return nil, metadata end
    local size = tonumber(metadata and metadata.size)
    if not size or size < 1 or size > self.maximum_bytes then
        return nil, Errors.image_decode("invalid image response size", "local")
    end
    local file, open_error = self.open_file(path, "rb")
    if not file then return nil, Errors.local_path(open_error) end
    local body = file:read(self.maximum_bytes + 1)
    local closed = file:close()
    if type(body) ~= "string" or #body ~= size or not closed then
        return nil, Errors.image_decode("local image changed while reading", "local")
    end
    return body
end

function MemoryPages:_read(image, connection)
    if type(self.read_provider) == "function" then
        return self.read_provider(image, connection, self.maximum_bytes)
    end
    local client = self.client_factory(connection)
    if connection.kind == "local" then return self:_read_local(client, image) end
    return client:read_image(image.path, self.maximum_bytes)
end

function MemoryPages:_metadata(image, bytes)
    local metadata, detail = self.image_probe.inspect_bytes(bytes,
        Formats.extension(image.name or image.path), #bytes, {
            allow_extension_mismatch = true,
        })
    if not metadata then return nil, Errors.image_decode(detail, "memory") end
    metadata.size = #bytes
    metadata.memory = true
    return metadata
end

function MemoryPages:_decode(job, bytes)
    local metadata, metadata_error = self:_metadata(job.image, bytes)
    if not metadata then return nil, metadata_error end
    local ok, width, height = pcall(job.target_provider, job.image, metadata)
    if not ok or not width or not height then
        return nil, Errors.image_decode("memory target unavailable", "memory")
    end
    local renderer = self:_renderer()
    if not renderer or type(renderer.renderImageData) ~= "function" then
        return nil, Errors.image_decode("memory image renderer unavailable", "memory")
    end
    local decoded, buffer = pcall(renderer.renderImageData, renderer,
        bytes, #bytes, false, width, height)
    if not decoded or not buffer then
        return nil, Errors.image_decode(decoded and "empty decoded buffer" or buffer,
            "memory")
    end
    metadata.decoded = true
    if type(self.on_bytes) == "function" then
        pcall(self.on_bytes, job.image, job.connection, bytes, metadata)
    end
    metadata.memory_bytes = math.max(1, math.floor(width))
        * math.max(1, math.floor(height)) * 4
    if type(job.process_buffer) == "function" then
        local called, processed, processed_metadata = pcall(job.process_buffer,
            buffer, metadata, job.image)
        if called and processed then
            if processed ~= buffer then release(buffer) end
            buffer = processed
            for key, value in pairs(processed_metadata or {}) do
                metadata[key] = value
            end
        else
            metadata.processing_error = called and processed_metadata
                or "memory_processing_failed"
        end
    end
    return buffer, metadata
end

function MemoryPages:_pump()
    if self.active or #self.queue == 0 then return end
    local job = table.remove(self.queue, 1)
    self.active = job
    local connection = job.connection
    job.handle = self.transfer.run(function()
        return self:_read(job.image, connection)
    end, function(ok, bytes, transfer_error)
        if self.active ~= job then return end
        self.active = nil
        if job.canceled or job.generation ~= self.generation then
            self:_pump()
            return
        end
        if not ok then
            if job.callbacks and job.callbacks.on_error then
                pcall(job.callbacks.on_error, Errors.transport(transfer_error))
            end
            self:_pump()
            return
        end
        local buffer, metadata = self:_decode(job, bytes)
        bytes = nil
        if not buffer then
            if job.callbacks and job.callbacks.on_error then
                pcall(job.callbacks.on_error, metadata)
            end
            self:_pump()
            return
        end
        if job.foreground then
            if job.callbacks and job.callbacks.on_ready then
                local callback_ok = pcall(job.callbacks.on_ready,
                    buffer, metadata, false)
                if not callback_ok then release(buffer) end
            else
                release(buffer)
            end
        elseif job.wanted and self:buffer_bytes() + metadata.memory_bytes
            <= self.maximum_buffer_bytes then
            self.buffers[job.image.path] = {
                buffer = buffer, metadata = metadata, bytes = metadata.memory_bytes,
            }
        else
            release(buffer)
            if job.wanted then self.queue = {} end
        end
        self:_pump()
    end, {
        maximum_bytes = self.maximum_bytes,
        scheduler = self.scheduler,
        timeout = 120,
        on_cancelled = function()
            if self.active ~= job then return end
            self.active = nil
            self:_pump()
        end,
    })
end

function MemoryPages:_begin_generation(generation)
    if self.generation == generation then return end
    self:cancel_all()
    self.generation = generation
end

function MemoryPages:request(generation, image, target_provider, callbacks, process_buffer)
    self:_begin_generation(generation)
    local connection = self.connection_provider()
    if not MemoryPages.eligible(image, connection and connection.kind) then return nil end
    local cached = self.buffers[image.path]
    if cached then
        self.buffers[image.path] = nil
        if callbacks and callbacks.on_ready then
            local callback_ok = pcall(callbacks.on_ready,
                cached.buffer, cached.metadata, true)
            if not callback_ok then release(cached.buffer) end
        else
            release(cached.buffer)
        end
        return { cancel = function() end }
    end
    if self.active and self.active.image.path == image.path then
        local active = self.active
        active.foreground = true
        active.callbacks = callbacks
        active.target_provider = target_provider
        active.process_buffer = process_buffer
        return active.handle or { cancel = function() active.canceled = true end }
    end
    local active_to_cancel
    if self.active and not self.active.foreground then
        active_to_cancel = self.active
        active_to_cancel.canceled = true
    end
    self.queue = {}
    self:_release_all()
    local job = {
        generation = generation, image = image, target_provider = target_provider,
        callbacks = callbacks, process_buffer = process_buffer,
        connection = connection, foreground = true,
    }
    self.queue[1] = job
    if active_to_cancel and active_to_cancel.handle then
        active_to_cancel.handle:cancel()
    end
    self:_pump()
    return job.handle or { cancel = function() job.canceled = true end }
end

function MemoryPages:prefetch(generation, images, target_provider, process_buffer)
    self:_begin_generation(generation)
    local connection = self.connection_provider()
    local wanted, ordered = {}, {}
    for _, image in ipairs(images or {}) do
        if #ordered >= 5 then break end
        if MemoryPages.eligible(image, connection and connection.kind)
            and not wanted[image.path] then
            wanted[image.path] = true
            ordered[#ordered + 1] = image
        end
    end
    for path, cached in pairs(self.buffers) do
        if not wanted[path] then release(cached.buffer); self.buffers[path] = nil end
    end
    local active_to_cancel
    if self.active and not self.active.foreground
        and not wanted[self.active.image.path] then
        active_to_cancel = self.active
        active_to_cancel.canceled = true
    end
    local queue = {}
    for _, image in ipairs(ordered) do
        local active_path = self.active and self.active.image.path
        if not self.buffers[image.path] and active_path ~= image.path then
            queue[#queue + 1] = {
                generation = generation, image = image, target_provider = target_provider,
                process_buffer = process_buffer,
                connection = connection, foreground = false, wanted = true,
            }
        elseif active_path == image.path then
            self.active.wanted = true
        end
    end
    self.queue = queue
    if active_to_cancel and active_to_cancel.handle then
        active_to_cancel.handle:cancel()
    end
    self:_pump()
end

function MemoryPages:cancel_generation(generation)
    if generation ~= self.generation then return end
    self:cancel_all()
end

function MemoryPages:cancel_all()
    local active = self.active
    self.queue = {}
    self:_release_all()
    self.generation = nil
    if active then
        active.canceled = true
        if active.handle then
            active.handle:cancel()
        else
            self.active = nil
        end
    end
end

return MemoryPages
