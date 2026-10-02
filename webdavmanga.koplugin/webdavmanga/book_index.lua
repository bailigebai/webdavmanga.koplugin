local NaturalSort = require("webdavmanga.natural_sort")
local Formats = require("webdavmanga.image_formats")

local BookIndex = {}
BookIndex.__index = BookIndex

function BookIndex:count()
    return #self.items
end

function BookIndex:get(position)
    position = tonumber(position)
    if not position or position < 1 or position > #self.items
        or math.floor(position) ~= position then return nil end
    return self.items[position]
end

function BookIndex:replace_items(items, generation)
    if type(items) ~= "table" or #items < 1 then return false end
    if generation ~= nil and ((self.generation ~= nil and self.generation ~= generation)
        or #items < #self.items) then return false end
    local copy = {}
    for position = 1, #items do
        if type(items[position]) ~= "table" then return false end
        copy[position] = items[position]
    end
    for key in pairs(items) do
        if type(key) ~= "number" or key < 1 or key > #items
            or key ~= math.floor(key) then return false end
    end
    if generation ~= nil then
        for position = 1, #self.items do
            if self.items[position].path ~= copy[position].path then return false end
        end
    end
    self.items = copy
    if generation ~= nil then self.generation = generation end
    return true
end

function BookIndex:find(path, hint)
    hint = tonumber(hint)
    if hint and self.items[hint] and self.items[hint].path == path then return hint end
    for position, item in ipairs(self.items) do
        if item.path == path then return position end
    end
end

function BookIndex:window(center, radius)
    center = math.max(1, math.min(#self.items, math.floor(tonumber(center) or 1)))
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    local result = {}
    for position = math.max(1, center - radius), math.min(#self.items, center + radius) do
        result[#result + 1] = self.items[position]
    end
    return result
end

function BookIndex.from_items(items)
    local copy = {}
    for index, item in ipairs(type(items) == "table" and items or {}) do
        copy[index] = item
    end
    NaturalSort.sort(copy, function(item) return item.name end)
    return setmetatable({ items = copy }, BookIndex)
end

local string_fields = {
    name = 4096, path = 32768, archive_kind = 16, archive_format = 16,
    archive_remote_path = 16384, archive_entry_name = 4096,
    archive_local_path = 16384, etag = 4096, format = 16,
    archive_version = 16384,
}
local number_fields = {
    archive_source_size = 4294967294, archive_local_offset = 4294967294,
    archive_entry_offset = 4294967294, archive_entry_ordinal = 20000,
    archive_spine_position = 20000,
    archive_method = 65535, archive_flags = 65535, archive_crc32 = 4294967295,
    archive_compressed_size = 128 * 1024 * 1024, archive_size = 128 * 1024 * 1024,
    size = 128 * 1024 * 1024, width = 1000000, height = 1000000,
}
local archive_required = { "name", "path", "archive_kind", "archive_remote_path",
    "archive_entry_name", "archive_source_size", "archive_size" }
local libarchive_formats = { cbr = true, rar = true, cb7 = true, ["7z"] = true }
local zip_formats = { zip = true, cbz = true, epub = true }

function BookIndex.matches_archive_format(page, kind)
    if type(page) ~= "table" then return false end
    if page.archive_kind == "libarchive" then
        return (zip_formats[kind] or libarchive_formats[kind]) == true
            and page.archive_format == kind
    end
    if page.archive_format ~= nil and page.archive_format ~= kind then return false end
    return (zip_formats[kind] == true and page.archive_kind == "zip")
        or ((kind == "cbt" or kind == "tar") and page.archive_kind == "tar")
end

local function numeric_suffix(value, prefix)
    if type(value) ~= "string" or value:sub(1, #prefix) ~= prefix then return nil end
    local suffix = value:sub(#prefix + 1)
    if not suffix:match("^[1-9]%d*$") then return nil end
    return tonumber(suffix)
end

local function archive_ordinal(page, marker)
    local prefix = page.archive_remote_path .. marker
    if page.archive_spine_position ~= nil then
        if page.archive_format ~= "epub" or page.archive_spine_position < 1 then return nil end
        local suffix = "/spine/" .. page.archive_spine_position
        if page.path:sub(-#suffix) ~= suffix then return nil end
        local ordinal = numeric_suffix(page.path:sub(1, -#suffix - 1), prefix)
        return ordinal == page.archive_entry_ordinal and ordinal or nil
    end
    return numeric_suffix(page.path, prefix)
end

-- A cache is untrusted input: copy only bounded scalar fields, never methods.
function BookIndex.from_table(value)
    if type(value) ~= "table" or value.version ~= 1 or type(value.items) ~= "table"
        or type(value.count) ~= "number" or value.count < 1 or value.count > 20000
        or value.count ~= math.floor(value.count) then return nil end
    for key in pairs(value) do
        if key ~= "version" and key ~= "count" and key ~= "items" then return nil end
    end
    for key in pairs(value.items) do
        if type(key) ~= "number" or key < 1 or key > value.count
            or key ~= math.floor(key) then return nil end
    end
    local items, bytes = {}, 0
    for position = 1, value.count do
        local item = value.items[position]
        if type(item) ~= "table" then return nil end
        local copy = {}
        for key, field in pairs(item) do
            if string_fields[key] then
                if type(field) ~= "string" or (#field == 0 and key ~= "etag") or #field > string_fields[key]
                    or field:find("%z") then return nil end
                bytes = bytes + #field
            elseif number_fields[key] then
                if type(field) ~= "number" or field < 0 or field > number_fields[key]
                    or field ~= math.floor(field) then return nil end
            elseif key ~= "is_file" or field ~= true then return nil end
            copy[key] = field
            bytes = bytes + #key + 32
        end
        if bytes > 8 * 1024 * 1024 then return nil end
        if copy.archive_spine_position ~= nil and copy.archive_format ~= "epub" then return nil end
        for _, key in ipairs(archive_required) do
            if copy[key] == nil then return nil end
        end
        if not copy.is_file or not Formats.is_image(copy.name)
            or copy.name ~= copy.archive_entry_name
            or copy.archive_source_size < 1 or copy.archive_size < 1 then
            return nil
        end
        if not BookIndex.matches_archive_format(copy, Formats.extension(copy.archive_remote_path)) then
            return nil
        end
        if copy.archive_kind == "zip" then
            if copy.archive_source_size < 22
                or copy.archive_local_offset == nil
                or copy.archive_method == nil
                or copy.archive_flags == nil
                or copy.archive_crc32 == nil
                or copy.archive_compressed_size == nil
                or (copy.archive_method ~= 0 and copy.archive_method ~= 8)
                or copy.archive_flags % 2 == 1
                or copy.archive_local_offset + 30 + #copy.archive_entry_name
                    + copy.archive_compressed_size > copy.archive_source_size
                or (copy.archive_method == 0
                    and copy.archive_compressed_size ~= copy.archive_size)
                or not archive_ordinal(copy, "#zip/") then return nil end
        elseif copy.archive_kind == "tar" then
            if copy.archive_entry_offset == nil or copy.archive_method ~= 0
                or copy.archive_entry_offset + copy.archive_size
                    > copy.archive_source_size
                or not numeric_suffix(copy.path,
                    copy.archive_remote_path .. "#tar/") then return nil end
        elseif copy.archive_kind == "libarchive" then
            local ordinal = archive_ordinal(copy, "#archive/")
            if (not libarchive_formats[copy.archive_format] and not zip_formats[copy.archive_format])
                or copy.archive_entry_ordinal == nil
                or copy.archive_entry_ordinal < 1
                or ordinal ~= copy.archive_entry_ordinal then return nil end
            if zip_formats[copy.archive_format] then
                if copy.archive_local_offset == nil or copy.archive_method == nil
                    or copy.archive_flags == nil or copy.archive_crc32 == nil
                    or copy.archive_compressed_size == nil
                    or copy.archive_method == 0 or copy.archive_method == 8
                    or copy.archive_flags % 2 == 1
                    or copy.archive_local_offset + 30 + #copy.archive_entry_name
                        + copy.archive_compressed_size > copy.archive_source_size then return nil end
            end
        else
            return nil
        end
        items[position] = copy
    end
    return setmetatable({ items = items }, BookIndex)
end

function BookIndex:to_table()
    local index = BookIndex.from_table({ version = 1, count = #self.items, items = self.items })
    if not index then return nil end
    return { version = 1, count = index:count(), items = index.items }
end

return BookIndex
