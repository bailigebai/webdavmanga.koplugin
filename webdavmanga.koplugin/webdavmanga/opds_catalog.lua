local Catalog = {}
local Url = require("webdavmanga.opds_url")
Catalog.__index = Catalog

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function opds_url(value)
    return trim(value):gsub("/+$", "")
end

local function as_catalog(source)
    if not source or source.kind ~= "opds" then return nil end
    local entry = {}
    for key, value in pairs(source) do entry[key] = value end
    entry.url = source.server_url
    return entry
end

function Catalog:new(options)
    options = options or {}
    return setmetatable({
        settings = assert(options.settings, "settings is required"),
        legacy_store = options.legacy_store,
        client_factory = assert(options.client_factory, "client factory is required"),
    }, self)
end

function Catalog:list()
    local result = {}
    for _, source in ipairs(self.settings:get_sources()) do
        if source.kind == "opds" then result[#result + 1] = as_catalog(source) end
    end
    return result
end

function Catalog:get(id)
    return as_catalog(self.settings:get_source(id))
end

function Catalog:save(values)
    values = values or {}
    local url = opds_url(values.server_url or values.url)
    if trim(values.name) == "" or not url:match("^https?://[^/]+") then
        return nil, "invalid_catalog"
    end
    local current = values.id and self:get(values.id) or nil
    if values.id and not current then return nil, "missing_source" end
    local input = {
        kind = "opds", name = values.name, server_url = url,
        username = values.username, password = values.password,
        server_kind = values.server_kind or (current and current.server_kind) or "auto",
    }
    local ok, id
    if current then
        ok, id = self.settings:set_source(current.id, input)
        id = current.id
    else
        ok, id = self.settings:add_source(input)
    end
    if not ok then return nil, id end
    self.settings:flush()
    return self:get(id)
end

function Catalog:remove(id)
    if not self:get(id) then return false end
    local ok = self.settings:remove_source(id)
    if ok then self.settings:flush() end
    return ok == true
end

function Catalog:set_active(id)
    if not self:get(id) then return false end
    local ok = self.settings:select_source(id)
    if ok then self.settings:flush() end
    return ok == true
end

function Catalog:active()
    return self:get(self.settings:get_active_source_id())
end

function Catalog:fetch(id, url)
    local entry = self:get(id)
    if not entry then return nil, "missing_source" end
    local target, err = Url.request_target(entry.url, url or entry.url)
    if not target then return nil, err end
    local client = self.client_factory(entry)
    return client:fetch(target, {
        username = entry.username, password = entry.password,
    }, entry.url)
end

function Catalog:fetch_active()
    local entry = self:active()
    if not entry then return nil, "no_active_catalog" end
    return self:fetch(entry.id, entry.url)
end

function Catalog:migrate_legacy_once()
    local store = self.legacy_store
    if not store or store:readSetting("migrated_to_sources_v1") == true then
        return true
    end
    local rows = store:readSetting("catalogs", {})
    if type(rows) ~= "table" then rows = {} end
    local by_identity = {}
    for _, entry in ipairs(self:list()) do
        by_identity[opds_url(entry.url) .. "\0" .. trim(entry.username)] = entry.id
    end
    local active_legacy = store:readSetting("active_catalog_id")
    local active_source_id
    local previous_source_id = self.settings:get_active_source_id()
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            local url = opds_url(row.url or row.server_url)
            local username = trim(row.username)
            if url:match("^https?://[^/]+") then
                local identity = url .. "\0" .. username
                local id = by_identity[identity]
                if not id then
                    local ok, added_id = self.settings:add_source{
                        kind = "opds", name = row.name, server_url = url,
                        username = username, password = row.password,
                        server_kind = row.server_kind,
                    }
                    if not ok then return nil, added_id end
                    id = added_id
                    by_identity[identity] = id
                end
                if row.id == active_legacy then active_source_id = id end
            end
        end
    end
    local selected_id = active_source_id or previous_source_id
    if selected_id then self.settings:select_source(selected_id) end
    local source_ok, source_result = pcall(self.settings.flush, self.settings)
    if not source_ok or source_result == false then
        return nil, source_ok and "source_flush_failed" or source_result
    end
    local marker_ok, marker_result = pcall(function()
        store:saveSetting("migrated_to_sources_v1", true)
        if store.flush then return store:flush() end
        return true
    end)
    if not marker_ok or marker_result == false then
        pcall(store.saveSetting, store, "migrated_to_sources_v1", false)
        return nil, marker_ok and "marker_flush_failed" or marker_result
    end
    return true
end

return Catalog
