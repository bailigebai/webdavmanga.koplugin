local NaturalSort = require("webdavmanga.natural_sort")
local ImageFormats = require("webdavmanga.image_formats")
local Path = require("webdavmanga.path")
local Identity = require("webdavmanga.manga_identity")

local Library = {}
Library.__index = Library
Library.ALL = "__all__"
Library.UNCATEGORIZED = "__uncategorized__"
local LIBRARY_SCHEMA_VERSION = 3
local MIN_RATING_SCALE = 5
local MAX_RATING_SCALE = 10

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function identity(connection)
    return Identity.connection(connection)
end

local function copy_resource(resource)
    if type(resource) ~= "table" then return nil end
    local path = Identity.resource_path(resource.path)
    if path == "" then return nil end
    local result = {
        name = tostring(resource.name or ""),
        path = path,
        is_folder = resource.is_folder and true or nil,
    }
    for _, key in ipairs({ "opds_catalog_id", "source_id", "series_id", "chapter_id", "pointer_path" }) do
        if type(resource[key]) == "string" and resource[key] ~= "" then
            result[key] = resource[key]
        end
    end
    if resource.opds_feed_url then
        result.opds_feed_url = require("webdavmanga.opds_driver").redact_url(resource.opds_feed_url)
    end
    local book = resource.opds_route_book
    if type(book) == "string" and #book <= 20 and book:match("^%d+$") then
        result.opds_route_book = book
    end
    return result
end

local function copy_image(image)
    if type(image) ~= "table" then return nil end
    local path = Identity.resource_path(image.path)
    if path == "" then return nil end
    local result = {
        name = tostring(image.name or ""),
        path = path,
    }
    if image.size ~= nil then result.size = tonumber(image.size) end
    if image.etag ~= nil then result.etag = tostring(image.etag) end
    if image.last_modified ~= nil then result.last_modified = tostring(image.last_modified) end
    for _, key in ipairs({ "width", "height", "mobi_source_size", "mobi_record",
        "mobi_offset", "mobi_size" }) do
        local value = tonumber(image[key])
        if value and value == value and value ~= math.huge and value ~= -math.huge then
            result[key] = value
        end
    end
    if type(image.format) == "string" and image.format ~= "" then result.format = image.format end
    for _, key in ipairs({ "mobi_path", "mobi_remote_path", "opds_catalog_id" }) do
        if type(image[key]) == "string" and image[key] ~= "" then result[key] = image[key] end
    end
    if image.opds_feed_url then
        result.opds_feed_url = require("webdavmanga.opds_driver").redact_url(image.opds_feed_url)
    end
    return result
end

local function copy_hint(hint)
    if type(hint) ~= "table" then return nil end
    local result = {}
    if hint.image ~= nil then
        local image = copy_image(hint.image)
        if not image or not ImageFormats.is_supported(image.name) then return nil end
        result.image = image
    end
    if hint.chapter ~= nil then
        local chapter = copy_resource(hint.chapter)
        if not chapter then return nil end
        result.chapter = chapter
    end
    if result.chapter == nil and hint.chapters ~= nil then
        if type(hint.chapters) ~= "table" then return nil end
        local chapter = copy_resource(hint.chapters[1])
        if hint.chapters[1] ~= nil and not chapter then return nil end
        result.chapter = chapter
    end
    if next(result) == nil then return nil end
    return result
end

local function hint_is_within(hint, root_path)
    if not hint then return true end
    if hint.image and not Path.is_within_remote(hint.image.path, root_path) then return false end
    if hint.chapter and not Path.is_within_remote(hint.chapter.path, root_path) then return false end
    return true
end

local function has_legacy_chapter_hints(saved)
    if type(saved) ~= "table" or type(saved.connections) ~= "table" then return false end
    for _, bucket in pairs(saved.connections) do
        local mangas = type(bucket) == "table" and type(bucket.mangas) == "table"
            and bucket.mangas or {}
        for _, record in pairs(mangas) do
            local hint = type(record) == "table" and record.cover_hint or nil
            if type(hint) == "table" and hint.chapters ~= nil then return true end
        end
    end
    return false
end

local function valid_layout(layout)
    return layout == nil or layout == "direct" or layout == "chapters" or layout == "opds"
end

local function copy_category(record)
    if type(record) ~= "table" or tostring(record.id or "") == "" then return nil end
    local name = trim(record.name)
    if name == "" then return nil end
    return {
        id = tostring(record.id),
        name = name,
        created_at = tonumber(record.created_at) or 0,
        updated_at = tonumber(record.updated_at) or 0,
    }
end

local function copy_memberships(category_ids)
    local result = {}
    if type(category_ids) ~= "table" then return result end
    for id, selected in pairs(category_ids) do
        if selected and type(id) == "string" then result[id] = true end
    end
    return result
end

local function integer_in_range(value, minimum, maximum)
    value = tonumber(value)
    if value == nil or value ~= math.floor(value)
        or value < minimum or value > maximum then return nil end
    return value
end

local function copy_rating(record)
    local scale = integer_in_range(record and record.rating_scale,
        MIN_RATING_SCALE, MAX_RATING_SCALE)
    local rating = scale and integer_in_range(record.rating, 1, scale) or nil
    return rating, rating and scale or nil
end

local function copy_archive_path(value)
    local raw = tostring(value or ""):gsub("\\", "/")
    if raw == "" or raw:find("\0", 1, true) or raw:sub(1, 1) ~= "/" then
        return nil
    end
    for segment in raw:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
    end
    local normalized = Path.normalize_remote(raw)
    return normalized ~= "" and normalized or nil
end

local function copy_manga_record(record)
    if type(record) ~= "table" then return nil end
    local manga = copy_resource(record.manga)
    local key = tostring(record.key or "")
    if not manga or key == "" then return nil end
    local rating, rating_scale = copy_rating(record)
    local archived_cover_path = copy_archive_path(record.archived_cover_path)
    local local_deleted = archived_cover_path ~= nil and record.local_deleted == true
    return {
        key = key,
        manga = manga,
        chapter = copy_resource(record.chapter),
        category_ids = copy_memberships(record.category_ids),
        layout = record.layout ~= nil and tostring(record.layout) or nil,
        cover_hint = copy_hint(record.cover_hint),
        rating = rating,
        rating_scale = rating_scale,
        is_read = record.is_read == true,
        archived_cover_path = archived_cover_path,
        local_deleted = local_deleted,
        deleted_at = local_deleted and (tonumber(record.deleted_at) or 0) or nil,
        created_at = tonumber(record.created_at) or 0,
        updated_at = tonumber(record.updated_at) or 0,
    }
end

local function copy_cover_record(record)
    if type(record) ~= "table" then return nil end
    local manga_path = Identity.resource_path(record.manga_path)
    if manga_path == "" then return nil end
    local result = {
        manga_path = manga_path,
        resolved_at = tonumber(record.resolved_at) or 0,
    }
    if record.none == true then
        result.none = true
        return result
    end
    local image = copy_image(record.image)
    if not image or not ImageFormats.is_supported(image.name) then return nil end
    result.image = image
    return result
end

local function clean_connection(connection)
    return Identity.normalize_connection(connection)
end

local function copy_bucket(bucket, connection)
    local result = {
        connection = clean_connection(connection or (type(bucket) == "table" and bucket.connection or {})),
        categories = {},
        mangas = {},
        covers = {},
    }
    if type(bucket) ~= "table" then return result end
    local categories = type(bucket.categories) == "table" and bucket.categories or {}
    local mangas = type(bucket.mangas) == "table" and bucket.mangas or {}
    local covers = type(bucket.covers) == "table" and bucket.covers or {}
    for key, record in pairs(categories) do
        local copied = copy_category(record)
        if copied then result.categories[tostring(key)] = copied end
    end
    for key, record in pairs(mangas) do
        local copied = copy_manga_record(record)
        if copied then result.mangas[tostring(key)] = copied end
    end
    for key, record in pairs(covers) do
        local copied = copy_cover_record(record)
        if copied then result.covers[tostring(key)] = copied end
    end
    return result
end

local function clean_schema(saved)
    local result = { schema_version = LIBRARY_SCHEMA_VERSION, connections = {} }
    if type(saved) ~= "table" or type(saved.connections) ~= "table" then return result end
    for key, bucket in pairs(saved.connections) do
        if type(bucket) == "table" and type(bucket.connection) == "table" then
            local copied = copy_bucket(bucket)
            local normalized_key = identity(copied.connection)
            local existing = result.connections[normalized_key]
            if not existing then
                result.connections[normalized_key] = copied
            else
                for category_id, category in pairs(copied.categories) do
                    if existing.categories[category_id] == nil then
                        existing.categories[category_id] = category
                    end
                end
                for manga_key, manga in pairs(copied.mangas) do
                    if existing.mangas[manga_key] == nil then
                        existing.mangas[manga_key] = manga
                    else
                        local target = existing.mangas[manga_key]
                        for category_id in pairs(manga.category_ids or {}) do
                            target.category_ids[category_id] = true
                        end
                        if target.rating == nil then target.rating = manga.rating end
                        if target.rating_scale == nil then target.rating_scale = manga.rating_scale end
                        target.is_read = target.is_read or manga.is_read
                    end
                end
                for cover_key, cover in pairs(copied.covers) do
                    if existing.covers[cover_key] == nil then existing.covers[cover_key] = cover end
                end
            end
        end
    end
    return result
end

local function normalized_name(name)
    return trim(name):lower()
end

local function has_category(bucket, category_id)
    return category_id ~= Library.ALL and category_id ~= Library.UNCATEGORIZED
        and bucket.categories[tostring(category_id)] ~= nil
end

local function collect_category_ids(bucket, category_ids)
    local result = {}
    if category_ids == nil then return result end
    if type(category_ids) ~= "table" then return nil end
    for _, category_id in ipairs(category_ids) do
        category_id = tostring(category_id)
        if not has_category(bucket, category_id) then return nil end
        result[category_id] = true
    end
    for category_id, selected in pairs(category_ids) do
        if type(category_id) == "string" and selected then
            if not has_category(bucket, category_id) then return nil end
            result[category_id] = true
        end
    end
    return result
end

local function merge_memberships(target, source)
    for category_id in pairs(source or {}) do target[category_id] = true end
end

local function positive_cover_record(manga_path, image, resolved_at)
    return {
        manga_path = Identity.resource_path(manga_path),
        image = copy_image(image),
        resolved_at = tonumber(resolved_at) or 0,
    }
end

function Library:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.store = assert(options.store, "library store is required")
    object.md5 = options.md5 or default_md5
    object.clock = options.clock or os.time
    object.category_counter = 0
    local saved = object.store:readSetting("library", {})
    local needs_migration = type(saved) ~= "table"
        or tonumber(saved.schema_version) ~= LIBRARY_SCHEMA_VERSION
    local migrate_legacy_hints = has_legacy_chapter_hints(saved)
    object.data = clean_schema(saved)
    for key, bucket in pairs(object.data.connections) do
        local clean_bucket = object:_sanitize_bucket(key, bucket)
        if clean_bucket then
            object.data.connections[key] = clean_bucket
        else
            object.data.connections[key] = nil
        end
    end
    if needs_migration then
        pcall(function()
            object.store:saveSetting("library", object.data)
            if object.store.flush then object.store:flush() end
        end)
    end
    if migrate_legacy_hints then
        pcall(function()
            object.store:saveSetting("library", object.data)
            if object.store.flush then object.store:flush() end
        end)
    end
    return object
end

function Library:_bucket(connection)
    local key = identity(connection)
    local bucket = self.data.connections[key]
    return key, bucket or copy_bucket(nil, connection)
end

function Library:_commit(key, bucket)
    local candidate = { schema_version = LIBRARY_SCHEMA_VERSION, connections = {} }
    for existing_key, existing_bucket in pairs(self.data.connections) do
        candidate.connections[existing_key] = existing_bucket
    end
    candidate.connections[key] = bucket
    local saved = pcall(self.store.saveSetting, self.store, "library", candidate)
    if not saved then return nil, "storage_failure" end
    if self.store.flush then
        local flushed = pcall(self.store.flush, self.store)
        if not flushed then
            pcall(self.store.saveSetting, self.store, "library", self.data)
            pcall(self.store.flush, self.store)
            return nil, "storage_failure"
        end
    end
    self.data = candidate
    return true
end

function Library:_manga_key(connection, manga_path)
    if type(manga_path) == "string" and manga_path:sub(1, 5) == "opds:" then return manga_path end
    return self.md5(identity(connection) .. "\0" .. Path.normalize_remote(manga_path or ""))
end

function Library:_sanitize_bucket(key, bucket)
    if type(bucket) ~= "table" or type(bucket.connection) ~= "table" then return nil end
    local candidate = copy_bucket(bucket)
    if identity(candidate.connection) ~= key then return nil end
    local root_path = candidate.connection.root_path
    local cleaned = {
        connection = candidate.connection,
        categories = {}, mangas = {}, covers = {},
    }
    for map_key, category in pairs(candidate.categories) do
        if tostring(map_key) == category.id then cleaned.categories[category.id] = category end
    end
    for _map_key, record in pairs(candidate.mangas) do
        local expected_key = self:_manga_key(candidate.connection, record.manga.path)
        if Path.is_within_remote(record.manga.path, root_path) then
            local memberships = {}
            for category_id in pairs(record.category_ids) do
                if cleaned.categories[category_id] then memberships[category_id] = true end
            end
            record.category_ids = memberships
            if record.cover_hint and not hint_is_within(record.cover_hint, root_path) then
                record.cover_hint = nil
            end
            record.key = expected_key
            local existing_record = cleaned.mangas[expected_key]
            if existing_record then
                for category_id in pairs(record.category_ids) do
                    existing_record.category_ids[category_id] = true
                end
                if existing_record.rating == nil then existing_record.rating = record.rating end
                if existing_record.rating_scale == nil then existing_record.rating_scale = record.rating_scale end
                existing_record.is_read = existing_record.is_read or record.is_read
            else
                cleaned.mangas[expected_key] = record
            end
        end
    end
    for _map_key, record in pairs(candidate.covers) do
        local expected_key = self:_manga_key(candidate.connection, record.manga_path)
        if Path.is_within_remote(record.manga_path, root_path)
            and (record.none == true
                or (record.image and Path.is_within_remote(record.image.path, root_path))) then
            if cleaned.covers[expected_key] == nil then cleaned.covers[expected_key] = record end
        end
    end
    return cleaned
end

function Library:list_categories(connection)
    local _, bucket = self:_bucket(connection)
    local result = {}
    for _, category in pairs(bucket.categories) do result[#result + 1] = copy_category(category) end
    table.sort(result, function(left, right)
        if left.name == right.name then return left.id < right.id end
        return NaturalSort.less(left, right, function(item) return item.name end)
    end)
    return result
end

function Library:create_category(connection, name)
    name = trim(name)
    if name == "" then return nil, "invalid_category_name" end
    local key, bucket = self:_bucket(connection)
    local wanted = normalized_name(name)
    for _, category in pairs(bucket.categories) do
        if normalized_name(category.name) == wanted then return nil, "duplicate_category" end
    end
    local candidate = copy_bucket(bucket)
    local category_id
    repeat
        self.category_counter = self.category_counter + 1
        category_id = tostring(self.md5(table.concat({
            key, wanted, tostring(tonumber(self.clock()) or 0), tostring(self.category_counter),
        }, "\0")))
    until candidate.categories[category_id] == nil
    local now = tonumber(self.clock()) or 0
    candidate.categories[category_id] = {
        id = category_id, name = name, created_at = now, updated_at = now,
    }
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_category(candidate.categories[category_id])
end

function Library:rename_category(connection, category_id, name)
    name = trim(name)
    if name == "" then return nil, "invalid_category_name" end
    local key, bucket = self:_bucket(connection)
    category_id = tostring(category_id or "")
    local category = bucket.categories[category_id]
    if not category then return nil, "missing_category" end
    local wanted = normalized_name(name)
    for id, existing in pairs(bucket.categories) do
        if id ~= category_id and normalized_name(existing.name) == wanted then
            return nil, "duplicate_category"
        end
    end
    local candidate = copy_bucket(bucket)
    candidate.categories[category_id].name = name
    candidate.categories[category_id].updated_at = tonumber(self.clock()) or 0
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_category(candidate.categories[category_id])
end

function Library:remove_category(connection, category_id)
    category_id = tostring(category_id or "")
    if category_id == self.ALL or category_id == self.UNCATEGORIZED then return false end
    local key, bucket = self:_bucket(connection)
    if not bucket.categories[category_id] then return false end
    local candidate = copy_bucket(bucket)
    candidate.categories[category_id] = nil
    local now = tonumber(self.clock()) or 0
    for _, record in pairs(candidate.mangas) do
        if record.category_ids[category_id] then
            record.category_ids[category_id] = nil
            record.updated_at = now
        end
    end
    return self:_commit(key, candidate) and true or false
end

function Library:add_manga(connection, manga, options)
    options = options or {}
    local resource = copy_resource(manga)
    if not resource or not Path.is_within_remote(resource.path, connection and connection.root_path) then
        return nil, "invalid_manga_path"
    end
    local layout = options.layout ~= nil and tostring(options.layout) or nil
    if not valid_layout(layout) then return nil, "invalid_layout" end
    local hint = copy_hint(options.cover_hint)
    if options.cover_hint ~= nil and (not hint
        or not hint_is_within(hint, connection and connection.root_path)) then
        return nil, "invalid_cover_hint"
    end
    local direct_cover = copy_image(options.direct_cover_image)
    if options.direct_cover_image ~= nil and (layout ~= "direct" or not direct_cover
        or not ImageFormats.is_supported(direct_cover.name)
        or not Path.is_within_remote(direct_cover.path, connection and connection.root_path)) then
        return nil, "invalid_cover_hint"
    end
    local key, bucket = self:_bucket(connection)
    local selected = collect_category_ids(bucket, options.category_ids)
    if not selected then return nil, "invalid_category" end
    local manga_key = self:_manga_key(connection, resource.path)
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    local now = tonumber(self.clock()) or 0
    if record then
        record.manga = resource
        if options.chapter then record.chapter = copy_resource(options.chapter) end
        merge_memberships(record.category_ids, selected)
        if options.layout ~= nil then record.layout = layout end
        if options.cover_hint ~= nil then record.cover_hint = hint end
        record.updated_at = now
    else
        record = {
            key = manga_key, manga = resource, chapter = copy_resource(options.chapter), category_ids = selected,
            layout = layout,
            cover_hint = hint, is_read = false,
            local_deleted = false, created_at = now, updated_at = now,
        }
        candidate.mangas[manga_key] = record
    end
    if direct_cover then
        candidate.covers[manga_key] = positive_cover_record(resource.path, direct_cover, now)
    end
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(record)
end

function Library:ensure_manga(connection, manga, options)
    return self:add_manga(connection, manga, options or {})
end

function Library:get_manga(connection, manga_path)
    local _, bucket = self:_bucket(connection)
    local record = bucket.mangas[self:_manga_key(connection, manga_path)]
    return copy_manga_record(record)
end

function Library:set_rating(connection, manga_path, rating, rating_scale)
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.mangas[manga_key] then return nil, "missing_manga" end
    local normalized_rating
    local normalized_scale
    if rating ~= nil and tonumber(rating) ~= 0 then
        normalized_scale = integer_in_range(rating_scale,
            MIN_RATING_SCALE, MAX_RATING_SCALE)
        normalized_rating = normalized_scale
            and integer_in_range(rating, 1, normalized_scale) or nil
        if not normalized_rating then return nil, "invalid_rating" end
    end
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    record.rating = normalized_rating
    record.rating_scale = normalized_scale
    record.updated_at = tonumber(self.clock()) or 0
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(record)
end

function Library:set_read(connection, manga_path, is_read)
    if type(is_read) ~= "boolean" then return nil, "invalid_read_status" end
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.mangas[manga_key] then return nil, "missing_manga" end
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    record.is_read = is_read
    record.updated_at = tonumber(self.clock()) or 0
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(record)
end

function Library:set_local_archive(connection, manga_path, archived_cover_path, local_deleted)
    if type(local_deleted) ~= "boolean" then return nil, "invalid_delete_status" end
    local archive_path = copy_archive_path(archived_cover_path)
    if not archive_path then return nil, "invalid_archive_path" end
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.mangas[manga_key] then return nil, "missing_manga" end
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    record.archived_cover_path = archive_path
    record.local_deleted = local_deleted
    record.deleted_at = local_deleted and (tonumber(self.clock()) or 0) or nil
    record.updated_at = tonumber(self.clock()) or 0
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(record)
end

function Library.rating_for(record, current_scale)
    local scale = integer_in_range(current_scale, MIN_RATING_SCALE, MAX_RATING_SCALE) or 5
    local rating, source_scale = copy_rating(record)
    if not rating then return 0 end
    local converted = math.floor(rating * scale / source_scale + 0.5)
    return math.max(1, math.min(scale, converted))
end

function Library:list_mangas_by_rating(connection, rating, current_scale)
    local scale = integer_in_range(current_scale, MIN_RATING_SCALE, MAX_RATING_SCALE) or 5
    local wanted = integer_in_range(rating, 1, scale)
    if not wanted then return {} end
    local result = {}
    for _, record in ipairs(self:list_mangas(connection, self.ALL)) do
        if Library.rating_for(record, scale) == wanted then result[#result + 1] = record end
    end
    return result
end

function Library:list_mangas(connection, view_id)
    local _, bucket = self:_bucket(connection)
    view_id = view_id or self.ALL
    local result = {}
    for _, record in pairs(bucket.mangas) do
        local include = view_id == self.ALL
            or (view_id == self.UNCATEGORIZED and next(record.category_ids) == nil)
            or (view_id ~= self.UNCATEGORIZED and record.category_ids[tostring(view_id)] == true)
        if include then result[#result + 1] = copy_manga_record(record) end
    end
    table.sort(result, function(left, right)
        if left.manga.name == right.manga.name then return left.manga.path < right.manga.path end
        return NaturalSort.less(left, right, function(item) return item.manga.name end)
    end)
    return result
end

function Library:list_all_mangas()
    local result = {}
    for _, bucket in pairs(self.data.connections) do
        for _, record in pairs(bucket.mangas or {}) do
            local copied = copy_manga_record(record)
            if copied then
                local connection = Identity.normalize_connection(bucket.connection)
                copied.connection = connection
                copied.identity = Identity.manga(connection, copied.manga.path)
                copied.connection_identity = Identity.connection(connection)
                result[#result + 1] = copied
            end
        end
    end
    table.sort(result, function(left, right)
        if left.identity == right.identity then return false end
        return left.identity < right.identity
    end)
    return result
end

function Library:set_categories(connection, manga_path, category_ids)
    local normalized_path = Identity.resource_path(manga_path)
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, normalized_path)
    if not bucket.mangas[manga_key] then return nil, "missing_manga" end
    local selected = collect_category_ids(bucket, category_ids)
    if not selected then return nil, "invalid_category" end
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    record.category_ids = selected
    record.updated_at = tonumber(self.clock()) or 0
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(record)
end

function Library:remove_from_category(connection, manga_path, category_id)
    category_id = tostring(category_id or "")
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.mangas[manga_key] or not bucket.mangas[manga_key].category_ids[category_id] then return false end
    local candidate = copy_bucket(bucket)
    local record = candidate.mangas[manga_key]
    record.category_ids[category_id] = nil
    record.updated_at = tonumber(self.clock()) or 0
    return self:_commit(key, candidate) and true or false
end

function Library:remove_manga(connection, manga_path)
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.mangas[manga_key] then return false end
    local candidate = copy_bucket(bucket)
    candidate.mangas[manga_key] = nil
    return self:_commit(key, candidate) and true or false
end

function Library:relink_manga(connection, old_path, recognition)
    local has_fresh_metadata = type(recognition) == "table" and type(recognition.manga) == "table"
    local resource = copy_resource(has_fresh_metadata and recognition.manga or recognition)
    if not resource or not Path.is_within_remote(resource.path, connection and connection.root_path) then
        return nil, "invalid_manga_path"
    end
    local layout, hint, direct_cover
    if has_fresh_metadata then
        layout = recognition.layout ~= nil and tostring(recognition.layout) or nil
        if not valid_layout(layout) or layout == nil then return nil, "invalid_layout" end
        hint = copy_hint(recognition.cover_hint)
        if recognition.cover_hint ~= nil and (not hint
            or not hint_is_within(hint, connection and connection.root_path)) then
            return nil, "invalid_cover_hint"
        end
        direct_cover = copy_image(recognition.direct_cover_image)
        if recognition.direct_cover_image ~= nil and (layout ~= "direct" or not direct_cover
            or not ImageFormats.is_supported(direct_cover.name)
            or not Path.is_within_remote(direct_cover.path, connection and connection.root_path)) then
            return nil, "invalid_cover_hint"
        end
    end
    local key, bucket = self:_bucket(connection)
    local old_key = self:_manga_key(connection, old_path)
    local source = bucket.mangas[old_key]
    if not source then return nil, "missing_manga" end
    local target_key = self:_manga_key(connection, resource.path)
    local candidate = copy_bucket(bucket)
    local old_record = candidate.mangas[old_key]
    local target = candidate.mangas[target_key]
    local now = tonumber(self.clock()) or 0
    if target_key == old_key then
        old_record.manga = resource
        if has_fresh_metadata then
            old_record.layout = layout
            old_record.cover_hint = hint
        end
        old_record.local_deleted = false
        old_record.deleted_at = nil
        old_record.updated_at = now
        target = old_record
    elseif target then
        merge_memberships(target.category_ids, old_record.category_ids)
        if old_record.rating ~= nil then
            target.rating = old_record.rating
            target.rating_scale = old_record.rating_scale
        end
        target.is_read = target.is_read == true or old_record.is_read == true
        if target.archived_cover_path == nil then
            target.archived_cover_path = old_record.archived_cover_path
        end
        target.local_deleted = false
        target.deleted_at = nil
        target.manga = resource
        if has_fresh_metadata then
            target.layout = layout
            target.cover_hint = hint
        else
            if target.layout == nil then target.layout = old_record.layout end
            if target.cover_hint == nil then target.cover_hint = old_record.cover_hint end
        end
        target.updated_at = now
        candidate.mangas[old_key] = nil
    else
        old_record.key = target_key
        old_record.manga = resource
        if has_fresh_metadata then
            old_record.layout = layout
            old_record.cover_hint = hint
        end
        old_record.updated_at = now
        old_record.local_deleted = false
        old_record.deleted_at = nil
        candidate.mangas[old_key] = nil
        candidate.mangas[target_key] = old_record
        target = old_record
    end
    if direct_cover then
        candidate.covers[target_key] = positive_cover_record(resource.path, direct_cover, now)
    end
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_manga_record(target)
end

function Library:get_cover(connection, manga_path)
    local _, bucket = self:_bucket(connection)
    local record = bucket.covers[self:_manga_key(connection, manga_path)]
    return copy_cover_record(record)
end

function Library:set_cover(connection, manga_path, image)
    local normalized_manga_path = Identity.resource_path(manga_path)
    local copied_image = copy_image(image)
    if normalized_manga_path == "" or not copied_image
        or not ImageFormats.is_supported(copied_image.name)
        or not Path.is_within_remote(normalized_manga_path, connection and connection.root_path)
        or not Path.is_within_remote(copied_image.path, connection and connection.root_path) then
        return nil, "invalid_cover_path"
    end
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, normalized_manga_path)
    local candidate = copy_bucket(bucket)
    candidate.covers[manga_key] = positive_cover_record(
        normalized_manga_path, copied_image, self.clock())
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_cover_record(candidate.covers[manga_key])
end

function Library:set_no_cover(connection, manga_path)
    local normalized_manga_path = Identity.resource_path(manga_path)
    if normalized_manga_path == ""
        or not Path.is_within_remote(normalized_manga_path, connection and connection.root_path) then
        return nil, "invalid_cover_path"
    end
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, normalized_manga_path)
    local candidate = copy_bucket(bucket)
    candidate.covers[manga_key] = {
        manga_path = normalized_manga_path,
        none = true,
        resolved_at = tonumber(self.clock()) or 0,
    }
    local committed, error_code = self:_commit(key, candidate)
    if not committed then return nil, error_code end
    return copy_cover_record(candidate.covers[manga_key])
end

function Library:clear_cover(connection, manga_path)
    local key, bucket = self:_bucket(connection)
    local manga_key = self:_manga_key(connection, manga_path)
    if not bucket.covers[manga_key] then return false end
    local candidate = copy_bucket(bucket)
    candidate.covers[manga_key] = nil
    return self:_commit(key, candidate) and true or false
end

return Library
