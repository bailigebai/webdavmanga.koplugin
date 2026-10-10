local Cache = {}
Cache.__index = Cache

local ImageProbe = require("webdavmanga.image_probe")
local Formats = require("webdavmanga.image_formats")
local MobiCompat = require("webdavmanga.mobi_compat")
local Identity = require("webdavmanga.manga_identity")

local CURRENT_SCHEMA = 3
local ALLOWED_KINDS = { page = true, cover = true, manifest = true, document = true }
local GB = 1024 * 1024 * 1024
local DEFAULT_BROWSE_TOTAL_BYTES = 5 * GB
local DEFAULT_BROWSE_TRIGGER_BYTES = 3 * GB
local DEFAULT_BROWSE_RETAIN_BYTES = 1 * GB
local DEFAULT_BROWSE_INTERVAL_SECONDS = 10 * 60
local CACHE_FINAL_EXTENSIONS = {
    jpg = true, jpeg = true, png = true, webp = true, gif = true,
    tif = true, tiff = true, svg = true, img = true, manifest = true,
    pdf = true, mobi = true, azw = true, epub = true, cbz = true, cbr = true,
    djvu = true, djv = true, fb2 = true, pdb = true, prc = true,
}

local function default_filesystem()
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    return {
        make_path = function(path) return util.makePath(path) end,
        exists = function(path) return lfs.attributes(path, "mode") == "file" end,
        size = function(path) return lfs.attributes(path, "size") end,
        open = function(path, mode) return io.open(path, mode) end,
        rename = function(source, target) return os.rename(source, target) end,
        remove = function(path) return os.remove(path) end,
        list = function(root)
            local ok, iterator, directory = pcall(lfs.dir, root)
            if not ok or not iterator then return function() return nil end end
            return function()
                while true do
                    local next_ok, name = pcall(iterator, directory)
                    if not next_ok or not name then return nil end
                    if name ~= "." and name ~= ".." then
                        local path = root .. "/" .. name
                        local attributes = lfs.attributes(path)
                        if attributes and attributes.mode == "file" then
                            return {
                                path = path, name = name, size = attributes.size,
                                modified = attributes.modification,
                            }
                        end
                    end
                end
            end
        end,
    }
end

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function safe_extension(extension)
    local value = tostring(extension or "img"):lower():match("^([%w]+)$")
    return value or "img"
end

local function production_cache_key(key)
    return type(key) == "string" and #key == 32
        and key:match("^[0-9a-f]+$") ~= nil
end

local function is_finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function is_positive_integer(value)
    return is_finite_number(value) and value > 0 and value == math.floor(value)
end

local function is_nonnegative_integer(value)
    return is_finite_number(value) and value >= 0 and value == math.floor(value)
end

local function is_direct_descendant(root, path)
    if type(path) ~= "string" then return false end
    local prefix = root .. "/"
    if path:sub(1, #prefix) ~= prefix then return false end
    local filename = path:sub(#prefix + 1)
    return filename ~= "" and not filename:find("/", 1, true)
        and not filename:find("\\", 1, true)
end

local function copy_record(record)
    local copy = {}
    for key, value in pairs(record or {}) do copy[key] = value end
    return copy
end

local function valid_record(key, record, root)
    if type(key) ~= "string" or key == "" or type(record) ~= "table"
        or record.key ~= key or not ALLOWED_KINDS[record.kind]
        or type(record.remote_path) ~= "string"
        or not is_direct_descendant(root, record.path)
        or not is_positive_integer(record.size)
        or type(record.extension) ~= "string" or record.extension == ""
        or record.validated ~= true or not is_finite_number(record.atime) then
        return false
    end
    local filename = record.path:sub(#root + 2)
    local path_key, extension = filename:match("^(.+)%.([%w]+)$")
    if path_key ~= key or extension ~= record.extension then return false end
    if record.kind == "manifest" then
        return record.extension == "manifest"
    end
    if record.kind == "document" then
        return record.validated == true
            and Formats.is_document("x." .. record.extension)
    end
    if not Formats.is_supported("x." .. record.extension) then return false end
    -- Some WebDAV servers label JPEG bytes with a PNG (or other image)
    -- extension.  The client has already validated the signature in that
    -- case; keep the remote extension for the cache filename but validate the
    -- dimensions against the detected format instead of rejecting the hit.
    local metadata_extension = record.extension
    if record.extension_mismatch == true then
        -- A mismatched record is only valid when the published filename uses
        -- the canonical extension for the detected bytes. This invalidates
        -- old entries such as JPEG bytes stored as ``.png``.
        if Formats.extension_for_format(record.format) ~= record.extension then
            return false
        end
        metadata_extension = nil
    end
    return ImageProbe.valid_metadata(record.format,
        record.width, record.height, metadata_extension)
end

local function valid_entries(entries, root)
    if type(entries) ~= "table" then return false end
    for key, record in pairs(entries) do
        if not valid_record(key, record, root) then return false end
    end
    return true
end

local function each_file(fs, root, callback)
    local listed = fs.list(root)
    if type(listed) == "function" then
        while true do
            local file = listed()
            if not file then break end
            callback(file)
        end
    elseif type(listed) == "table" then
        for _, file in ipairs(listed) do callback(file) end
    end
end

function Cache:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.root = assert(options.root, "cache root is required"):gsub("/+$", "")
    object.limit_bytes = assert(tonumber(options.limit_bytes), "cache limit is required")
    object.document_limit_bytes_provider = options.document_limit_bytes_provider
    object.cover_limit_bytes = tonumber(options.cover_limit_bytes)
        or object.limit_bytes
    if not is_positive_integer(object.cover_limit_bytes) then
        object.cover_limit_bytes = object.limit_bytes
    end
    object.store = assert(options.store, "cache index store is required")
    object.unified_quota = options.unified_quota == true
    object.fs = options.fs or default_filesystem()
    object.md5 = options.md5 or default_md5
    object.cache_key_validator = options.cache_key_validator or production_cache_key
    object.clock = options.clock or os.time
    object.browse_total_bytes = tonumber(options.browse_total_bytes)
        or DEFAULT_BROWSE_TOTAL_BYTES
    object.browse_trigger_bytes = tonumber(options.browse_trigger_bytes)
        or DEFAULT_BROWSE_TRIGGER_BYTES
    object.browse_retain_bytes = tonumber(options.browse_retain_bytes)
        or DEFAULT_BROWSE_RETAIN_BYTES
    object.browse_check_interval_seconds = tonumber(options.browse_check_interval_seconds)
        or DEFAULT_BROWSE_INTERVAL_SECONDS
    if not object:_valid_browse_policy() then
        object.browse_total_bytes = DEFAULT_BROWSE_TOTAL_BYTES
        object.browse_trigger_bytes = DEFAULT_BROWSE_TRIGGER_BYTES
        object.browse_retain_bytes = DEFAULT_BROWSE_RETAIN_BYTES
        object.browse_check_interval_seconds = DEFAULT_BROWSE_INTERVAL_SECONDS
    end
    object.browse_last_cleanup_at = tonumber(
        object.store:readSetting("browse_last_cleanup_at"))
    object.protected_keys = {}
    object.base_protected_keys = {}
    object.protection_leases = {}
    object.owned_parts = {}
    object.fs.make_path(object.root)

    object.schema_version = object.store:readSetting("schema_version")
    object.migration_pending = object.store:readSetting("migration_pending", false) == true
    local stored_entries = object.store:readSetting("entries", {})
    if object.schema_version == CURRENT_SCHEMA and valid_entries(stored_entries, object.root) then
        object.entries = stored_entries
    else
        object.entries = {}
        object.legacy_entries = stored_entries
        object.invalid_index = object.schema_version == CURRENT_SCHEMA
    end
    return object
end

function Cache:_flush()
    if self.unified_quota and self.store.cache_index_size then
        local previous=self.store.on_disk_size and self.store:on_disk_size() or 0
        if self:total_size()+previous>self.limit_bytes then return false end
    end
    self.store:saveSetting("schema_version", self.schema_version)
    self.store:saveSetting("migration_pending", self.migration_pending == true)
    self.store:saveSetting("entries", self.entries)
    if self.browse_last_cleanup_at ~= nil then
        self.store:saveSetting("browse_last_cleanup_at", self.browse_last_cleanup_at)
    end
    if self.store.flush then return self.store:flush() end
end

function Cache:key_for(identity, remote_path, kind)
    local namespace = tostring(identity or "")
    -- A cover is a separate cache namespace even when it points at the same
    -- first image as a reader page. Otherwise publishing the cover replaces
    -- the page record and defeats the independent cover quota.
    if kind == "cover" then namespace = namespace .. "\0cover" end
    return self.md5(namespace .. "\0" .. tostring(remote_path or ""))
end

function Cache:paths_for(key, extension, part_token)
    local final_path = self.root .. "/" .. tostring(key) .. "." .. safe_extension(extension)
    local token = tostring(part_token or ""):match("^([%w_-]+)$")
    local part_path = token and final_path .. "." .. token .. ".part" or final_path .. ".part"
    self.owned_parts[part_path] = true
    return final_path, part_path
end

function Cache:_rebuild_protected()
    local protected = {}
    for key in pairs(self.base_protected_keys) do protected[key] = true end
    for key in pairs(self.protection_leases) do protected[key] = true end
    self.protected_keys = protected
end

function Cache:set_protected(key_set)
    local protected = {}
    for key, value in pairs(key_set or {}) do
        if type(key) == "string" and value == true then
            protected[key] = true
        elseif type(key) == "number" and type(value) == "string" then
            protected[value] = true
        end
    end
    self.base_protected_keys = protected
    self:_rebuild_protected()
end

function Cache:protect(key)
    if type(key) ~= "string" or key == "" then return false end
    self.protection_leases[key] = (self.protection_leases[key] or 0) + 1
    self:_rebuild_protected()
    return true
end

function Cache:unprotect(key)
    local count = self.protection_leases[key]
    if not count then return false end
    if count > 1 then
        self.protection_leases[key] = count - 1
    else
        self.protection_leases[key] = nil
    end
    self:_rebuild_protected()
    return true
end

function Cache:_part_size(part)
    -- Consume only the size; filesystem errors may also return an error string.
    local part_size = self.fs.size(part)
    local size=tonumber(part_size) or 0
    if self.unified_quota then
        local zipwork_size = self.fs.size(part..".zipwork")
        size=size+(tonumber(zipwork_size) or 0)
    end
    if self.unified_quota and self.fs.list then
        each_file(self.fs,self.root,function(entry)
            if entry.path and entry.path:sub(1,#part+5)==part..".wdm-" then
                local entry_size = self.fs.size(entry.path)
                size=size+(tonumber(entry_size) or tonumber(entry.size) or 0)
            end
        end)
    end
    return size
end
function Cache:pending_size()
    local size=0
    for path in pairs(self.owned_parts) do size=size+self:_part_size(path) end
    return size
end
function Cache:write_budget(reserve,required,part,maximum)
    reserve=math.max(0,tonumber(reserve) or 0)
    local disk=self.store.on_disk_size and self.store:on_disk_size() or 0
    local held=0
    for path,amount in pairs(self.write_reservations or {}) do
        if path~=part then held=held+math.max(0,amount-self:_part_size(path)) end
    end
    self:evict((tonumber(required) or 0)+reserve+disk+held,self.protected_keys)
    local available=math.max(0,self.limit_bytes-self:total_size()-disk-reserve-held)
    -- Concurrent shelf tasks reserve a bounded share rather than one task
    -- claiming every free byte. Other cache users retain the existing budget.
    if is_positive_integer(maximum) then available=math.min(available,maximum) end
    if part and available>0 then
        self.write_reservations=self.write_reservations or {}
        self.write_reservations[part]=available+reserve
    end
    return available
end
-- Shelf producers wait for real release/reap, rather than snapshotting a
-- zero allowance into a child process. Waiters are one-shot and cancelable.
function Cache:has_pending_writes(except)
    for path,amount in pairs(self.write_reservations or {}) do
        if path~=except and amount>0 then return true end
    end
    return false
end
function Cache:wait_for_space(owner,callback)
    self.space_waiters=self.space_waiters or {}
    self.space_waiters[owner]=callback
end
function Cache:cancel_space_wait(owner)
    if self.space_waiters then self.space_waiters[owner]=nil end
end
function Cache:wake_space_waiters()
    local waiting=self.space_waiters or {};self.space_waiters={}
    for _,callback in pairs(waiting) do pcall(callback) end
end
function Cache:total_size(entries)
    local total = 0
    entries = entries or self.entries
    for _, record in pairs(entries) do total = total + (tonumber(record.size) or 0) end
    if self.unified_quota and self.store.cache_index_size then
        total = total + self.store:cache_index_size(entries,self.browse_last_cleanup_at)
    end
    if self.unified_quota then total=total+self:pending_size() end
    return total
end

function Cache:content_size()
    local total = 0
    for _, record in pairs(self.entries) do
        if record.kind ~= "cover" then
            total = total + (tonumber(record.size) or 0)
        end
    end
    return total
end

function Cache:browse_size()
    if self.unified_quota then return self:total_size() end
    return self:kind_size("page") + self:kind_size("manifest")
end

-- Streamed document pages use the same physical records as normal browsing.
-- Keep a named API for the settings UI so it cannot accidentally evict full
-- document downloads or cover records when the user manages stream storage.
function Cache:stream_size()
    return self:browse_size()
end

function Cache:stream_policy()
    return self:browse_policy()
end

function Cache:set_stream_policy(values)
    return self:set_browse_policy(values)
end

function Cache:cleanup_stream(force)
    return self:cleanup_browse(force)
end

function Cache:clear_stream_cache()
    local removed, freed, retained, failed = 0, 0, 0, 0
    for key, record in pairs(self.entries) do
        if (record.kind == "page" or record.kind == "manifest") then
            if self.protected_keys[key] then
                retained = retained + (tonumber(record.size) or 0)
            else
                local did_remove = self:_forget(key, true)
                if did_remove then
                    removed = removed + 1
                    freed = freed + (tonumber(record.size) or 0)
                else
                    failed = failed + 1
                end
            end
        end
    end
    if removed > 0 then self:_flush() end
    return failed == 0, {
        removed = removed,
        freed_bytes = freed,
        retained_bytes = retained,
        failed = failed,
    }
end

function Cache:_document_limit_bytes()
    if type(self.document_limit_bytes_provider) == "function" then
        local ok, value = pcall(self.document_limit_bytes_provider)
        value = ok and tonumber(value) or nil
        if is_positive_integer(value) then return value end
    end
    return self.limit_bytes
end

-- Cache records are shared by page, cover, and directory-manifest data.  Keep
-- per-kind accounting available to the UI without exposing the mutable index.
function Cache:kind_size(kind)
    if not ALLOWED_KINDS[kind] then return 0 end
    local total = 0
    for _, record in pairs(self.entries) do
        if record.kind == kind then total = total + (tonumber(record.size) or 0) end
    end
    return total
end

function Cache:kind_count(kind)
    if not ALLOWED_KINDS[kind] then return 0 end
    local count = 0
    for _, record in pairs(self.entries) do
        if record.kind == kind then count = count + 1 end
    end
    return count
end

function Cache:protected_size()
    local total = 0
    for key in pairs(self.protected_keys) do
        local record = self.entries[key]
        if record then total = total + (tonumber(record.size) or 0) end
    end
    return total
end

function Cache:_valid_browse_policy()
    return is_positive_integer(self.browse_total_bytes)
        and is_positive_integer(self.browse_trigger_bytes)
        and is_nonnegative_integer(self.browse_retain_bytes)
        and is_positive_integer(self.browse_check_interval_seconds)
        and self.browse_trigger_bytes <= self.browse_total_bytes
        and self.browse_retain_bytes < self.browse_trigger_bytes
end

function Cache:browse_policy()
    return {
        total_bytes = self.browse_total_bytes,
        trigger_bytes = self.browse_trigger_bytes,
        retain_bytes = self.browse_retain_bytes,
        check_interval_seconds = self.browse_check_interval_seconds,
        last_cleanup_at = self.browse_last_cleanup_at,
    }
end

function Cache:set_browse_policy(values)
    values = values or {}
    local policy = {
        total_bytes = values.total_bytes == nil
            and self.browse_total_bytes or values.total_bytes,
        trigger_bytes = values.trigger_bytes == nil
            and self.browse_trigger_bytes or values.trigger_bytes,
        retain_bytes = values.retain_bytes == nil
            and self.browse_retain_bytes or values.retain_bytes,
        check_interval_seconds = values.check_interval_seconds == nil
            and self.browse_check_interval_seconds or values.check_interval_seconds,
    }
    if not is_positive_integer(policy.total_bytes) then
        return nil, "invalid_browse_total"
    end
    if not is_positive_integer(policy.trigger_bytes) then
        return nil, "invalid_browse_trigger"
    end
    if policy.trigger_bytes > policy.total_bytes then
        return nil, "invalid_browse_trigger_range"
    end
    if not is_nonnegative_integer(policy.retain_bytes) then
        return nil, "invalid_browse_retain"
    end
    if policy.retain_bytes >= policy.trigger_bytes then
        return nil, "invalid_browse_retain_range"
    end
    if not is_positive_integer(policy.check_interval_seconds) then
        return nil, "invalid_browse_interval"
    end
    self.browse_total_bytes = policy.total_bytes
    self.browse_trigger_bytes = policy.trigger_bytes
    self.browse_retain_bytes = policy.retain_bytes
    self.browse_check_interval_seconds = policy.check_interval_seconds
    self.limit_bytes = policy.total_bytes
    return true
end

function Cache:_forget(key, remove_file)
    local record = self.entries[key]
    if not record then return false, false end
    if remove_file and is_direct_descendant(self.root, record.path) then
        local removed = self.fs.remove(record.path)
        if not removed and self.fs.exists(record.path) then return false, false end
    end
    self.entries[key] = nil
    self.protected_keys[key] = nil
    return true, true
end

function Cache:lookup_record(key)
    local record = self.entries[key]
    if not record then return nil end
    if not valid_record(key, record, self.root) or not self.fs.exists(record.path) then
        self.entries[key] = nil
        self.protected_keys[key] = nil
        self:_flush()
        return nil
    end
    if record.kind == "document" and type(self.fs.size) == "function" then
        local file_size = self.fs.size(record.path)
        local actual_size = tonumber(file_size)
        if actual_size and actual_size ~= record.size then
            self:_forget(key, true)
            self:_flush()
            return nil
        end
    end
    if record.kind == "document" and record.extension == "mobi"
        and type(self.fs.open) == "function" then
        local ok, repaired = pcall(MobiCompat.repair_cached_file,
            record.path, self.fs.open)
        if not ok or repaired ~= true then
            self:_forget(key, true)
            self:_flush()
            return nil
        end
    end
    if (record.kind == "page" or record.kind == "cover") and record.validated ~= true then
        self:_forget(key, true)
        self:_flush()
        return nil
    end
    local touched_at = self.clock()
    if is_finite_number(touched_at) then record.atime = touched_at end
    -- LRU touches are kept in memory and persisted by the next cache
    -- mutation/teardown. Flushing on every hit blocks the Kindle UI while a
    -- page and its prefetch neighbors are being opened.
    return record.path, copy_record(record)
end

function Cache:lookup(key)
    return self:lookup_record(key)
end

function Cache:list_documents(identity)
    local documents = {}
    for key, record in pairs(self.entries) do
        if record.kind == "document"
            and self:key_for(identity, record.remote_path) == key then
            local local_path, current = self:lookup_record(key)
            if local_path and current then
                current.name = current.remote_path:match("([^/]+)$") or current.remote_path
                current.local_path = local_path
                documents[#documents + 1] = current
            end
        end
    end
    table.sort(documents, function(left, right)
        return tostring(left.name):lower() < tostring(right.name):lower()
    end)
    return documents
end

function Cache:list_all_documents()
    local documents = {}
    for key, record in pairs(self.entries) do
        if type(record) == "table" and record.kind == "document"
            and valid_record(key, record, self.root)
            and self.fs.exists(record.path) then
            local current = copy_record(record)
            current.name = current.remote_path:match("([^/]+)$") or current.remote_path
            current.local_path = record.path
            local connection_identity = record.identity
            if type(connection_identity) ~= "string" or connection_identity == "" then
                connection_identity = "legacy-cache:" .. tostring(key)
            end
            current.identity = Identity.manga(connection_identity, record.remote_path)
            documents[#documents + 1] = current
        end
    end
    table.sort(documents, function(left, right)
        return tostring(left.identity) < tostring(right.identity)
    end)
    return documents
end

function Cache:_evict_to(target_bytes, protected_keys)
    local target = math.max(0, tonumber(target_bytes) or 0)
    local protected = protected_keys or self.protected_keys
    local bytes_to_free = self:total_size() - target
    if bytes_to_free <= 0 then return 0, false end

    local candidates = {}
    for key, record in pairs(self.entries) do
        if not protected[key] then candidates[#candidates + 1] = { key = key, record = record } end
    end
    table.sort(candidates, function(left, right)
        local left_time = tonumber(left.record.atime) or 0
        local right_time = tonumber(right.record.atime) or 0
        if left_time == right_time then return left.key < right.key end
        return left_time < right_time
    end)

    local freed, changed = 0, false
    for _, candidate in ipairs(candidates) do
        if self.unified_quota and self:total_size() <= target then break end
        if not self.unified_quota and freed >= bytes_to_free then break end
        local record = candidate.record
        if is_direct_descendant(self.root, record.path) then
            local removed = self.fs.remove(record.path)
            if removed or not self.fs.exists(record.path) then
                freed = freed + (tonumber(record.size) or 0)
                self.entries[candidate.key] = nil
                changed = true
            end
        else
            self.entries[candidate.key] = nil
            changed = true
        end
    end
    return freed, changed
end

function Cache:_evict_kind_to(kind, target_bytes, protected_keys)
    local target = math.max(0, tonumber(target_bytes) or 0)
    local protected = protected_keys or self.protected_keys
    local bytes_to_free = self:kind_size(kind) - target
    if bytes_to_free <= 0 then return 0, false end

    local candidates = {}
    for key, record in pairs(self.entries) do
        if record.kind == kind and not protected[key] then
            candidates[#candidates + 1] = { key = key, record = record }
        end
    end
    table.sort(candidates, function(left, right)
        local left_time = tonumber(left.record.atime) or 0
        local right_time = tonumber(right.record.atime) or 0
        if left_time == right_time then return left.key < right.key end
        return left_time < right_time
    end)

    local freed, changed = 0, false
    for _, candidate in ipairs(candidates) do
        if freed >= bytes_to_free then break end
        local record = candidate.record
        if is_direct_descendant(self.root, record.path) then
            local removed = self.fs.remove(record.path)
            if removed or not self.fs.exists(record.path) then
                freed = freed + (tonumber(record.size) or 0)
                self.entries[candidate.key] = nil
                changed = true
            end
        else
            self.entries[candidate.key] = nil
            changed = true
        end
    end
    return freed, changed
end

function Cache:_evict(required_bytes, protected_keys)
    if self.unified_quota then return self:_evict_to(self.limit_bytes-(tonumber(required_bytes) or 0),protected_keys) end
    local required = math.max(0, tonumber(required_bytes) or 0)
    return self:_evict_noncover_to(self.limit_bytes - required, protected_keys)
end

function Cache:_evict_noncover_to(target_bytes, protected_keys)
    local target = math.max(0, tonumber(target_bytes) or 0)
    local protected = protected_keys or self.protected_keys
    local bytes_to_free = self:browse_size() - target
    if bytes_to_free <= 0 then return 0, false end

    local candidates = {}
    for key, record in pairs(self.entries) do
        if record.kind ~= "cover" and record.kind ~= "document"
            and not protected[key] then
            candidates[#candidates + 1] = { key = key, record = record }
        end
    end
    table.sort(candidates, function(left, right)
        local left_time = tonumber(left.record.atime) or 0
        local right_time = tonumber(right.record.atime) or 0
        if left_time == right_time then return left.key < right.key end
        return left_time < right_time
    end)

    local freed, changed = 0, false
    for _, candidate in ipairs(candidates) do
        if freed >= bytes_to_free then break end
        local record = candidate.record
        if is_direct_descendant(self.root, record.path) then
            local removed = self.fs.remove(record.path)
            if removed or not self.fs.exists(record.path) then
                freed = freed + (tonumber(record.size) or 0)
                self.entries[candidate.key] = nil
                changed = true
            end
        else
            self.entries[candidate.key] = nil
            changed = true
        end
    end
    return freed, changed
end

function Cache:evict(required_bytes, protected_keys)
    local freed, changed = self:_evict(required_bytes, protected_keys)
    if changed then self:_flush() end
    return freed
end

-- Periodic LRU maintenance for WebDAV browsing results.  The current page
-- and nearby prefetch pages remain protected by the normal cache lease API.
function Cache:cleanup_browse(force)
    local now = self.clock()
    if not is_finite_number(now) then now = 0 end
    if not force and is_finite_number(self.browse_last_cleanup_at)
        and now - self.browse_last_cleanup_at < self.browse_check_interval_seconds then
        return 0, false, "not_due"
    end
    self.browse_last_cleanup_at = now
    if self:browse_size() <= self.browse_trigger_bytes then
        return 0, false, "below_trigger"
    end
    local evict = self.unified_quota and self._evict_to or self._evict_noncover_to
    local freed, changed = evict(self, self.browse_retain_bytes, self.protected_keys)
    if changed then self:_flush() end
    return freed, changed, changed and "cleaned" or "nothing_to_evict"
end

function Cache:publish(record, part_path)
    record = record or {}
    self.owned_parts[part_path] = nil
    if self.write_reservations then self.write_reservations[part_path]=nil end
    local kind = record.kind or "page"
    if not ALLOWED_KINDS[kind] then
        self.fs.remove(part_path)
        return nil, "invalid_kind"
    end
    local part_size = self.fs.size(part_path)
    local actual_size = tonumber(part_size) or tonumber(record.size) or 0
    if not is_positive_integer(actual_size) then return nil, "empty_part" end
    local extension = safe_extension(record.extension)
    if record.extension_mismatch == true then
        extension = Formats.extension_for_format(record.format)
        if not extension then
            self.fs.remove(part_path)
            return nil, "unvalidated"
        end
    end
    local final_path = self.root .. "/" .. tostring(record.key) .. "." .. extension
    local previous = self.entries[record.key]
    local previous_size = previous and (tonumber(previous.size) or 0) or 0
    local validated = record.validated
    if validated == nil and (kind == "page" or kind == "cover") then
        local metadata_extension = extension
        if record.extension_mismatch == true then metadata_extension = nil end
        validated = ImageProbe.valid_metadata(record.format,
            record.width, record.height, metadata_extension)
    end
    if type(validated) ~= "boolean"
        or ((kind == "page" or kind == "cover") and not validated) then
        self.fs.remove(part_path)
        return nil, "unvalidated"
    end
    if kind == "manifest" then
        if not validated or extension ~= "manifest" then
            self.fs.remove(part_path)
            return nil, "unvalidated"
        end
    elseif kind == "document" then
        if validated ~= true or not Formats.is_document("x." .. extension) then
            self.fs.remove(part_path)
            return nil, "unvalidated"
        end
        if extension == "mobi" and type(self.fs.open) == "function" then
            local ok, repaired = pcall(MobiCompat.repair_cached_file,
                part_path, self.fs.open)
            if not ok or repaired ~= true then
                self.fs.remove(part_path)
                return nil, "invalid_document_cache"
            end
        end
    else
        local metadata_extension = extension
        if record.extension_mismatch == true then metadata_extension = nil end
        if not Formats.is_supported("x." .. extension)
            or not ImageProbe.valid_metadata(record.format,
                record.width, record.height, metadata_extension) then
            self.fs.remove(part_path)
            return nil, "unvalidated"
        end
    end
    local quota = self.unified_quota and self.limit_bytes or kind == "cover" and self.cover_limit_bytes
        or (kind == "document" and self:_document_limit_bytes() or self.limit_bytes)
    if actual_size > quota then
        self.fs.remove(part_path)
        return nil, "cache_limit"
    end

    local protected = {}
    for key, value in pairs(self.protected_keys) do protected[key] = value end
    protected[record.key] = true
    local previous_quota_size = previous and (previous.kind == kind
        or (kind ~= "cover" and kind ~= "document"
            and previous.kind ~= "cover" and previous.kind ~= "document"))
        and previous_size or 0
    local required = math.max(0, actual_size - previous_quota_size)
    local _freed, evicted
    local published_at = self.clock()
    if not is_finite_number(published_at) then published_at = 0 end
    local candidate = {
        key = record.key, kind = kind, remote_path = tostring(record.remote_path or ""),
        identity = type(record.identity) == "string" and record.identity or nil,
        path = final_path, size = actual_size, extension = extension,
        validated = validated, extension_mismatch = record.extension_mismatch == true,
        etag = record.etag, modified = record.modified,
        format = record.format, width = record.width, height = record.height,
        crop = record.crop, crop_checked = record.crop_checked,
        crop_reason = record.crop_reason, atime = published_at,
    }
    local function projected_size()
        local entries = {}; for k,v in pairs(self.entries) do entries[k] = v end
        entries[record.key] = candidate
        local size = self:total_size(entries)
        -- Atomic registry writes temporarily coexist with the previous file.
        if self.store.on_disk_size then size=size+self.store:on_disk_size()
        elseif self.store.cache_index_size then size = size + self.store:cache_index_size(self.entries,self.browse_last_cleanup_at) end
        return size
    end
    if self.unified_quota then
        while projected_size() > quota do
            local _, changed = self:_evict_to(math.max(0,
                self:total_size() - (projected_size() - quota)), protected)
            evicted = evicted or changed
            if not changed then break end
            -- Reclaim the old registry as well, before the candidate's
            -- atomic write needs room for both registration files.
            if self:_flush()==false then
                self.fs.remove(part_path)
                return nil,"index_write_failed"
            end
        end
    elseif kind == "cover" then
        _freed, evicted = self:_evict_kind_to(
            kind, self.cover_limit_bytes - required, protected)
    elseif kind ~= "document" then
        _freed, evicted = self:_evict(required, protected)
    end
    local quota_size = kind == "cover" and self:kind_size("cover")
        or (kind == "document" and self:kind_size("document") or self:browse_size())
    if (self.unified_quota and projected_size() > quota)
        or (not self.unified_quota and quota_size - previous_quota_size + actual_size > quota) then
        self.fs.remove(part_path)
        if evicted then self:_flush() end
        return nil, "cache_limit"
    end
    local ok, err = self.fs.rename(part_path, final_path)
    if not ok then
        if evicted then self:_flush() end
        return nil, err or "rename_failed"
    end
    if previous and previous.path ~= final_path and is_direct_descendant(self.root, previous.path) then
        local previous_removed = self.fs.remove(previous.path)
        if not previous_removed and self.fs.exists(previous.path) then
            self.fs.remove(final_path)
            if evicted then self:_flush() end
            return nil, "replace_remove_failed"
        end
    end
    self.entries[record.key] = candidate
    if self:_flush() == false and self.unified_quota then
        self.fs.remove(final_path)
        self.entries[record.key] = nil
        self:_flush()
        return nil, "index_write_failed"
    end
    return final_path
end

function Cache:remove(key)
    local removed, changed = self:_forget(key, true)
    if changed then self:_flush() end
    return removed
end

function Cache:discard_part(key, extension, part_token)
    local final_path = self.root .. "/" .. tostring(key) .. "." .. safe_extension(extension)
    local token = tostring(part_token or ""):match("^([%w_-]+)$")
    local part_path = token and final_path .. "." .. token .. ".part" or final_path .. ".part"
    self.owned_parts[part_path] = nil
    if self.write_reservations then self.write_reservations[part_path]=nil end
    if self.unified_quota then self.fs.remove(part_path..".zipwork") end
    if self.unified_quota and self.fs.list then
        each_file(self.fs,self.root,function(entry)
            if entry.path and entry.path:sub(1,#part_path+5)==part_path..".wdm-" then
                self.fs.remove(entry.path)
            end
        end)
    end
    local removed = self.fs.remove(part_path)
    return removed or not self.fs.exists(part_path)
end

function Cache:set_limit_bytes(limit_bytes)
    if not is_positive_integer(limit_bytes) then return nil, "invalid_limit" end
    self.limit_bytes = limit_bytes
    local freed = self:_evict(0, self.protected_keys)
    self:_flush()
    return true, freed
end

function Cache:set_cover_limit_bytes(limit_bytes)
    if not is_positive_integer(limit_bytes) then return nil, "invalid_cover_limit" end
    self.cover_limit_bytes = limit_bytes
    local freed = self:_evict_kind_to("cover", limit_bytes, self.protected_keys)
    self:_flush()
    return true, freed
end

function Cache:_remove_parts(maximum_age)
    local now, removed, failed = self.clock(), 0, 0
    each_file(self.fs, self.root, function(file)
        if type(file) == "table" and type(file.name) == "string"
            and file.name:match("%.part$") and is_direct_descendant(self.root, file.path)
            and not self.owned_parts[file.path]
            and (maximum_age == nil or now - (tonumber(file.modified) or 0) > maximum_age) then
            local did_remove = self.fs.remove(file.path)
            if did_remove or not self.fs.exists(file.path) then removed = removed + 1
            else failed = failed + 1 end
        end
    end)
    return removed, failed
end

function Cache:_cache_final_key(file)
    if type(file) ~= "table" or type(file.name) ~= "string" then return nil end
    if file.name:match("%.part$") then return nil end
    local key, extension = file.name:match("^(.+)%.([%w]+)$")
    if extension and extension ~= extension:lower() then return nil end
    if not key or not CACHE_FINAL_EXTENSIONS[extension] then return nil end
    if not self.cache_key_validator(key) then return nil end
    return key
end

function Cache:_remove_orphan_finals(preserved_paths)
    local removed, failed = 0, 0
    each_file(self.fs, self.root, function(file)
        local key = self:_cache_final_key(file)
        if key and is_direct_descendant(self.root, file.path)
            and not (preserved_paths and preserved_paths[file.path])
            and not self.protected_keys[key] then
            local did_remove = self.fs.remove(file.path)
            if did_remove or not self.fs.exists(file.path) then removed = removed + 1
            else failed = failed + 1 end
        end
    end)
    return removed, failed
end

function Cache:cleanup_parts(max_age_seconds)
    local removed = self:_remove_parts(tonumber(max_age_seconds) or 0)
    return removed
end

function Cache:clear()
    local changed, failed = false, 0
    for key, record in pairs(self.entries) do
        if not self.protected_keys[key] then
            if not is_direct_descendant(self.root, record.path) then
                self.entries[key], changed = nil, true
            else
                local removed = self.fs.remove(record.path)
                if removed or not self.fs.exists(record.path) then
                    self.entries[key], changed = nil, true
                else
                    failed = failed + 1
                end
            end
        end
    end
    local _parts_removed, part_failures = self:_remove_parts(nil)
    failed = failed + part_failures
    local preserved_paths = {}
    for _, record in pairs(self.entries) do preserved_paths[record.path] = true end
    local _finals_removed, final_failures = self:_remove_orphan_finals(preserved_paths)
    failed = failed + final_failures
    if changed then self:_flush() end
    return failed == 0, self:protected_size(), failed
end

-- Reset only the cache index.  This intentionally leaves every file in place:
-- the button is a recovery operation for stale metadata and must never remove
-- a source image from NAS/Kindle or a local cache artifact unexpectedly.
function Cache:clear_index(predicate)
    if predicate ~= nil and type(predicate) ~= "function" then
        return nil, "invalid_predicate"
    end
    local changed, retained = false, 0
    for key, record in pairs(self.entries) do
        if not predicate or predicate(record, key) then
            if self.protected_keys[key] then
                retained = retained + (tonumber(record.size) or 0)
            else
                self.entries[key] = nil
                self.protected_keys[key] = nil
                changed = true
            end
        end
    end
    if changed then self:_flush() end
    return true, retained, 0
end

function Cache:clear_matching_cache(predicate)
    if type(predicate) ~= "function" then return nil, "invalid_predicate" end
    local changed, retained, failed = false, 0, 0
    for key, record in pairs(self.entries) do
        if predicate(record, key) then
            if self.protected_keys[key] then
                retained = retained + (tonumber(record.size) or 0)
            else
                local removed, record_changed = self:_forget(key, true)
                if removed then changed = changed or record_changed else failed = failed + 1 end
            end
        end
    end
    if changed then self:_flush() end
    return failed == 0, retained, failed
end

function Cache:clear_kind_index(kind)
    if not ALLOWED_KINDS[kind] then return nil, "invalid_kind" end
    return self:clear_index(function(record) return record.kind == kind end)
end

-- Clear one plugin-owned cache namespace and release its physical files.
-- This is separate from clear_kind_index: the public page-cache action is
-- index-only for recovery safety, while cover files are plugin-generated
-- thumbnails and can be reclaimed on demand.
function Cache:clear_kind_cache(kind)
    if not ALLOWED_KINDS[kind] then return nil, "invalid_kind" end
    local changed, retained, failed = false, 0, 0
    for key, record in pairs(self.entries) do
        if record.kind == kind then
            if self.protected_keys[key] then
                retained = retained + (tonumber(record.size) or 0)
            else
                local removed = true
                if is_direct_descendant(self.root, record.path) then
                    removed = self.fs.remove(record.path)
                    if not removed and self.fs.exists(record.path) then
                        failed = failed + 1
                    else
                        removed = true
                    end
                end
                if removed then
                    self.entries[key] = nil
                    self.protected_keys[key] = nil
                    changed = true
                end
            end
        end
    end
    if changed then self:_flush() end
    return failed == 0, retained, failed
end

function Cache:clear_page_files()
    local changed, removed_files, freed_bytes, retained_bytes, failed =
        false, 0, 0, 0, 0
    for key, record in pairs(self.entries) do
        if record.kind == "page" then
            if self.protected_keys[key] then
                retained_bytes = retained_bytes + (tonumber(record.size) or 0)
            else
                local existed = is_direct_descendant(self.root, record.path)
                    and self.fs.exists(record.path)
                local removed = not existed or self.fs.remove(record.path)
                if removed or not self.fs.exists(record.path) then
                    if existed then
                        removed_files = removed_files + 1
                        freed_bytes = freed_bytes + (tonumber(record.size) or 0)
                    end
                    self.entries[key] = nil
                    changed = true
                else
                    failed = failed + 1
                end
            end
        end
    end

    local preserved_paths = {}
    for _, record in pairs(self.entries) do preserved_paths[record.path] = true end
    each_file(self.fs, self.root, function(file)
        local key = self:_cache_final_key(file)
        if key and Formats.is_image(file.name)
            and is_direct_descendant(self.root, file.path)
            and not preserved_paths[file.path] and not self.protected_keys[key] then
            local did_remove = self.fs.remove(file.path)
            if did_remove or not self.fs.exists(file.path) then
                removed_files = removed_files + 1
                freed_bytes = freed_bytes + (tonumber(file.size) or 0)
            else
                failed = failed + 1
            end
        end
    end)
    if changed then self:_flush() end
    return failed == 0, {
        removed_files = removed_files, freed_bytes = freed_bytes,
        retained_bytes = retained_bytes, failed = failed,
    }
end

function Cache:clear_except_kind_index(kind)
    if not ALLOWED_KINDS[kind] then return nil, "invalid_kind" end
    return self:clear_index(function(record) return record.kind ~= kind end)
end

function Cache:migrate(schema_version)
    local target = tonumber(schema_version)
    if not is_positive_integer(target) then
        return { invalidated = 0, parts_removed = 0, migrated = false }
    end
    local reset_required = self.schema_version ~= target or self.invalid_index
    if reset_required and not self.migration_pending then
        self.migration_pending = true
        self.store:saveSetting("migration_pending", true)
        if self.store.flush then self.store:flush() end
    end

    local invalidated, failed = 0, 0
    local attempted_paths = {}
    if reset_required then
        local source = self.legacy_entries or self.entries
        if type(source) == "table" then
            for _, record in pairs(source) do
                invalidated = invalidated + 1
                if type(record) == "table" and is_direct_descendant(self.root, record.path) then
                    attempted_paths[record.path] = true
                    local removed = self.fs.remove(record.path)
                    if not removed and self.fs.exists(record.path) then failed = failed + 1 end
                end
            end
        end
    end
    local parts_removed, part_failures = self:_remove_parts(nil)
    failed = failed + part_failures
    local preserved_paths = reset_required and attempted_paths or {}
    if not reset_required then
        for _, record in pairs(self.entries) do preserved_paths[record.path] = true end
    end
    local finals_removed, final_failures = self:_remove_orphan_finals(preserved_paths)
    failed = failed + final_failures

    if failed > 0 then
        self.migration_pending = true
        self.store:saveSetting("migration_pending", true)
        if self.store.flush then self.store:flush() end
        return {
            invalidated = invalidated, parts_removed = parts_removed,
            finals_removed = finals_removed, failed = failed,
            migrated = false, pending = true,
        }
    end

    if reset_required then
        self.entries, self.legacy_entries, self.invalid_index = {}, nil, nil
        self.schema_version = target
    end
    local was_pending = self.migration_pending
    self.migration_pending = false
    if reset_required or was_pending then self:_flush() end
    return {
        invalidated = invalidated, parts_removed = parts_removed,
        finals_removed = finals_removed, failed = 0,
        migrated = reset_required, pending = false,
    }
end

return Cache
