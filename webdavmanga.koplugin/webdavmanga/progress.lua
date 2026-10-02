local Progress = {}
Progress.__index = Progress
local HISTORY_SCHEMA_VERSION = 2
local Identity = require("webdavmanga.manga_identity")

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function connection_identity(connection)
    return Identity.connection(connection)
end

local function copy_resource(resource)
    if type(resource) ~= "table" then return nil end
    local path = tostring(resource.path or "")
    if path == "" then return nil end
    local result = {
        name = tostring(resource.name or ""),
        path = path,
        is_folder = resource.is_folder and true or nil,
        is_file = resource.is_file and true or nil,
    }
    -- MOBI image pages use a synthetic path (book.mobi#mobi/N).  Keep only
    -- scalar extraction metadata so a later history view can re-fetch it.
    for _, key in ipairs({ "size", "width", "height", "mupdf_page", "mupdf_source_size", "mobi_source_size",
        "mobi_record", "mobi_offset", "mobi_size", "archive_source_size",
        "archive_local_offset", "archive_method", "archive_flags", "archive_crc32",
        "archive_compressed_size", "archive_size", "pdf_source_size",
        "pdf_image_offset", "pdf_image_length" }) do
        local value = tonumber(resource[key])
        if value and value == value and value ~= math.huge and value ~= -math.huge then
            result[key] = value
        end
    end
    if resource.pdf_image == true then result.pdf_image = true end
    if type(resource.format) == "string" and resource.format ~= "" then
        result.format = resource.format
    end
    for _, key in ipairs({ "mupdf_remote_path", "mupdf_source_path", "mobi_path", "mobi_remote_path", "pdf_remote_path", "etag", "modified", "archive_kind",
        "archive_remote_path", "archive_entry_name", "archive_local_path", "archive_version",
        "opds_catalog_id", "source_id", "series_id", "chapter_id", "pointer_path" }) do
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

local function copy_source_context(source)
    if type(source) ~= "table" or source.opds ~= true then return nil end
    return {
        opds = true,
        catalog_id = type(source.catalog_id) == "string" and source.catalog_id or nil,
        feed_url = type(source.feed_url) == "string"
            and require("webdavmanga.opds_driver").redact_url(source.feed_url) or nil,
        source_id = source.source_id,
        series_id = source.series_id,
        chapter_id = source.chapter_id,
        pointer_path = source.pointer_path,
    }
end

local function copy_cover_hint(hint)
    if type(hint) ~= "table" then return nil end
    local result = {}
    if type(hint.image) == "table" then result.image = copy_resource(hint.image) end
    if type(hint.chapter) == "table" then result.chapter = copy_resource(hint.chapter) end
    if next(result) == nil then return nil end
    return result
end

local function copy_history_record(record)
    if type(record) ~= "table" or type(record.connection) ~= "table" then return nil end
    local manga = copy_resource(record.manga)
    local chapter = copy_resource(record.chapter)
    if not manga or not chapter then return nil end
    local result = {
        connection = Identity.normalize_connection(record.connection),
        manga = manga,
        chapter = chapter,
        image_path = tostring(record.image_path or ""),
        index = tonumber(record.index) or 1,
        segment = (record.segment == "left" or record.segment == "right")
            and record.segment or "whole",
        total = tonumber(record.total) or 1,
        updated_at = tonumber(record.updated_at) or 0,
        layout = record.layout ~= nil and tostring(record.layout) or nil,
        cover_hint = copy_cover_hint(record.cover_hint),
        source_context = copy_source_context(record.source_context),
    }
    return result
end

local function clean_history(saved)
    local result = {}
    local changed = type(saved) ~= "table"
    if type(saved) ~= "table" then return result, changed end
    for key, record in pairs(saved) do
        local copied = copy_history_record(record)
        if copied then
            result[tostring(key)] = copied
            if type(record) == "table" and record.chapters ~= nil then changed = true end
        else
            changed = true
        end
    end
    return result, changed
end

function Progress:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.store = assert(options.store, "progress store is required")
    object.md5 = options.md5 or default_md5
    object.clock = options.clock or os.time
    object.scheduler = options.scheduler
    object.flush_delay = math.max(0, tonumber(options.flush_delay) or 0.75)
    object.flush_pending = false
    object.dirty = false
    object.records = object.store:readSetting("progress", {})
    if type(object.records) ~= "table" then object.records = {} end
    local saved_history = object.store:readSetting("history", {})
    local history_changed
    object.history, history_changed = clean_history(saved_history)
    local saved_schema = object.store:readSetting("history_schema_version")
    if next(object.history) ~= nil
        and (history_changed or saved_schema ~= HISTORY_SCHEMA_VERSION) then
        object.dirty = true
        local scheduled = pcall(function() object:_schedule_flush() end)
        if not scheduled then
            object.flush_pending = false
            object.dirty = true
        end
    end
    return object
end

function Progress:chapter_id(connection, manga, chapter)
    if connection and connection.kind == "opds" then
        local path = Identity.opds_path(chapter) or Identity.opds_path(manga)
        if path then return path end
    end
    local legacy_input = table.concat({
        tostring(connection and connection.server_url or ""),
        tostring(connection and connection.username or ""):match("^%s*(.-)%s*$"),
        tostring(connection and connection.root_path or ""),
        tostring(manga and manga.path or ""),
        tostring(chapter and chapter.path or ""),
    }, "\0")
    -- Connections written before kind/local_path existed retain their old
    -- chapter key shape; explicit typed connections use the unified identity.
    if type(connection) == "table" and connection.kind == nil
        and connection.local_path == nil then
        return self.md5(legacy_input)
    end
    local unified_input = Identity.manga(connection, manga and manga.path or "")
        .. "\0" .. tostring(chapter and chapter.path or "")
    local chapter_key = self.md5(unified_input)
    local legacy_key = self.md5(legacy_input)
    -- The three-field key predates typed connections and is only a WebDAV
    -- compatibility alias. Local and NodeShare sources must never inherit a
    -- record from that namespace just because their paths happen to match.
    local normalized = Identity.normalize_connection(connection)
    if normalized.kind == "webdav"
        and self.records[chapter_key] == nil and self.records[legacy_key] ~= nil then
        self.records[chapter_key] = self.records[legacy_key]
        self.dirty = true
        self:_schedule_flush()
    end
    return chapter_key
end

function Progress:_flush()
    self.store:saveSetting("progress", self.records)
    self.store:saveSetting("history", self.history)
    self.store:saveSetting("history_schema_version", HISTORY_SCHEMA_VERSION)
    if self.store.flush then self.store:flush() end
end

function Progress:_schedule_flush()
    if not self.scheduler or type(self.scheduler.scheduleIn) ~= "function" then
        self:_flush()
        self.dirty = false
        return true
    end
    if self.flush_pending then return true end
    self.flush_pending = true
    local ok, result = pcall(self.scheduler.scheduleIn,
        self.scheduler, self.flush_delay,
        function()
            self.flush_pending = false
            if not self.dirty then return end
            local flushed = pcall(function() self:_flush() end)
            if flushed then self.dirty = false end
        end)
    if not ok or result == false then
        self.flush_pending = false
        self:_flush()
        self.dirty = false
    end
    return true
end

function Progress:flush()
    if not self.dirty then return true end
    local ok, err = pcall(function() self:_flush() end)
    if ok then self.dirty = false end
    return ok, err
end

function Progress:save(chapter_id, image_path, index, segment, history_context)
    if type(segment) == "table" and history_context == nil then
        history_context, segment = segment, "whole"
    end
    if segment ~= "left" and segment ~= "right" then segment = "whole" end
    local previous = self.records[chapter_id]
    self.records[chapter_id] = {
        image_path = image_path,
        index = tonumber(index) or 1,
        segment = segment,
        server_last_read = previous and previous.server_last_read,
    }
    if history_context and history_context.connection
        and history_context.manga and history_context.chapter then
        local connection = history_context.connection
        local manga = history_context.manga
        local key = self.md5(connection_identity(connection) .. "\0" .. tostring(manga.path or ""))
        if connection.kind == "opds" and Identity.opds_path(manga) then key = manga.path end
        self.history[key] = {
            connection = Identity.normalize_connection(connection),
            manga = copy_resource(manga),
            chapter = copy_resource(history_context.chapter),
            image_path = tostring(image_path or ""),
            index = tonumber(index) or 1,
            segment = segment,
            total = tonumber(history_context.total) or 1,
            updated_at = tonumber(self.clock()) or 0,
            layout = history_context.layout ~= nil and tostring(history_context.layout) or nil,
            cover_hint = copy_cover_hint(history_context.cover_hint),
            source_context = copy_source_context(history_context.source_context),
        }
    end
    self.dirty = true
    self:_schedule_flush()
end

function Progress:server_page(desc)
    local key = Identity.opds_path(desc)
    local record = key and self.records[key]
    return tonumber(record and record.server_last_read) or 0
end

-- A durable high-water reservation precedes the remote write. It is stored in
-- the existing chapter record and survives ordinary local backwards saves.
-- Called only after Reader has successfully displayed/checkpointed a page.
function Progress:reserve_server_page(desc, page)
    local key = Identity.opds_path(desc)
    if not key then return false end
    local previous = self.records[key]
    if previous and (tonumber(previous.server_last_read) or 0) >= page then return true end
    local record = {}
    for name, value in pairs(previous or {}) do record[name] = value end
    record.server_last_read = math.max(tonumber(record.server_last_read) or 0, page)
    self.records[key] = record
    local ok = pcall(function()
        local saved, save_error = self.store:saveSetting("progress", self.records)
        assert(saved ~= false and save_error == nil)
        if self.store.flush then
            local flushed, flush_error = self.store:flush()
            assert(flushed ~= false and flush_error == nil)
        end
    end)
    if not ok then self.records[key] = previous; return false end
    return true
end

function Progress:list_history(connection)
    local variants = Identity.connection_variants(connection)
    local records = {}
    for _, record in pairs(self.history) do
        if type(record) == "table" and type(record.connection) == "table"
            and (connection_identity(record.connection) == variants.current
                or connection_identity(record.connection) == variants.legacy) then
            records[#records + 1] = copy_history_record(record)
        end
    end
    table.sort(records, function(left, right)
        local left_time = tonumber(left.updated_at) or 0
        local right_time = tonumber(right.updated_at) or 0
        if left_time ~= right_time then return left_time > right_time end
        return tostring(left.manga.name) < tostring(right.manga.name)
    end)
    return records
end

function Progress:list_all_history()
    local records = {}
    for _, record in pairs(self.history) do
        local copied = copy_history_record(record)
        if copied then
            copied.identity = Identity.manga(copied.connection, copied.manga.path)
            records[#records + 1] = copied
        end
    end
    table.sort(records, function(left, right)
        local left_time = tonumber(left.updated_at) or 0
        local right_time = tonumber(right.updated_at) or 0
        if left_time ~= right_time then return left_time > right_time end
        return tostring(left.identity) < tostring(right.identity)
    end)
    return records
end

function Progress:remove_history(connection, manga_path)
    local variants = Identity.connection_variants(connection)
    local normalize = Identity.normalize_connection(connection).kind == "opds"
        and function(value) return tostring(value or "") end
        or require("webdavmanga.path").normalize_remote
    local normalized_path = normalize(manga_path)
    local key
    for candidate, record in pairs(self.history) do
        if type(record) == "table" and type(record.connection) == "table"
            and (connection_identity(record.connection) == variants.current
                or connection_identity(record.connection) == variants.legacy)
            and type(record.manga) == "table"
            and normalize(record.manga.path) == normalized_path then
            key = candidate
            break
        end
    end
    if not key then return false end
    self.history[key] = nil
    self.dirty = true
    self:_schedule_flush()
    return true
end

local function legacy_resolve(record, images)
    if type(images) ~= "table" or #images == 0 then return nil end
    if not record then return 1 end
    for index, image in ipairs(images) do
        if image.path == record.image_path then return index end
    end
    local fallback = math.floor(tonumber(record.index) or 1)
    if fallback < 1 then fallback = 1 end
    if fallback > #images then fallback = #images end
    return fallback
end

function Progress:resolve(chapter_id, chapter_index, valid_segments)
    local record = self.records[chapter_id]
    if type(chapter_index) ~= "table"
        or type(chapter_index.count) ~= "function"
        or type(chapter_index.find) ~= "function" then
        return legacy_resolve(record, chapter_index)
    end

    local count = math.floor(tonumber(chapter_index:count()) or 0)
    if count < 1 then return nil end
    local fallback = record and math.floor(tonumber(record.index) or 1) or 1
    if fallback < 1 then fallback = 1 end
    if fallback > count then fallback = count end
    local index = record and chapter_index:find(record.image_path, record.index) or nil
    if type(index) ~= "number" or index < 1 or index > count
        or index ~= math.floor(index) then
        index = fallback
    end

    local segment = record and record.segment or "whole"
    if segment ~= "left" and segment ~= "right" then segment = "whole" end
    if type(valid_segments) ~= "table" or valid_segments[segment] ~= true then
        segment = "whole"
    end
    return { index = index, segment = segment }
end

return Progress
