local Identity = require("webdavmanga.manga_identity")

local PremiumAccess = {}
PremiumAccess.__index = PremiumAccess

local FREE_LIMIT = 5

local function text(value)
    if value == nil then return "" end
    return tostring(value)
end

local function add_source(sources, source)
    if not source or source == "" then return end
    for _, value in ipairs(sources) do
        if value == source then return end
    end
    sources[#sources + 1] = source
end

local function count_nul(value)
    local _, count = tostring(value or ""):gsub("%z", "")
    return count
end

local function copy_entry(entry)
    local result = {
        id = entry.id,
        name = entry.name,
        path = entry.path,
        sources = {},
    }
    for _, source in ipairs(entry.sources or {}) do
        result.sources[#result.sources + 1] = source
    end
    return result
end

function PremiumAccess:new(options)
    options = options or {}
    local object = setmetatable({
        identity = options.identity or Identity,
        license = options.license,
        progress = options.progress,
        library = options.library,
        offline_cache = options.offline_cache,
        document_cache = options.document_cache,
        connection_provider = options.connection_provider,
        free_limit = tonumber(options.free_limit) or FREE_LIMIT,
        records = {},
        enumeration_failed = false,
        last_error = nil,
    }, self)
    object:refresh()
    return object
end

function PremiumAccess:_list(label, object, method)
    if not object or type(object[method]) ~= "function" then
        self.enumeration_failed = true
        self.last_error = label .. "_unavailable"
        return {}
    end
    local ok, value = pcall(object[method], object)
    if not ok or type(value) ~= "table" then
        self.enumeration_failed = true
        self.last_error = label .. "_failed"
        return {}
    end
    return value
end

function PremiumAccess:_record_identity(record, path)
    if type(record) ~= "table" then return nil end
    local explicit = record.identity or record.id
    if type(explicit) == "string" and explicit ~= "" then
        local separators = count_nul(explicit)
        -- A full manga identity already contains the path. Connection identities
        -- (current or legacy) still need the record path appended.
        if separators >= 5 or not path then return explicit end
        if separators == 4 or separators == 2 then
            local ok, value = pcall(self.identity.manga, explicit, path)
            if ok and type(value) == "string" and value ~= "" then return value end
        end
        -- Opaque legacy cache namespaces must never merge with a live source.
        if separators ~= 0 then return explicit end
        return explicit .. "\0" .. text(path)
    end
    local connection = record.connection
    if not connection and self.connection_provider then
        local ok, value = pcall(self.connection_provider)
        if ok then connection = value end
    end
    if not connection or not path then return nil end
    local ok, value = pcall(self.identity.manga, connection, path)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    return value
end

function PremiumAccess:_record_values(record, source)
    if type(record) ~= "table" then return nil end
    local manga = type(record.manga) == "table" and record.manga or nil
    local path = (manga and manga.path) or record.manga_path
        or record.remote_path or record.path
    if type(path) ~= "string" or path == "" then return nil end
    local name = (manga and manga.name) or record.manga_name or record.name
        or path:match("([^/]+)$") or path
    local id = self:_record_identity(record, path)
    if not id then return nil end
    return id, text(name), path, source
end

function PremiumAccess:_add_record(map, record, source)
    local id, name, path, source_name = self:_record_values(record, source)
    if not id then return end
    local entry = map[id]
    if not entry then
        entry = { id = id, name = name, path = path, sources = {} }
        map[id] = entry
    else
        if entry.name == "" then entry.name = name end
        if entry.path == "" then entry.path = path end
    end
    add_source(entry.sources, source_name)
end

function PremiumAccess:refresh()
    local map = {}
    self.enumeration_failed = false
    self.last_error = nil
    local groups = {
        { "history", self.progress, "list_all_history" },
        { "library", self.library, "list_all_mangas" },
        { "offline_cache", self.offline_cache, "list_all_mangas" },
        { "document_cache", self.document_cache, "list_all_documents" },
    }
    for _, group in ipairs(groups) do
        local source, object, method = group[1], group[2], group[3]
        local records = self:_list(source, object, method)
        for _, record in ipairs(records) do
            self:_add_record(map, record, source)
        end
    end
    local records = {}
    for _, entry in pairs(map) do records[#records + 1] = entry end
    table.sort(records, function(left, right)
        local left_name, right_name = text(left.name):lower(), text(right.name):lower()
        if left_name ~= right_name then return left_name < right_name end
        return text(left.id) < text(right.id)
    end)
    self.records = records
    return #records
end

function PremiumAccess:collect_tracked_mangas()
    self:refresh()
    local result = {}
    for _, entry in ipairs(self.records) do result[#result + 1] = copy_entry(entry) end
    return result
end

function PremiumAccess:count_tracked_mangas()
    self:refresh()
    return #self.records
end

function PremiumAccess:is_authorized()
    if not self.license or type(self.license.is_authorized) ~= "function" then return false end
    local ok, authorized = pcall(self.license.is_authorized, self.license)
    return ok and authorized == true
end

function PremiumAccess:_manga_id(manga)
    if type(manga) ~= "table" then return nil end
    local path = manga.path or manga.manga_path or manga.remote_path
    local explicit = manga.id or manga.identity
    if type(explicit) == "string" and explicit ~= "" then
        local separators = count_nul(explicit)
        if separators >= 5 or not path then return explicit end
        if separators == 4 or separators == 2 then
            local ok, value = pcall(self.identity.manga, explicit, path)
            if ok and type(value) == "string" then return value end
        end
        return explicit
    end
    if type(path) ~= "string" or path == "" or not self.connection_provider then return nil end
    local ok, connection = pcall(self.connection_provider)
    if not ok or not connection then return nil end
    ok, explicit = pcall(self.identity.manga, connection, path)
    if not ok then return nil end
    return explicit
end

function PremiumAccess:_decision(manga)
    if self:is_authorized() then return true end
    self:refresh()
    if self.enumeration_failed then return false, "license_required" end
    local count = #self.records
    if count > self.free_limit then return false, "license_required" end
    local id = self:_manga_id(manga)
    if not id then return false, "license_required" end
    if count < self.free_limit then return true end
    for _, entry in ipairs(self.records) do
        if entry.id == id then return true end
    end
    return false, "license_required"
end

function PremiumAccess:can_open(manga)
    return self:_decision(manga)
end

function PremiumAccess:can_add(manga)
    return self:_decision(manga)
end

function PremiumAccess:can_cache(manga)
    return self:_decision(manga)
end

return PremiumAccess
