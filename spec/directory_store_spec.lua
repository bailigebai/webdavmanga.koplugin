local DirectoryStore = require("webdavmanga.directory_store")
local Cache = require("webdavmanga.cache")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local manifest_files = {}
local function new_manifest(path, folders, images)
    local records = {}
    for index = 1, folders do
        records[#records + 1] = {
            path = path .. "/Folder " .. index,
            name = "Folder " .. index,
            is_folder = true,
        }
    end
    for index = 1, images do
        records[#records + 1] = {
            path = path .. "/" .. index .. ".jpg",
            name = index .. ".jpg",
            is_file = true,
        }
    end
    local manifest = {
        folders = folders,
        images = images,
        count = folders + images,
        closed = false,
    }
    function manifest:_record_at(index) return records[index] end
    function manifest:_find_ordinal(wanted)
        for index, record in ipairs(records) do
            if record.path == wanted then return index end
        end
    end
    function manifest:close() self.closed = true; return true end
    return manifest
end

local fake_manifest = {}
function fake_manifest.open(path)
    local manifest = manifest_files[path]
    if manifest == "corrupt" or manifest == nil then
        return nil, { code = "decode", detail = "corrupt manifest" }
    end
    return manifest
end

local function new_scheduler()
    local scheduler = { pending = {} }
    function scheduler:scheduleIn(_delay, callback)
        self.pending[#self.pending + 1] = callback
    end
    function scheduler:flush()
        local pending = self.pending
        self.pending = {}
        for _, callback in ipairs(pending) do callback() end
    end
    return scheduler
end

local function new_async()
    local async = { tasks = {} }
    function async.run(work, done, options)
        local task = {
            work = work,
            done = done,
            options = options or {},
            canceled = false,
        }
        async.tasks[#async.tasks + 1] = task
        local handle = {}
        function handle:cancel() task.canceled = true end
        task.handle = handle
        return handle
    end
    return async
end

local function new_cache()
    local cache = {
        records = {},
        removed = {},
        discarded = {},
        published = {},
        protected_keys = { reader_page = true },
        base_protected = { reader_page = true },
        leases = {},
    }
    function cache:key_for(identity, remote_path)
        self.last_key_identity = identity
        self.last_key_path = remote_path
        return identity .. "|" .. remote_path
    end
    function cache:lookup(key)
        local record = self.records[key]
        return record and record.path, record
    end
    function cache:paths_for(key, extension, token)
        local final = "/cache/" .. key .. "." .. extension
        return final, final .. "." .. token .. ".part"
    end
    function cache:publish(record, part_path)
        self.published[#self.published + 1] = { record = record, part_path = part_path }
        local final = "/cache/" .. record.key .. ".manifest"
        manifest_files[final] = manifest_files[part_path]
        self.records[record.key] = { path = final, kind = record.kind }
        return final
    end
    function cache:remove(key)
        self.removed[#self.removed + 1] = key
        local record = self.records[key]
        if record then manifest_files[record.path] = nil end
        self.records[key] = nil
        return true
    end
    function cache:discard_part(key, extension, token)
        self.discarded[#self.discarded + 1] = {
            key = key, extension = extension, token = token,
        }
        local _final, part = self:paths_for(key, extension, token)
        manifest_files[part] = nil
        return true
    end
    function cache:protect(key)
        self.leases[key] = (self.leases[key] or 0) + 1
        self.protected_keys[key] = true
    end
    function cache:unprotect(key)
        local remaining = (self.leases[key] or 0) - 1
        self.leases[key] = remaining > 0 and remaining or nil
        if not self.leases[key] and not self.base_protected[key] then
            self.protected_keys[key] = nil
        end
    end
    return cache
end

local function new_reporter()
    local reporter = { stages = {}, failures = {} }
    function reporter:guard(stage, callback, fallback)
        self.stages[#self.stages + 1] = stage
        local ok, value = pcall(callback)
        if ok then return value end
        self.failures[#self.failures + 1] = value
        return fallback
    end
    return reporter
end

local function serialized_descriptor_size(descriptor)
    local fields = {}
    for key, value in pairs(descriptor) do
        fields[#fields + 1] = ("[%q]=%q"):format(tostring(key), tostring(value))
    end
    return 2 + #table.concat(fields, ",")
end

local function fixture(options)
    options = options or {}
    local cache = options.cache or new_cache()
    local async = options.async or new_async()
    local scheduler = options.scheduler or new_scheduler()
    local reporter = options.reporter or new_reporter()
    local clients = 0
    local client = options.client or {}
    if not client.write_directory_manifest then
        function client:write_directory_manifest(remote_path, part_path)
            clients = clients + 1
            manifest_files[part_path] = new_manifest(remote_path, 4000, 8000)
            return {
                part_path = part_path,
                size = 987654,
                count = 12000,
                folders = 4000,
                images = 8000,
                digest = "0123456789abcdef0123456789abcdef",
            }
        end
    end
    local store = DirectoryStore:new{
        client_factory = function() return client end,
        cache = cache,
        async = async,
        identity = options.identity or "account",
        md5 = function(value) return value end,
        manifest = fake_manifest,
        scheduler = scheduler,
        error_reporter = reporter,
        instance_token = "spec",
    }
    return store, cache, async, scheduler, reporter, function() return clients end
end

do
    local store, cache, async, scheduler, _reporter, client_count = fixture()
    local key = "account\0directory-v2|/Books/A"
    local path = "/cache/hit.manifest"
    cache.records[key] = { path = path, kind = "manifest" }
    manifest_files[path] = new_manifest("/Books/A", 2, 3)
    local ready
    store:load("/Books//A/", { on_ready = function(value) ready = value end })
    expect(#async.tasks == 0 and client_count() == 0,
        "a valid manifest cache hit must not create a client or network task")
    expect(ready == nil and #scheduler.pending == 1,
        "a cache hit must deliver on the next UI tick")
    expect(cache.last_key_identity == "account\0directory-v2"
        and cache.last_key_path == "/Books/A",
        "directory cache keys must include identity, kind, and normalized path")
    scheduler:flush()
    expect(ready and ready:path() == "/Books/A"
        and ready:folders():count() == 2 and ready:images():count() == 3,
        "a ready directory must expose ChapterIndex views")
    expect(ready:folders():get(2).name == "Folder 2"
        and ready:images():get(1).name == "1.jpg"
        and ready.entries == nil,
        "directories must stay manifest-backed without retaining an entries array")
    expect(cache.protected_keys.reader_page and cache.protected_keys[key],
        "opening a directory must preserve existing cache protection")
    ready:close()
    expect(cache.protected_keys.reader_page and not cache.protected_keys[key],
        "closing a directory must release only its own protection")
end

do
    local store, cache, async, _scheduler, _reporter, client_count = fixture()
    local key = "account\0directory-v2|/Books/A"
    cache.records[key] = { path = "/cache/old.manifest", kind = "manifest" }
    manifest_files["/cache/old.manifest"] = new_manifest("/Books/A", 1, 1)
    local ready
    store:load("/Books/A", {
        refresh = true,
        on_ready = function(value) ready = value end,
    })
    local task = async.tasks[1]
    expect(task and task.options.max_payload_bytes == 8192,
        "refresh must run with the bounded async control protocol")
    local descriptor = task.work()
    expect(client_count() == 1 and descriptor.part_path and descriptor.count == 12000,
        "the child must stream the directory into a manifest and return its descriptor")
    expect(descriptor.entries == nil and serialized_descriptor_size(descriptor) < 8192,
        "the child result must not contain directory entries and must fit 8192 bytes")
    expect(#cache.published == 0 and ready == nil,
        "child work must not publish or open the manifest")
    task.done(true, descriptor)
    expect(#cache.published == 1 and ready and ready:path() == "/Books/A",
        "the parent callback must atomically publish then open the manifest")
    ready:close()
end

do
    local store, cache, async = fixture()
    local key = "account\0directory-v2|/Books/Corrupt"
    cache.records[key] = { path = "/cache/corrupt.manifest", kind = "manifest" }
    manifest_files["/cache/corrupt.manifest"] = "corrupt"
    store:load("/Books/Corrupt", {})
    expect(cache.removed[1] == key and #async.tasks == 1,
        "a corrupt cached manifest must be removed and treated as a miss")
end

do
    local store, cache, async = fixture()
    local ready, failed
    local handle = store:load("/Books/Cancel", {
        on_ready = function(value) ready = value end,
        on_error = function(err) failed = err end,
    })
    local task = async.tasks[1]
    local descriptor = task.work()
    handle:cancel()
    expect(task.canceled and #cache.discarded == 0,
        "cancel must not delete a part while its child may still be writing")
    task.options.on_cancelled()
    task.done(true, descriptor)
    expect(#cache.discarded == 1 and #cache.published == 0
        and ready == nil and failed == nil,
        "canceled loads must clean their part and ignore late completion")
end

do
    local store, cache, async = fixture()
    local failed
    store:load("/Books/Timeout", { on_error = function(err) failed = err end })
    local task = async.tasks[1]
    task.work()
    task.done(false, nil, "async timeout", { reap_pending = true })
    expect(failed and failed.code == "transport" and #cache.discarded == 0,
        "reap-pending timeout must deliver an error without deleting the part")
    task.options.on_reaped()
    task.options.on_reaped()
    expect(#cache.discarded == 1,
        "on_reaped must release the part exactly once")
end

do
    local store, cache, async = fixture()
    local old_ready, new_ready
    store:load("/Books/Race", { on_ready = function(value) old_ready = value end })
    local old_task = async.tasks[1]
    store:load("/Books/Race", { on_ready = function(value) new_ready = value end })
    local new_task = async.tasks[2]
    expect(old_task.canceled, "a newer same-path generation must cancel the old one")
    local old_descriptor = old_task.work()
    old_task.done(true, old_descriptor)
    expect(#cache.published == 0 and old_ready == nil,
        "an old generation must never publish or callback")
    old_task.options.on_cancelled()
    local new_descriptor = new_task.work()
    new_task.done(true, new_descriptor)
    expect(#cache.published == 1 and new_ready ~= nil,
        "the current generation must remain publishable")
    new_ready:close()
end

do
    local work_called = false
    local unavailable = {}
    function unavailable.run(_work, done)
        local handle = { cancel = function() end }
        done(false, nil, "background subprocess unavailable")
        return handle
    end
    local client = {
        write_directory_manifest = function()
            work_called = true
            error("network work must not run inline")
        end,
    }
    local failed
    local store = fixture{ async = unavailable, client = client }
    store:load("/Books/Offline", { on_error = function(err) failed = err end })
    expect(not work_called and failed and failed.code == "transport",
        "subprocess unavailability must fail without inline network work")
end

do
    local store, cache, async, scheduler = fixture()
    local key = "account\0directory-v2|/Books/Open"
    cache.records[key] = { path = "/cache/open.manifest", kind = "manifest" }
    manifest_files["/cache/open.manifest"] = new_manifest("/Books/Open", 1, 0)
    local opened
    store:load("/Books/Open", { on_ready = function(value) opened = value end })
    scheduler:flush()
    local stale_called = false
    store:load("/Books/Pending", { on_ready = function() stale_called = true end })
    local pending = async.tasks[1]
    store:invalidate("/Books/Pending")
    expect(pending.canceled and cache.removed[#cache.removed]
        == "account\0directory-v2|/Books/Pending",
        "invalidate must cancel the path generation and remove its cache record")
    store:cancel_all()
    expect(opened.manifest.closed and not cache.protected_keys[key],
        "cancel_all must close directories and release manifest protection")
    pending.done(true, { part_path = "late", size = 1, count = 0,
        folders = 0, images = 0, digest = string.rep("0", 32) })
    expect(not stale_called, "cancel_all must suppress stale callbacks")
end

do
    local store, cache, _async, scheduler = fixture()
    local key = "account\0directory-v2|/Books/Shared"
    local path = "/cache/shared.manifest"
    local manifest = new_manifest("/Books/Shared", 1, 1)
    cache.records[key] = { path = path, kind = "manifest" }
    manifest_files[path] = manifest
    local first, second
    store:load("/Books/Shared", { on_ready = function(value) first = value end })
    scheduler:flush()
    store:load("/Books/Shared", { on_ready = function(value) second = value end })
    scheduler:flush()
    expect(first == second and not manifest.closed,
        "same-path consumers must share an open directory")
    first:close()
    expect(not manifest.closed,
        "closing one directory consumer must retain the shared manifest")
    second:close()
    expect(manifest.closed,
        "the shared manifest closes after the final directory consumer releases it")
end

do
    local store, _cache, async, _scheduler, reporter = fixture()
    store:load("/Books/Callback", {
        on_ready = function() error("ready callback failed") end,
    })
    local task = async.tasks[1]
    local descriptor = task.work()
    local ok = pcall(task.done, true, descriptor)
    expect(ok and #reporter.failures == 1
        and reporter.stages[#reporter.stages] == "load_directory",
        "directory callbacks must be isolated by the central reporter")
end

do
    local settings_store = {
        readSetting = function(_self, _key, default) return default end,
        saveSetting = function() end,
        flush = function() end,
    }
    local cache = Cache:new{
        root = "/cache",
        limit_bytes = 1024,
        store = settings_store,
        cache_key_validator = function() return true end,
        fs = {
            make_path = function() end, exists = function() return false end,
            size = function() return nil end, rename = function() return true end,
            remove = function() return true end, list = function() return {} end,
        },
    }
    cache:set_protected({ reader_a = true })
    cache:protect("manifest")
    cache:set_protected({ reader_b = true })
    expect(not cache.protected_keys.reader_a and cache.protected_keys.reader_b
        and cache.protected_keys.manifest,
        "replacing reader protection must preserve active manifest leases")
    cache:unprotect("manifest")
    expect(cache.protected_keys.reader_b and not cache.protected_keys.manifest,
        "releasing a manifest lease must preserve the reader protection set")
end

print(("directory_store_spec: %d checks"):format(checks))
