local Errors = require("webdavmanga.errors")
local ErrorReporter = require("webdavmanga.error_reporter")
local ImageFormats = require("webdavmanga.image_formats")
local Path = require("webdavmanga.path")

local Cover = {}; Cover.__index = Cover
local function copy_resource(resource, root)
    if type(resource) ~= "table" then return nil end
    local path = Path.normalize_remote(resource.path or ""); if path == "" or (root and not Path.is_within_remote(path, root)) then return nil end
    return { name = tostring(resource.name or ""), path = path, is_folder = resource.is_folder and true or nil, is_file = resource.is_file and true or nil }
end
local function copy_image(image, root)
    if type(image) ~= "table" or not ImageFormats.is_supported(image.name) then return nil end
    local copied = copy_resource(image, root); if not copied then return nil end; copied.is_file = nil
    if image.size ~= nil then copied.size = tonumber(image.size) end; if image.etag ~= nil then copied.etag = tostring(image.etag) end
    if image.modified ~= nil then copied.modified = tostring(image.modified) end
    for _, key in ipairs({ "width", "height", "mupdf_page", "mupdf_source_size", "mobi_source_size", "mobi_record",
        "mobi_offset", "mobi_size", "archive_source_size", "archive_local_offset",
        "archive_method", "archive_flags", "archive_crc32", "archive_compressed_size",
        "archive_size" }) do
        local value = tonumber(image[key])
        if value and value == value and value ~= math.huge and value ~= -math.huge then
            copied[key] = value
        end
    end
    if type(image.format) == "string" and image.format ~= "" then copied.format = image.format end
    for _, key in ipairs({ "mupdf_remote_path", "mupdf_source_path", "mobi_path", "mobi_remote_path", "archive_kind",
        "archive_remote_path", "archive_entry_name", "archive_local_path", "archive_version" }) do
        if type(image[key]) == "string" and image[key] ~= "" then copied[key] = image[key] end
    end
    return copied
end
local function noop_handle() return { cancel = function() end } end
local function directory_index(directory, kind)
    if type(directory) ~= "table" then return nil end
    local value = directory[kind]
    return type(value) == "function" and directory[kind](directory) or value
end
local function identity(connection)
    connection = connection or {}; local user = tostring(connection.username or ""):match("^%s*(.-)%s*$")
    return table.concat({ tostring(connection.server_url or ""), user, Path.normalize_remote(connection.root_path or "") }, "\0")
end

function Cover.hint_for_directory(directory)
    directory = type(directory) == "table" and directory or {}
    local images = type(directory.images) == "function" and directory:images() or directory.images
    local folders = type(directory.folders) == "function" and directory:folders() or directory.folders
    if images and type(images.get) == "function" then
        local image = images:get(1); if image then return { layout = "direct", image = image } end
    end
    if folders and type(folders.get) == "function" then return { layout = "chapters", chapter = folders:get(1) } end
    return { layout = "chapters" }
end

function Cover:new(options)
    options = options or {}; local o = setmetatable({}, self)
    o.library = assert(options.library, "library is required")
    o.directory_store = assert(options.directory_store, "directory store is required")
    o.search_all_children = options.search_all_children == true
    o.scheduler = options.scheduler
    if o.search_all_children and not o.scheduler then
        local ok, manager = pcall(require, "ui/uimanager")
        if ok then o.scheduler = manager end
    end
    o.error_reporter = options.error_reporter or ErrorReporter:new{ logger = options.logger }
    o.generation, o.active = 0, nil; return o
end
function Cover:_root(connection) return Path.normalize_remote(connection and connection.root_path or "") end
function Cover:_valid_record(connection, record)
    if type(record) ~= "table" or type(record.manga) ~= "table" then return nil end
    local root, manga = self:_root(connection), copy_resource(record.manga, self:_root(connection)); if not manga then return nil end
    local chapter = record.chapter and copy_resource(record.chapter, root); if record.chapter and not chapter then return nil end
    local hint = record.cover_hint; if hint ~= nil and type(hint) ~= "table" then return nil end
    local hint_image = hint and hint.image and copy_image(hint.image, root); if hint and hint.image and not hint_image then return nil end
    local hint_chapter = hint and hint.chapter and copy_resource(hint.chapter, root); if hint and hint.chapter and not hint_chapter then return nil end
    local layout = record.layout and tostring(record.layout)
    if layout and layout ~= "direct" and layout ~= "chapters"
        and layout ~= "mobi_images" and layout ~= "archive_images"
        and layout ~= "mupdf_pages" then return nil end
    return { manga = manga, chapter = chapter, layout = layout, hint_image = hint_image, hint_chapter = hint_chapter, root = root }
end
function Cover:get(connection, manga_path)
    local root, path = self:_root(connection), Path.normalize_remote(manga_path or ""); if path == "" or not Path.is_within_remote(path, root) then return nil end
    local record = self.library:get_cover(connection, path); if type(record) ~= "table" then return nil end; if Path.normalize_remote(record.manga_path or "") ~= path then return nil end; if record.none then return nil, "none" end
    return copy_image(record.image, root)
end
function Cover:_cancel_active()
    local active = self.active; self.active = nil; self.generation = self.generation + 1
    if not active then return end
    if active.directory and active.directory.close then active.directory:close(); active.directory=nil end
    local handles = active.handles or { active.handle }
    local canceled = {}
    for _, handle in ipairs(handles) do
        if handle and not canceled[handle] and handle.cancel then
            canceled[handle] = true
            pcall(handle.cancel, handle)
        end
    end
end
function Cover:cancel_all() self:_cancel_active() end
function Cover:_notify(callbacks, key, value)
    if callbacks and type(callbacks[key]) == "function" then self.error_reporter:guard("load_cover", function() return callbacks[key](value) end, nil, nil, { silent = true }) end
end
function Cover:_finish(active, callbacks, key, value)
    if self.active ~= active then return end; self.active = nil
    if active.directory and active.directory.close then active.directory:close(); active.directory=nil end
    if key == "on_ready" then
        local image = copy_image(value, active.record.root); if not image then return self:_notify(callbacks, "on_error", Errors.invalid_path()) end
        local stored = self.error_reporter:guard("save_cache_index", function() return self.library:set_cover(active.connection, active.record.manga.path, image) end, false, nil, { silent = true })
        if not stored then return self:_notify(callbacks, "on_error", Errors.storage("cover_index")) end
        return self:_notify(callbacks, "on_ready", image)
    end
    if key == "none" then
        local stored = self.error_reporter:guard("save_cache_index", function()
            return self.library:set_no_cover(active.connection, active.record.manga.path)
        end, false, nil, { silent = true })
        if not stored then return self:_notify(callbacks, "on_error", Errors.storage("cover_index")) end
        return self:_notify(callbacks, "on_error", Errors.empty("cover"))
    end
    self:_notify(callbacks, "on_error", value)
end
function Cover:_start(connection, record, callbacks, force)
    self:_cancel_active(); self.generation = self.generation + 1; local active = { generation = self.generation, connection = connection, record = record, handles = {} }; self.active = active
    local function track(handle)
        active.handles[#active.handles + 1] = handle
        active.handle = handle
        return handle
    end
    local function finish_image(image) self:_finish(active, callbacks, "on_ready", image) end
    local function finish_error(err) self:_finish(active, callbacks, "error", err) end
    local function finish_none() self:_finish(active, callbacks, "none") end
    if not force and record.hint_image then finish_image(record.hint_image); return noop_handle() end
    local store = self.directory_store
    local function load(path, ready, failed)
        return store:load(path, { refresh = force, on_ready = function(directory)
            if self.active ~= active then if directory.close then directory:close() end; return end
            ready(directory)
        end, on_error = function(err) if self.active == active then failed(err) end end })
    end
    local function chapter_image(chapter_path)
        track(load(chapter_path, function(directory)
            local index = directory_index(directory, "images")
            local image = index and index:get(1)
            if directory.close then directory:close() end
            if image then finish_image(image) else finish_none() end
        end, finish_error))
    end
    local function search_children(folders)
        local position, last_error = 0, nil
        local step
        local function advance()
            if self.active ~= active then return end
            if self.scheduler and self.scheduler.scheduleIn then self.scheduler:scheduleIn(0, step)
            else step() end
        end
        step = function()
            if self.active ~= active then return end
            position = position + 1
            local chapter = position <= folders:count() and folders:get(position)
            if not chapter then
                if last_error then finish_error(last_error) else finish_none() end
                return
            end
            track(load(chapter.path, function(directory)
                if self.active ~= active then if directory.close then directory:close() end; return end
                local images = directory_index(directory, "images")
                local image = images and images:get(1)
                if directory.close then directory:close() end
                if image then finish_image(image) else advance() end
            end, function(err) last_error = err; advance() end))
        end
        step()
    end
    track(load(record.manga.path, function(directory)
        local hint = Cover.hint_for_directory{
            folders = directory_index(directory, "folders"),
            images = directory_index(directory, "images"),
        }
        if hint.layout == "direct" then
            local image = hint.image
            if directory.close then directory:close() end
            if image then finish_image(image) else finish_none() end
        else
            local chapter = record.hint_chapter or hint.chapter
            local children
            if self.search_all_children then
                children = directory_index(directory, "folders")
            end
            if children then active.directory=directory;search_children(children)
            else
                if directory.close then directory:close() end
                if chapter then chapter_image(chapter.path) else finish_none() end
            end
        end
    end, finish_error))
    return { cancel = function() if self.active == active then self:_cancel_active() end end }
end
function Cover:resolve(connection, record, callbacks)
    self:_cancel_active()
    local safe = self:_valid_record(connection, record); if not safe then self:_notify(callbacks, "on_error", Errors.invalid_path()); return noop_handle() end
    local indexed, state = self:get(connection, safe.manga.path); if indexed then self:_notify(callbacks, "on_ready", indexed); return noop_handle() end; if state == "none" then self:_notify(callbacks, "on_error", Errors.empty("cover")); return noop_handle() end
    return self:_start(connection, safe, callbacks, false)
end
function Cover:refresh(connection, record, callbacks)
    local safe = self:_valid_record(connection, record); if not safe then self:_notify(callbacks, "on_error", Errors.invalid_path()); return noop_handle() end; return self:_start(connection, safe, callbacks, true)
end

return Cover
