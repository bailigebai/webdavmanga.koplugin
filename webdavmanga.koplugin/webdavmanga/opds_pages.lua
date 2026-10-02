local Errors = require("webdavmanga.errors")
local MemoryPages = require("webdavmanga.memory_pages")
local Index = require("webdavmanga.opds_chapter_index")
local Url = require("webdavmanga.opds_url")
local Progress = require("webdavmanga.opds_progress")

local Pages = {}
Pages.__index = Pages

-- Restore only the currently selected source's exact, unique secret values.
-- Redacted descriptors never contain credentials and are never request URLs.
function Pages.restore_url(value, source)
    if not source then return nil, "source_missing" end
    local parsed, origin = Url.parse(value), Url.parse(source.url or source.server_url)
    if not parsed or not origin or parsed.authority:find("@", 1, true)
        or parsed.authority ~= origin.authority:gsub("^.*@", "")
        or parsed.scheme ~= origin.scheme then return nil, "source_restore_failed" end
    local keys, duplicates = {}, {}
    for pair in tostring(origin.query or ""):gmatch("[^&]+") do
        local key, content = pair:match("^([^=]+)=(.*)$")
        if key then
            if keys[key] then duplicates[key] = true end
            keys[key] = content
        end
    end
    local api_key, api_count
    api_count = 0
    for candidate in origin.path:gmatch("/[aA][pP][iI]/[oO][pP][dD][sS]/([^/]+)") do
        api_key, api_count = candidate, api_count + 1
    end
    local failed = false
    local restored = value:gsub("{apiKey}", function()
        if api_count ~= 1 or api_key:find("[{}]") then failed = true; return "" end
        return api_key
    end):gsub("{query:([^}]+)}", function(key)
        if not keys[key] or duplicates[key] or keys[key]:find("[{}]") then failed = true; return "" end
        return keys[key]
    end)
    if failed or restored:find("[{}]") then return nil, "source_restore_failed" end
    return restored
end

function Pages.virtual_index(desc, path)
    local count = type(desc) == "table" and desc.page_count
    if type(count) ~= "number" or count < 1 or count > 100000 or count % 1 ~= 0 then
        return nil, "invalid_page_count"
    end
    if not Url.parse(desc.stream_template) or not desc.stream_template:find("{pageNumber}", 1, true) then
        return nil, "invalid_stream_template"
    end
    local images = {}
    for index = 1, count do
        local page = index
        images[index] = { name = index .. ".jpg", path = path .. "#opds/" .. index,
            opds_page = true, opds_source_id = desc.source_id,
            image_url = function(width, height, source)
                local url = desc.stream_template:gsub("{pageNumber}", tostring(page - 1))
                for _, size in ipairs({ { "width", width }, { "maxWidth", width },
                    { "height", height }, { "maxHeight", height } }) do
                    if url:find("{" .. size[1] .. "}", 1, true) then
                        if not tonumber(size[2]) or size[2] < 1 then return nil, "target_size_missing" end
                        url = url:gsub("{" .. size[1] .. "}", tostring(math.floor(size[2])))
                    end
                end
                if desc.server_kind == "suwayomi" then
                    url = url:gsub("([?&])updateProgress=[^&]*&?", "%1"):gsub("[?&]$", "")
                end
                local restored, err = Pages.restore_url(url, source)
                if not restored then return nil, err end
                if desc.server_kind == "suwayomi" then
                    restored = restored .. (restored:find("?", 1, true) and "&" or "?") .. "updateProgress=true"
                end
                return restored
            end }
    end
    return Index:new(images)
end

local safe_codes = { source_missing = true, source_restore_failed = true, target_size_missing = true,
    timeout = true, tls = true, transport = true, decode = true }
function Pages.classify(err)
    local detail = type(err) == "table" and err.detail or err
    local code = tostring(detail or ""):match("^opds:([%w_]+)$")
    if code and safe_codes[code] then return { code = code, source_kind = "opds" } end
    local http = tostring(detail or ""):match("^opds:http:(%d+)$")
    if http then return { code = "http", http_status = tonumber(http), source_kind = "opds" } end
    if type(err) == "table" and err.code == "decode" then return { code = "decode", source_kind = "opds" } end
    if tostring(detail):lower():find("timeout", 1, true) then return { code = "timeout", source_kind = "opds" } end
    return { code = "transport", source_kind = "opds" }
end

function Pages.error_message(err)
    local messages = { source_missing = "此 OPDS 连接已不存在（source_missing）。",
        source_restore_failed = "无法从当前连接恢复 OPDS 密钥，请检查连接设置。",
        target_size_missing = "阅读区域尺寸不可用，请返回后重试。", timeout = "OPDS 页面请求超时，请重试。",
        decode = "OPDS 页面不是有效图片，请重试。", transport = "OPDS 网络连接失败，请重试。" }
    if err.code == "http" then
        if err.http_status == 401 or err.http_status == 403 then return "OPDS 认证失败，请检查当前连接的账号或密钥。" end
        return "OPDS 服务器返回 HTTP " .. tostring(err.http_status) .. "。"
    end
    return messages[err.code] or Errors.message(err)
end

function Pages:eligible(image)
    return image and image.opds_page == true
end

function Pages:new(options)
    options = options or {}
    local transport = assert(options.transport, "transport is required")
    local object = setmetatable({}, self)
    object.auth_provider = options.auth_provider or function() return {} end
    object.source_provider = options.source_provider
    object.progress = Progress:new{ progress_store = options.progress_store }
    object.transport = transport
    object.cover_store = options.cover_store
    object.cover_handle = nil
    object.cover_enabled = options.cover_enabled or function() return true end
    object.cover_sequence = 0
    local function read_image(image, maximum_bytes)
        local source = object.source_provider and object.source_provider(image.opds_source_id)
        if object.source_provider and (not source or source.id ~= image.opds_source_id) then return nil, "opds:source_missing" end
        local url, resolve_error = image.image_url
        if type(url) == "function" then url, resolve_error = url(image.opds_width, image.opds_height, source) end
        if type(url) ~= "string" or url:find("[{}]") then return nil, "opds:" .. (resolve_error or "source_restore_failed") end
        local auth = source and { username = source.username, password = source.password }
            or object.auth_provider(image.opds_source_id)
        local code, _headers, status, body = transport:get_bytes(
            url, auth, maximum_bytes)
        if type(code) ~= "number" then
            local reason = tostring(status):lower()
            return nil, reason:find("timeout", 1, true) and "opds:timeout"
                or reason:find("tls", 1, true) and "opds:tls" or "opds:transport"
        end
        if code < 200 or code >= 300 then return nil, "opds:http:" .. code end
        if type(body) ~= "string" or #body < 1 or #body > maximum_bytes then
            return nil, "opds:decode"
        end
        return body
    end
    object.read_image = read_image
    object.inner = MemoryPages:new{
        transfer = options.transfer,
        client_factory = function() return {} end,
        connection_provider = options.connection_provider
            or function() return { kind = "opds" } end,
        renderer = options.renderer,
        image_probe = options.image_probe,
        scheduler = options.scheduler,
        maximum_bytes = options.maximum_bytes or 64 * 1024 * 1024,
        maximum_buffer_bytes = options.maximum_buffer_bytes or 48 * 1024 * 1024,
        on_bytes = function(image, _connection, bytes, metadata)
            if image.opds_cover == true and image.opds_cover_connection
                and options.cover_store
                and type(options.cover_store.store) == "function" then
                options.cover_store:store(image.opds_cover_connection,
                    image, bytes, metadata)
            end
        end,
        read_provider = function(image, _connection, maximum_bytes)
            return read_image(image, maximum_bytes)
        end,
    }
    return object
end

local function noop_handle() return { cancel = function() end } end

function Pages:_cancel_cover()
    self.cover_sequence = self.cover_sequence + 1
    local handle = self.cover_handle
    self.cover_handle = nil
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
end

function Pages:ensure_descriptor_cover(desc, connection, hint, on_ready)
    if not self.cover_enabled() or not self.cover_store or not hint or not hint.chapter
        or not hint.chapter.pointer_path then return noop_handle() end
    local existing = self.cover_store:lookup(connection, hint)
    if existing then if on_ready then on_ready(existing) end; return noop_handle() end
    self:_cancel_cover()
    local sequence = self.cover_sequence
    local candidates = require("webdavmanga.opds_cover").candidates(desc, hint)
    local position = 0
    local attempt
    attempt = function()
        if self.cover_sequence ~= sequence then return end
        position = position + 1
        local candidate = candidates[position]
        if not candidate then return end
        candidate.opds_width, candidate.opds_height = self.target_width, self.target_height
        local settled = false
        local handle = self.inner.transfer.run(function()
            return self.read_image(candidate, 16 * 1024 * 1024)
        end, function(ok, bytes)
            settled = true
            if self.cover_sequence ~= sequence or not self.cover_enabled() then return end
            self.cover_handle = nil
            if not ok then return attempt() end
            local buffer, metadata = self.inner:_decode({ image = candidate,
                target_provider = function() return 120, 160 end }, bytes)
            if not buffer then return attempt() end
            if buffer.free then pcall(buffer.free, buffer) end
            local path = self.cover_store:store(connection, candidate, bytes, metadata)
            if path then if on_ready then on_ready(path) end else attempt() end
        end, { maximum_bytes = 16 * 1024 * 1024, scheduler = self.inner.scheduler, timeout = 30 })
        if not settled then self.cover_handle = handle end
    end
    attempt()
    return self.cover_handle or noop_handle()
end

function Pages:ensure_cover(connection, image, callbacks)
    callbacks = callbacks or {}
    if not self.cover_store or type(self.cover_store.store) ~= "function" then
        if callbacks.on_error then pcall(callbacks.on_error, "cover_store_unavailable") end
        return noop_handle()
    end
    local existing = self.cover_store:lookup(connection, { image = image })
    if existing then
        if callbacks.on_ready then pcall(callbacks.on_ready, existing) end
        return noop_handle()
    end
    self:_cancel_cover()
    local settled, handle = false, nil
    handle = self.inner.transfer.run(function()
        return self.read_image(image, self.inner.maximum_bytes)
    end, function(ok, bytes, transfer_error)
        settled = true
        self.cover_handle = nil
        if not ok then
            if callbacks.on_error then pcall(callbacks.on_error, transfer_error) end
            return
        end
        local metadata, metadata_error = self.inner:_metadata(image, bytes)
        if not metadata then
            if callbacks.on_error then pcall(callbacks.on_error, metadata_error) end
            return
        end
        local path, store_error = self.cover_store:store(
            connection, image, bytes, metadata)
        if path then
            if callbacks.on_ready then pcall(callbacks.on_ready, path) end
        elseif callbacks.on_error then
            pcall(callbacks.on_error, store_error)
        end
    end, {
        maximum_bytes = self.inner.maximum_bytes,
        scheduler = self.inner.scheduler,
        timeout = 120,
    })
    if not settled then self.cover_handle = handle end
    return handle or noop_handle()
end

local function sized_image(image, target_provider)
    if type(image.image_url) ~= "function" then return image end
    local result = {}
    for key, value in pairs(image) do result[key] = value end
    result.opds_width, result.opds_height = target_provider(image)
    return result
end

function Pages:request(generation, image, target_provider, callbacks, processor)
    self:_cancel_cover()
    self.target_width, self.target_height = target_provider(image)
    local wrapped = { on_ready = callbacks and callbacks.on_ready, on_error = function(err)
        if callbacks and callbacks.on_error then callbacks.on_error(Pages.classify(err)) end
    end }
    return self.inner:request(generation, sized_image(image, target_provider), target_provider, wrapped, processor)
end
function Pages:prefetch(generation, images, target_provider, processor)
    local sized = {}
    for _, image in ipairs(images or {}) do sized[#sized + 1] = sized_image(image, target_provider) end
    return self.inner:prefetch(generation, sized, target_provider, processor)
end
function Pages:cancel_all(...)
    self:_cancel_cover()
    local active = self.progress_active
    self.progress_active, self.progress_pending = nil, nil
    if active and active.handle then active.handle:cancel() end
    return self.inner:cancel_all(...)
end
function Pages:cancel_generation(generation)
    if self.inner.generation == generation then return self:cancel_all() end
end
function Pages:buffer_count(...) return self.inner:buffer_count(...) end
function Pages:buffer_bytes(...) return self.inner:buffer_bytes(...) end

function Pages:_pump_progress()
    if self.progress_active or not self.progress_pending then return end
    local job = self.progress_pending
    self.progress_pending, self.progress_active = nil, job
    job.handle = self.inner.transfer.run(function()
        local source = self.source_provider and self.source_provider(job.request.source_id)
        if not source or source.id ~= job.request.source_id then return nil, "opds:source_missing" end
        local url, err = Pages.restore_url(job.request.url, source)
        if not url then return nil, "opds:" .. err end
        local ok, result = pcall(self.transport.request_json, self.transport,
            job.request.method, url, job.request.body, { username = source.username, password = source.password })
        if not ok or not result then return nil, "opds:transport" end
        return "ok"
    end, function(ok, _body, err)
        if self.progress_active ~= job then return end
        self.progress_active = nil
        self.last_progress_error = not ok and Pages.classify(err) or nil
        self:_pump_progress()
    end, { scheduler = self.inner.scheduler, maximum_bytes = 4096, timeout = 30 })
end

function Pages:sync_progress(desc, index)
    local request = self.progress:on_page(desc, index)
    if not request or request.read_only then return request end
    self.progress_pending = { request = request }
    self:_pump_progress()
    return request
end

return Pages
