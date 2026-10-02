local Formats = require("webdavmanga.image_formats")
local ImageProbe = require("webdavmanga.image_probe")
local NaturalSort = require("webdavmanga.natural_sort")
local Identity = require("webdavmanga.manga_identity")

local OfflineCache = {}
OfflineCache.__index = OfflineCache

local GB = 1024 * 1024 * 1024
local NAMESPACE = "webdavmanga-offline-v1"

local function default_filesystem()
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    return {
        make_path = function(path) return util.makePath(path) end,
        exists = function(path) return lfs.attributes(path, "mode") == "file" end,
        size = function(path) return lfs.attributes(path, "size") end,
        rename = function(source, target) return os.rename(source, target) end,
        remove = function(path) return os.remove(path) end,
    }
end

local function default_disk_usage(path)
    return require("util").diskUsage(path)
end

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function copy_table(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function scalar(value)
    local kind = type(value)
    return kind == "string" or kind == "number" or kind == "boolean"
end

local function finite_positive_integer(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and value > 0 and value == math.floor(value)
end

local function normalize_root(path)
    local value = tostring(path or ""):match("^%s*(.-)%s*$"):gsub("\\", "/")
    value = value:gsub("/+", "/")
    if #value > 1 then value = value:gsub("/+$", "") end
    return value
end

local function valid_root(path)
    path = normalize_root(path)
    return path == "/mnt/us" or path:sub(1, 8) == "/mnt/us/"
end

local function within_root(root, path)
    if not valid_root(root) or type(path) ~= "string" or path:find("\\", 1, true)
        or path:find("%z") or path:find("..", 1, true) then
        return false
    end
    return path:sub(1, #root + 1) == root .. "/"
end

local function sanitize_component(value, fallback)
    local text = tostring(value or ""):match("^%s*(.-)%s*$")
    text = text:gsub("[\\/:*?\"<>|%c]", "_")
    text = text:gsub("%.+", "_"):gsub("%s+", " ")
    text = text:gsub("^[_%s]+", ""):gsub("[_%s]+$", "")
    if text == "" then text = fallback or "item" end
    if #text > 72 then text = text:sub(1, 72) end
    return text
end

local function safe_extension(name)
    local extension = Formats.extension(tostring(name or "")) or "img"
    extension = tostring(extension):lower():match("^([%w]+)$")
    return extension or "img"
end

local function valid_owned_path(key, root, path)
    if type(key) ~= "string" or #key ~= 32 or not key:match("^%x+$")
        or not within_root(root, path) then
        return false
    end
    local filename = path:match("([^/]+)$") or ""
    return filename:find("-" .. key:sub(1, 8) .. ".", 1, true) ~= nil
end

local function valid_record(key, record)
    if type(key) ~= "string" or key == "" or type(record) ~= "table"
        or type(record.key) ~= "string" or record.namespace ~= NAMESPACE or record.owned ~= true
        or type(record.identity) ~= "string" or type(record.remote_path) ~= "string"
        or type(record.manga_path) ~= "string" or record.manga_path == ""
        or not valid_root(record.root)
        or not valid_owned_path(record.key, record.root, record.local_path)
        or (key ~= record.key and key ~= record.key .. "\0" .. record.root
            and key ~= record.key .. "\0" .. record.local_path)
        or not finite_positive_integer(record.size)
        or type(record.extension) ~= "string" then
        return false
    end
    local metadata_extension = record.extension
    if record.extension_mismatch == true then
        if Formats.extension_for_format(record.format) ~= record.extension then return false end
        metadata_extension = nil
    end
    return ImageProbe.valid_metadata(record.format, record.width,
        record.height, metadata_extension)
end

local function valid_job(key, job, identity, manga_path)
    return type(job) == "table" and job.schema_version == 2 and job.key == key
        and job.identity == tostring(identity or "") and job.manga_path == manga_path
        and type(job.manga_name) == "string" and scalar(job.status)
end

function OfflineCache:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.store = assert(options.store, "offline cache store is required")
    object.root_provider = assert(options.root_provider, "offline root provider is required")
    object.limit_bytes_provider = options.limit_bytes_provider or function() return 0 end
    object.external_bytes_provider = options.external_bytes_provider
    object.fs = options.fs or default_filesystem()
    object.disk_usage = options.disk_usage or default_disk_usage
    object.md5 = options.md5 or default_md5
    object.reserve_bytes = math.max(5 * GB,
        math.floor(tonumber(options.reserve_bytes) or 5 * GB))
    local entries = object.store:readSetting("entries", {})
    object.entries = type(entries) == "table" and entries or {}
    local saved_jobs = object.store:readSetting("jobs", {})
    object.jobs = type(saved_jobs) == "table" and saved_jobs or {}
    object.owned_parts = {}
    object:_migrate_legacy_jobs()
    return object
end

function OfflineCache:root()
    return normalize_root(self.root_provider())
end

function OfflineCache:_ensure_root()
    local root = self:root()
    if not valid_root(root) then return nil, "invalid_offline_root" end
    local made, err = self.fs.make_path(root)
    if made == false or made == nil then return nil, err or "make_path_failed" end
    return root
end

function OfflineCache:key_for(identity, remote_path)
    return self.md5(tostring(identity or "") .. "\0" .. tostring(remote_path or ""))
end

function OfflineCache:_flush()
    self.store:saveSetting("schema_version", 2)
    self.store:saveSetting("entries", self.entries)
    self.store:saveSetting("jobs", self.jobs)
    if self.store.flush then self.store:flush() end
end

function OfflineCache:_limit_bytes()
    local ok, value = pcall(self.limit_bytes_provider)
    value = ok and tonumber(value) or 0
    if not value or value ~= value or value == math.huge or value <= 0 then return 0 end
    return math.floor(value)
end

function OfflineCache:_external_bytes()
    if type(self.external_bytes_provider) ~= "function" then return 0 end
    local ok, value = pcall(self.external_bytes_provider)
    value = ok and tonumber(value) or nil
    if not value or value ~= value or value == math.huge or value < 0 then return 0 end
    return math.floor(value)
end

function OfflineCache:_valid_record(key, record, identity, any_root)
    return valid_record(key, record) and (any_root or (record.root == self:root()
        and key ~= record.key .. "\0" .. record.local_path))
        and (identity == nil or record.identity == tostring(identity))
        and self.fs.exists(record.local_path)
end

function OfflineCache:_offline_bytes()
    local total = 0
    for key, record in pairs(self.entries) do
        if self:_valid_record(key, record, nil, true) then total = total + record.size end
    end
    return total
end

function OfflineCache:_migrate_legacy_jobs()
    local migrated = {}
    for key, job in pairs(self.jobs) do
        if type(job) == "table" and type(job.manga_path) == "string"
            and key == self:key_for(job.identity, job.manga_path)
            and valid_job(key, job, job.identity, job.manga_path) then
            local root, ambiguous = job.root, false
            if root == nil then
                for entry_key, record in pairs(self.entries) do
                    if self:_valid_record(entry_key, record, job.identity, true)
                        and record.manga_path == job.manga_path then
                        if root and root ~= record.root then ambiguous = true; break end
                        root = record.root
                    end
                end
                root = root or self:root()
            end
            if not ambiguous and valid_root(root) then
                migrated[#migrated + 1] = { key = key, root = root, job = job }
            end
        end
    end
    for _, item in ipairs(migrated) do
        local key = item.key .. "\0" .. item.root
        if self.jobs[key] == nil then
            local job = copy_table(item.job)
            job.key, job.root = key, item.root
            self.jobs[key] = job
        end
        self.jobs[item.key] = nil
    end
    if #migrated > 0 then self:_flush() end
end

function OfflineCache:_job(identity, manga_path)
    local root = self:root()
    local key = self:key_for(identity, manga_path) .. "\0" .. root
    local job = self.jobs[key]
    if valid_job(key, job, identity, manga_path) and job.root == root then return job end
end

function OfflineCache:save_job(identity, manga, values, destination_root)
    if type(manga) ~= "table" or type(manga.path) ~= "string" or manga.path == "" then
        return nil, "invalid_manga"
    end
    values = type(values) == "table" and values or {}
    local identity_text = tostring(identity or "")
    local root = normalize_root(destination_root or self:root())
    if not valid_root(root) then return nil, "invalid_offline_root" end
    local key = self:key_for(identity_text, manga.path) .. "\0" .. root
    local job = {
        schema_version = 2, key = key, identity = identity_text, root = root,
        manga_path = manga.path, manga_name = tostring(manga.name or ""),
    }
    for _, name in ipairs({
        "status", "total_pages", "total_bytes", "cached_pages",
        "cached_bytes", "downloaded", "failed", "error_code",
        "detail_code", "detail_used_bytes", "detail_required_bytes",
        "detail_limit_bytes",
    }) do
        if scalar(values[name]) then job[name] = values[name] end
    end
    self.jobs[key] = job
    self:_flush()
    return copy_table(job)
end

function OfflineCache:plan(identity, manga, chapter, image, denoised, token)
    local root = self:root()
    if not valid_root(root) then return nil, "invalid_offline_root" end
    if type(image) ~= "table" or type(image.path) ~= "string" or image.path == "" then
        return nil, "invalid_remote_path"
    end
    local key = self:key_for(identity, image.path)
    local manga_hash = self.md5(tostring(manga and manga.path or "")):sub(1, 8)
    local chapter_hash = self.md5(tostring(chapter and chapter.path or "")):sub(1, 8)
    local manga_name = sanitize_component(manga and manga.name, "manga") .. "-" .. manga_hash
    local chapter_name = sanitize_component(chapter and chapter.name, "chapter") .. "-" .. chapter_hash
    local directory = root .. "/" .. manga_name .. "/" .. chapter_name
    local made, make_error = self.fs.make_path(directory)
    if made == false or made == nil then return nil, make_error or "make_path_failed" end

    local base = sanitize_component((image.name or "page"):gsub("%.[^%.]+$", ""), "page")
    local extension = denoised and "png" or safe_extension(image.name)
    local suffix = denoised and ".denoise.png" or "." .. extension
    local final_path = directory .. "/" .. base .. "-" .. key:sub(1, 8) .. suffix
    local part_token = tostring(token or "task"):match("^([%w_-]+)$") or "task"
    local part_path = final_path .. "." .. part_token .. ".part"
    local denoise_path = final_path .. "." .. part_token .. ".denoise.part"
    if not within_root(root, final_path) or not within_root(root, part_path)
        or not within_root(root, denoise_path) then
        return nil, "invalid_offline_path"
    end
    self.owned_parts[part_path] = true
    self.owned_parts[denoise_path] = true
    return {
        key = key, identity = tostring(identity or ""), remote_path = image.path,
        manga_path = tostring(manga and manga.path or ""),
        manga_name = tostring(manga and manga.name or ""),
        chapter_path = tostring(chapter and chapter.path or ""),
        chapter_name = tostring(chapter and chapter.name or ""),
        chapter_position = chapter and chapter.offline_position,
        page_position = image.offline_position,
        image_name = tostring(image.name or ""),
        root = root, final_path = final_path, part_path = part_path,
        denoise_path = denoise_path, extension = extension,
        denoised = denoised == true,
    }
end

function OfflineCache:can_store(required_bytes)
    local root, root_error = self:_ensure_root()
    if not root then return false, root_error end
    local ok, usage = pcall(self.disk_usage, root)
    if not ok or type(usage) ~= "table" or tonumber(usage.available) == nil then
        return false, "disk_usage"
    end
    local required = math.max(0, math.floor(tonumber(required_bytes) or 0))
    local limit_bytes = self:_limit_bytes()
    local offline_bytes = self:_offline_bytes() + self:_external_bytes()
    if limit_bytes > 0 and offline_bytes + required > limit_bytes then
        return false, "offline_limit", {
            code = "offline_limit", used_bytes = offline_bytes,
            required_bytes = required, limit_bytes = limit_bytes,
        }
    end
    if usage.available - required < self.reserve_bytes then
        return false, "reserve_space"
    end
    return true
end

function OfflineCache:_entry_key(identity, remote_path)
    local key = self:key_for(identity, remote_path)
    local rooted_key = key .. "\0" .. self:root()
    local legacy = self.entries[key]
    if self.entries[rooted_key] ~= nil or (type(legacy) == "table"
        and legacy.root ~= self:root()) then return rooted_key end
    return key
end

function OfflineCache:lookup(identity, remote_path)
    local key = self:_entry_key(identity, remote_path)
    local record = self.entries[key]
    if not record then return nil end
    if not self:_valid_record(key, record, identity, true)
        or record.remote_path ~= tostring(remote_path or "") then
        self.entries[key] = nil
        self:_flush()
        return nil
    end
    if record.root ~= self:root() then return nil end
    return record.local_path, copy_table(record), key
end

function OfflineCache:enrich(identity, remote_path, values)
    local path, record, key = self:lookup(identity, remote_path)
    if not path then return nil, "missing_cached_page" end
    if type(values) ~= "table" then return nil, "invalid_ordering" end
    for _, name in ipairs({
        "manga_path", "manga_name", "chapter_path", "chapter_name", "image_name",
    }) do
        if type(values[name]) ~= "string"
            or (name:match("_path$") and values[name] == "") then
            return nil, "invalid_ordering"
        end
        record[name] = values[name]
    end
    for _, name in ipairs({ "chapter_position", "page_position" }) do
        if not finite_positive_integer(values[name]) then return nil, "invalid_ordering" end
        record[name] = values[name]
    end
    self.entries[key] = record
    self:_flush()
    return copy_table(record)
end

function OfflineCache:publish(plan, part_path, metadata, denoised)
    metadata = metadata or {}
    local root = self:root()
    if type(plan) ~= "table" or plan.root ~= root or not valid_root(root)
        or not within_root(root, plan.final_path) or not within_root(root, part_path)
        or not self.owned_parts[part_path] then
        return nil, "invalid_offline_plan"
    end
    local actual_size = tonumber(self.fs.size(part_path)) or tonumber(metadata.size)
    if not finite_positive_integer(actual_size) then return nil, "empty_part" end
    local extension = denoised and "png" or tostring(plan.extension or "img")
    local format = denoised and "png" or metadata.format
    local extension_mismatch = not denoised and metadata.extension_mismatch == true
    if extension_mismatch then
        extension = Formats.extension_for_format(format)
        if not extension then return nil, "unvalidated" end
    end
    local metadata_extension = extension_mismatch and nil or extension
    if not ImageProbe.valid_metadata(format, metadata.width, metadata.height,
        metadata_extension) then
        return nil, "unvalidated"
    end
    local enough, space_error = self:can_store(actual_size)
    if not enough then return nil, space_error end

    local final_path = plan.final_path
    if extension_mismatch then
        final_path = final_path:gsub("%.[^./]+$", "." .. extension)
    end
    if not within_root(root, final_path) then return nil, "invalid_offline_plan" end
    if self.fs.exists(final_path) then return nil, "offline_file_exists" end
    local limit_bytes = self:_limit_bytes()
    if limit_bytes > 0 and self:_offline_bytes() + actual_size > limit_bytes then
        return nil, "offline_limit"
    end
    local renamed, rename_error = self.fs.rename(part_path, final_path)
    if not renamed then return nil, rename_error or "rename_failed" end
    self.owned_parts[part_path] = nil
    local previous_key = self:_entry_key(plan.identity, plan.remote_path)
    local previous = self.entries[previous_key]
    if self:_valid_record(previous_key, previous) then
        self.entries[previous.key .. "\0" .. previous.local_path] = previous
        self.entries[previous_key] = nil
    end
    self.entries[plan.key .. "\0" .. root] = {
        namespace = NAMESPACE, owned = true, key = plan.key,
        identity = plan.identity, remote_path = plan.remote_path,
        manga_path = plan.manga_path, manga_name = plan.manga_name,
        chapter_path = plan.chapter_path, chapter_name = plan.chapter_name,
        chapter_position = plan.chapter_position,
        page_position = plan.page_position, image_name = plan.image_name,
        root = root, local_path = final_path, size = actual_size,
        extension = extension, format = format, width = metadata.width,
        height = metadata.height, denoised = denoised == true,
        extension_mismatch = extension_mismatch,
    }
    self:_flush()
    return final_path
end

local function ordered_entries(entries)
    table.sort(entries, function(left, right)
        local left_chapter = finite_positive_integer(left.chapter_position)
            and left.chapter_position or nil
        local right_chapter = finite_positive_integer(right.chapter_position)
            and right.chapter_position or nil
        if left_chapter and right_chapter and left_chapter ~= right_chapter then
            return left_chapter < right_chapter
        end
        if left_chapter ~= right_chapter then return left_chapter ~= nil end
        local left_chapter_name = left.chapter_name ~= "" and left.chapter_name
            or left.chapter_path or left.remote_path
        local right_chapter_name = right.chapter_name ~= "" and right.chapter_name
            or right.chapter_path or right.remote_path
        if left_chapter_name ~= right_chapter_name then
            return NaturalSort.less(left_chapter_name, right_chapter_name)
        end
        local left_page = finite_positive_integer(left.page_position)
            and left.page_position or nil
        local right_page = finite_positive_integer(right.page_position)
            and right.page_position or nil
        if left_page and right_page and left_page ~= right_page then
            return left_page < right_page
        end
        if left_page ~= right_page then return left_page ~= nil end
        local left_name = left.image_name ~= "" and left.image_name or left.remote_path
        local right_name = right.image_name ~= "" and right.image_name or right.remote_path
        return NaturalSort.less(left_name, right_name)
    end)
    return entries
end

function OfflineCache:_manga_entries(identity, manga_path)
    local result = {}
    for key, record in pairs(self.entries) do
        if self:_valid_record(key, record, identity)
            and record.manga_path == manga_path then
            result[#result + 1] = record
        end
    end
    return ordered_entries(result)
end

function OfflineCache:list_mangas(identity)
    local groups = {}
    for key, record in pairs(self.entries) do
        if self:_valid_record(key, record, identity) then
            local group = groups[record.manga_path]
            if not group then
                group = { entries = {}, manga_name = record.manga_name }
                groups[record.manga_path] = group
            end
            group.entries[#group.entries + 1] = record
        end
    end
    for _, job in pairs(self.jobs) do
        if type(job) == "table" and type(job.manga_path) == "string" and job.manga_path ~= ""
            and self:_job(identity, job.manga_path) == job
            and not groups[job.manga_path] then
            groups[job.manga_path] = { entries = {}, manga_name = job.manga_name }
        end
    end
    local result = {}
    for manga_path, group in pairs(groups) do
        ordered_entries(group.entries)
        local job = self:_job(identity, manga_path)
        local total_pages = type(job) == "table" and tonumber(job.total_pages) or 0
        total_pages = finite_positive_integer(total_pages) and total_pages or 0
        for _, record in ipairs(group.entries) do
            if finite_positive_integer(record.page_position) then
                total_pages = math.max(total_pages, record.page_position)
            end
        end
        local cached_pages = #group.entries
        local manga = { name = group.manga_name, path = manga_path }
        result[#result + 1] = {
            manga = manga, name = manga.name, path = manga.path,
            manga_name = manga.name, manga_path = manga.path,
            status = type(job) == "table" and job.status or "incomplete",
            cached_pages = cached_pages, total_pages = total_pages,
            progress = total_pages > 0 and math.min(1, cached_pages / total_pages) or 0,
            cover_path = group.entries[1] and group.entries[1].local_path,
        }
    end
    NaturalSort.sort(result, function(item) return item.manga_name end)
    return result
end

function OfflineCache:list_all_mangas()
    local groups = {}
    local function add_group(identity_text, manga_path, manga_name, root, status,
        total_pages, cached_pages, cover_path)
        identity_text = tostring(identity_text or "")
        manga_path = tostring(manga_path or "")
        if identity_text == "" or manga_path == "" then return end
        local group_key = identity_text .. "\0" .. manga_path .. "\0" .. tostring(root or "")
        local group = groups[group_key]
        if not group then
            group = { identity = identity_text, manga_path = manga_path,
                manga_name = tostring(manga_name or ""), root = root,
                status = status or "incomplete", total_pages = tonumber(total_pages) or 0,
                cached_pages = tonumber(cached_pages) or 0, cover_path = cover_path }
            groups[group_key] = group
        else
            if group.manga_name == "" then group.manga_name = tostring(manga_name or "") end
            if status ~= nil then group.status = status end
            group.total_pages = math.max(group.total_pages, tonumber(total_pages) or 0)
            group.cached_pages = math.max(group.cached_pages, tonumber(cached_pages) or 0)
            if not group.cover_path then group.cover_path = cover_path end
        end
    end
    for key, record in pairs(self.entries) do
        if self:_valid_record(key, record, nil, true) then
            add_group(record.identity, record.manga_path, record.manga_name,
                record.root, nil, record.page_position, 1, record.local_path)
        end
    end
    for _, job in pairs(self.jobs) do
        if type(job) == "table" and type(job.identity) == "string"
            and type(job.manga_path) == "string" and job.manga_path ~= "" then
            add_group(job.identity, job.manga_path, job.manga_name, job.root,
                job.status, job.total_pages, job.cached_pages, nil)
        end
    end
    local result = {}
    for _, group in pairs(groups) do
        local manga_identity = Identity.manga(group.identity, group.manga_path)
        result[#result + 1] = {
            identity = manga_identity,
            connection_identity = group.identity,
            manga_path = group.manga_path,
            manga_name = group.manga_name,
            name = group.manga_name,
            path = group.manga_path,
            status = group.status,
            cached_pages = group.cached_pages,
            total_pages = group.total_pages,
            progress = group.total_pages > 0
                and math.min(1, group.cached_pages / group.total_pages) or 0,
            cover_path = group.cover_path,
            root = group.root,
            manga = { name = group.manga_name, path = group.manga_path },
        }
    end
    NaturalSort.sort(result, function(item) return item.manga_name end)
    return result
end

function OfflineCache:delete_mangas(identity, manga_paths)
    local selected, result, failed, candidates = {}, { deleted_paths = {}, failed_paths = {} }, {}, {}
    local root = self:root()
    for _, path in ipairs(manga_paths or {}) do
        if type(path) == "string" and path ~= "" then selected[path] = true end
    end
    for key, record in pairs(self.entries) do
        local path = record and record.manga_path
        if type(record) == "table" and selected[path]
            and record.identity == tostring(identity or "")
            and record.root == root then
            if not self:_valid_record(key, record, identity) then
                failed[path] = true
            else
                candidates[path] = candidates[path] or {}
                candidates[path][#candidates[path] + 1] = { key = key, record = record }
            end
        end
    end
    for path, records in pairs(candidates) do
        if not failed[path] then
            for _, item in ipairs(records) do
                local record = item.record
                local removed = self.fs.remove(record.local_path)
                if removed and not self.fs.exists(record.local_path) then
                    self.entries[item.key] = nil
                else
                    failed[path] = true
                end
            end
        end
    end
    for path in pairs(selected) do
        if failed[path] or not candidates[path] then
            result.failed_paths[#result.failed_paths + 1] = path
        else
            local job = self:_job(identity, path)
            if job then self.jobs[job.key] = nil end
            result.deleted_paths[#result.deleted_paths + 1] = path
        end
    end
    table.sort(result.deleted_paths)
    table.sort(result.failed_paths)
    self:_flush()
    return result
end

function OfflineCache:reader_model(identity, manga_path)
    local entries = self:_manga_entries(identity, manga_path)
    local job = self:_job(identity, manga_path)
    if #entries == 0 and type(job) ~= "table" then return nil, "missing" end
    local total_pages = type(job) == "table" and tonumber(job.total_pages) or nil
    local cached_pages = type(job) == "table" and tonumber(job.cached_pages) or nil
    if not job or job.status ~= "complete"
        or tonumber(job.failed) ~= 0 or not finite_positive_integer(total_pages)
        or cached_pages ~= total_pages or #entries ~= total_pages then
        return nil, "incomplete"
    end
    for _, record in ipairs(entries) do
        if type(record.chapter_path) ~= "string" or record.chapter_path == ""
            or type(record.chapter_name) ~= "string"
            or not finite_positive_integer(record.chapter_position)
            or type(record.image_name) ~= "string"
            or not finite_positive_integer(record.page_position) then
            return nil, "incomplete"
        end
    end
    local chapters, by_path = {}, {}
    for _, record in ipairs(entries) do
        local chapter = by_path[record.chapter_path]
        if not chapter then
            chapter = {
                name = record.chapter_name, path = record.chapter_path,
                offline_position = record.chapter_position, images = {},
            }
            by_path[record.chapter_path] = chapter
            chapters[#chapters + 1] = chapter
        end
        chapter.images[#chapter.images + 1] = {
            name = record.image_name, path = record.remote_path,
            local_path = record.local_path, size = record.size,
            extension = record.extension, format = record.format,
            width = record.width, height = record.height,
            denoised = record.denoised == true, offline_owned = true,
            offline_position = record.page_position,
        }
    end
    local manga = { name = job.manga_name, path = job.manga_path }
    return {
        manga = manga, status = job.status, cached_pages = #entries,
        total_pages = total_pages, progress = math.min(1, #entries / total_pages),
        cover_path = entries[1].local_path, chapters = chapters,
    }
end

function OfflineCache:owns_local_path(identity, remote_path, local_path)
    local key = self:_entry_key(identity, remote_path)
    local record = self.entries[key]
    return self:_valid_record(key, record, identity)
        and record.remote_path == tostring(remote_path or "")
        and record.local_path == local_path
end

function OfflineCache:discard_part(plan_or_path)
    local paths = {}
    local root = self:root()
    if type(plan_or_path) == "table" then
        paths = { plan_or_path.part_path, plan_or_path.denoise_path }
        root = plan_or_path.root or root
    else
        paths = { plan_or_path }
    end
    local success = true
    for _, path in ipairs(paths) do
        if path and self.owned_parts[path] and within_root(root, path) then
            self.owned_parts[path] = nil
            local removed = self.fs.remove(path)
            if not removed and self.fs.exists(path) then success = false end
        end
    end
    return success
end

function OfflineCache:stats(identity, manga_path)
    local root = self:root()
    local usable_root = self:_ensure_root()
    local offline_bytes, manga_bytes = 0, 0
    for key, record in pairs(self.entries) do
        if self:_valid_record(key, record, nil, true) then
            offline_bytes = offline_bytes + record.size
            if identity ~= nil and manga_path ~= nil
                and record.root == root
                and record.identity == tostring(identity)
                and record.manga_path == tostring(manga_path) then
                manga_bytes = manga_bytes + record.size
            end
        end
    end
    offline_bytes = offline_bytes + self:_external_bytes()
    local ok, usage = false, nil
    if usable_root then ok, usage = pcall(self.disk_usage, root) end
    if not ok or type(usage) ~= "table" then usage = {} end
    return {
        root = root, offline_bytes = offline_bytes, manga_bytes = manga_bytes,
        total_bytes = tonumber(usage.total) or 0,
        used_bytes = tonumber(usage.used) or 0,
        available_bytes = tonumber(usage.available) or 0,
        reserve_bytes = self.reserve_bytes,
        limit_bytes = self:_limit_bytes(),
    }
end

return OfflineCache
