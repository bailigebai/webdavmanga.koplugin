local Path = require("webdavmanga.path")
local GrayEnhance = require("webdavmanga.gray_enhance")
local ToneAdjust = require("webdavmanga.tone_adjust")

local PanelOptions = require("webdavmanga.panel_options")
local Dynamic = require('webdavmanga.dynamic_panel_zoom')
local Quadrant = require('webdavmanga.quadrant_zoom')

local AutoCrop = require("webdavmanga.auto_crop")
local Settings = {}
Settings.__index = Settings

local DEFAULT_CONNECTION = {
    server_url = "",
    username = "",
    password = "",
    root_path = "",
}

local DEFAULT_READER = {
    opds_pointer_per_server = true,
    opds_cover_enabled = true,
    direction = "normal",
    prefetch_count = 3,
    prefetch_first_pages = 10,
    prefetch_near_count = 5,
    prefetch_far_count = 2,
    prefetch_concurrency = 2,
    -- Keep segmented prefetch enabled for image chapters by default.
    image_prefetch_enabled = true,
    range_streaming_enabled = true,
    cache_limit_mb = 200,
    cover_cache_limit_mb = 200,
    -- page: fit the complete image in the screen; width: fit the screen
    -- width and allow vertical paging; match: keep KOReader's automatic fit.
    fit_mode = "page",
    display_background = "auto",
    webtoon_smart_enabled = true,
    webtoon_overlap_percent = 5,
    webtoon_fit_percent = 5,
    webtoon_margin_percent = 0,
    bubble_zoom_enabled = false,
    bubble_zoom_trigger = "both",
    bubble_zoom_scale = 2,
    gray_enhance_enabled = false,
    gray_enhance_preset = "original",
    gray_enhance_custom_presets = {},
    gray_enhance_sample_path = "",
    tone_adjust_enabled = false,
    tone_adjust_preset = "original",
    tone_adjust_custom_presets = {},
    tone_adjust_sample_path = "",
    show_preprocess_success = true,
    show_progress_bar = true,
    progress_bar_thickness = 1,
    full_refresh_each_page = false,
    graydither_enabled = false,
    graydither_refresh_enabled = false,
    auto_crop_enabled = false,
    auto_crop_threshold = 242,
    auto_crop_max_percent = 15,
    auto_crop_enhance_enabled = false,
    auto_crop_border_width = 2,
    auto_crop_min_area = 4,
    auto_crop_padding_percent = 1,
    split_enabled = false,
    split_min_ratio = 1.20,
    split_max_ratio = 2.20,
    split_cut_percent = 50,
    -- Explicit first viewport for a two-page spread.
    split_first_segment = "left",
    panel_zoom_enabled = false,
    panel_show_adjacent = true,
    panel_standard_margin_percent = 0,
    panel_hold_margin_percent = 5,
    panel_initial_zoom = 1.2,
    panel_experimental_sort = false,
    panel_view = "context",
    panel_rotation = 0,
    panel_navigation = "horizontal",
    panel_reverse_navigation = false,
    panel_order = "follow",
    grid_columns = 5,
    animation_enabled = false,
}

for _, field in ipairs(PanelOptions.fields) do DEFAULT_READER[field.key]=field.default end
for _, field in ipairs(Quadrant.fields) do DEFAULT_READER[field.key]=field.default end

local DEFAULT_BROWSE_CACHE = {
    total_mb = 5120,
    trigger_mb = 3072,
    retain_mb = 1024,
    interval_minutes = 10,
}

local DEFAULT_RATING_MAX = 5
local DEFAULT_OFFLINE_ROOT = "/mnt/us/Books/WebDAVManga"
local DEFAULT_OFFLINE_LIMIT_GB = 5
local DEFAULT_OFFLINE_REFRESH_SECONDS = 15

local function copy_table(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function with_defaults(defaults, values)
    local result = copy_table(defaults)
    for key, value in pairs(values or {}) do
        result[key] = value
    end
    return result
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function opds_server_kind(value)
    if value == "kavita" or value == "suwayomi" or value == "komga" then
        return value
    end
    return "auto"
end

local function valid_opds_url(value)
    local authority = tostring(value or ""):match("^https?://([^/?#]+)")
    local host = authority and authority:match("([^@]+)$")
    return host ~= nil and host:match("^[^:%s]+") ~= nil
end

local function normalize_root(value)
    local root = trim(value)
    if root == "" then return "" end
    local normalized = Path.normalize_remote(root)
    return normalized == "" and "/" or normalized
end

local function normalize_offline_root(value)
    local root = trim(value):gsub("\\", "/"):gsub("/+", "/")
    if #root > 1 then root = root:gsub("/+$", "") end
    return root
end

local function valid_offline_root(value)
    local root = normalize_offline_root(value)
    if root:find("%z") or root:find("..", 1, true) then return false end
    return root == "/mnt/us" or root:sub(1, 8) == "/mnt/us/"
end

local function connection_copy(connection)
    connection = connection or {}
    local raw_kind = trim(connection.kind)
    local raw_server = trim(connection.server_url)
    local raw_local_path = trim(connection.local_path)
    -- Older local-source settings may contain only local_path (or an empty
    -- server_url).  Recover those records as local instead of silently
    -- treating them as an unconfigured WebDAV source.
    local kind = raw_kind
    if kind == "" then
        kind = raw_local_path ~= ""
            and (raw_server == "" or raw_server == "local://")
            and "local" or "webdav"
    end
    local root_path = normalize_root(connection.root_path)
    if kind == "local" and raw_local_path ~= "" then
        root_path = normalize_root(raw_local_path)
    end
    return {
        kind = kind,
        server_url = kind == "local" and "local://" or raw_server,
        username = kind == "local" and "" or trim(connection.username),
        password = kind == "local" and "" or tostring(connection.password or ""),
        root_path = kind == "opds" and "/" or root_path,
        server_kind = kind == "opds" and opds_server_kind(connection.server_kind) or nil,
        local_path = kind == "local" and root_path
            or raw_local_path,
        nodeshare = type(connection.nodeshare) == "table"
            and copy_table(connection.nodeshare) or nil,
    }
end

local function source_name(connection, name)
    name = trim(name)
    if name ~= "" then return name end
    if connection.kind == "local" then return connection.local_path end
    local server = trim(connection.server_url):gsub("^https?://", "")
    if connection.kind == "opds" then
        return (server:match("^[^/?#]+") or server):gsub("^.*@", "")
    end
    return server .. normalize_root(connection.root_path)
end

local function browser_identity(connection)
    connection = connection or {}
    return table.concat({
        trim(connection.kind) ~= "" and trim(connection.kind) or "webdav",
        trim(connection.server_url),
        trim(connection.username),
        normalize_root(connection.root_path),
        trim(connection.local_path),
        trim(connection.server_kind),
    }, "\0")
end

local function is_within_root(path, root)
    if path == "" or root == "" then return false end
    if root == "/" then return path:sub(1, 1) == "/" end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function is_integer_in_range(value, minimum, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function is_number_in_range(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
end

local function one_of(value, allowed)
    for _, candidate in ipairs(allowed) do
        if value == candidate then return true end
    end
    return false
end

function Settings:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.settings_path = options.settings_path
    object.default_opds_pointer_root = options.default_opds_pointer_root or "./webdavmanga-streams"
    object.store = options.store
    if not object.store then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        object.settings_path = object.settings_path
            or (DataStorage:getSettingsDir() .. "/webdavmanga.lua")
        object.store = LuaSettings:open(object.settings_path)
    end
    return object
end

local function copy_source(source)
    local connection = connection_copy(source)
    return {
        id = trim(source and source.id),
        name = source_name(connection, source and source.name),
        kind = connection.kind,
        server_url = connection.server_url,
        username = connection.username,
        password = connection.password,
        root_path = connection.root_path,
        server_kind = connection.server_kind,
        local_path = connection.local_path,
        nodeshare = connection.nodeshare,
    }
end

local function normalize_connection(values)
    values = values or {}
    local server_url = trim(values.server_url or values.url):gsub("/+$", "")
    if values.kind == "opds" then
        if not valid_opds_url(server_url) then
            return nil, "invalid_opds_url"
        end
        return {
            kind = "opds", server_url = server_url,
            username = trim(values.username),
            password = tostring(values.password or ""),
            root_path = "/", server_kind = opds_server_kind(values.server_kind),
        }
    end
    if not server_url:match("^https?://[^/]+") then
        return nil, "invalid_server_url"
    end
    local root_path = normalize_root(values.root_path)
    if root_path == "" then return nil, "invalid_root_path" end
    return {
        kind = values.kind == "nodeshare" and "nodeshare" or "webdav",
        server_url = server_url,
        username = trim(values.username),
        password = tostring(values.password or ""),
        root_path = root_path,
        nodeshare = type(values.nodeshare) == "table"
            and copy_table(values.nodeshare) or nil,
    }
end

local function normalize_local_connection(values)
    values = values or {}
    local local_path = trim(values.local_path or values.root_path):gsub("\\", "/")
    if local_path == "" or local_path:sub(1, 1) ~= "/"
        or local_path:find("\0", 1, true) then
        return nil, "invalid_local_path"
    end
    for segment in local_path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil, "invalid_local_path" end
    end
    local root_path = normalize_root(local_path)
    if root_path == "" then return nil, "invalid_local_path" end
    return {
        kind = "local",
        server_url = "local://",
        username = "",
        password = "",
        root_path = root_path,
        local_path = root_path,
    }
end

function Settings:_source_records()
    local records, used = {}, {}
    local saved = self.store:readSetting("sources", nil)
    local function append(raw, fallback_id)
        if type(raw) ~= "table" then return end
        local connection = connection_copy(raw)
        local valid_webdav = connection.kind ~= "local"
            and connection.server_url ~= ""
            and connection.server_url:match("^https?://[^/]+")
        local valid_local = connection.kind == "local"
            and connection.local_path ~= "" and connection.root_path ~= ""
        if not valid_webdav and not valid_local then
            return
        end
        local id = trim(raw.id)
        if id == "" or used[id] then
            id = trim(fallback_id)
        end
        if id == "" or used[id] then
            local number = #records + 1
            repeat
                id = "source-" .. tostring(number)
                number = number + 1
            until not used[id]
        end
        used[id] = true
        connection.id = id
        connection.name = source_name(connection, raw.name)
        records[#records + 1] = copy_source(connection)
    end
    if type(saved) == "table" then
        if #saved > 0 then
            for index, value in ipairs(saved) do append(value, "source-" .. tostring(index)) end
        else
            local keys = {}
            for key in pairs(saved) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            for _, key in ipairs(keys) do append(saved[key], key) end
        end
    end
    if #records == 0 then
        append(self.store:readSetting("connection", {}), "source-1")
    end
    return records
end

function Settings:_save_sources(records)
    local saved = {}
    for index, source in ipairs(records or {}) do
        saved[index] = copy_source(source)
    end
    self.store:saveSetting("sources", saved)
    self:_next_source_number(records)
end

function Settings:_next_source_number(records)
    local number = tonumber(self.store:readSetting("next_source_number")) or 1
    number = math.max(1, math.floor(number))
    for _, source in ipairs(records or {}) do
        local used = tonumber(tostring(source.id):match("^source%-(%d+)$"))
        if used then number = math.max(number, used + 1) end
    end
    self.store:saveSetting("next_source_number", number)
    return number
end

function Settings:_allocate_source_id(records)
    local number = self:_next_source_number(records)
    self.store:saveSetting("next_source_number", number + 1)
    return "source-" .. tostring(number)
end

function Settings:_active_id(records)
    local wanted = trim(self.store:readSetting("active_source_id", ""))
    for _, source in ipairs(records or {}) do
        if source.id == wanted then return wanted end
    end
    return records and records[1] and records[1].id or nil
end

function Settings:get_sources()
    local result = {}
    for index, source in ipairs(self:_source_records()) do
        result[index] = copy_source(source)
    end
    return result
end

function Settings:get_active_source_id()
    return self:_active_id(self:_source_records())
end

function Settings:get_source(source_id)
    source_id = trim(source_id)
    for _, source in ipairs(self:_source_records()) do
        if source.id == source_id then return copy_source(source) end
    end
    return nil
end

function Settings:get_connection()
    local records = self:_source_records()
    local active_id = self:_active_id(records)
    for _, source in ipairs(records) do
        if source.id == active_id then
            local connection = connection_copy(source)
            connection.name = source.name
            if connection.kind == "opds" then connection.source_id = source.id end
            return connection
        end
    end
    return with_defaults(DEFAULT_CONNECTION, self.store:readSetting("connection", {}))
end

function Settings:_save_browser_path(connection, path)
    local paths = self.store:readSetting("browser_paths", {})
    if type(paths) ~= "table" then paths = {} end
    paths[browser_identity(connection)] = path
    self.store:saveSetting("browser_paths", paths)
    self.store:saveSetting("browser_path", path)
end

function Settings:set_connection(values)
    local connection, error_code = normalize_connection(values)
    if not connection then return nil, error_code end
    local previous_connection = self:get_connection()
    local previous_browser_path = self:get_browser_path()
    local records = self:_source_records()
    local active_id = self:_active_id(records)
    local active
    for _, source in ipairs(records) do
        if source.id == active_id then active = source; break end
    end
    if not active then
        active_id = self:_allocate_source_id(records)
        active = { id = active_id }
        records[#records + 1] = active
    end
    for key, value in pairs(connection) do active[key] = value end
    active.kind = connection.kind
    active.local_path = nil
    active.nodeshare = connection.nodeshare
    active.server_kind = connection.server_kind
    active.name = source_name(connection, values and values.name or active.name)
    active.id = active_id
    self:_save_sources(records)
    self.store:saveSetting("active_source_id", active_id)
    self.store:saveSetting("connection", connection_copy(connection))
    local same_identity = trim(previous_connection.kind) == connection.kind
        and trim(previous_connection.server_url):gsub("/+$", "") == connection.server_url
        and trim(previous_connection.username) == connection.username
    local browser_path = connection.root_path
    if same_identity and is_within_root(previous_browser_path, connection.root_path) then
        browser_path = previous_browser_path
    end
    self:_save_browser_path(connection, browser_path)
    return true
end

function Settings:add_source(values)
    local connection, error_code = normalize_connection(values)
    if not connection then return nil, error_code end
    local records = self:_source_records()
    local id = self:_allocate_source_id(records)
    records[#records + 1] = {
        id = id,
        name = source_name(connection, values and values.name),
        kind = connection.kind,
        server_url = connection.server_url,
        username = connection.username,
        password = connection.password,
        root_path = connection.root_path,
        server_kind = connection.server_kind,
        nodeshare = connection.nodeshare,
    }
    self:_save_sources(records)
    self.store:saveSetting("active_source_id", id)
    self.store:saveSetting("connection", connection_copy(connection))
    self:_save_browser_path(connection, connection.root_path)
    return true, id
end

function Settings:set_source(source_id, values)
    source_id = trim(source_id)
    if source_id == "" then return nil, "missing_source" end
    if values and values.kind == "local" then
        return self:set_local_source(source_id, values)
    end
    if source_id == self:get_active_source_id() then
        return self:set_connection(values)
    end
    local connection, error_code = normalize_connection(values)
    if not connection then return nil, error_code end
    local records = self:_source_records()
    for _, source in ipairs(records) do
        if source.id == source_id then
            source.server_url = connection.server_url
            source.username = connection.username
            source.password = connection.password
            source.root_path = connection.root_path
            source.server_kind = connection.server_kind
            source.kind = connection.kind
            source.local_path = nil
            source.nodeshare = connection.nodeshare
            source.name = source_name(connection, values and values.name or source.name)
            self:_save_sources(records)
            return true
        end
    end
    return nil, "missing_source"
end

function Settings:add_local_source(values)
    local connection, error_code = normalize_local_connection(values)
    if not connection then return nil, error_code end
    local records = self:_source_records()
    local id = self:_allocate_source_id(records)
    records[#records + 1] = {
        id = id,
        name = source_name(connection, values and values.name),
        kind = "local",
        server_url = connection.server_url,
        username = "",
        password = "",
        root_path = connection.root_path,
        local_path = connection.local_path,
    }
    self:_save_sources(records)
    self.store:saveSetting("active_source_id", id)
    self.store:saveSetting("connection", connection_copy(connection))
    self:_save_browser_path(connection, connection.root_path)
    return true, id
end

function Settings:set_local_source(source_id, values)
    source_id = trim(source_id)
    local connection, error_code = normalize_local_connection(values)
    if not connection then return nil, error_code end
    local records = self:_source_records()
    for _, source in ipairs(records) do
        if source.id == source_id then
            source.kind = "local"
            source.server_url = connection.server_url
            source.username = ""
            source.password = ""
            source.root_path = connection.root_path
            source.local_path = connection.local_path
            source.server_kind = nil
            source.name = source_name(connection, values and values.name or source.name)
            self:_save_sources(records)
            if source_id == self:_active_id(records) then
                self.store:saveSetting("connection", connection_copy(source))
                self:_save_browser_path(connection, connection.root_path)
            end
            return true
        end
    end
    return nil, "missing_source"
end

function Settings:select_source(source_id)
    source_id = trim(source_id)
    local records = self:_source_records()
    for _, source in ipairs(records) do
        if source.id == source_id then
            local connection = connection_copy(source)
            self.store:saveSetting("active_source_id", source_id)
            self.store:saveSetting("connection", connection_copy(connection))
            local path = self.store:readSetting("browser_paths", {})
            path = type(path) == "table" and normalize_root(path[browser_identity(connection)]) or nil
            if not path or not is_within_root(path, connection.root_path) then path = connection.root_path end
            self:_save_browser_path(connection, path)
            return true
        end
    end
    return nil, "missing_source"
end

function Settings:remove_source(source_id)
    source_id = trim(source_id)
    local records, kept = self:_source_records(), {}
    if #records <= 1 then return nil, "last_source" end
    local removed = false
    for _, source in ipairs(records) do
        if source.id == source_id then removed = true else kept[#kept + 1] = source end
    end
    if not removed then return nil, "missing_source" end
    local active_id = self:_active_id(records)
    self:_next_source_number(records)
    self:_save_sources(kept)
    if active_id == source_id then
        local selected = kept[1]
        self.store:saveSetting("active_source_id", selected.id)
        self.store:saveSetting("connection", connection_copy(selected))
        self:_save_browser_path(selected, selected.root_path)
    end
    return true
end

function Settings:get_browser_path()
    local connection = self:get_connection()
    local root_path = normalize_root(connection.root_path)
    local paths = self.store:readSetting("browser_paths", {})
    local saved
    if type(paths) == "table" then
        saved = normalize_root(paths[browser_identity(connection)])
    end
    if not saved or saved == "" then
        saved = normalize_root(self.store:readSetting("browser_path", root_path))
    end
    if is_within_root(saved, root_path) then return saved end
    return root_path
end

function Settings:set_browser_path(value)
    local path = normalize_root(value)
    local connection = self:get_connection()
    local root_path = normalize_root(connection.root_path)
    if not is_within_root(path, root_path) then
        return nil, "browser_path_outside_root"
    end
    self:_save_browser_path(connection, path)
    return true
end

local function strip_removed_processing(reader)
    -- Ignore old filter values without rewriting the user's settings on read.
    for key in pairs(reader) do
        if type(key) == "string" and key:match("^image_filter_") then reader[key] = nil end
    end
    reader.contrast_percent = nil
    reader.large_image_optimize_enabled = nil
end

function Settings:get_reader()
    local saved = self.store:readSetting("reader", {})
    if type(saved) ~= "table" then saved = {} end
    local reader = with_defaults(DEFAULT_READER, saved)
    reader.hide_status_bar = nil
    if type(reader.opds_pointer_root) ~= "string" or trim(reader.opds_pointer_root) == ""
        or reader.opds_pointer_root:find("[%z\1-\31\127]") then
        reader.opds_pointer_root = self.default_opds_pointer_root
    end
    reader.opds_pointer_per_server = reader.opds_pointer_per_server ~= false
    reader.opds_cover_enabled = reader.opds_cover_enabled ~= false
    local legacy_prefetch = tonumber(saved.prefetch_count)
    if legacy_prefetch and legacy_prefetch == math.floor(legacy_prefetch)
        and legacy_prefetch >= 0 and legacy_prefetch <= 10 then
        if saved.prefetch_near_count == nil then
            reader.prefetch_near_count = legacy_prefetch
        end
        if saved.prefetch_far_count == nil then
            reader.prefetch_far_count = legacy_prefetch
        end
    end
    local custom_presets = GrayEnhance.sanitize_custom_presets(
        reader.gray_enhance_custom_presets)
    local selected = trim(reader.gray_enhance_preset)
    if not GrayEnhance.is_valid_id(selected, custom_presets) then
        selected = "original"
    end
    reader.gray_enhance_enabled = reader.gray_enhance_enabled == true
    reader.gray_enhance_preset = selected
    reader.gray_enhance_custom_presets = custom_presets
    reader.gray_enhance_sample_path = GrayEnhance.normalize_sample_path(
        reader.gray_enhance_sample_path) or ""
    local tone_presets = ToneAdjust.sanitize_custom_presets(
        reader.tone_adjust_custom_presets)
    local tone_selected = trim(reader.tone_adjust_preset)
    if not ToneAdjust.is_valid_id(tone_selected, tone_presets) then
        tone_selected = "original"
    end
    reader.tone_adjust_enabled = reader.tone_adjust_enabled == true
    reader.tone_adjust_preset = tone_selected
    reader.tone_adjust_custom_presets = tone_presets
    reader.tone_adjust_sample_path = GrayEnhance.normalize_sample_path(
        reader.tone_adjust_sample_path) or ""
    reader.panel_zoom_enabled = reader.panel_zoom_enabled == true
    Dynamic.normalize(reader)
    Quadrant.normalize(reader)
    AutoCrop.normalize_enhance(reader)
    reader.bubble_zoom_enabled = reader.bubble_zoom_enabled == true
    if not one_of(reader.bubble_zoom_trigger,{"hold","tap","both"}) then reader.bubble_zoom_trigger="both" end
    PanelOptions.normalize(reader)
    if not one_of(reader.bubble_zoom_scale, {1.5, 2, 3}) then reader.bubble_zoom_scale = 2 end
    reader.panel_show_adjacent = reader.panel_show_adjacent ~= false
    reader.panel_experimental_sort = reader.panel_experimental_sort == true
    if not one_of(reader.panel_view,{"cut","context","free"}) then reader.panel_view="context" end
    if not one_of(reader.panel_rotation,{0,90,180,270}) then reader.panel_rotation=0 end
    if not one_of(reader.panel_navigation,{"horizontal","vertical"}) then reader.panel_navigation="horizontal" end
    reader.panel_reverse_navigation=reader.panel_reverse_navigation==true
    if not one_of(reader.panel_order,{"follow","normal","manga"}) then reader.panel_order="follow" end
    reader.show_preprocess_success = reader.show_preprocess_success ~= false
    strip_removed_processing(reader)
    reader.show_page_number = nil
    -- v0.3.7 delegates page animation to the Kindle display driver.  Old
    -- software-animation tuning values must not re-enter the live settings.
    reader.animation_steps = nil
    reader.animation_delay_ms = nil
    return reader
end

function Settings:set_reader(values)
    values = values or {}
    local has_segmented_prefetch = values.prefetch_first_pages ~= nil
        or values.prefetch_near_count ~= nil
        or values.prefetch_far_count ~= nil
    local previous = self:get_reader()
    local reader = with_defaults(previous, values)
    if not Quadrant.validate(reader) then return nil, 'invalid_grid_zoom_settings' end
    if not AutoCrop.validate_enhance(reader) then return nil, 'invalid_auto_crop_enhance_settings' end
    if not Dynamic.validate(reader) then return nil, 'invalid_dynamic_panel_settings' end
    Dynamic.resolve(reader, previous)
    if type(reader.graydither_enabled) ~= "boolean"
        or type(reader.graydither_refresh_enabled) ~= "boolean" then
        return nil, "invalid_graydither_settings"
    end
    reader.hide_status_bar = nil
    if type(reader.opds_pointer_root) ~= "string" or trim(reader.opds_pointer_root) == ""
        or reader.opds_pointer_root:find("[%z\1-\31\127]")
        or type(reader.opds_pointer_per_server) ~= "boolean"
        or type(reader.opds_cover_enabled) ~= "boolean" then
        return nil, "invalid_opds_pointer_settings"
    end
    if type(reader.gray_enhance_enabled) ~= "boolean" then
        return nil, "invalid_gray_enhance_enabled"
    end
    if type(reader.tone_adjust_enabled) ~= "boolean" then
        return nil, "invalid_tone_adjust_enabled"
    end
    if not PanelOptions.validate(reader) then return nil,"invalid_panel_view_settings" end
    if type(reader.panel_zoom_enabled) ~= "boolean"
        or type(reader.panel_show_adjacent) ~= "boolean"
        or type(reader.panel_experimental_sort) ~= "boolean" then
        return nil, "invalid_panel_toggle"
    end
    if not one_of(reader.panel_view,{"cut","context","free"})
        or not one_of(reader.panel_rotation,{0,90,180,270})
        or not one_of(reader.panel_navigation,{"horizontal","vertical"})
        or type(reader.panel_reverse_navigation)~="boolean"
        or not one_of(reader.panel_order,{"follow","normal","manga"}) then
        return nil,"invalid_panel_view_settings"
    end
    if type(reader.bubble_zoom_enabled) ~= "boolean"
        or not one_of(reader.bubble_zoom_trigger, {"hold", "tap", "both"})
        or not one_of(reader.bubble_zoom_scale, {1.5, 2, 3}) then
        return nil, "invalid_bubble_zoom"
    end
    if not one_of(reader.panel_standard_margin_percent, { 0, 2, 5, 10 }) then
        return nil, "invalid_panel_standard_margin"
    end
    if not one_of(reader.panel_hold_margin_percent, { 2, 5, 10, 15, 20 }) then
        return nil, "invalid_panel_hold_margin"
    end
    if not one_of(reader.panel_initial_zoom, { 1.0, 1.2, 1.5, 2.0 }) then
        return nil, "invalid_panel_initial_zoom"
    end
    if type(reader.show_preprocess_success) ~= "boolean" then
        return nil, "invalid_preprocess_success_setting"
    end
    if values.prefetch_count ~= nil and not has_segmented_prefetch then
        reader.prefetch_near_count = values.prefetch_count
        reader.prefetch_far_count = values.prefetch_count
    end
    -- Removed in v0.3.0: never carry the obsolete title-bar setting forward.
    reader.show_page_number = nil
    reader.animation_steps = nil
    reader.animation_delay_ms = nil
    reader.gray_enhance_custom_presets = GrayEnhance.sanitize_custom_presets(
        reader.gray_enhance_custom_presets)
    reader.gray_enhance_preset = trim(reader.gray_enhance_preset)
    if not GrayEnhance.is_valid_id(reader.gray_enhance_preset,
        reader.gray_enhance_custom_presets) then
        return nil, "invalid_gray_preset"
    end
    reader.tone_adjust_custom_presets = ToneAdjust.sanitize_custom_presets(
        reader.tone_adjust_custom_presets)
    reader.tone_adjust_preset = trim(reader.tone_adjust_preset)
    if not ToneAdjust.is_valid_id(reader.tone_adjust_preset,
        reader.tone_adjust_custom_presets) then
        return nil, "invalid_tone_preset"
    end
    local sample_path = GrayEnhance.normalize_sample_path(reader.gray_enhance_sample_path)
    if sample_path == nil then return nil, "invalid_gray_sample_path" end
    reader.gray_enhance_sample_path = sample_path
    local tone_sample_path = GrayEnhance.normalize_sample_path(
        reader.tone_adjust_sample_path)
    if tone_sample_path == nil then return nil, "invalid_tone_sample_path" end
    reader.tone_adjust_sample_path = tone_sample_path
    strip_removed_processing(reader)
    if reader.direction ~= "normal" and reader.direction ~= "manga" then
        return nil, "invalid_direction"
    end
    if not is_integer_in_range(reader.prefetch_count, 0, 10) then
        return nil, "invalid_prefetch_count"
    end
    if not is_integer_in_range(reader.prefetch_first_pages, 1, 100) then
        return nil, "invalid_prefetch_first_pages"
    end
    if not is_integer_in_range(reader.prefetch_near_count, 0, 10) then
        return nil, "invalid_prefetch_near_count"
    end
    if not is_integer_in_range(reader.prefetch_far_count, 0, 10) then
        return nil, "invalid_prefetch_far_count"
    end
    if not is_integer_in_range(reader.prefetch_concurrency, 1, 3) then
        return nil, "invalid_prefetch_concurrency"
    end
    if type(reader.image_prefetch_enabled) ~= "boolean" then
        return nil, "invalid_image_prefetch_enabled"
    end
    if type(reader.range_streaming_enabled) ~= "boolean" then
        return nil, "invalid_range_streaming_enabled"
    end
    if not is_integer_in_range(reader.cache_limit_mb, 16, 4096) then
        return nil, "invalid_cache_limit"
    end
    if not is_integer_in_range(reader.cover_cache_limit_mb, 16, 4096) then
        return nil, "invalid_cover_cache_limit"
    end
    if reader.fit_mode ~= "page" and reader.fit_mode ~= "width"
        and reader.fit_mode ~= "match" and reader.fit_mode ~= "webtoon" then
        return nil, "invalid_fit_mode"
    end
    if reader.display_background ~= "auto" and reader.display_background ~= "white"
        and reader.display_background ~= "black" then return nil, "invalid_display_background" end
    if type(reader.webtoon_smart_enabled) ~= "boolean"
        or not is_integer_in_range(reader.webtoon_overlap_percent, 0, 20)
        or not is_integer_in_range(reader.webtoon_fit_percent, 0, 15)
        or not is_integer_in_range(reader.webtoon_margin_percent, 0, 20) then
        return nil, "invalid_webtoon_settings"
    end
    if type(reader.show_progress_bar) ~= "boolean" then
        return nil, "invalid_progress_bar_setting"
    end
    if not is_integer_in_range(reader.progress_bar_thickness, 1, 4) then
        return nil, "invalid_progress_bar_thickness"
    end
    if type(reader.full_refresh_each_page) ~= "boolean" then
        return nil, "invalid_full_refresh_setting"
    end
    if type(reader.auto_crop_enabled) ~= "boolean" then
        return nil, "invalid_auto_crop_enabled"
    end
    if not is_integer_in_range(reader.auto_crop_threshold, 200, 255) then
        return nil, "invalid_auto_crop_threshold"
    end
    if not is_integer_in_range(reader.auto_crop_max_percent, 0, 30) then
        return nil, "invalid_auto_crop_max_percent"
    end
    if type(reader.split_enabled) ~= "boolean" then
        return nil, "invalid_split_enabled"
    end
    if not is_number_in_range(reader.split_min_ratio, 1.00, 4.00) then
        return nil, "invalid_split_min_ratio"
    end
    if not is_number_in_range(reader.split_max_ratio, 1.00, 4.00) then
        return nil, "invalid_split_max_ratio"
    end
    if reader.split_min_ratio >= reader.split_max_ratio then
        return nil, "invalid_split_ratio_range"
    end
    if not is_integer_in_range(reader.split_cut_percent, 10, 90) then
        return nil, "invalid_split_cut_percent"
    end
    if reader.split_first_segment ~= "left" and reader.split_first_segment ~= "right" then
        return nil, "invalid_split_first_segment"
    end
    if reader.grid_columns ~= 3 and reader.grid_columns ~= 5 then
        return nil, "invalid_grid_columns"
    end
    if type(reader.animation_enabled) ~= "boolean" then
        return nil, "invalid_animation_enabled"
    end
    if self.store:saveSetting("reader", copy_table(reader)) == false then
        return nil, "reader_settings_write_failed"
    end
    return true
end

local BOOKSHELF_DEFAULTS = {total_mb=200, trigger_mb=150, retain_mb=100, interval_minutes=10}
local function valid_bookshelf_policy(p)
    return is_integer_in_range(p.total_mb, 1, 32768)
        and is_integer_in_range(p.trigger_mb, 1, 32768)
        and is_integer_in_range(p.retain_mb, 0, 32768)
        and is_integer_in_range(p.interval_minutes, 1, 1440)
        and p.retain_mb < p.trigger_mb and p.trigger_mb <= p.total_mb
end
function Settings:get_bookshelf_cache()
    local saved = self.store:readSetting("bookshelf_cache", {})
    local policy = copy_table(BOOKSHELF_DEFAULTS)
    if type(saved) == "table" then
        for key in pairs(policy) do if saved[key] ~= nil then policy[key] = tonumber(saved[key]) end end
    end
    return valid_bookshelf_policy(policy) and policy or copy_table(BOOKSHELF_DEFAULTS)
end
function Settings:set_bookshelf_cache(values)
    local policy = self:get_bookshelf_cache()
    for key in pairs(policy) do if values[key] ~= nil then policy[key] = tonumber(values[key]) end end
    if not valid_bookshelf_policy(policy) then return nil, "invalid_bookshelf_policy" end
    self.store:saveSetting("bookshelf_cache", policy)
    return true
end
function Settings:get_bookshelf_view()
    return self.store:readSetting("bookshelf_view") == "covers" and "covers" or "list"
end
function Settings:set_bookshelf_view(mode)
    if mode ~= "list" and mode ~= "covers" then return nil, "invalid_bookshelf_view" end
    self.store:saveSetting("bookshelf_view", mode)
    return true
end

function Settings:get_browse_cache()
    local saved = self.store:readSetting("browse_cache", {})
    if type(saved) ~= "table" then saved = {} end
    local result = copy_table(DEFAULT_BROWSE_CACHE)
    for key in pairs(result) do
        local value = tonumber(saved[key])
        if value and value == math.floor(value) then result[key] = value end
    end
    if not is_integer_in_range(result.total_mb, 16, 32768)
        or not is_integer_in_range(result.trigger_mb, 16, 32768)
        or not is_integer_in_range(result.retain_mb, 0, 32768)
        or not is_integer_in_range(result.interval_minutes, 1, 1440)
        or result.trigger_mb > result.total_mb
        or result.retain_mb >= result.trigger_mb then
        return copy_table(DEFAULT_BROWSE_CACHE)
    end
    return result
end

function Settings:set_browse_cache(values)
    values = values or {}
    local current = self:get_browse_cache()
    local policy = {
        total_mb = values.total_mb == nil and current.total_mb or values.total_mb,
        trigger_mb = values.trigger_mb == nil and current.trigger_mb or values.trigger_mb,
        retain_mb = values.retain_mb == nil and current.retain_mb or values.retain_mb,
        interval_minutes = values.interval_minutes == nil
            and current.interval_minutes or values.interval_minutes,
    }
    if not is_integer_in_range(policy.total_mb, 16, 32768) then
        return nil, "invalid_browse_cache_total"
    end
    if not is_integer_in_range(policy.trigger_mb, 16, 32768) then
        return nil, "invalid_browse_cache_trigger"
    end
    if policy.trigger_mb > policy.total_mb then
        return nil, "invalid_browse_cache_trigger_range"
    end
    if not is_integer_in_range(policy.retain_mb, 0, 32768) then
        return nil, "invalid_browse_cache_retain"
    end
    if policy.retain_mb >= policy.trigger_mb then
        return nil, "invalid_browse_cache_retain_range"
    end
    if not is_integer_in_range(policy.interval_minutes, 1, 1440) then
        return nil, "invalid_browse_cache_interval"
    end
    self.store:saveSetting("browse_cache", copy_table(policy))
    return true
end

function Settings:get_offline_root()
    local root = normalize_offline_root(
        self.store:readSetting("offline_root", DEFAULT_OFFLINE_ROOT))
    if not valid_offline_root(root) then return DEFAULT_OFFLINE_ROOT end
    return root
end

function Settings:set_offline_root(value)
    local root = normalize_offline_root(value)
    if not valid_offline_root(root) then return nil, "invalid_offline_root" end
    self.store:saveSetting("offline_root", root)
    return true
end

function Settings:get_offline_limit_gb()
    local value = tonumber(self.store:readSetting(
        "offline_limit_gb", DEFAULT_OFFLINE_LIMIT_GB))
    if not is_integer_in_range(value, 1, 20) then return DEFAULT_OFFLINE_LIMIT_GB end
    return value
end

function Settings:set_offline_limit_gb(value)
    value = tonumber(value)
    if not is_integer_in_range(value, 1, 20) then
        return nil, "invalid_offline_limit"
    end
    self.store:saveSetting("offline_limit_gb", value)
    return true
end

function Settings:get_offline_refresh_seconds()
    local value = tonumber(self.store:readSetting(
        "offline_refresh_seconds", DEFAULT_OFFLINE_REFRESH_SECONDS))
    return is_integer_in_range(value, 1, 60) and value or DEFAULT_OFFLINE_REFRESH_SECONDS
end

function Settings:set_offline_refresh_seconds(value)
    value = tonumber(value)
    if not is_integer_in_range(value, 1, 60) then
        return nil, "invalid_offline_refresh"
    end
    self.store:saveSetting("offline_refresh_seconds", value)
    return true
end

function Settings:get_rating_max()
    local value = tonumber(self.store:readSetting("rating_max", DEFAULT_RATING_MAX))
    if not is_integer_in_range(value, 5, 10) then return DEFAULT_RATING_MAX end
    return value
end

function Settings:set_rating_max(value)
    if not is_integer_in_range(value, 5, 10) then
        return nil, "invalid_rating_max"
    end
    self.store:saveSetting("rating_max", value)
    if self.store.flush then self.store:flush() end
    return true
end

function Settings:get_gray_presets()
    local reader = self:get_reader()
    return GrayEnhance.all_presets(reader.gray_enhance_custom_presets)
end

function Settings:set_gray_preset(preset_id)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not GrayEnhance.is_valid_id(preset_id, reader.gray_enhance_custom_presets) then
        return nil, "invalid_gray_preset"
    end
    reader.gray_enhance_preset = preset_id
    return self:set_reader(reader)
end

function Settings:set_gray_sample_path(path)
    local reader = self:get_reader()
    local normalized = GrayEnhance.normalize_sample_path(path)
    if normalized == nil then return nil, "invalid_gray_sample_path" end
    reader.gray_enhance_sample_path = normalized
    return self:set_reader(reader)
end

function Settings:add_gray_preset(values)
    local reader = self:get_reader()
    local id = GrayEnhance.next_custom_id(reader.gray_enhance_custom_presets)
    local preset, error_code = GrayEnhance.normalize_custom(values, id)
    if not preset then return nil, error_code end
    reader.gray_enhance_custom_presets[#reader.gray_enhance_custom_presets + 1] = preset
    reader.gray_enhance_preset = id
    local ok, err = self:set_reader(reader)
    if not ok then return nil, err end
    return true, id
end

function Settings:update_gray_preset(preset_id, values)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not preset_id:match("^custom%-") then
        return nil, "cannot_edit_builtin_gray_preset"
    end
    local updated, error_code = GrayEnhance.normalize_custom(values, preset_id)
    if not updated then return nil, error_code end
    local found = false
    for index, preset in ipairs(reader.gray_enhance_custom_presets) do
        if preset.id == preset_id then
            reader.gray_enhance_custom_presets[index] = updated
            found = true
            break
        end
    end
    if not found then return nil, "missing_gray_preset" end
    local ok, err = self:set_reader(reader)
    return ok, err
end

function Settings:remove_gray_preset(preset_id)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not preset_id:match("^custom%-") then
        return nil, "cannot_delete_builtin_gray_preset"
    end
    local kept, removed = {}, false
    for _, preset in ipairs(reader.gray_enhance_custom_presets) do
        if preset.id == preset_id then removed = true else kept[#kept + 1] = preset end
    end
    if not removed then return nil, "missing_gray_preset" end
    reader.gray_enhance_custom_presets = kept
    if reader.gray_enhance_preset == preset_id then
        reader.gray_enhance_preset = "original"
    end
    return self:set_reader(reader)
end

function Settings:get_tone_presets()
    local reader = self:get_reader()
    return ToneAdjust.all_presets(reader.tone_adjust_custom_presets)
end

function Settings:set_tone_preset(preset_id)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not ToneAdjust.is_valid_id(preset_id, reader.tone_adjust_custom_presets) then
        return nil, "invalid_tone_preset"
    end
    reader.tone_adjust_preset = preset_id
    return self:set_reader(reader)
end

function Settings:set_tone_sample_path(path)
    local reader = self:get_reader()
    local normalized = GrayEnhance.normalize_sample_path(path)
    if normalized == nil then return nil, "invalid_tone_sample_path" end
    reader.tone_adjust_sample_path = normalized
    return self:set_reader(reader)
end

function Settings:add_tone_preset(values)
    local reader = self:get_reader()
    local id = ToneAdjust.next_custom_id(reader.tone_adjust_custom_presets)
    local preset, error_code = ToneAdjust.normalize_custom(values, id)
    if not preset then return nil, error_code end
    reader.tone_adjust_custom_presets[#reader.tone_adjust_custom_presets + 1] = preset
    reader.tone_adjust_preset = id
    local ok, err = self:set_reader(reader)
    if not ok then return nil, err end
    return true, id
end

function Settings:update_tone_preset(preset_id, values)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not preset_id:match("^custom%-%d+$") then
        return nil, "cannot_edit_builtin_tone_preset"
    end
    local updated, error_code = ToneAdjust.normalize_custom(values, preset_id)
    if not updated then return nil, error_code end
    for index, preset in ipairs(reader.tone_adjust_custom_presets) do
        if preset.id == preset_id then
            reader.tone_adjust_custom_presets[index] = updated
            return self:set_reader(reader)
        end
    end
    return nil, "missing_tone_preset"
end

function Settings:remove_tone_preset(preset_id)
    local reader = self:get_reader()
    preset_id = trim(preset_id)
    if not preset_id:match("^custom%-%d+$") then
        return nil, "cannot_delete_builtin_tone_preset"
    end
    local kept, removed = {}, false
    for _, preset in ipairs(reader.tone_adjust_custom_presets) do
        if preset.id == preset_id then removed = true else kept[#kept + 1] = preset end
    end
    if not removed then return nil, "missing_tone_preset" end
    reader.tone_adjust_custom_presets = kept
    if reader.tone_adjust_preset == preset_id then reader.tone_adjust_preset = "original" end
    return self:set_reader(reader)
end

function Settings:is_configured()
    local connection = self:get_connection()
    if connection.kind == "local" then return connection.local_path ~= "" end
    if connection.kind == "opds" then
        return valid_opds_url(connection.server_url)
    end
    return connection.server_url ~= ""
        and connection.username ~= ""
        and connection.root_path ~= ""
end

local PANEL_CHOICES={
    panel_view={"cut","context","free"},panel_rotation={0,90,180,270},
    panel_navigation={"horizontal","vertical"},panel_reverse_navigation={false,true},
    panel_order={"follow","normal","manga"},panel_zoom_enabled={false,true},
    panel_show_adjacent={false,true},panel_standard_margin_percent={0,2,5,10},
    panel_hold_margin_percent={2,5,10,15,20},panel_initial_zoom={1,1.2,1.5,2},
    panel_experimental_sort={false,true},
}
for _,f in ipairs(PanelOptions.fields) do PANEL_CHOICES[f.key]=f.choices end
for _,f in ipairs(Dynamic.fields) do PANEL_CHOICES[f.key]=f.choices end
for _,f in ipairs(Quadrant.fields) do PANEL_CHOICES[f.key]={false,true} end
local function book_key(key)
    return type(key)=="string" and #key==32 and key:match("^%x+$") and key:lower()
end
local function panel_values(values,strict)
    local result={}
    if type(values)~="table" then return strict and nil or result end
    for k,v in pairs(values) do
        if PANEL_CHOICES[k] and one_of(v,PANEL_CHOICES[k]) then result[k]=v
        elseif strict then return nil end
    end
    return Dynamic.override(result)
end
function Settings:panel_values(values) return panel_values(values,false) end
function Settings:get_panel_reader(key)
    local reader=self:get_reader()
    for k,v in pairs(self:get_panel_overrides(key)) do reader[k]=v end
    return Dynamic.normalize(reader)
end
function Settings:get_panel_overrides(key)
    key=book_key(key)
    local profiles=self.store:readSetting("panel_books",{})
    local profile=key and type(profiles)=="table" and profiles[key]
    return panel_values(type(profile)=="table" and profile.values,false)
end
function Settings:set_panel_reader(key,values,make_default)
    key=book_key(key)
    values=panel_values(values,true)
    if not key or not values then return nil,"invalid_panel_profile" end
    local old_profiles=self.store:readSetting("panel_books",{})
    local old_reader=self.store:readSetting("reader",{})
    local profiles,sequence={},0
    for id,profile in pairs(type(old_profiles)=="table" and old_profiles or {}) do
        if book_key(id) and type(profile)=="table" then
            local serial=tonumber(profile.serial) or 0
            if serial~=serial or math.abs(serial)==math.huge then serial=0 end
            profiles[id]={values=panel_values(profile.values,false),serial=serial}
            sequence=math.max(sequence,serial)
        end
    end
    local current=profiles[key] and copy_table(profiles[key].values) or {}
    for k,v in pairs(values) do current[k]=v end
    profiles[key]={values=current,serial=sequence+1}
    local ids={};for id in pairs(profiles) do ids[#ids+1]=id end
    table.sort(ids,function(a,b)
        if profiles[a].serial~=profiles[b].serial then return profiles[a].serial<profiles[b].serial end
        return a<b
    end)
    for i=1,#ids-64 do profiles[ids[i]]=nil end
    local ok,reason=pcall(function()
        if make_default then assert(self:set_reader(values)) end
        assert(self.store:saveSetting("panel_books",profiles)~=false)
        assert(self:flush()~=false)
    end)
    if not ok then
        pcall(self.store.saveSetting,self.store,"panel_books",old_profiles)
        pcall(self.store.saveSetting,self.store,"reader",old_reader)
        return nil,"panel_profile_write_failed"
    end
    return true
end

function Settings:panel_snapshot()
    return {books=self.store:readSetting("panel_books",{}),reader=self.store:readSetting("reader",{})}
end
function Settings:restore_panel(snapshot)
    local ok=pcall(function()
        assert(self.store:saveSetting("panel_books",snapshot.books)~=false)
        assert(self.store:saveSetting("reader",snapshot.reader)~=false)
        assert(self:flush()~=false)
    end)
    return ok
end

function Settings:flush()
    if self.store.flush then
        return self.store:flush()
    end
end

return Settings
