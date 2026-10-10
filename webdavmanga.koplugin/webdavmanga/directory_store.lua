local ChapterIndex = require("webdavmanga.chapter_index")
local ErrorReporter = require("webdavmanga.error_reporter")
local Errors = require("webdavmanga.errors")
local Manifest = require("webdavmanga.manifest")
local Path = require("webdavmanga.path")

local DirectoryStore = {}
DirectoryStore.__index = DirectoryStore

local Directory = {}
Directory.__index = Directory

local function default_scheduler()
    local ok, scheduler = pcall(require, "ui/uimanager")
    return ok and scheduler or nil
end

local function schedule(scheduler, callback)
    if scheduler and type(scheduler.scheduleIn) == "function" then
        local ok, result = pcall(scheduler.scheduleIn, scheduler, 0, callback)
        if ok and result ~= false then return true end
    end
    callback()
    return false
end

local function nonnegative_integer(value)
    return type(value) == "number" and value >= 0
        and value == math.floor(value) and value < math.huge
end

local function positive_integer(value)
    return nonnegative_integer(value) and value > 0
end

local function valid_descriptor(descriptor, part_path)
    local documents = tonumber(descriptor and descriptor.documents) or 0
    return type(descriptor) == "table"
        and descriptor.entries == nil
        and descriptor.part_path == part_path
        and positive_integer(descriptor.size)
        and nonnegative_integer(descriptor.count)
        and nonnegative_integer(descriptor.folders)
        and nonnegative_integer(descriptor.images)
        and nonnegative_integer(documents)
        and descriptor.folders + descriptor.images + documents == descriptor.count
        and type(descriptor.digest) == "string"
        and #descriptor.digest == 32
        and descriptor.digest:match("^[0-9a-fA-F]+$") ~= nil
end

function Directory:path()
    return self.remote_path
end

function Directory:folders()
    return self.folder_index
end

function Directory:images()
    return self.image_index
end

function Directory:documents()
    return self.document_index
end

function Directory:file_count()
    local images = tonumber(self.image_index and self.image_index:count()) or 0
    local documents = tonumber(self.document_index and self.document_index:count()) or 0
    -- The manifest builder keeps every direct file visible.  Unknown
    -- extensions are represented in the document range so the browser can
    -- still expose the folder entry without guessing a reader format.
    return images + documents
end

function Directory:acquire()
    if self.closed then return nil end
    self.references = (self.references or 0) + 1
    return self
end

function Directory:force_close()
    if self.closed then return true end
    self.closed = true
    local store = self.store
    if store then
        store.open_directories[self] = nil
        if store.directories_by_path[self.remote_path] == self then
            store.directories_by_path[self.remote_path] = nil
        end
    end
    local ok, err = self.manifest:close()
    self.cache:unprotect(self.key)
    self.store = nil
    self.references = 0
    return ok, err
end

function Directory:close()
    if self.closed then return true end
    if (self.references or 0) > 0 then
        self.references = self.references - 1
        if self.references > 0 then return true end
    end
    return self:force_close()
end

function DirectoryStore:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.client_factory = assert(options.client_factory, "client factory is required")
    object.cache = assert(options.cache, "cache is required")
    object.async = assert(options.async, "async runner is required")
    object.identity = tostring(options.identity or "")
    object.md5 = options.md5
    object.temporary_limit_provider = options.temporary_limit_provider
    object.manifest_module = options.manifest or Manifest
    object.scheduler = options.scheduler or default_scheduler()
    object.error_reporter = options.error_reporter
        or ErrorReporter:new{ logger = options.logger }
    object.instance_token = tostring(options.instance_token or {}):gsub("[^%w]", "")
    if object.instance_token == "" then object.instance_token = "directory" end
    object.decode_retry_limit = math.max(0,
        math.min(1, math.floor(tonumber(options.decode_retry_limit) or 1)))
    object.sequence = 0
    object.pending = {}
    object.open_directories = {}
    object.directories_by_path = {}
    return object
end

function DirectoryStore:_cache_key(remote_path)
    -- The manifest now keeps every direct file (including unknown
    -- extensions) in the document range.  Namespace this format so an old
    -- image-only manifest cannot hide a folder's PDF/MOBI/other files after
    -- upgrading the plugin.
    return self.cache:key_for(self.identity .. "\0directory-v2", remote_path)
end

function DirectoryStore:_report_callback(callback)
    return self.error_reporter:guard(
        "load_directory", callback, nil, nil, { silent = true })
end

function DirectoryStore:_close_path(remote_path)
    local directories = {}
    for directory in pairs(self.open_directories) do
        if directory.remote_path == remote_path then
            directories[#directories + 1] = directory
        end
    end
    for _, directory in ipairs(directories) do directory:force_close() end
end

function DirectoryStore:_open(remote_path, key, manifest_path)
    local manifest, err = self.manifest_module.open(manifest_path, { md5 = self.md5 })
    if not manifest then return nil, err end
    self.cache:protect(key)
    local directory = setmetatable({
        remote_path = remote_path,
        key = key,
        manifest = manifest,
        cache = self.cache,
        store = self,
        closed = false,
        references = 0,
    }, Directory)
    directory.folder_index = ChapterIndex:new{ manifest = manifest, kind = "folder" }
    directory.image_index = ChapterIndex:new{ manifest = manifest, kind = "image" }
    directory.document_index = ChapterIndex:new{ manifest = manifest, kind = "document" }
    self.open_directories[directory] = true
    self.directories_by_path[remote_path] = directory
    return directory
end

function DirectoryStore:_open_cached(remote_path, key)
    local manifest_path = self.cache:lookup(key)
    if not manifest_path then return nil end
    local directory, err = self:_open(remote_path, key, manifest_path)
    if directory then return directory end
    self.cache:remove(key)
    return nil, err
end

function DirectoryStore:lookup(remote_path)
    remote_path = Path.normalize_remote(remote_path)
    local current = self.directories_by_path[remote_path]
    if current and not current.closed then return current end
    return self:_open_cached(remote_path, self:_cache_key(remote_path))
end

function DirectoryStore:_release_part(request)
    if request.part_released then return end
    request.part_released = true
    self.cache:discard_part(request.key, "manifest", request.token)
    if self.cache.wake_space_waiters then self.cache:wake_space_waiters() end
end

function DirectoryStore:_is_current(request)
    return not request.canceled and self.pending[request.remote_path] == request
end

function DirectoryStore:_cancel_request(request)
    if request.canceled then return end
    request.canceled = true
    if self.cache.cancel_space_wait then self.cache:cancel_space_wait(request) end
    if self.pending[request.remote_path] == request then
        self.pending[request.remote_path] = nil
    end
    if request.directory then
        request.directory:close()
        request.directory = nil
    end
    if request.async_handle and request.async_handle.cancel then
        request.async_handle:cancel()
    elseif request.part_path then
        self:_release_part(request)
    end
end

function DirectoryStore:load(remote_path, callbacks)
    callbacks = callbacks or {}
    remote_path = Path.normalize_remote(remote_path)
    local old = self.pending[remote_path]
    if old then self:_cancel_request(old) end

    self.sequence = self.sequence + 1
    local request = {
        remote_path = remote_path,
        key = self:_cache_key(remote_path),
        generation = self.sequence,
        canceled = false,
        callbacks = callbacks,
    }
    self.pending[remote_path] = request

    local public_handle = {}
    function public_handle:cancel()
        request.store:_cancel_request(request)
    end
    request.store = self

    if not callbacks.refresh then
        local directory = self.directories_by_path[remote_path]
        if not directory or directory.closed then
            directory = self:_open_cached(remote_path, request.key)
        end
        if directory then
            request.directory = directory:acquire()
            schedule(self.scheduler, function()
                if not self:_is_current(request) then
                    directory:close()
                    return
                end
                self.pending[remote_path] = nil
                request.directory = nil
                if callbacks.on_ready then
                    self:_report_callback(function() return callbacks.on_ready(directory) end)
                end
            end)
            return public_handle
        end
    end

    request.token = self.instance_token .. "g" .. tostring(request.generation)
    local _final_path
    _final_path, request.part_path = self.cache:paths_for(
        request.key, "manifest", request.token)
    local client_factory = self.client_factory
    -- Bind the source client when the request is created.  The main plugin
    -- factory follows the active source, so resolving it later inside the
    -- async worker could turn a pending local request into a WebDAV request
    -- after the user switches sources.
    local client_ok, request_client = pcall(client_factory)
    if not client_ok then request_client = nil end
    local async_options = {
        max_payload_bytes = 8192,
        on_cancelled = function() self:_release_part(request) end,
        on_reaped = function() self:_release_part(request) end,
        on_callback_error = function(callback_error)
            self:_report_callback(function() error(callback_error, 0) end)
        end,
    }

    local function fail(err, defer_part_release)
        if not defer_part_release then self:_release_part(request) end
        if not self:_is_current(request) then return end
        self.pending[remote_path] = nil
        if self.error_reporter and type(self.error_reporter.report) == "function" then
            self.error_reporter:report("load_directory", err,
                { silent = true })
        end
        if callbacks.on_error then
            self:_report_callback(function() return callbacks.on_error(err) end)
        end
    end

    local function start()
        if not self:_is_current(request) then return end
        local manifest_options
        if self.cache.unified_quota then
            local maximum=self.temporary_limit_provider and self.temporary_limit_provider()
            manifest_options={max_temp_bytes=self.cache:write_budget(65536,0,request.part_path,maximum)}
            -- Partial positive space is also transient. Old canceled workers
            -- must be reaped before a fresh full allowance enters the child.
            if manifest_options.max_temp_bytes<(maximum or 1) and self.cache.has_pending_writes
                and self.cache:has_pending_writes(request.part_path) then
                self.cache:wait_for_space(request,start)
                return
            end
        end
        request.async_handle = self.async.run(function()
        if not request_client then
            return { error = Errors.transport("client initialization failed") }
        end
        local descriptor, err
        for attempt = 1, self.decode_retry_limit + 1 do
            descriptor, err = request_client:write_directory_manifest(
                remote_path, request.part_path,manifest_options)
            if descriptor or type(err) ~= "table" or err.code ~= "decode"
                or attempt > self.decode_retry_limit then
                break
            end
        end
        if not descriptor then return { error = err or Errors.transport("empty manifest") } end
        return descriptor
    end, function(ok, descriptor, async_error, async_state)
        if not self:_is_current(request) then return end
        if not ok then
            return fail(Errors.transport(async_error),
                async_state and async_state.reap_pending == true)
        end
        if type(descriptor) == "table" and descriptor.error then
            return fail(descriptor.error)
        end
        if not valid_descriptor(descriptor, request.part_path) then
            return fail(Errors.decode("invalid directory manifest descriptor"))
        end
        local published, publish_error = self.cache:publish({
            key = request.key,
            kind = "manifest",
            remote_path = remote_path,
            size = descriptor.size,
            extension = "manifest",
            validated = true,
            digest = descriptor.digest,
        }, request.part_path)
        if not published then return fail(Errors.storage(publish_error)) end
        request.part_released = true
        local directory, open_error = self:_open(remote_path, request.key, published)
        if not directory then
            self.cache:remove(request.key)
            return fail(open_error or Errors.decode("invalid published manifest"))
        end
        if not self:_is_current(request) then
            directory:close()
            return
        end
        directory:acquire()
        self.pending[remote_path] = nil
        if callbacks.on_ready then
            self:_report_callback(function() return callbacks.on_ready(directory) end)
        end
        if self.cache.wake_space_waiters then self.cache:wake_space_waiters() end
    end, async_options)
    end
    start()

    return public_handle
end

function DirectoryStore:invalidate_subtree(remote_path)
    remote_path=Path.normalize_remote(remote_path)
    local paths={[remote_path]=true}
    for path in pairs(self.pending) do if Path.is_within_remote(path,remote_path) then paths[path]=true end end
    for path in pairs(self.directories_by_path) do if Path.is_within_remote(path,remote_path) then paths[path]=true end end
    for _,record in pairs(self.cache.entries or {}) do
        if Path.is_within_remote(record.remote_path,remote_path)
            and record.key==self:_cache_key(record.remote_path) then paths[record.remote_path]=true end
    end
    for path in pairs(paths) do self:invalidate(path) end
end

function DirectoryStore:invalidate(remote_path)
    remote_path = Path.normalize_remote(remote_path)
    local request = self.pending[remote_path]
    if request then self:_cancel_request(request) end
    self:_close_path(remote_path)
    return self.cache:remove(self:_cache_key(remote_path))
end

function DirectoryStore:cancel_all()
    local pending = {}
    for _, request in pairs(self.pending) do pending[#pending + 1] = request end
    for _, request in ipairs(pending) do self:_cancel_request(request) end
    local directories = {}
    for directory in pairs(self.open_directories) do
        directories[#directories + 1] = directory
    end
    for _, directory in ipairs(directories) do directory:force_close() end
    self.pending = {}
end

return DirectoryStore
