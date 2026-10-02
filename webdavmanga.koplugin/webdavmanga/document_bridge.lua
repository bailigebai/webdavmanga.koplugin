local Errors = require("webdavmanga.errors")
local Formats = require("webdavmanga.image_formats")
local ImageProbe = require("webdavmanga.image_probe")
local MobiPages = require("webdavmanga.mobi_pages")
local RemoteStream = require("webdavmanga.remote_stream")
local ArchivePages = require("webdavmanga.archive_pages")
local MupdfPages = require("webdavmanga.mupdf_pages")
local PdfImageStream = require("webdavmanga.pdf_image_stream")
local BookIndex = require("webdavmanga.book_index")
local MANIFEST_LIMIT = 8 * 1024 * 1024
-- Bound the worst-case JSON output before asking the encoder to allocate it.
-- A byte may become a six-byte \u00XX escape; table/key punctuation is
-- deliberately overcounted. False positives fail safely at the same limit.
local function within_json_budget(value, limit)
    local remaining, pending, seen = limit, { value }, {}
    while #pending > 0 do
        local field = pending[#pending]
        pending[#pending] = nil
        local kind = type(field)
        if kind == "string" then
            remaining = remaining - 6 * #field - 2
        elseif kind == "number" then
            remaining = remaining - 32
        elseif kind == "boolean" then
            remaining = remaining - 5
        elseif kind == "table" then
            if seen[field] then return false end
            seen[field] = true
            remaining = remaining - 2
            for key, item in pairs(field) do
                remaining = remaining - 4
                pending[#pending + 1] = key
                pending[#pending + 1] = item
            end
        else
            return false
        end
        if remaining < 0 then return false end
    end
    return true
end
local EPUB_NATIVE_CLASSIFICATIONS = {
    epub_not_image_book = true, epub_drm = true, zip_encrypted = true, zip64_unsupported = true,
}

local DocumentBridge = {}
DocumentBridge.__index = DocumentBridge

local function noop() end
local function notify_index_growth(stream_state)
    if stream_state and type(stream_state.on_index_growth) == "function" then
        pcall(stream_state.on_index_growth, stream_state.generation)
    end
end
local function new_stream_state(options)
    options = options or {}
    local opening_ready = math.max(0, math.floor(tonumber(options.opening_ready) or 0))
    local ready = {}
    for position = 1, opening_ready do ready[position] = true end
    local state = {
        phase = options.phase or "opening",
        complete = options.complete == true,
        available_pages = opening_ready,
        catalog_pages = math.max(0, math.floor(tonumber(options.catalog_pages) or 0)),
        total_pages = options.total_pages,
        error = nil,
        generation = options.generation,
        warm_target = options.warm_target,
    }
    state.mark_ready = function(position, generation)
        position = tonumber(position)
        if generation ~= state.generation or state.phase == "close"
            or not position or position < 1 or position ~= math.floor(position) then return false end
        ready[position] = true
        while ready[state.available_pages + 1] do
            state.available_pages = state.available_pages + 1
        end
        return true
    end
    return state
end
local DOCUMENT_TIMEOUT_SECONDS = 24 * 60 * 60
local ARCHIVE_TIMEOUT_SECONDS = 60
local ARCHIVE_INITIAL_PAGE_LIMIT = 20
local STREAM_OPENING_PAGES = 3
local STREAM_WARM_TARGET = 20
DocumentBridge.STREAM_WARM_TARGET = STREAM_WARM_TARGET
local ARCHIVE_PROGRESS_INTERVAL = 5
local ARCHIVE_PROGRESS_POLL_SECONDS = 0.25
local MOBI_INSPECT_BLOCK_SIZE = 64 * 1024
local MUPDF_STREAM_FORMATS = {
    pdf = true, cbr = true, cb7 = true, cbt = true,
    xps = true, djvu = true, djv = true,
}
local MUPDF_PAGE_FORMATS = { pdf = true, cbr = true, cb7 = true, cbt = true }
local MOBI_PAGE_FORMATS = { mobi = true, azw = true, azw3 = true }
local ARCHIVE_PAGE_FORMATS = {
    cbz = true, zip = true, epub = true, cbt = true, tar = true, cbr = true, cb7 = true, rar = true, ["7z"] = true,
}
-- Remote RAR/7z requires libarchive callbacks; local MuPDF remains independent.
local LIBARCHIVE_PAGE_FORMATS = { cbr = true, rar = true, cb7 = true, ["7z"] = true }

local function mobi_page_format(entry_or_name)
    local name = type(entry_or_name) == "table"
        and (entry_or_name.name or entry_or_name.path) or entry_or_name
    local extension = Formats.extension(name)
    return MOBI_PAGE_FORMATS[extension] == true, extension
end

local function archive_format_supported(self, extension)
    if not ARCHIVE_PAGE_FORMATS[extension] or type(self.archive_pages) ~= "table" then
        return false
    end
    if type(self.archive_pages.can_stream) == "function" then
        local ok, value = pcall(self.archive_pages.can_stream, self.archive_pages, extension)
        return ok and value == true
    end
    return (extension == "cbz" or extension == "epub" or extension == "cbt")
        and type(self.archive_pages.inspect_remote) == "function"
end

local function index_items(index)
    if type(index) ~= "table" then return nil end
    if type(index.items) == "table" then return index.items end
    if type(index.count) ~= "function" or type(index.get) ~= "function" then return nil end
    local ok, count = pcall(index.count, index)
    if not ok or type(count) ~= "number" or count < 1 then return nil end
    local items = {}
    for position = 1, count do
        local got, item = pcall(index.get, index, position)
        if not got or type(item) ~= "table" then return nil end
        items[position] = item
    end
    return items
end

local function default_file_size(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return 0 end
    return tonumber(lfs.attributes(path, "size")) or 0
end

function DocumentBridge:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.cache = assert(options.cache, "cache is required")
    object.client_factory = assert(options.client_factory, "client factory is required")
    object.async = options.async or require("webdavmanga.async")
    object.ui_manager = options.ui_manager
    object.scheduler = options.scheduler
    object.error_reporter = options.error_reporter
    object.logger = options.logger
    object.identity = options.identity or ""
    object.identity_provider = options.identity_provider
    object.connection_provider = options.connection_provider
    object.streaming_enabled_provider = options.streaming_enabled_provider
    object.can_store_document = options.can_store_document
    object.mobi_pages = options.mobi_pages or MobiPages:new()
    object.archive_pages = options.archive_pages or ArchivePages:new()
    object.mupdf_pages = options.mupdf_pages or MupdfPages:new()
    object.pdf_image_stream = options.pdf_image_stream or PdfImageStream:new{ logger = object.logger }
    object.pdf_sequence, object.pending_pdf = 0, {}
    object.open_reader = options.open_reader
    object.file_size = options.file_size or default_file_size
    object.sequence = 0
    object.pending = {}
    object.mobi_sequence = 0
    object.pending_mobi = {}
    object.pending_archive = {}
    object.pending_mupdf = {}
    if object.archive_pages and object.archive_pages.logger == nil then
        object.archive_pages.logger = object.logger
    end
    return object
end

local function diagnostic(self, stage, format, adapter, detail)
    local logger = self.logger
    if logger == nil then
        local loaded, value = pcall(require, "logger")
        if loaded then logger = value end
    end
    if logger and type(logger.warn) == "function" then
        detail = detail or {}
        local fields = { Errors.stream_reason(detail.reason) }
        for _, key in ipairs({ "size", "offset", "count", "pages", "line" }) do
            local value = tonumber(detail[key])
            if value and value >= 0 and value < math.huge and value == math.floor(value) then
                fields[#fields + 1] = key .. "=" .. tostring(value)
            end
        end
        pcall(logger.warn, "WebDavManga stream:", stage, format, adapter, table.concat(fields, " "))
    end
end

local function exception_site(error_value)
    local message = tostring(error_value or "")
    for _, module in ipairs({ "archive_pages", "document_bridge", "book_index" }) do
        local line = tonumber(message:match(module .. "%.lua:(%d+):"))
        if line and line >= 1 and line <= 100000 then return module, line end
    end
end

local function stream_adapter(format)
    if MOBI_PAGE_FORMATS[format] then return "mobi_images" end
    if ARCHIVE_PAGE_FORMATS[format] then return "archive_pages" end
    return "pdf_images"
end

local function request_complete_download(self, entry, callbacks, format, reason, request)
    if request and request.canceled then return false end
    local stream_error = type(reason) == "table" and reason.code == "document" and reason.stage == "stream"
        and Errors.stream(format, reason.stream_stage, reason.reason) or nil
    local code = stream_error and stream_error.reason or Errors.stream_reason(reason)
    diagnostic(self, "fallback", format, request and request.adapter or stream_adapter(format), { reason = code })
    -- PDF/EPUB network failures use the same explicit, sanitized confirmation
    -- boundary as a refused Range response. Never pass transport detail to UI.
    if (format == "pdf" or format == "epub")
        and (code == "transport" or code == "tls" or code == "http") then
        reason = Errors.stream(format, "range_probe", code)
        stream_error = reason
    end
    if type(reason) == "table" and (reason.code == "storage" or reason.code == "transport"
        or reason.code == "tls" or reason.code == "http" or reason.code == "invalid_path") then
        return self:_fail(callbacks, reason)
    end
    if code == "zip_write_failed" or code == "archive_write_failed"
        or code == "pdf_image_write_failed" or code == "target_open_failed" or code == "write_failed" then
        return self:_fail(callbacks, Errors.storage(code))
    end
    -- Preflight refusal has no adapter task/handle yet, but its confirmation
    -- must still be canceled by Browser dismissal just like an active probe.
    if not request then
        request = { canceled = false }
        if type(callbacks.on_open_handle) == "function" then
            pcall(callbacks.on_open_handle, { cancel = function()
                if request.canceled then return false end
                request.canceled = true
                return true
            end })
        end
    end
    if request.canceled then return false end
    stream_error = stream_error or Errors.stream(format, Errors.stream_stage(format, code), code)
    local retried = false
    local cancel_epoch = self.cancel_epoch
    local function retry()
        if retried or self.cancel_epoch ~= cancel_epoch or (request and request.canceled) then return false end
        retried = true
        local fallback = {}
        for key, value in pairs(entry) do fallback[key] = value end
        fallback._complete_download_confirmed = true
        fallback._skip_mobi_stream, fallback._skip_archive_stream = true, true
        fallback._skip_pdf_image_stream, fallback._skip_mupdf_stream = true, true
        return self:_open(fallback, callbacks, false)
    end
    if type(callbacks.on_document_fallback_prompt) == "function" then
        return callbacks.on_document_fallback_prompt(format, code, retry, stream_error)
    end
    if format == "pdf" and type(callbacks.on_pdf_fallback_prompt) == "function" then
        return callbacks.on_pdf_fallback_prompt(code, retry)
    end
    return self:_fail(callbacks, stream_error)
end

-- Keep validation in RemoteStream, logging only the first failed bounded read.
local function diagnostic_stream(self, client, path, entry, adapter, options)
    options = options or {}
    options.size = tonumber(entry.size)
    local request_offset, request_count
    options.read_range = function(first, last)
        request_offset, request_count = first, last - first + 1
        local body, headers, reason = client:read_range(path, first, last)
        if not body then return nil, nil, reason or headers end
        return body, headers
    end
    local stream = RemoteStream:new(options)
    if not stream then return nil end
    local read_at = stream.read_at
    stream.read_at = function(instance, offset, count)
        local body, reason = read_at(instance, offset, count)
        if not body and not instance.failure then
            instance.failure = reason or "range_request_failed"
            diagnostic(self, "range", Formats.extension(entry.name or path), adapter,
                { reason = instance.failure, size = options.size,
                    offset = request_offset or offset, count = request_count or count })
        end
        return body, reason
    end
    return stream
end

-- Report what this plugin can safely do before a document is opened.
function DocumentBridge:stream_capability(entry)
    local extension = Formats.extension(entry and (entry.name or entry.path))
    local is_mobi_page_format = mobi_page_format(entry)
    local can_open = type(self.open_reader) == "function"
    if extension == "pdf" and can_open and type(self.pdf_image_stream) == "table"
        and type(self.pdf_image_stream.inspect_remote) == "function"
        and type(self.pdf_image_stream.extract_remote) == "function" then
        return { format = extension, kind = "pdf_images", supported = true }
    end
    if LIBARCHIVE_PAGE_FORMATS[extension] then
        if can_open and archive_format_supported(self, extension) then
            return { format = extension, kind = "archive_pages", supported = true }
        end
        return { format = extension, kind = "native_fallback", supported = false,
            fallback = "complete_download", reason = "libarchive_unavailable" }
    end
    local mupdf_remote = type(self.mupdf_pages.inspect_remote) == "function"
    if type(self.mupdf_pages.remote_capability) == "function" then
        local ok, value = pcall(self.mupdf_pages.remote_capability, self.mupdf_pages)
        mupdf_remote = ok and value == true
    end
    if can_open and archive_format_supported(self, extension) then
        return { format = extension, kind = "archive_pages", supported = true }
    end
    if can_open and MUPDF_PAGE_FORMATS[extension]
        and type(self.mupdf_pages.inspect_remote) == "function" and mupdf_remote then
        return { format = extension, kind = "mupdf_pages", supported = true }
    end
    if can_open and MUPDF_PAGE_FORMATS[extension]
        and type(self.mupdf_pages.inspect_remote) == "function" and not mupdf_remote then
        return { format = extension, kind = "native_fallback", supported = false,
            fallback = "complete_download", reason = "mupdf_remote_unavailable" }
    end
    if can_open and is_mobi_page_format
        and type(self.mobi_pages.inspect_remote) == "function" then
        return { format = extension, kind = "mobi_images", supported = true }
    end
    return { format = extension, kind = "native_fallback", supported = false,
        fallback = "complete_download", reason = "page_adapter_unavailable" }
end

local function notify_open_progress(callbacks, stage, name, progress,
    downloaded_bytes, total_bytes)
    if not callbacks or type(callbacks.on_open_progress) ~= "function" then return end
    pcall(callbacks.on_open_progress, {
        stage = stage,
        name = name,
        progress = math.max(0, math.min(1, tonumber(progress) or 0)),
        downloaded_bytes = math.max(0, tonumber(downloaded_bytes) or 0),
        total_bytes = math.max(0, tonumber(total_bytes) or 0),
    })
end

local function notify_open_handle(callbacks, handle)
    if callbacks and type(callbacks.on_open_handle) == "function" then
        pcall(callbacks.on_open_handle, handle)
    end
end

function DocumentBridge:_identity(entry, client)
    if type(self.identity_provider) == "function" then
        local ok, value = pcall(self.identity_provider, entry, client)
        if ok and value ~= nil then return tostring(value) end
    end
    if entry and entry.identity ~= nil then return tostring(entry.identity) end
    return tostring(self.identity)
end

function DocumentBridge:_ui()
    if self.ui_manager then return self.ui_manager end
    local ok, reader_ui = pcall(require, "apps/reader/readerui")
    return ok and reader_ui or nil
end

function DocumentBridge:_show(path, callbacks)
    callbacks = callbacks or {}
    local ui_manager = self:_ui()
    local show_reader = ui_manager and (ui_manager.showReader or ui_manager.show_reader)
    if type(show_reader) ~= "function" then
        if callbacks.on_error then callbacks.on_error(Errors.document("native", "showReader unavailable")) end
        return false
    end
    if callbacks.close_plugin then pcall(callbacks.close_plugin) end
    local on_closed = function(...)
        if callbacks.on_closed then
            local ok, err = pcall(callbacks.on_closed, ...)
            if not ok and self.error_reporter and self.error_reporter.report then
                pcall(self.error_reporter.report, self.error_reporter,
                    "close_document", Errors.document("native", err), { silent = true })
            end
        end
    end
    local function after_open(reader)
        if type(reader) == "table" then
            local old_close, closed = reader.onClose, false
            reader.onClose = function(instance, ...)
                local result = old_close and old_close(instance, ...) or nil
                if not closed then
                    closed = true
                    on_closed()
                end
                return result
            end
        end
        if callbacks.on_opened then callbacks.on_opened(path) end
    end
    local called, result = pcall(show_reader, ui_manager, path, nil, nil, false, after_open)
    if not called or result == false then
        if callbacks.on_error then
            callbacks.on_error(Errors.document("native", called and result
                or "native reader rejected document"))
        end
        return false
    end
    return true
end

-- KOReader 5.19.5 exposes only showReader(file_path), so the normal path
-- below still stages a complete document.  Newer/host-patched readers may
-- expose showReaderStream(descriptor, on_closed); keep that capability
-- optional and never pass a partial file to the native document engines.
function DocumentBridge:_try_show_stream(entry, client, remote_path, callbacks)
    local ui_manager = self:_ui()
    local extension = Formats.extension(entry.name or remote_path)
    if not MUPDF_STREAM_FORMATS[extension] then
        return nil
    end
    if self.streaming_enabled_provider then
        local ok, enabled = pcall(self.streaming_enabled_provider, entry, client)
        if not ok or enabled == false then return nil end
    end
    local show_stream = ui_manager
        and (ui_manager.showReaderStream or ui_manager.show_reader_stream)
    local size = tonumber(entry.size)
    if type(show_stream) ~= "function" or type(client.read_range) ~= "function"
        or not size or size <= 0 or math.floor(size) ~= size then
        return nil
    end
    local on_closed = function(...)
        if callbacks.on_closed then
            local ok, err = pcall(callbacks.on_closed, ...)
            if not ok and self.error_reporter and self.error_reporter.report then
                pcall(self.error_reporter.report, self.error_reporter,
                    "close_stream_document", Errors.document("native", err),
                    { silent = true })
            end
        end
    end
    local range_stream = RemoteStream:new{
        size = size,
        read_range = function(first, last)
            return client:read_range(remote_path, first, last)
        end,
        block_size = entry.range_block_size,
        max_blocks = entry.range_cache_blocks,
    }
    if not range_stream then return nil end
    -- Probe the first block before handing control to the native engine.  A
    -- server that ignores Range or returns malformed ranges falls back to the
    -- existing complete-download path instead of opening a partial file.
    local probe = range_stream:read_at(0, 8)
    if not probe or #probe == 0 then return nil end
    local descriptor = {
        path = remote_path,
        name = entry.name or remote_path,
        key = self:_identity(entry, client) .. "|" .. remote_path,
        size = size,
        format = extension,
        magic = extension,
        range_reader = function(first, last)
            return client:read_range(remote_path, first, last)
        end,
        read_at = function(offset, max_bytes)
            return range_stream:read_at(offset, max_bytes)
        end,
    }
    if callbacks.close_plugin then pcall(callbacks.close_plugin) end
    local called, result = pcall(show_stream, ui_manager, descriptor, on_closed)
    if not called or result == false then return nil end
    if callbacks.on_opened then callbacks.on_opened(remote_path) end
    return true
end

function DocumentBridge:_try_open_mobi_remote(entry, client, remote_path, callbacks)
    if not mobi_page_format(entry.name or remote_path)
        or type(self.open_reader) ~= "function"
        or type(client.read_range) ~= "function" then
        return nil
    end
    if entry._skip_mobi_stream == true then return nil end
    if self.streaming_enabled_provider then
        local ok, enabled = pcall(self.streaming_enabled_provider, entry, client)
        if not ok or enabled == false then return nil end
    end
    local size = tonumber(entry.size)
    if not size or size <= 0 or size ~= math.floor(size) then return nil end
    local name = tostring(entry.name or remote_path:match("([^/]+)$") or "MOBI")
    notify_open_progress(callbacks, "index", name, 0.05, 0, size)
    -- Keep bounded MOBI metadata inspection off the UI thread and return a
    -- plain serializable page list; methods/metatables do not survive IPC.
    self.mobi_sequence = self.mobi_sequence + 1
    local token = "mobi" .. tostring(self.mobi_sequence)
    local extension = Formats.extension(entry.name or remote_path)
    local request = { canceled = false, adapter = "mobi_images" }
    diagnostic(self, "route", extension, request.adapter, { reason = "ok", size = size })
    self.pending_mobi[token] = request
    local cancel_handle = {
        cancel = function()
            if request.canceled then return false end
            request.canceled = true
            if self.pending_mobi[token] == request then
                self.pending_mobi[token] = nil
            end
            if request.handle and type(request.handle.cancel) == "function" then
                pcall(request.handle.cancel, request.handle)
            end
            return true
        end,
    }
    notify_open_handle(callbacks, cancel_handle)
    local function fail(error_value)
        if self.pending_mobi[token] ~= request or request.canceled then return false end
        self.pending_mobi[token] = nil
        diagnostic(self, "index", extension, request.adapter, { reason = error_value })
        return request_complete_download(self, entry, callbacks, extension, error_value, request)
    end
    request.handle = self.async.run(function()
        local ok_client, worker_client = pcall(self.client_factory, entry.connection)
        if not ok_client or not worker_client
            or type(worker_client.read_range) ~= "function" then
            return { error = Errors.transport("MOBI Range client unavailable") }
        end
        local stream = diagnostic_stream(self, worker_client, remote_path, entry, request.adapter, {
            block_size = entry.range_inspect_block_size or MOBI_INSPECT_BLOCK_SIZE,
            max_blocks = entry.range_cache_blocks,
        })
        if not stream then return { error = "invalid_remote_mobi_size" } end
        local book, inspect_error = self.mobi_pages:inspect_remote({
            size = size,
            read_at = function(offset, max_bytes)
                return stream:read_at(offset, max_bytes)
            end,
        }, remote_path)
        if not book or not book.index or type(book.index.items) ~= "table" then
            return { error = stream.failure or inspect_error or "invalid_remote_mobi_index" }
        end
        return {
            items = book.index.items,
            fixed_layout = book.fixed_layout,
            text_length = book.text_length,
        }
    end, function(success, result, async_error)
        if self.pending_mobi[token] ~= request or request.canceled then return end
        if not success or type(result) ~= "table" then
            return fail(async_error or "MOBI inspection failed")
        end
        if result.error then
            return fail(result.error)
        end
        local index = type(self.mobi_pages.index_from_items) == "function"
            and self.mobi_pages:index_from_items(result.items) or nil
        if not index or (tonumber(index:count()) or 0) < 1 then
            return fail("invalid_remote_mobi_index")
        end
        self.pending_mobi[token] = nil
        diagnostic(self, "index", extension, request.adapter, { reason = "ok", pages = index:count() })
        diagnostic(self, "first_page", extension, request.adapter, { reason = "ok" })
        notify_open_progress(callbacks, "index", name, 1, size, size)
        local range_stream = RemoteStream:new{
            size = size,
            read_range = function(first, last)
                return client:read_range(remote_path, first, last)
            end,
            block_size = entry.range_block_size,
            max_blocks = entry.range_cache_blocks,
        }
        local resource = {
            name = name, path = remote_path, is_file = true, size = size,
        }
        local context = {
            manga = resource, chapter = resource, chapter_index = index,
            layout = "mobi_images", cover_hint = { image = index:get(1) },
            remote_stream = range_stream,
            source_context = { on_return = callbacks and callbacks.on_closed },
        }
        if callbacks and callbacks.close_plugin then pcall(callbacks.close_plugin) end
        local called, opened = pcall(self.open_reader, context)
        if not called or opened == false then
            if callbacks and callbacks.on_error then
                callbacks.on_error(Errors.document("native",
                    called and opened or "manga reader rejected remote MOBI"))
            end
            return false
        end
        if callbacks and callbacks.on_opened then callbacks.on_opened(remote_path) end
        return true
    end, {
        timeout = DOCUMENT_TIMEOUT_SECONDS,
        -- ponytail: 1 MiB keeps common MOBI indexes cheap; use a file-backed
        -- index if books larger than several thousand pages become a target.
        max_payload_bytes = 1024 * 1024,
        on_cancelled = function() request.canceled = true end,
        on_reaped = noop,
    })
    if request.canceled and request.handle and request.handle.cancel then
        pcall(request.handle.cancel, request.handle)
    end
    return true
end

function DocumentBridge:_fail(callbacks, error_value)
    if type(error_value) ~= "table" or not error_value.code then
        error_value = Errors.document("staging", error_value)
    end
    if callbacks and callbacks.on_error then callbacks.on_error(error_value) end
    return false
end

function DocumentBridge:_try_open_archive_remote(entry, client, path, callbacks)
    if entry._skip_archive_stream then return nil end
    local extension = Formats.extension(entry and (entry.name or path))
    if not ARCHIVE_PAGE_FORMATS[extension] then return nil end
    if self.streaming_enabled_provider then
        local ok, enabled = pcall(self.streaming_enabled_provider, entry, client)
        if not ok or enabled == false then return nil end
    end
    return self:_open_archive(entry, client, path, callbacks)
end

local valid_opening_part

function DocumentBridge:_open_pdf_images_remote(entry, client, remote_path, callbacks)
    if Formats.extension(entry.name or remote_path) ~= "pdf"
        or entry._skip_pdf_image_stream
        or type(self.open_reader) ~= "function"
        or type(client.read_range) ~= "function" then return nil end
    local size = tonumber(entry.size)
    if not size or size <= 0 or size ~= math.floor(size) then return nil end
    if self.streaming_enabled_provider then
        local ok, enabled = pcall(self.streaming_enabled_provider, entry, client)
        if not ok or enabled == false then return nil end
    end
    self.pdf_sequence = (self.pdf_sequence or 0) + 1
    local token = "pdf" .. tostring(self.pdf_sequence)
    local request = { canceled = false, adapter = "pdf_images" }
    diagnostic(self, "route", "pdf", request.adapter, { reason = "ok", size = size })
    self.pending_pdf[token] = request
    local identity = self:_identity(entry, client)
    -- Cache retains modified/etag, but not PDF-specific descriptor fields.
    -- Bind persisted opening records to all known source-version components.
    local source_etag = tostring(entry.etag or "")
    local source_version = "pdf:" .. size .. ":" .. #source_etag .. ":"
        .. source_etag .. ":" .. tostring(entry.modified or "")
    local job = { token = token, parts = {}, opening = {}, canceled = false, allow_reuse = true,
        reused_versions = {},
        key_for_page = function(_, page) return self.cache:key_for(identity, page.path) end,
        record_for_page = function(current_job, page, metadata)
            local record = { key = self.cache:key_for(identity, page.path), kind = "page",
                identity = identity, remote_path = page.path, size = metadata.size,
                extension = Formats.extension_for_format(metadata.format), format = metadata.format, width = metadata.width,
                height = metadata.height, extension_mismatch = metadata.extension_mismatch == true,
                pdf_image = true, pdf_remote_path = remote_path, pdf_source_size = size,
                pdf_image_offset = page.pdf_image_offset, pdf_image_length = page.pdf_image_length,
                pdf_page_object = page.pdf_page_object, etag = entry.etag, modified = source_version }
            local reused = current_job.reused_versions[page.path]
            if reused then record.etag, record.modified = reused.etag, reused.modified end
            return record
        end }
    -- Register deterministic opening paths in the parent before a worker can
    -- write them. The page tree later determines whether one, two or three apply.
    for position = 1, STREAM_OPENING_PAGES do
        local part = self:_opening_part(job, {
            name = ("%05d.jpg"):format(position), path = remote_path .. "#pdf/" .. position,
        }, position)
        if not part then
            self.pending_pdf[token] = nil
            self:_discard_opening_parts(job)
            return self:_fail(callbacks, "invalid_opening_part")
        end
        job.opening[position] = part
    end
    local function cleanup()
        self:_discard_opening_parts(job)
    end
    local cancel_handle = { cancel = function()
        if request.canceled then return false end
        request.canceled = true
        job.canceled = true
        self.pending_pdf[token] = nil
        if request.handle and type(request.handle.cancel) == "function" then
            pcall(request.handle.cancel, request.handle)
        end
        cleanup()
        return true
    end }
    notify_open_handle(callbacks, cancel_handle)
    if request.canceled then return true end
    local name = tostring(entry.name or remote_path)
    notify_open_progress(callbacks, "index", name, 0.05, 0, size)
    local function try_next_adapter(reason)
        if self.pending_pdf[token] ~= request or request.canceled then return false end
        self.pending_pdf[token] = nil
        cleanup()
        diagnostic(self, "index", "pdf", request.adapter, { reason = reason })
        if type(reason) == "table" and (reason.code == "storage" or reason.code == "invalid_path") then
            return self:_fail(callbacks, reason)
        end
        if reason == "pdf_image_write_failed" then
            return self:_fail(callbacks, Errors.storage(reason))
        end
        local next_entry = {}
        for key, value in pairs(entry) do next_entry[key] = value end
        next_entry._skip_pdf_image_stream = true
        next_entry._prior_stream_reason = Errors.stream_reason(reason)
        return self:_open(next_entry, callbacks, false)
    end
    request.handle = self.async.run(function()
        local ok_client, worker = pcall(self.client_factory, entry.connection)
        if not ok_client or not worker or type(worker.read_range) ~= "function" then
            return { error = "pdf_range_client_unavailable" }
        end
        local stream = diagnostic_stream(self, worker, remote_path, entry, request.adapter, {
            block_size = entry.range_block_size,
            max_blocks = entry.range_cache_blocks,
        })
        if not stream then return { error = "invalid_remote_pdf_size" } end
        local read_at = function(offset, count) return stream:read_at(offset, count) end
        local book, inspect_error = self.pdf_image_stream:inspect_remote({
            size = size,
            read_at = read_at,
        }, remote_path)
        if not book or not book.index then
            return { error = stream.failure or inspect_error or "pdf_inspection_failed" }
        end
        local metadata = {}
        for position = 1, math.min(STREAM_OPENING_PAGES, book.index:count()) do
            local value, err = self.pdf_image_stream:extract_remote(book.index:get(position),
                read_at, job.opening[position].part_path, book.session)
            if not value then return { error = stream.failure or err or "pdf_first_page_invalid" } end
            metadata[position] = value
        end
        return { items = index_items(book.index), opening_metadata = metadata,
            total_pages = book.total_pages or book.index:count() }
    end, function(success, result, async_error)
        if self.pending_pdf[token] ~= request or request.canceled then cleanup(); return end
        if not success or type(result) ~= "table" or result.error then
            return try_next_adapter(type(result) == "table" and result.error
                or async_error or "pdf_inspection_failed")
        end
        local index = BookIndex.from_items(result.items)
        if not index or index:count() < 1 or type(result.opening_metadata) ~= "table" then
            return try_next_adapter("pdf_first_page_invalid")
        end
        diagnostic(self, "index", "pdf", request.adapter, { reason = "ok", pages = index:count() })
        local first = index:get(1)
        job.total_pages = result.total_pages
        local staged, replacements, seen_paths = {}, {}, {}
        local function conflict()
            self.pending_pdf[token] = nil
            cleanup()
            return self:_fail(callbacks, Errors.storage("opening_page_conflict"))
        end
        local function classify(part, path, record)
            if type(path) ~= "string" or type(record) ~= "table"
                or record.key ~= part.key or record.path ~= path
                or record.kind ~= "page"
                or (record.identity ~= nil and record.identity ~= identity)
                or record.remote_path ~= part.page.path
                or record.key ~= self.cache:key_for(identity, record.remote_path)
                or record.extension ~= Formats.extension_for_format(record.format) then return nil end
            if record.identity == nil then return "replace" end
            local tagged = type(record.modified) == "string" and record.modified:sub(1, 4) == "pdf:"
            if tagged then
                local prior_size, etag_length, suffix = record.modified:match("^pdf:(%d+):(%d+):(.*)$")
                local prior_etag = tostring(record.etag or "")
                if not tonumber(prior_size) or tonumber(prior_size) < 1
                    or tonumber(etag_length) ~= #prior_etag
                    or suffix:sub(1, #prior_etag) ~= prior_etag
                    or suffix:sub(#prior_etag + 1, #prior_etag + 1) ~= ":" then return nil end
                if record.modified ~= source_version or record.etag ~= entry.etag then return "replace" end
            else
                -- Older records retain raw remote validators. At least one
                -- nonempty comparable value must prove current or stale state.
                local compared, changed = false, false
                for _, key in ipairs({ "etag", "modified" }) do
                    local old, current = record[key], entry[key]
                    if type(old) == "string" and old:match("%S")
                        and type(current) == "string" and current:match("%S") then
                        compared = true
                        if old ~= current then changed = true end
                    end
                end
                -- Legacy image adapters omitted validators and identity. The
                -- connection-derived key above still proves page ownership.
                -- Re-extract only this book's three derived opening pages;
                -- never reuse bytes whose source version cannot be confirmed.
                if not compared then return "replace" end
                if changed then return "replace" end
            end
            local probed = ImageProbe.inspect(path, part.extension,
                { allow_extension_mismatch = true, file_size = self.file_size })
            local expected = part.metadata
            if probed and record.size == self.file_size(path) and record.size == expected.size
                and record.format == probed.format and record.format == expected.format
                and record.width == probed.width and record.width == expected.width
                and record.height == probed.height and record.height == expected.height
                and record.extension_mismatch == (probed.extension_mismatch == true)
                and record.extension_mismatch == (expected.extension_mismatch == true) then
                return "reuse"
            end
            return "replace"
        end
        for position = 1, math.min(STREAM_OPENING_PAGES, index:count()) do
            local part = job.opening[position]
            part.page, part.metadata = index:get(position), result.opening_metadata[position]
            if not valid_opening_part(self, part.part_path, part.extension, part.metadata) then return conflict() end
            if type(self.cache.lookup_record) == "function" then
                local path, record = self.cache:lookup_record(part.key)
                if path or record then
                    local state = classify(part, path, record)
                    if not state or seen_paths[path] then return conflict() end
                    seen_paths[path] = true
                    if state == "reuse" then
                        part.reused, part.cached_path = true, path
                        job.reused_versions[part.page.path] = { etag = record.etag, modified = record.modified }
                    else
                        local snapshot = {}
                        for key, value in pairs(record) do snapshot[key] = value end
                        replacements[#replacements + 1] = { part = part, path = path, record = snapshot }
                    end
                end
            end
            staged[position] = part
        end
        -- Preflight every record before deleting anything. Recheck the exact
        -- same owner/version immediately before removing only that page key.
        for _, prior in ipairs(replacements) do
            local path, record = self.cache:lookup_record(prior.part.key)
            if path ~= prior.path or classify(prior.part, path, record) ~= "replace" then return conflict() end
            for _, key in ipairs({ "key", "path", "identity", "remote_path", "kind", "extension",
                "etag", "modified", "size", "format", "width", "height", "extension_mismatch" }) do
                if record[key] ~= prior.record[key] then return conflict() end
            end
            local ok, removed = pcall(self.cache.remove, self.cache, prior.part.key)
            if not ok or removed ~= true then return conflict() end
            local remaining_path, remaining_record = self.cache:lookup_record(prior.part.key)
            if remaining_path or remaining_record then return conflict() end
        end
        index.generation = token
        local published, publish_error = self:_publish_opening_pages(job, staged, index)
        if not published then
            self.pending_pdf[token] = nil
            cleanup()
            return self:_fail(callbacks, Errors.storage(publish_error))
        end
        self.pending_pdf[token] = nil
        local connection_copy = {}
        for key, value in pairs(entry.connection or {}) do connection_copy[key] = value end
        for position = 1, index:count() do
            local page = index:get(position)
            page.pdf_image = true
            page.pdf_remote_path, page.pdf_source_size = remote_path, size
            page.pdf_connection = connection_copy
        end
        cleanup()
        local resource = { name = name, path = remote_path, is_file = true,
            size = size, etag = entry.etag, modified = entry.modified }
        local context = { manga = resource, chapter = resource, chapter_index = index,
            layout = "pdf_images", cover_hint = { image = first },
            remote_stream = true,
            stream_state = new_stream_state{ phase = "complete", complete = true,
                opening_ready = math.min(STREAM_OPENING_PAGES, index:count()),
                catalog_pages = index:count(), total_pages = index:count(), generation = token,
                warm_target = STREAM_WARM_TARGET },
            source_context = { on_return = callbacks.on_closed } }
        diagnostic(self, "first_page", "pdf", request.adapter, { reason = "ok" })
        notify_open_progress(callbacks, "first_page", name, 1, result.opening_metadata[1].size,
            result.opening_metadata[1].size)
        if request.canceled then cleanup(); return false end
        if callbacks.close_plugin then pcall(callbacks.close_plugin) end
        local called, opened = pcall(self.open_reader, context)
        if not called or opened == false then
            return self:_fail(callbacks, Errors.document("native",
                called and opened or "manga reader rejected PDF image document"))
        end
        if callbacks.on_opened then callbacks.on_opened(remote_path) end
        return true
    end, { timeout = DOCUMENT_TIMEOUT_SECONDS, max_payload_bytes = MANIFEST_LIMIT,
        on_cancelled = function() request.canceled = true; self.pending_pdf[token] = nil; cleanup() end,
        on_reaped = cleanup })
    if request.canceled and request.handle and request.handle.cancel then
        pcall(request.handle.cancel, request.handle)
    end
    return true
end

function DocumentBridge:_open_mupdf_remote(entry, client, remote_path, callbacks)
    if entry._skip_mupdf_stream then return nil end
    local extension = Formats.extension(entry.name or remote_path)
    if LIBARCHIVE_PAGE_FORMATS[extension] then return nil end
    if not MUPDF_PAGE_FORMATS[extension]
        or type(self.open_reader) ~= "function"
        or type(self.mupdf_pages.inspect_remote) ~= "function"
        or type(client.read_range) ~= "function" then return nil end
    if type(self.mupdf_pages.remote_capability) == "function" then
        local ok, available = pcall(self.mupdf_pages.remote_capability, self.mupdf_pages)
        if not ok or available ~= true then return nil end
    end
    local size = tonumber(entry.size)
    if not size or size <= 0 or size ~= math.floor(size) then return nil end
    if self.streaming_enabled_provider then
        local ok, enabled = pcall(self.streaming_enabled_provider, entry, client)
        if not ok or enabled == false then return nil end
    end
    self.mupdf_sequence = (self.mupdf_sequence or 0) + 1
    local token = "mupdf" .. tostring(self.mupdf_sequence)
    local request = { canceled = false, adapter = "mupdf_pages" }
    diagnostic(self, "route", extension, request.adapter, { reason = "ok", size = size })
    self.pending_mupdf[token] = request
    local identity = self:_identity(entry, client)
    local page_key = self.cache:key_for(identity, remote_path .. "#mupdf/1")
    local page_part, temporary_part
    if type(self.cache.paths_for) == "function" then
        local ok_paths, _, path = pcall(self.cache.paths_for, self.cache, page_key,
            "png", token)
        if ok_paths then page_part = path end
    end
    if type(page_part) ~= "string" or page_part == "" then
        page_part, temporary_part = os.tmpname(), true
    end
    local function cleanup_part()
        if not temporary_part and self.cache.discard_part then
            pcall(self.cache.discard_part, self.cache, page_key, "png", token)
        end
        pcall(os.remove, page_part)
    end
    local name = tostring(entry.name or remote_path)
    local cancel_handle = { cancel = function()
        if request.canceled then return false end
        request.canceled = true; self.pending_mupdf[token] = nil
        if request.handle and request.handle.cancel then pcall(request.handle.cancel, request.handle) end
        cleanup_part()
        return true
    end }
    notify_open_handle(callbacks, cancel_handle)
    if request.canceled then return true end
    notify_open_progress(callbacks, "index", name, 0.05, 0, size)
    request.handle = self.async.run(function()
        local ok_client, worker = pcall(self.client_factory, entry.connection)
        if not ok_client or not worker or type(worker.read_range) ~= "function" then
            return { error = "MuPDF Range client unavailable" }
        end
        local stream = diagnostic_stream(self, worker, remote_path, entry, "mupdf_pages", {
            block_size = entry.range_block_size, max_blocks = entry.range_cache_blocks })
        if not stream then return { error = "invalid_remote_mupdf_size" } end
        local book, err = self.mupdf_pages:inspect_remote({
            size = size, name = name, format = extension,
            read_at = function(offset, count) return stream:read_at(offset, count) end,
        }, remote_path, { page = 1, path = page_part })
        if not book or not book.index then return { error = stream.failure or err or "invalid_mupdf_index" } end
        return { items = index_items(book.index), first_metadata = book.first_metadata }
    end, function(success, result, async_error)
        if self.pending_mupdf[token] ~= request or request.canceled then cleanup_part(); return end
        self.pending_mupdf[token] = nil
        if not success or type(result) ~= "table" or result.error then
            diagnostic(self, "index", extension, "mupdf_pages",
                { reason = type(result) == "table" and result.error or async_error })
            cleanup_part()
            notify_open_progress(callbacks, "fallback", name, 0, 0, size)
            return request_complete_download(self, entry, callbacks, extension,
                type(result) == "table" and result.error or async_error or "mupdf_inspection_failed", request)
        end
        local index = require("webdavmanga.book_index").from_items(result.items)
        if not index or index:count() < 1 then
            cleanup_part()
            diagnostic(self, "index", extension, "mupdf_pages", { reason = "invalid_mupdf_index" })
            return request_complete_download(self, entry, callbacks, extension, "invalid_mupdf_index", request)
        end
        local first = index:get(1)
        diagnostic(self, "index", extension, "mupdf_pages", { reason = "ok", pages = index:count() })
        first.mupdf_remote_path, first.mupdf_source_size = remote_path, size
        first.mupdf_connection = {}
        for key, value in pairs(entry.connection or {}) do first.mupdf_connection[key] = value end
        for position = 2, index:count() do
            index:get(position).mupdf_remote_path = remote_path
            index:get(position).mupdf_source_size = size
            index:get(position).mupdf_connection = first.mupdf_connection
        end
        local resource = { name = name, path = remote_path, is_file = true, size = size,
            etag = entry.etag, modified = entry.modified }
        if type(self.cache.publish) == "function" and type(result.first_metadata) == "table" then
            local published, publish_error = self.cache:publish({
                key = page_key, kind = "page", identity = identity, remote_path = first.path,
                size = result.first_metadata.size, extension = "png",
                format = result.first_metadata.format, width = result.first_metadata.width,
                height = result.first_metadata.height, mupdf_page = first.mupdf_page,
                etag = entry.etag, modified = entry.modified,
            }, page_part)
            if not published then
                cleanup_part()
                return self:_fail(callbacks, Errors.storage(publish_error))
            end
        end
        cleanup_part()
        diagnostic(self, "first_page", extension, "mupdf_pages", { reason = "ok" })
        local context = { manga = resource, chapter = resource, chapter_index = index,
            layout = "mupdf_pages", cover_hint = { image = first },
            remote_stream = true, source_context = { on_return = callbacks.on_closed } }
        notify_open_progress(callbacks, "first_page", name, 1, size, size)
        if request.canceled then cleanup_part(); return false end
        if callbacks.close_plugin then pcall(callbacks.close_plugin) end
        local called, opened = pcall(self.open_reader, context)
        if not called or opened == false then
            return self:_fail(callbacks, Errors.document("native", called and opened
                or "manga reader rejected MuPDF document"))
        end
        if callbacks.on_opened then callbacks.on_opened(remote_path) end
        return true
    end, { timeout = DOCUMENT_TIMEOUT_SECONDS, max_payload_bytes = MANIFEST_LIMIT,
        on_cancelled = function() request.canceled = true; self.pending_mupdf[token] = nil; cleanup_part() end,
        on_reaped = cleanup_part })
    if request.canceled and request.handle and request.handle.cancel then
        pcall(request.handle.cancel, request.handle)
    end
    return true
end

function DocumentBridge:_try_open_mupdf_local(path, entry, callbacks)
    local extension = Formats.extension(entry and (entry.name or path))
    if not MUPDF_PAGE_FORMATS[extension]
        or type(self.open_reader) ~= "function" then return nil end
    local book, err = self.mupdf_pages:inspect_local(path, extension)
    if not book or not book.index then return nil end
    local index = book.index
    local first = index:get(1)
    for position = 1, index:count() do
        local item = index:get(position)
        item.local_path, item.mupdf_source_path = path, path
    end
    local resource = { name = entry.name or path, path = path, local_path = path, is_file = true }
    local context = { manga = resource, chapter = resource, chapter_index = index,
        layout = "mupdf_pages", cover_hint = { image = first },
        source_context = { on_return = callbacks and callbacks.on_closed } }
    local called, opened = pcall(self.open_reader, context)
    if not called or opened == false then return self:_fail(callbacks, err or "manga reader rejected MuPDF document") end
    if callbacks and callbacks.on_opened then callbacks.on_opened(path) end
    return true
end

function DocumentBridge:_discard_opening_parts(job, release)
    for _, part in ipairs(job.parts or {}) do
        if job.owned_parts and job.owned_parts[part.part_path] == part then
            if self.cache and type(self.cache.discard_part) == "function" then
                pcall(self.cache.discard_part, self.cache,
                    part.storage_key or part.key, part.storage_extension or part.extension, part.token)
            end
            os.remove(part.part_path)
        end
    end
    -- A canceled worker can still finish a write before it is reaped. Keep
    -- ownership paths for a second cleanup pass until termination is known.
    if release then
        job.parts = {}
        job.owned_parts = {}
    end
end

function DocumentBridge:_opening_part(job, page, position)
    if type(job.token) ~= "string" or not job.token:match("^[%w_-]+$")
        or type(page) ~= "table" or type(page.path) ~= "string"
        or type(position) ~= "number" or position < 1
        or position ~= math.floor(position) then return nil end
    local extension = Formats.extension(page.name or page.path)
    local key = job:key_for_page(page)
    if type(key) ~= "string" or key == "" then return nil end
    local token = job.token .. "_opening_" .. position
    local _, part_path = self.cache:paths_for(key, extension, token)
    if type(part_path) ~= "string" or part_path == "" then return nil end
    job.owned_parts = job.owned_parts or {}
    if job.owned_parts[part_path] then return nil end
    local part = { page = page, key = key, extension = extension,
        storage_key = key, storage_extension = extension,
        token = token, part_path = part_path }
    job.owned_parts[part_path] = part
    job.parts = job.parts or {}
    job.parts[#job.parts + 1] = part
    return part
end

valid_opening_part = function(self, part_path, extension, metadata)
    if type(metadata) ~= "table" then return false end
    local actual_size = self.file_size(part_path)
    if not actual_size or actual_size <= 0
        or (metadata.size ~= nil and tonumber(metadata.size) ~= actual_size) then
        return false
    end
    local probed = ImageProbe.inspect(part_path, extension, {
        allow_extension_mismatch = true, file_size = self.file_size,
    })
    return probed ~= nil and probed.format == metadata.format
        and probed.width == tonumber(metadata.width)
        and probed.height == tonumber(metadata.height)
        and (probed.extension_mismatch == true)
            == (metadata.extension_mismatch == true)
end

function DocumentBridge:_stage_opening_pages(job, index, count, extractor)
    local needed = math.min(math.max(0,
        math.floor(tonumber(count or STREAM_OPENING_PAGES) or 0)), index:count())
    local staged = {}
    job.index = index
    job.parts = job.parts or {}
    for position = 1, needed do
        if job.canceled then self:_discard_opening_parts(job); return nil, "canceled" end
        local page = index:get(position)
        if not page then self:_discard_opening_parts(job); return nil, "invalid_archive_index" end
        local part = self:_opening_part(job, page, position)
        if not part then
            self:_discard_opening_parts(job)
            return nil, "invalid_opening_part"
        end
        local extracted, metadata, err = pcall(extractor, page, part.part_path)
        if job.canceled then self:_discard_opening_parts(job); return nil, "canceled" end
        if not extracted then
            self:_discard_opening_parts(job)
            return nil, "opening_extract_failed"
        end
        if not valid_opening_part(self, part.part_path, part.extension, metadata) then
            self:_discard_opening_parts(job)
            return nil, err or "zip_image_invalid"
        end
        part.metadata = metadata
        staged[#staged + 1] = part
    end
    return staged
end

function DocumentBridge:_publish_opening_pages(job, staged, index)
    local published_keys = {}
    local function rollback(reason)
        local rolled_back = true
        for position = #published_keys, 1, -1 do
            local key = published_keys[position]
            local ok, removed = pcall(self.cache.remove, self.cache, key)
            if not ok or removed == false then rolled_back = false end
        end
        self:_discard_opening_parts(job)
        return nil, rolled_back and reason or "opening_rollback_failed"
    end
    index = index or job.index
    if type(index) ~= "table" or type(index.count) ~= "function"
        or type(index.get) ~= "function" or type(staged) ~= "table" then
        return rollback("invalid_opening_pages")
    end
    local available = index:count()
    local total_pages
    if job.total_pages ~= nil then
        total_pages = tonumber(job.total_pages)
    elseif job.index_complete == true then
        total_pages = available
    elseif type(job.total_pages_lower_bound) == "number"
        and job.total_pages_lower_bound == math.floor(job.total_pages_lower_bound)
        and job.total_pages_lower_bound >= STREAM_OPENING_PAGES
        and job.total_pages_lower_bound <= available
        and available >= STREAM_OPENING_PAGES then
        -- This is only proof that three pages exist, never an exact book total.
        total_pages = available
    else
        return rollback("opening_total_unknown")
    end
    if not total_pages or total_pages == math.huge or total_pages == -math.huge then
        return rollback("invalid_opening_pages")
    end
    local required = math.min(STREAM_OPENING_PAGES, total_pages)
    if total_pages < available or total_pages < 1
        or total_pages ~= math.floor(total_pages)
        or available < required or #staged ~= required then
        return rollback("invalid_opening_pages")
    end
    local seen_paths, seen_keys, seen_storage_paths = {}, {}, {}
    for position = 1, required do
        local part, page = staged[position], index:get(position)
        local owned = type(part) == "table" and job.owned_parts
            and job.owned_parts[part.part_path]
        local reused = type(part) == "table" and job.allow_reuse == true
            and part.reused == true
        local storage_path = type(part) == "table"
            and (reused and part.cached_path or part.part_path) or nil
        if type(part) ~= "table" or type(page) ~= "table"
            or type(page.path) ~= "string" or type(part.page) ~= "table"
            or part.page.path ~= page.path or seen_paths[page.path]
            or type(part.key) ~= "string" or seen_keys[part.key]
            or part.key ~= job:key_for_page(page)
            or type(storage_path) ~= "string" or seen_storage_paths[storage_path]
            or (not reused and (not owned or owned.key ~= part.key
                or owned.token ~= part.token or owned.extension ~= part.extension
                or owned.page.path ~= page.path)) then
            return rollback("invalid_opening_pages")
        end
        seen_paths[page.path], seen_keys[part.key], seen_storage_paths[storage_path] = true, true, true
    end
    for key in pairs(staged) do
        if type(key) ~= "number" or key < 1 or key > required
            or key ~= math.floor(key) then return rollback("invalid_opening_pages") end
    end
    -- An adapter may hand already extracted, validated artifacts to this
    -- publisher. Check the entire handoff before the first indexed write.
    for _, part in ipairs(staged) do
        local metadata = part.metadata
        local storage_path = part.reused and part.cached_path or part.part_path
        if type(part.page) ~= "table" or type(part.key) ~= "string"
            or type(storage_path) ~= "string" or type(metadata) ~= "table"
            or not valid_opening_part(self, storage_path,
                part.extension, metadata) then
            return rollback("invalid_opening_pages")
        end
        if part.reused then
            local path, record = self.cache:lookup_record(part.key)
            local built, expected = pcall(job.record_for_page, job, part.page, metadata)
            if not built or type(expected) ~= "table" or path ~= storage_path
                or type(record) ~= "table" or record.key ~= part.key
                or record.path ~= path
                or record.kind ~= expected.kind or record.identity ~= expected.identity
                or record.remote_path ~= expected.remote_path
                or record.extension ~= expected.extension
                or record.size ~= expected.size or record.format ~= expected.format
                or record.width ~= expected.width or record.height ~= expected.height
                or record.extension_mismatch ~= expected.extension_mismatch
                or record.etag ~= expected.etag or record.modified ~= expected.modified then
                return rollback("invalid_opening_pages")
            end
        end
    end
    for _, part in ipairs(staged) do
        if job.canceled then return rollback("canceled") end
        if not part.reused then
            local built, record = pcall(job.record_for_page, job, part.page, part.metadata)
            if not built or type(record) ~= "table" or record.key ~= part.key then
                return rollback("invalid_opening_record")
            end
            if type(self.cache.lookup_record) == "function" then
                local _, previous = self.cache:lookup_record(part.key)
                if previous then return rollback("opening_page_conflict") end
            end
            local called, path, err = pcall(self.cache.publish, self.cache,
                record, part.part_path)
            if not called or not path then
                if type(self.cache.lookup_record) == "function" then
                    local _, current = self.cache:lookup_record(part.key)
                    if current then published_keys[#published_keys + 1] = part.key end
                end
                return rollback(called and (err or "opening_publish_failed")
                    or "opening_publish_failed")
            end
            published_keys[#published_keys + 1] = part.key
        end
    end
    if job.canceled then return rollback("canceled") end
    if type(self.cache.lookup_record) == "function" then
        for _, part in ipairs(staged) do
            local path, record = self.cache:lookup_record(part.key)
            if not path or not record then
                return rollback("opening_page_evicted")
            end
        end
    end
    self:_discard_opening_parts(job, true)
    return true
end

function DocumentBridge:_open_archive(entry, client, remote_path, callbacks, local_path)
    local kind = Formats.extension(entry and (entry.name or remote_path))
    local resumable_epub = kind == "epub" and not local_path
    local streaming_archive = LIBARCHIVE_PAGE_FORMATS[kind] == true and not local_path
    local staged_opening = resumable_epub or streaming_archive
    if local_path and not archive_format_supported(self, kind) then return nil end
    if not ARCHIVE_PAGE_FORMATS[kind] or type(self.archive_pages.inspect_remote) ~= "function"
        or type(self.open_reader) ~= "function" then return nil end
    callbacks = callbacks or {}
    local identity = self:_identity(entry, client)
    local size = tonumber(entry.size)
    local name = entry.name or remote_path
    self.sequence = self.sequence + 1
    local token = "archive" .. self.sequence
    local function source_version(bytes)
        local etag = tostring(entry.etag or "")
        return tostring(bytes or "") .. ":" .. #etag .. ":" .. etag .. ":" .. tostring(entry.modified or "")
    end
    local version = remote_path .. "\0" .. source_version(size)
    local manifest_key = self.cache:key_for(identity .. "\0book-index", version)
    local staging_key = self.cache:key_for(identity .. "\0archive-first", version)
    local _, page_part = self.cache:paths_for(staging_key, "jpg", token)
    local _, manifest_part = self.cache:paths_for(manifest_key, "manifest", token)
    local metadata_work_path = manifest_part .. ".zipwork"
    local progress_part = manifest_part .. ".progress"
    local progress_tmp = progress_part .. ".tmp"
    local continuation_part = manifest_part .. ".continuation"
    local manifest_path, manifest_record = self.cache:lookup_record(manifest_key)
    if not manifest_record or manifest_record.kind ~= "manifest" then manifest_path = nil end
    local request = { canceled = false, adapter = "archive_pages" }
    local stop_background_poll = noop
    if not local_path then diagnostic(self, "route", kind, request.adapter, { reason = "ok", size = size }) end
    self.pending_archive[token] = request
    local function cleanup(preserve_continuation)
        -- Reap may run after cancellation, so repeat removal if the child wrote
        -- between cancel and termination. These paths belong only to this job.
        if self.cache and type(self.cache.discard_part) == "function" then
            pcall(self.cache.discard_part, self.cache, staging_key, "jpg", token)
            pcall(self.cache.discard_part, self.cache, manifest_key, "manifest", token)
        end
        os.remove(page_part)
        os.remove(page_part .. ".zipwork")
        os.remove(manifest_part)
        os.remove(metadata_work_path)
        os.remove(progress_part)
        os.remove(progress_tmp)
        if not preserve_continuation then os.remove(continuation_part) end
        if request.opening_job then self:_discard_opening_parts(request.opening_job) end
    end
    local cancel_handle = { cancel = function()
        if request.canceled then return false end
        request.canceled = true
        if request.opening_job then request.opening_job.canceled = true end
        self.pending_archive[token] = nil
        stop_background_poll()
        if request.handle and request.handle.cancel then pcall(request.handle.cancel, request.handle) end
        if request.stage_handle and request.stage_handle.cancel then
            pcall(request.stage_handle.cancel, request.stage_handle)
        end
        if request.background_handle and request.background_handle.cancel then
            pcall(request.background_handle.cancel, request.background_handle)
        end
        cleanup()
        return true
    end }
    request.cancel = cancel_handle.cancel
    notify_open_progress(callbacks, "index", name, 0.05, 0, size)
    notify_open_handle(callbacks, cancel_handle)
    if request.canceled then return true end
    local function fail(error_value, classification, stage)
        if self.pending_archive[token] ~= request or request.canceled then return false end
        request.failed = true
        local reason = Errors.stream_reason(error_value)
        if staged_opening then
            local inferred_stage = Errors.stream_stage(kind, reason)
            stage = inferred_stage == "range_probe" and inferred_stage or stage or inferred_stage
            if not (type(error_value) == "table"
                and (error_value.code == "storage" or error_value.code == "invalid_path")) then
                error_value = Errors.stream(kind, stage, reason)
            end
        end
        diagnostic(self, streaming_archive and stage == "fallback" and "index" or stage or "index",
            kind, "archive_pages", { reason = reason })
        self.pending_archive[token] = nil
        cleanup()
        if local_path then
            if entry._complete_download_confirmed == true then
                return self:_show(local_path, callbacks)
            end
            if kind == "epub" and classification == true and EPUB_NATIVE_CLASSIFICATIONS[error_value] then
                -- A complete EPUB is still useful to KOReader when it is
                -- outside the plugin's image-only subset (Calibre SVG covers
                -- are a common example). Operational failures must remain
                -- visible instead of being hidden by a native-reader retry.
                return self:_show(local_path, callbacks)
            end
            return self:_fail(callbacks, error_value)
        end
        if request.canceled then return false end
        if resumable_epub and (reason == "epub_continuation_invalid"
            or reason == "epub_continuation_too_large"
            or reason == "epub_continuation_write_failed") then
            return self:_fail(callbacks, error_value)
        end
        return request_complete_download(self, entry, callbacks, kind, error_value, request)
    end
    local function load_continuation()
        local file = io.open(continuation_part, "rb")
        if not file then return nil, "epub_continuation_invalid" end
        local bytes = file:read(MANIFEST_LIMIT + 1)
        file:close()
        if type(bytes) ~= "string" or #bytes > MANIFEST_LIMIT then
            return nil, "epub_continuation_too_large"
        end
        local loaded, json = pcall(require, "json")
        if not loaded then return nil, "epub_continuation_invalid" end
        local ok, value = pcall(json.decode, bytes)
        if not ok or type(value) ~= "table" or value.version ~= 1
            or value.source_version ~= source_version(size)
            or value.generation ~= token or value.source_size ~= size
            or value.remote_path ~= remote_path or value.next_cursor ~= 4 then
            return nil, "epub_continuation_invalid"
        end
        if type(self.archive_pages.validate_epub_continuation) == "function"
            and not self.archive_pages:validate_epub_continuation({ size = size },
                remote_path, { continuation = value, start_page = 4,
                    source_version = source_version(size), generation = token }) then
            return nil, "epub_continuation_invalid"
        end
        return value
    end
    if streaming_archive then
        -- Entry ordinals/extensions are unknown until the worker walks headers.
        -- Register three owned storage paths before dispatch, then bind those
        -- same parts to the returned, validated page descriptors in the parent.
        local job = { token = token, parts = {}, opening = {}, canceled = false,
            allow_reuse = true,
            key_for_page = function(_, page) return self.cache:key_for(identity, page.path) end,
            record_for_page = function(_, page, metadata)
                return { key = self.cache:key_for(identity, page.path), kind = "page",
                    identity = identity, remote_path = page.path, size = metadata.size,
                    extension = Formats.extension(page.name), format = metadata.format,
                    width = metadata.width, height = metadata.height,
                    extension_mismatch = metadata.extension_mismatch == true,
                    etag = entry.etag, modified = page.archive_version }
            end }
        request.opening_job = job
        for position = 1, STREAM_OPENING_PAGES do
            local part = self:_opening_part(job, { name = "opening.jpg",
                path = remote_path .. "#archive/opening/" .. position }, position)
            if not part then return fail("invalid_opening_part") end
            job.opening[position] = part
        end
    end
    local initial_work = function()
        if request.canceled then return { error = "canceled" } end
        local source, read_at, source_size, stream
        if local_path then
            source = io.open(local_path, "rb")
            if not source then return { error = "zip_read_failed" } end
            source_size = source:seek("end")
            read_at = function(offset, count)
                if not source:seek("set", offset) then return nil end
                return source:read(count)
            end
        else
            local ok, worker = pcall(self.client_factory, entry.connection)
            if not ok or not worker or type(worker.read_range) ~= "function" then
                return { error = "ZIP Range client unavailable" }
            end
            stream = diagnostic_stream(self, worker, remote_path, entry, "archive_pages", { exact_reads = true })
            if not stream then return { error = "invalid_remote_zip_size" } end
            source_size = size
            read_at = function(offset, count) return stream:read_at(offset, count) end
        end
        local function inspect()
            local loaded, json = pcall(require, "json")
            local index
            if not local_path and not streaming_archive and manifest_path and loaded then
                local file = io.open(manifest_path, "rb")
                if file then
                    local bytes = file:read(MANIFEST_LIMIT + 1); file:close()
                    if bytes and #bytes <= MANIFEST_LIMIT then
                        local ok, value = pcall(json.decode, bytes)
                        if ok then index = BookIndex.from_table(value) end
                    end
                end
                if index then
                    for _, page in ipairs(index.items) do
                        if page.archive_remote_path ~= remote_path or page.archive_source_size ~= size
                            or not BookIndex.matches_archive_format(page, kind)
                            or page.archive_local_path or page.etag ~= entry.etag
                            or page.archive_version ~= source_version(size) then index = nil; break end
                    end
                end
            end
            local inspected = not index
            local incomplete, total_pages = false, index and index:count() or nil
            local opening_metadata, opening_lower_bound
            if not index then
                local opening_targets
                if streaming_archive then
                    opening_targets = {}
                    for position, part in ipairs(request.opening_job.opening) do
                        opening_targets[position] = part.part_path
                    end
                end
                local book, err = self.archive_pages:inspect_remote({ size = source_size,
                    read_at = read_at, metadata_work_path = metadata_work_path }, kind, remote_path,
                    local_path and nil or { page_limit = staged_opening
                        and STREAM_OPENING_PAGES or ARCHIVE_INITIAL_PAGE_LIMIT,
                        opening_targets = opening_targets,
                        preserve_archive_order = streaming_archive,
                        source_version = source_version(source_size), generation = token })
                if not book or not book.index then
                    return { error = stream and stream.failure or err or "invalid_archive_index", classification = true }
                end
                incomplete = book.incomplete == true
                total_pages = tonumber(book.total_pages)
                opening_metadata, opening_lower_bound = book.opening_metadata, book.opening_lower_bound
                if resumable_epub and incomplete then
                    if type(book.continuation) ~= "table" then
                        return { error = "epub_continuation_invalid" }
                    end
                    if not within_json_budget(book.continuation, MANIFEST_LIMIT) then
                        return { error = "epub_continuation_too_large" }
                    end
                    local encoded_ok, continuation_bytes = false, nil
                    if loaded then
                        encoded_ok, continuation_bytes = pcall(json.encode, book.continuation)
                    end
                    if not encoded_ok or type(continuation_bytes) ~= "string" then
                        return { error = "epub_continuation_invalid" }
                    end
                    if #continuation_bytes > MANIFEST_LIMIT then
                        return { error = "epub_continuation_too_large" }
                    end
                    local file = io.open(continuation_part, "wb")
                    if not file then return { error = "epub_continuation_write_failed" } end
                    local wrote, closed = file:write(continuation_bytes), file:close()
                    if not wrote or not closed then
                        return { error = "epub_continuation_write_failed" }
                    end
                end
                for _, page in ipairs(book.index.items) do
                    if not BookIndex.matches_archive_format(page, kind) then
                        return { error = "invalid_archive_index" }
                    end
                    page.etag = entry.etag
                    page.archive_version = source_version(source_size)
                    if local_path then page.archive_local_path = local_path end
                end
                local value = book.index:to_table()
                index = value and BookIndex.from_table(value)
                if not index then return { error = "invalid_archive_index" } end
            end
            local page = index:get(1)
            local metadata, err
            if streaming_archive then
                metadata = opening_metadata and opening_metadata[1]
            elseif not resumable_epub then
                if local_path then metadata, err = self.archive_pages:extract_local(page, page_part)
                else metadata, err = self.archive_pages:extract_remote(page, read_at, page_part) end
                if not metadata then return { error = stream and stream.failure or err or "zip_image_invalid", stage = "first_page" } end
            end
            local manifest_size
            if inspected and not incomplete and not local_path and loaded then
                local ok, bytes = pcall(json.encode, index:to_table())
                if ok and type(bytes) == "string" and #bytes <= MANIFEST_LIMIT then
                    local file = io.open(manifest_part, "wb")
                    if file then
                        local wrote = file:write(bytes); local closed = file:close()
                        if wrote and closed then manifest_size = #bytes end
                    end
                end
            end
            return { index = index:to_table(), metadata = metadata, manifest_size = manifest_size,
                opening_metadata = opening_metadata, opening_lower_bound = opening_lower_bound,
                incomplete = incomplete, total_pages = total_pages }
        end
        local ok, result = pcall(inspect)
        if source then source:close() end
        if not ok then
            local module, line = exception_site(result)
            return { error = "stream_failed", diagnostic_exception = true,
                diagnostic_module = module,
                diagnostic_line = line }
        end
        return result
    end
    local archive_done
    archive_done = function(success, result, async_error)
        if self.pending_archive[token] ~= request or request.canceled then cleanup(); return end
        if not success or type(result) ~= "table" or result.error then
            if not success or type(result) ~= "table" then
                diagnostic(self, "index_async_failure", kind, "archive_pages",
                    { reason = "stream_failed" })
            end
            if type(result) == "table" and result.diagnostic_exception then
                diagnostic(self, "index_exception", kind,
                    result.diagnostic_module or "archive_pages",
                    { reason = "stream_failed", line = result.diagnostic_line })
            elseif type(result) == "table" and result.error and result.classification then
                diagnostic(self, "index_return_error", kind, "archive_pages",
                    { reason = Errors.stream_reason(result.error) })
            end
            return fail(type(result) == "table" and result.error or async_error or "archive inspection failed",
                type(result) == "table" and result.classification, type(result) == "table" and result.stage)
        end
        local index = BookIndex.from_table(result.index)
        local metadata = result.metadata
        if streaming_archive then
            if not index or type(result.opening_metadata) ~= "table"
                or #result.opening_metadata ~= math.min(STREAM_OPENING_PAGES, index:count()) then
                return fail("invalid_opening_pages")
            end
            local job = request.opening_job
            job.index, job.total_pages = index, result.total_pages
            job.index_complete = result.incomplete ~= true
            job.total_pages_lower_bound = result.opening_lower_bound
            local replacements, seen_cache_paths = {}, {}
            local function classify(part, path, record)
                if type(path) ~= "string" or type(record) ~= "table"
                    or record.path ~= path or record.key ~= part.key
                    or record.kind ~= "page"
                    or (record.identity ~= nil and record.identity ~= identity)
                    or record.remote_path ~= part.page.path or record.extension ~= part.extension
                    or record.key ~= self.cache:key_for(identity, record.remote_path) then return nil end
                -- The old lazy RAR adapter omitted identity after page one.
                -- A connection-derived key still proves ownership; regenerate
                -- those exact derived pages instead of trusting legacy bytes.
                if record.identity == nil or record.modified ~= part.page.archive_version then
                    return "replace"
                end
                -- Current version includes ETag. Conflicting duplicate markers
                -- are not a stale-version migration and remain an error.
                if record.etag ~= entry.etag then return nil end
                local probed = ImageProbe.inspect(path, part.extension,
                    { allow_extension_mismatch = true, file_size = self.file_size })
                local expected = part.metadata
                if probed and record.size == self.file_size(path) and record.size == expected.size
                    and record.format == probed.format and record.format == expected.format
                    and record.width == probed.width and record.width == expected.width
                    and record.height == probed.height and record.height == expected.height
                    and record.extension_mismatch == (probed.extension_mismatch == true)
                    and record.extension_mismatch == (expected.extension_mismatch == true) then
                    return "reuse"
                end
                return "replace"
            end
            local function conflict() return fail(Errors.storage("opening_page_conflict")) end
            for position = #job.opening, #result.opening_metadata + 1, -1 do job.opening[position] = nil end
            for position, part in ipairs(job.opening) do
                local page = index:get(position)
                part.page, part.key, part.extension = page, job:key_for_page(page), Formats.extension(page.name)
                part.metadata = result.opening_metadata[position]
                if not valid_opening_part(self, part.part_path, part.extension, part.metadata) then
                    return conflict()
                end
                local path, record = self.cache:lookup_record(part.key)
                if path or record then
                    local state = classify(part, path, record)
                    if not state or seen_cache_paths[path] then return conflict() end
                    seen_cache_paths[path] = true
                    if state == "reuse" then
                        -- The shared publisher checks metadata and bytes again.
                        part.reused, part.cached_path = true, path
                    else
                        local snapshot = {}
                        for key, value in pairs(record) do snapshot[key] = value end
                        replacements[#replacements + 1] = { part = part, path = path, record = snapshot }
                    end
                end
            end
            -- Validate all parts/owners first, then recheck the exact stale or
            -- damaged record before removing only its derived page key.
            for _, prior in ipairs(replacements) do
                local path, record = self.cache:lookup_record(prior.part.key)
                if path ~= prior.path or classify(prior.part, path, record) ~= "replace" then return conflict() end
                for _, key in ipairs({ "key", "path", "kind", "identity", "remote_path", "extension",
                    "etag", "modified", "size", "format", "width", "height", "extension_mismatch" }) do
                    if record[key] ~= prior.record[key] then return conflict() end
                end
                local ok, removed = pcall(self.cache.remove, self.cache, prior.part.key)
                if not ok or removed ~= true then return conflict() end
                local remaining_path, remaining_record = self.cache:lookup_record(prior.part.key)
                if remaining_path or remaining_record then return conflict() end
            end
        end
        if resumable_epub and not result.opening_metadata then
            if not index then return fail("invalid_archive_index") end
            if result.incomplete and not load_continuation() then
                return fail("epub_continuation_invalid")
            end
            local needed = math.min(STREAM_OPENING_PAGES,
                tonumber(result.total_pages)
                    or (result.incomplete ~= true and index:count() or 0))
            if needed < 1 or index:count() < needed then
                return fail("invalid_archive_index")
            end
            local job = { token = token, canceled = false, index = index,
                allow_reuse = true, opening = {}, parts = {},
                total_pages = tonumber(result.total_pages),
                index_complete = result.incomplete ~= true,
                key_for_page = function(_, page)
                    return self.cache:key_for(identity, page.path)
                end,
                record_for_page = function(_, page, image_metadata)
                    return { key = self.cache:key_for(identity, page.path),
                        kind = "page", identity = identity, remote_path = page.path,
                        size = image_metadata.size,
                        extension = Formats.extension(page.name),
                        format = image_metadata.format,
                        width = image_metadata.width, height = image_metadata.height,
                        extension_mismatch = image_metadata.extension_mismatch == true,
                        etag = entry.etag, modified = page.archive_version }
                end,
            }
            request.opening_job = job
            local seen_page_paths, seen_keys, seen_cache_paths = {}, {}, {}
            local function opening_conflict()
                return fail(Errors.storage("opening_page_conflict"))
            end
            local function opening_record_owner(record, path, key, page)
                return type(record) == "table" and type(path) == "string"
                    and record.kind == "page" and record.key == key
                    and record.path == path and record.identity == identity
                    and record.remote_path == page.path
                    and record.extension == Formats.extension(page.name)
            end
            local function current_opening_record(record, path, key, page)
                return opening_record_owner(record, path, key, page)
                    and record.modified == page.archive_version
                    and record.etag == entry.etag
            end
            local function confirmed_stale_record(record, path, key, page)
                if not opening_record_owner(record, path, key, page)
                    or type(record.modified) ~= "string"
                    or record.modified == page.archive_version then return false end
                local prior_size, etag_length, suffix =
                    record.modified:match("^(%d+):(%d+):(.*)$")
                local etag = tostring(record.etag or "")
                return tonumber(prior_size) and tonumber(etag_length) == #etag
                    and suffix:sub(1, #etag) == etag
                    and suffix:sub(#etag + 1, #etag + 1) == ":"
            end
            for position = 1, needed do
                local opening_page = index:get(position)
                local key = job:key_for_page(opening_page)
                if seen_page_paths[opening_page.path] or seen_keys[key] then
                    return fail("invalid_opening_pages")
                end
                seen_page_paths[opening_page.path], seen_keys[key] = true, true
                local path, record = self.cache:lookup_record(key)
                local probed = path and record and ImageProbe.inspect(path,
                    Formats.extension(opening_page.name), {
                        allow_extension_mismatch = true, file_size = self.file_size })
                if probed and current_opening_record(record, path, key, opening_page)
                    and record.size == self.file_size(path)
                    and record.format == probed.format
                    and record.width == probed.width
                    and record.height == probed.height
                    and record.extension_mismatch == (probed.extension_mismatch == true) then
                    if seen_cache_paths[path] then return fail("invalid_opening_pages") end
                    seen_cache_paths[path] = true
                    probed.size = record.size
                    job.opening[position] = { page = opening_page, key = key,
                        extension = Formats.extension(opening_page.name),
                        cached_path = path, metadata = probed, reused = true }
                else
                    if record and not confirmed_stale_record(
                        record, path, key, opening_page) then
                        if probed or not current_opening_record(
                            record, path, key, opening_page) then
                            return opening_conflict()
                        end
                        local latest_path, latest_record = self.cache:lookup_record(key)
                        local latest_probe = latest_path and ImageProbe.inspect(latest_path,
                            Formats.extension(opening_page.name), {
                                allow_extension_mismatch = true,
                                file_size = self.file_size })
                        if latest_path ~= path or latest_probe
                            or not current_opening_record(latest_record,
                                latest_path, key, opening_page) then
                            return opening_conflict()
                        end
                        local removed_ok, removed = pcall(self.cache.remove,
                            self.cache, key)
                        if not removed_ok or removed ~= true
                            or self.cache:lookup_record(key) then
                            return opening_conflict()
                        end
                    end
                    local part = self:_opening_part(job, opening_page, position)
                    if not part then return fail("invalid_opening_part") end
                    job.opening[position] = part
                end
            end
            if #job.parts == 0 then
                result.opening_metadata = {}
                for position, part in ipairs(job.opening) do
                    result.opening_metadata[position] = part.metadata
                end
                result.metadata = result.opening_metadata[1]
                return archive_done(true, result)
            end
            request.stage_handle = self.async.run(function()
                local connected, worker = pcall(self.client_factory, entry.connection)
                if not connected or not worker or type(worker.read_range) ~= "function" then
                    return { error = "ZIP Range client unavailable" }
                end
                local stage_stream = diagnostic_stream(self, worker, remote_path, entry,
                    "archive_pages", { exact_reads = true })
                if not stage_stream then return { error = "invalid_remote_zip_size" } end
                local extracted = {}
                for position, part in ipairs(job.parts) do
                    local image_metadata, err = self.archive_pages:extract_remote(
                        part.page, function(offset, count)
                            return stage_stream:read_at(offset, count)
                        end, part.part_path)
                    if not image_metadata then
                        return { error = stage_stream.failure or err or "zip_image_invalid" }
                    end
                    extracted[position] = image_metadata
                end
                return { metadata = extracted }
            end, function(stage_success, staged, stage_error)
                if request.canceled then cleanup(); return end
                if not stage_success or type(staged) ~= "table" or staged.error then
                    return fail(type(staged) == "table" and staged.error
                        or stage_error or "opening_extract_failed", false, "first_page")
                end
                if type(staged.metadata) ~= "table" or #staged.metadata ~= #job.parts then
                    return fail("invalid_opening_pages")
                end
                for position, part in ipairs(job.parts) do
                    part.metadata = staged.metadata[position]
                end
                result.opening_metadata = {}
                for position, part in ipairs(job.opening) do
                    result.opening_metadata[position] = part.metadata
                end
                result.metadata = result.opening_metadata[1]
                archive_done(true, result)
            end, { timeout = ARCHIVE_TIMEOUT_SECONDS,
                max_payload_bytes = MANIFEST_LIMIT,
                on_cancelled = cleanup,
                on_reaped = function()
                    if request.canceled or request.failed then cleanup() end
                    self:_discard_opening_parts(job, true)
                end })
            return true
        end
        if not index or type(metadata) ~= "table" then return fail("invalid_archive_index") end
        diagnostic(self, "index", kind, "archive_pages", { reason = "ok", pages = index:count() })
        notify_open_progress(callbacks, "first_page", name, 0.9, metadata.size, metadata.size)
        if request.canceled then cleanup(); return end
        -- Keep existing Reader/CoverGrid keys. Only this book's generated
        -- pages and thumbnails expire when its source version changes.
        local page = index:get(1)
        local prefixes = {}
        for _, indexed_page in ipairs(index.items) do
            local marker = indexed_page.archive_kind == "tar" and "#tar/"
                or indexed_page.archive_kind == "libarchive" and "#archive/" or "#zip/"
            prefixes[remote_path .. marker] = true
        end
        self.cache:clear_matching_cache(function(record, key)
            if (record.kind ~= "page" and record.kind ~= "cover")
                or record.modified == page.archive_version
                or key ~= self.cache:key_for(identity, record.remote_path,
                    record.kind == "cover" and "cover" or nil) then return false end
            for prefix in pairs(prefixes) do
                if record.remote_path:sub(1, #prefix) == prefix then return true end
            end
            return false
        end)
        local published, err
        if staged_opening then
            published, err = self:_publish_opening_pages(request.opening_job,
                request.opening_job.opening, index)
        else
            published, err = self.cache:publish({
            key = self.cache:key_for(identity, page.path), kind = "page", identity = identity,
            remote_path = page.path,
            size = metadata.size, extension = Formats.extension(page.name),
            format = metadata.format, width = metadata.width, height = metadata.height,
            extension_mismatch = metadata.extension_mismatch == true, etag = entry.etag,
            modified = page.archive_version,
            }, page_part)
        end
        if not published then return fail(Errors.storage(err), false, "first_page") end
        diagnostic(self, "first_page", kind, "archive_pages", { reason = "ok" })
        if result.manifest_size then
            self.cache:publish({ key = manifest_key, kind = "manifest", remote_path = remote_path,
                identity = identity, size = result.manifest_size, extension = "manifest",
                validated = true, etag = entry.etag }, manifest_part)
        end
        self.pending_archive[token] = nil
        if not staged_opening or result.incomplete ~= true then cleanup() end
        local stream_state = new_stream_state{
            phase = "opening",
            complete = result.incomplete ~= true,
            opening_ready = staged_opening and math.min(STREAM_OPENING_PAGES, index:count())
                or math.min(1, index:count()),
            catalog_pages = index:count(),
            total_pages = tonumber(result.total_pages)
                or (not streaming_archive and index:count() or nil),
            generation = token,
            warm_target = staged_opening and STREAM_WARM_TARGET or nil,
        }
        stream_state.phase = stream_state.complete and "complete" or "warming_20"
        local function close_stream()
            stream_state.phase = "close"
            cancel_handle.cancel()
            return true
        end
        local function reader_returned(...)
            if callbacks.on_closed then return callbacks.on_closed(...) end
        end
        local resource = { name = name, path = remote_path, is_file = true,
            size = page.archive_source_size, etag = entry.etag, modified = entry.modified }
        local context = { manga = resource, chapter = resource, chapter_index = index,
            layout = "archive_images", cover_hint = { image = page },
            stream_state = stream_state,
            source_context = { on_close = close_stream, on_return = reader_returned } }
        if callbacks.close_plugin then pcall(callbacks.close_plugin) end
        local ok, opened = pcall(self.open_reader, context)
        if not ok or opened == false then
            cleanup()
            return self:_fail(callbacks, "manga reader rejected archive")
        end
        if callbacks.on_opened then callbacks.on_opened(remote_path) end
        if result.incomplete == true and not request.canceled then
            local background_active = false
            local active_attempt
            local attempt_sequence = 0
            local download_prompted = false
            local function new_attempt()
                attempt_sequence = attempt_sequence + 1
                local suffix = ".attempt-" .. tostring(attempt_sequence)
                local attempt = {
                    id = attempt_sequence,
                    progress_part = progress_part .. suffix,
                    progress_tmp = progress_tmp .. suffix,
                    metadata_work_path = metadata_work_path .. suffix,
                    manifest_part = manifest_part .. suffix,
                    poll_scheduled = false,
                    result_notified = false,
                    reaped = false,
                    settled = false,
                }
                local function schedule_progress_poll()
                    if active_attempt ~= attempt or request.canceled or stream_state.complete
                        or stream_state.error or attempt.poll_scheduled or not self.scheduler
                        or type(self.scheduler.scheduleIn) ~= "function" then return false end
                    local ok, scheduled = pcall(self.scheduler.scheduleIn, self.scheduler,
                        ARCHIVE_PROGRESS_POLL_SECONDS, attempt.progress_poll)
                    attempt.poll_scheduled = ok and scheduled ~= false
                    return attempt.poll_scheduled
                end
                attempt.progress_poll = function()
                    attempt.poll_scheduled = false
                    if active_attempt ~= attempt or request.canceled or stream_state.complete
                        or stream_state.error then return end
                    local file = io.open(attempt.progress_part, "rb")
                    if file then
                        local bytes = file:read(MANIFEST_LIMIT + 1)
                        file:close()
                        os.remove(attempt.progress_part)
                        if type(bytes) == "string" and #bytes <= MANIFEST_LIMIT then
                            local loaded, json = pcall(require, "json")
                            local decoded_ok, snapshot = false, nil
                            if loaded then decoded_ok, snapshot = pcall(json.decode, bytes) end
                            local partial = decoded_ok and type(snapshot) == "table"
                                and BookIndex.from_table(snapshot.index) or nil
                            if partial and (not staged_opening
                                or (snapshot.source_version == source_version(size)
                                    and snapshot.generation == token))
                                and partial:count() > index:count()
                                and index:replace_items(partial.items,
                                    staged_opening and token or nil) then
                                stream_state.total_pages = tonumber(snapshot.total_pages)
                                    or (not streaming_archive and index:count() or nil)
                                stream_state.catalog_pages = index:count()
                                stream_state.phase = index:count() < STREAM_WARM_TARGET
                                    and "warming_20" or "indexing"
                                notify_index_growth(stream_state)
                                diagnostic(self, "background_progress", kind, "archive_pages",
                                    { reason = "ok", pages = index:count() })
                            end
                        end
                    end
                    schedule_progress_poll()
                end
                attempt.schedule_poll = schedule_progress_poll
                attempt.stop_poll = function()
                    if attempt.poll_scheduled and self.scheduler
                        and type(self.scheduler.unschedule) == "function" then
                        pcall(self.scheduler.unschedule, self.scheduler, attempt.progress_poll)
                    end
                    attempt.poll_scheduled = false
                    os.remove(attempt.progress_part)
                    os.remove(attempt.progress_tmp)
                    os.remove(attempt.metadata_work_path)
                end
                return attempt
            end
            local function release_attempt(attempt)
                if not attempt or attempt.released then return false end
                attempt.released = true
                attempt.stop_poll()
                os.remove(attempt.manifest_part)
                if active_attempt == attempt then
                    active_attempt = nil
                    background_active = false
                    request.background_handle = nil
                    stream_state.retry_pending = false
                end
                return true
            end
            local function settle_attempt(attempt)
                if not attempt or attempt.settled then return false end
                if not request.canceled
                    and not (attempt.result_notified and attempt.reaped) then return false end
                attempt.settled = true
                return release_attempt(attempt)
            end
            local function note_attempt_reaped(attempt)
                if not attempt or attempt.reaped then return false end
                attempt.reaped = true
                settle_attempt(attempt)
                return true
            end
            stop_background_poll = function()
                if active_attempt then active_attempt.stop_poll() end
            end
            local function start_background(retrying)
                if request.canceled or stream_state.complete or background_active or active_attempt then
                    if active_attempt and active_attempt.reap_pending then
                        stream_state.retry_pending = true
                    end
                    return false
                end
                local attempt = new_attempt()
                active_attempt = attempt
                background_active = true
                download_prompted = false
                stream_state.retry_pending = false
                stream_state.error = nil
                stream_state.phase = retrying and "retry"
                    or (stream_state.available_pages < STREAM_WARM_TARGET
                        and "warming_20" or "indexing")
                local handle = self.async.run(function()
                if request.canceled then return { error = "canceled" } end
                local continuation
                if resumable_epub then
                    local continuation_error
                    continuation, continuation_error = load_continuation()
                    if not continuation then return { error = continuation_error } end
                end
                local connected, worker = pcall(self.client_factory, entry.connection)
                if not connected or not worker or type(worker.read_range) ~= "function" then
                    return { error = "ZIP Range client unavailable" }
                end
                local full_stream = diagnostic_stream(self, worker, remote_path, entry,
                    "archive_pages", { exact_reads = true })
                if not full_stream then return { error = "invalid_remote_zip_size" } end
                local loaded, json = pcall(require, "json")
                if not loaded then return { error = "archive_progress_unavailable" } end
                local function write_progress(partial_index, partial_total)
                    for _, progress_page in ipairs(partial_index.items) do
                        if not BookIndex.matches_archive_format(progress_page, kind) then return false end
                        progress_page.etag = entry.etag
                        progress_page.archive_version = source_version(size)
                    end
                    local value = partial_index:to_table()
                    if not value then return false end
                    local encoded, bytes = pcall(json.encode, {
                        index = value,
                        total_pages = tonumber(partial_total),
                        source_version = staged_opening and source_version(size) or nil,
                        generation = staged_opening and token or nil,
                    })
                    if not encoded or type(bytes) ~= "string" or #bytes > MANIFEST_LIMIT then
                        return false
                    end
                    local file = io.open(attempt.progress_tmp, "wb")
                    if not file then return false end
                    local wrote = file:write(bytes)
                    local closed = file:close()
                    if not wrote or not closed then os.remove(attempt.progress_tmp); return false end
                    os.remove(attempt.progress_part)
                    if not os.rename(attempt.progress_tmp, attempt.progress_part) then
                        os.remove(attempt.progress_tmp)
                        return false
                    end
                    return true
                end
                local full_book, full_error = self.archive_pages:inspect_remote({
                    size = size,
                    read_at = function(offset, count) return full_stream:read_at(offset, count) end,
                    metadata_work_path = attempt.metadata_work_path,
                }, kind, remote_path, {
                    progress_interval = ARCHIVE_PROGRESS_INTERVAL,
                    on_progress = write_progress,
                    continuation = continuation,
                    start_page = streaming_archive and 4 or continuation and continuation.next_cursor or nil,
                    preserve_archive_order = streaming_archive,
                    source_version = resumable_epub and source_version(size) or nil,
                    generation = resumable_epub and token or nil,
                })
                if not full_book or not full_book.index then
                    return { error = full_stream.failure or full_error or "invalid_archive_index" }
                end
                for _, full_page in ipairs(full_book.index.items) do
                    if not BookIndex.matches_archive_format(full_page, kind) then
                        return { error = "invalid_archive_index" }
                    end
                    full_page.etag = entry.etag
                    full_page.archive_version = source_version(size)
                end
                local value = full_book.index:to_table()
                local verified = value and BookIndex.from_table(value)
                if not verified then return { error = "invalid_archive_index" } end
                local manifest_size
                local loaded, json = pcall(require, "json")
                if loaded then
                    local encoded, bytes = pcall(json.encode, verified:to_table())
                    if encoded and type(bytes) == "string" and #bytes <= MANIFEST_LIMIT then
                        local file = io.open(attempt.manifest_part, "wb")
                        if file then
                            local wrote = file:write(bytes)
                            local closed = file:close()
                            if wrote and closed then manifest_size = #bytes end
                        end
                    end
                end
                return { index = verified:to_table(), manifest_size = manifest_size }
                end, function(full_success, full_result, full_async_error, full_async_state)
                if attempt.result_notified or attempt.settled
                    or active_attempt ~= attempt then return end
                attempt.result_notified = true
                local reap_pending = full_async_state
                    and full_async_state.reap_pending == true
                attempt.reap_pending = reap_pending and not attempt.reaped
                if not reap_pending then attempt.reaped = true end
                if request.canceled then
                    cleanup()
                    settle_attempt(attempt)
                    return
                end
                if not full_success or type(full_result) ~= "table" or full_result.error then
                    attempt.stop_poll()
                    local background_reason = type(full_result) == "table"
                        and full_result.error or full_async_error or "archive inspection failed"
                    stream_state.error = Errors.stream_reason(background_reason)
                    stream_state.phase = "failed"
                    stream_state.retry_pending = not attempt.reaped
                    diagnostic(self, "background_index", kind, "archive_pages",
                        { reason = stream_state.error })
                    local keep_continuation = resumable_epub
                        and background_reason ~= "epub_continuation_invalid"
                        and background_reason ~= "epub_continuation_too_large"
                    cleanup(keep_continuation)
                    settle_attempt(attempt)
                    return
                end
                local full_index = BookIndex.from_table(full_result.index)
                if not full_index or not index:replace_items(full_index.items,
                    staged_opening and token or nil) then
                    attempt.stop_poll()
                    stream_state.error = "invalid_archive_index"
                    stream_state.phase = "failed"
                    cleanup()
                    settle_attempt(attempt)
                    return
                end
                stream_state.complete = true
                stream_state.phase = "complete"
                stream_state.catalog_pages = index:count()
                stream_state.total_pages = index:count()
                stream_state.error = nil
                notify_index_growth(stream_state)
                attempt.stop_poll()
                diagnostic(self, "background_index", kind, "archive_pages",
                    { reason = "ok", pages = index:count() })
                if full_result.manifest_size then
                    self.cache:publish({ key = manifest_key, kind = "manifest",
                        remote_path = remote_path, identity = identity,
                        size = full_result.manifest_size, extension = "manifest",
                        validated = true, etag = entry.etag }, attempt.manifest_part)
                end
                cleanup()
                settle_attempt(attempt)
                end, { timeout = DOCUMENT_TIMEOUT_SECONDS, max_payload_bytes = MANIFEST_LIMIT,
                on_cancelled = function() attempt.stop_poll(); cleanup() end,
                on_reaped = function() note_attempt_reaped(attempt) end })
                attempt.handle = handle
                if active_attempt == attempt then request.background_handle = handle end
                attempt.schedule_poll()
                return true
            end
            stream_state.retry = function()
                if stream_state.phase ~= "failed" then return false end
                return start_background(true)
            end
            stream_state.complete_download = function()
                if request.canceled or stream_state.phase ~= "failed"
                    or download_prompted then return false end
                download_prompted = true
                return request_complete_download(self, entry, callbacks, kind,
                    stream_state.error or "archive inspection failed", request)
            end
            start_background(false)
        end
        return true
    end
    request.handle = self.async.run(initial_work, archive_done,
        { timeout = ARCHIVE_TIMEOUT_SECONDS, max_payload_bytes = MANIFEST_LIMIT,
        on_cancelled = function() request.canceled = true; self.pending_archive[token] = nil; cleanup() end,
        on_reaped = function()
            if not staged_opening or request.canceled or request.failed then cleanup() end
        end })
    if request.canceled and request.handle and request.handle.cancel then pcall(request.handle.cancel, request.handle) end
    return true
end

function DocumentBridge:_try_open_mobi_images(path, entry, callbacks)
    if not mobi_page_format(entry or path)
        or type(self.open_reader) ~= "function" then return nil end
    local remote_path = tostring(entry.path or path)
    local inspect = self.mobi_pages.inspect_lazy or self.mobi_pages.inspect
    local book = inspect(self.mobi_pages, path, remote_path)
    if not book then return nil end
    local name = tostring(entry.name or remote_path:match("([^/]+)$") or "MOBI")
    local resource = { name = name, path = remote_path, is_file = true }
    local context = {
        manga = resource, chapter = resource, chapter_index = book.index,
        layout = "mobi_images", cover_hint = { image = book.index:get(1) },
        source_context = { on_return = callbacks and callbacks.on_closed },
    }
    if callbacks and callbacks.close_plugin then pcall(callbacks.close_plugin) end
    local called, opened = pcall(self.open_reader, context)
    if not called or opened == false then
        if callbacks and callbacks.on_error then
            callbacks.on_error(Errors.document("native", called and opened or "manga reader rejected MOBI"))
        end
        return false
    end
    if callbacks and callbacks.on_opened then callbacks.on_opened(path) end
    return true
end

function DocumentBridge:_ready(path, callbacks, cache_only, entry)
    if not cache_only then
        local extension = Formats.extension(entry and (entry.name or path))
        if archive_format_supported(self, extension) then
            local archive_result = self:_open_archive(entry, nil, entry.path or path, callbacks, path)
            if archive_result ~= nil then return archive_result end
        end
        local mupdf_result = self:_try_open_mupdf_local(path, entry, callbacks or {})
        if mupdf_result ~= nil then return mupdf_result end
        local archive_result = self:_open_archive(entry, nil, entry.path or path, callbacks, path)
        if archive_result ~= nil then return archive_result end
        local mobi_result = self:_try_open_mobi_images(path, entry, callbacks or {})
        if mobi_result ~= nil then return mobi_result end
        return self:_show(path, callbacks)
    end
    if callbacks and type(callbacks.on_cached) == "function" then
        pcall(callbacks.on_cached, path)
    end
    return true
end

function DocumentBridge:_check_capacity(required_bytes, callbacks)
    if type(self.can_store_document) ~= "function" then return true end
    local ok, allowed, code = pcall(self.can_store_document,
        math.max(0, math.floor(tonumber(required_bytes) or 0)))
    if ok and allowed == true then return true end
    return self:_fail(callbacks, Errors.storage(ok and code or allowed))
end

function DocumentBridge:_open(entry, callbacks, cache_only)
    callbacks = callbacks or {}
    entry = entry or {}
    if entry.file_kind ~= "document" and not Formats.is_document(entry.name or entry.path) then
        return self:_fail(callbacks, "unsupported document entry")
    end
    if type(entry.local_path) == "string" and entry.local_path ~= "" then
        return self:_ready(entry.local_path, callbacks, cache_only, entry)
    end
    local connection = entry.connection or (type(self.connection_provider) == "function"
        and self.connection_provider() or nil) or {}
    -- Bind all asynchronous stages (including fallback) to the click's source.
    local bound_entry, bound_connection = {}, {}
    for key, value in pairs(entry) do bound_entry[key] = value end
    for key, value in pairs(connection) do bound_connection[key] = value end
    entry, connection = bound_entry, bound_connection
    entry.connection = connection
    local ok_client, client = pcall(self.client_factory, connection)
    if not ok_client or not client then
        return self:_fail(callbacks, "client initialization failed")
    end
    local remote_path = entry.path or entry.full_path
    if type(remote_path) ~= "string" or remote_path == "" then
        return self:_fail(callbacks, "document path is missing")
    end

    if connection.kind == "local" or (client.connection and client.connection.kind == "local") then
        if type(client.resolve_document) ~= "function" then
            return self:_fail(callbacks, "local document resolver unavailable")
        end
        local path, resolve_error = client:resolve_document(remote_path)
        if not path then return self:_fail(callbacks, resolve_error) end
        return self:_ready(path, callbacks, cache_only, entry)
    end

    local identity = self:_identity(entry, client)
    local key = self.cache:key_for(identity, remote_path)
    local cached_path, cached_record = self.cache:lookup_record(key)
    local archive_kind = Formats.extension(entry.name or remote_path)
    if cached_record and ARCHIVE_PAGE_FORMATS[archive_kind]
        and ((entry.size ~= nil and tonumber(entry.size) ~= tonumber(cached_record.size))
            or (entry.etag ~= nil and entry.etag ~= cached_record.etag)
            or (entry.modified ~= nil and entry.modified ~= cached_record.modified)) then
        cached_path, cached_record = nil, nil
    end
    if cached_path and cached_record and cached_record.kind == "document" then
        return self:_ready(cached_path, callbacks, cache_only, entry)
    end
    if not cache_only and not entry._complete_download_confirmed then
        local extension = Formats.extension(entry.name or remote_path)
        if archive_format_supported(self, extension) then
            local archive = self:_try_open_archive_remote(entry, client, remote_path, callbacks)
            if archive ~= nil then return archive end
        end
        local pdf_images = self:_open_pdf_images_remote(entry, client, remote_path, callbacks)
        if pdf_images ~= nil then return pdf_images end
        local mupdf = self:_open_mupdf_remote(entry, client, remote_path, callbacks)
        if mupdf ~= nil then return mupdf end
        if not archive_format_supported(self, extension) then
            local archive = self:_try_open_archive_remote(entry, client, remote_path, callbacks)
            if archive ~= nil then return archive end
        end
        local remote_mobi = self:_try_open_mobi_remote(entry, client, remote_path, callbacks)
        if remote_mobi ~= nil then return remote_mobi end
        local streamed = not ARCHIVE_PAGE_FORMATS[extension]
            and self:_try_show_stream(entry, client, remote_path, callbacks) or nil
        if streamed ~= nil then return streamed end
        if ARCHIVE_PAGE_FORMATS[extension] or MUPDF_PAGE_FORMATS[extension] or MOBI_PAGE_FORMATS[extension] then
            local reason = entry._prior_stream_reason or "page_adapter_unavailable"
            diagnostic(self, "route", extension, "native_fallback", { reason = reason, size = entry.size })
            return request_complete_download(self, entry, callbacks, extension, reason)
        end
    end
    if type(client.download_document) ~= "function" then
        return self:_fail(callbacks, "document downloader unavailable")
    end
    local known_size = tonumber(entry.size)
    if known_size and known_size > 0
        and not self:_check_capacity(known_size, callbacks) then
        return false
    end
    self.sequence = self.sequence + 1
    local token = "doc" .. tostring(self.sequence)
    local extension = Formats.extension(entry.name or remote_path) or "pdf"
    local final_path, part_path = self.cache:paths_for(key, extension, token)
    local request = {
        key = key,
        identity = identity,
        name = entry.name or remote_path:match("([^/]+)$") or remote_path,
        remote_path = remote_path,
        total_bytes = known_size or 0,
        extension = extension,
        token = token,
        part_path = part_path,
        canceled = false,
    }
    self.pending[token] = request
    local function stop_progress_poll()
        local task = request.progress_task
        request.progress_task = nil
        if task and self.scheduler and type(self.scheduler.unschedule) == "function" then
            pcall(self.scheduler.unschedule, self.scheduler, task)
        end
    end
    local function release_part()
        if request.part_released then return end
        -- Cancellation requests termination; the worker may still create this
        -- path. Repeat cleanup after reap until publish has consumed the part.
        if self.cache.discard_part then
            pcall(self.cache.discard_part, self.cache, key, extension, token)
        end
    end
    local cancel_handle = {
        cancel = function()
            if request.canceled then return false end
            request.canceled = true
            if self.pending[token] == request then self.pending[token] = nil end
            stop_progress_poll()
            if request.handle and type(request.handle.cancel) == "function" then
                pcall(request.handle.cancel, request.handle)
            end
            release_part()
            return true
        end,
    }
    notify_open_handle(callbacks, cancel_handle)
    local function fail(error_value)
        self.pending[token] = nil
        stop_progress_poll()
        release_part()
        return self:_fail(callbacks, error_value)
    end
    if not cache_only and type(callbacks.on_open_progress) == "function" then
        notify_open_progress(callbacks, "download", request.name, 0, 0,
            request.total_bytes)
        local function poll_progress()
            if self.pending[token] ~= request or request.canceled then return end
            local ok, downloaded = pcall(self.file_size, request.part_path)
            downloaded = ok and math.max(0, tonumber(downloaded) or 0) or 0
            local total = math.max(0, tonumber(request.total_bytes) or 0)
            notify_open_progress(callbacks, "download", request.name,
                total > 0 and math.min(1, downloaded / total) or 0,
                downloaded, total)
            if self.pending[token] == request and self.scheduler
                and type(self.scheduler.scheduleIn) == "function" then
                pcall(self.scheduler.scheduleIn, self.scheduler, 0.5,
                    request.progress_task)
            end
        end
        request.progress_task = poll_progress
        if self.scheduler and type(self.scheduler.scheduleIn) == "function" then
            pcall(self.scheduler.scheduleIn, self.scheduler, 0.5, poll_progress)
        end
    end
    request.handle = self.async.run(function()
        local metadata, download_error = client:download_document(
            remote_path, part_path, callbacks.on_progress)
        if not metadata then return { error = download_error or "document download failed" } end
        metadata.remote_path = remote_path
        return metadata
    end, function(success, metadata, async_error)
        if request.canceled or self.pending[token] ~= request then return end
        if not success then return fail(async_error) end
        if type(metadata) ~= "table" or metadata.error then
            return fail(metadata and metadata.error or "document download failed")
        end
        if not self:_check_capacity(metadata.size, callbacks) then
            self.pending[token] = nil
            stop_progress_poll()
            release_part()
            return false
        end
        local published, publish_error = self.cache:publish({
            key = key,
            kind = "document",
            identity = identity,
            remote_path = remote_path,
            size = metadata.size,
            extension = extension,
            validated = true,
            etag = metadata.etag,
            modified = metadata.modified,
            format = metadata.format or extension,
            path = final_path,
        }, part_path)
        if not published then return fail(Errors.storage(publish_error)) end
        request.part_released = true
        self.pending[token] = nil
        stop_progress_poll()
        notify_open_progress(callbacks, "download", request.name, 1,
            metadata.size, metadata.size)
        return self:_ready(published, callbacks, cache_only, entry)
    end, {
        timeout = DOCUMENT_TIMEOUT_SECONDS,
        on_cancelled = function() stop_progress_poll(); release_part() end,
        on_reaped = function() stop_progress_poll(); release_part() end,
    })
    if request.canceled and request.handle and request.handle.cancel then
        pcall(request.handle.cancel, request.handle)
    end
    return true
end

function DocumentBridge:open(entry, callbacks)
    return self:_open(entry, callbacks, false)
end

function DocumentBridge:cache_document(entry, callbacks)
    return self:_open(entry, callbacks, true)
end

function DocumentBridge:list_pending(identity)
    local result = {}
    for _, request in pairs(self.pending) do
        if identity == nil or tostring(identity) == request.identity then
            local ok, size = pcall(self.file_size, request.part_path)
            local downloaded = ok and math.max(0, tonumber(size) or 0) or 0
            local total = math.max(0, tonumber(request.total_bytes) or 0)
            result[#result + 1] = {
                key = request.key,
                name = request.name,
                remote_path = request.remote_path,
                downloaded_bytes = downloaded,
                total_bytes = total,
                progress = total > 0 and math.min(1, downloaded / total) or 0,
            }
        end
    end
    table.sort(result, function(left, right)
        return tostring(left.name):lower() < tostring(right.name):lower()
    end)
    return result
end

function DocumentBridge:cancel_all()
    self.cancel_epoch = (self.cancel_epoch or 0) + 1
    local pending_archive = self.pending_archive
    self.pending_archive = {}
    for _, request in pairs(pending_archive) do request.cancel() end
    local pending_pdf = self.pending_pdf
    self.pending_pdf = {}
    for _, request in pairs(pending_pdf) do
        request.canceled = true
        if request.handle and request.handle.cancel then
            pcall(request.handle.cancel, request.handle)
        end
    end
    local pending_mupdf = self.pending_mupdf
    self.pending_mupdf = {}
    for _, request in pairs(pending_mupdf) do
        request.canceled = true
        if request.handle and request.handle.cancel then
            pcall(request.handle.cancel, request.handle)
        end
    end
    local pending_mobi = self.pending_mobi
    self.pending_mobi = {}
    for _, request in pairs(pending_mobi) do
        request.canceled = true
        if request.handle and request.handle.cancel then
            pcall(request.handle.cancel, request.handle)
        end
    end
    local pending = self.pending
    self.pending = {}
    for _, request in pairs(pending) do
        request.canceled = true
        if request.handle and request.handle.cancel then pcall(request.handle.cancel, request.handle) end
        if not request.part_released and self.cache.discard_part then
            pcall(self.cache.discard_part, self.cache, request.key,
                request.extension, request.token)
        end
    end
end

return DocumentBridge
