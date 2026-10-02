local Path = require("webdavmanga.path")

local ChapterIndex = {}
ChapterIndex.__index = ChapterIndex

local function has_dot_segment(path)
    path = tostring(path or ""):gsub("\\", "/")
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return true end
    end
    return false
end

local function positive_integer(value, fallback)
    value = tonumber(value)
    if not value or value < 1 or math.floor(value) ~= value then return fallback end
    return value
end

function ChapterIndex:new(options)
    options = options or {}
    assert(options.manifest, "manifest is required")
    assert(options.kind == "folder" or options.kind == "image"
        or options.kind == "document", "kind must be folder, image, or document")
    return setmetatable({
        manifest = options.manifest,
        kind = options.kind,
    }, self)
end

function ChapterIndex:count()
    if self.kind == "folder" then return self.manifest.folders end
    if self.kind == "image" then return self.manifest.images end
    return self.manifest.documents or 0
end

function ChapterIndex:_global_ordinal(index)
    if type(index) ~= "number" or index < 1 or index > self:count()
        or math.floor(index) ~= index then
        return nil
    end
    if self.kind == "folder" then return index end
    if self.kind == "image" then return self.manifest.folders + index end
    return self.manifest.folders + (self.manifest.images or 0) + index
end

function ChapterIndex:get(index)
    local ordinal = self:_global_ordinal(index)
    if not ordinal then return nil end
    local record = self.manifest:_record_at(ordinal)
    if not record then return nil end
    if (self.kind == "folder" and not record.is_folder)
        or (self.kind == "image" and (not record.is_file
            or record.file_kind == "document"))
        or (self.kind == "document" and (not record.is_file
            or record.file_kind ~= "document")) then
        return nil
    end
    return record
end

function ChapterIndex:find(path, hint_index)
    if type(path) ~= "string" or has_dot_segment(path) then return nil end
    local normalized = Path.normalize_remote(path)
    local hint = positive_integer(hint_index)
    if hint and hint <= self:count() then
        local hinted = self:get(hint)
        if hinted and hinted.path == normalized then return hint end
    end
    local ordinal = self.manifest:_find_ordinal(normalized)
    if not ordinal then return nil end
    if self.kind == "folder" then
        if ordinal <= self.manifest.folders then return ordinal end
    elseif self.kind == "image" then
        if ordinal > self.manifest.folders
            and ordinal <= self.manifest.folders + self.manifest.images then
            return ordinal - self.manifest.folders
        end
    elseif ordinal > self.manifest.folders + (self.manifest.images or 0) then
        return ordinal - self.manifest.folders - (self.manifest.images or 0)
    end
    return nil
end

function ChapterIndex:window(center, radius)
    local count = self:count()
    if count == 0 then return {} end
    center = positive_integer(center, 1)
    center = math.min(center, count)
    radius = tonumber(radius) or 0
    radius = math.max(0, math.floor(radius))
    local first = math.max(1, center - radius)
    local last = math.min(count, center + radius)
    local entries = {}
    for index = first, last do
        local record = self:get(index)
        if record then entries[#entries + 1] = record end
    end
    return entries
end

function ChapterIndex:iterator(start, limit)
    local count = self:count()
    start = positive_integer(start, 1)
    limit = tonumber(limit)
    if limit == nil then limit = math.max(0, count - start + 1) end
    limit = math.max(0, math.floor(limit))
    local index = start - 1
    local last = math.min(count, start + limit - 1)
    return function()
        index = index + 1
        if index > last then return nil end
        return self:get(index), index
    end
end

return ChapterIndex
