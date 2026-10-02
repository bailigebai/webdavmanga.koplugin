local Formats = require("webdavmanga.image_formats")
local Identity = require("webdavmanga.manga_identity")

local Cover = {}
Cover.__index = Cover

function Cover.candidates(desc, hint)
    local Pages = require("webdavmanga.opds_pages")
    local result = {}
    local image = hint and hint.image
    if not image then return result end
    local function add(resolver)
        result[#result + 1] = { name = image.name, path = image.path, image_url = resolver,
            opds_source_id = desc.source_id, opds_page = true,
            pointer_path = hint.chapter and hint.chapter.pointer_path }
    end
    for _, key in ipairs({ "cover_url", "series_cover_url" }) do
        local url = desc[key]
        if type(url) == "string" then add(function(_, _, source) return Pages.restore_url(url, source) end) end
    end
    local index = Pages.virtual_index(desc, image.path)
    if index then add(index:get(1).image_url) end
    return result
end

function Cover:new(options)
    options = options or {}
    return setmetatable({
        cache = assert(options.cache, "cache is required"),
        open_file = options.open_file or io.open,
        fs = options.fs or { open = options.open_file or io.open, rename = os.rename, remove = os.remove },
        image_probe = options.image_probe or require("webdavmanga.image_probe"),
        renderer = options.renderer,
        validated_sidecars = {},
    }, self)
end

function Cover.sidecar_path(pointer_path)
    if type(pointer_path) ~= "string" or pointer_path:find("[%z\1-\31]") then return nil end
    local normalized = pointer_path:gsub("\\", "/")
    if normalized:sub(1, 1) ~= "/" and not normalized:match("^%a:/") then return nil end
    for segment in normalized:gmatch("[^/]+") do if segment == "." or segment == ".." then return nil end end
    local directory = normalized:match("^(.+)/[^/]+%.[mM][eE][gG][uU][rR][uU]$")
    return directory and directory .. "/.cover.jpg" or nil
end

function Cover:_lookup_sidecar(path)
    if not path then return nil end
    if self.validated_sidecars[path] then return path end
    local file = self.fs.open(path, "rb")
    if not file then return nil end
    local ok, bytes = pcall(file.read, file, 16 * 1024 * 1024 + 1)
    local closed, close_result = pcall(file.close, file)
    if not ok or not closed or not close_result or type(bytes) ~= "string"
        or #bytes > 16 * 1024 * 1024 then return nil end
    local metadata = self.image_probe.inspect_bytes(bytes, "jpg", #bytes, { allow_extension_mismatch = true })
    if not metadata then return nil end
    local renderer = self.renderer
    if not renderer then local loaded, value = pcall(require, "ui/renderimage"); renderer = loaded and value end
    if not renderer then return nil end
    local decoded, buffer = pcall(renderer.renderImageData, renderer, bytes, #bytes, false, 120, 160)
    if not decoded or not buffer then return nil end
    if buffer.free then pcall(buffer.free, buffer) end
    self.validated_sidecars[path] = true
    return path
end

function Cover:_key(connection, image)
    if type(image) ~= "table" or type(image.path) ~= "string"
        or image.path == "" then return nil end
    return self.cache:key_for(Identity.connection(connection), image.path, "cover")
end

function Cover:lookup(connection, hint)
    local pointer = hint and hint.chapter and hint.chapter.pointer_path
        or hint and hint.image and hint.image.pointer_path
    if pointer then return self:_lookup_sidecar(Cover.sidecar_path(pointer)) end
    if hint and hint.image and tostring(hint.image.path):sub(1, 5) == "opds:" then return nil end
    local key = self:_key(connection, type(hint) == "table" and hint.image or nil)
    if not key then return nil end
    return self.cache:lookup_record(key)
end

function Cover:store(connection, image, bytes, metadata)
    if image and image.pointer_path then
        local path = Cover.sidecar_path(image.pointer_path)
        if not path or type(bytes) ~= "string" or #bytes == 0 or #bytes > 16 * 1024 * 1024
            or not metadata or metadata.decoded ~= true then return nil, "invalid_cover" end
        local existing = self:_lookup_sidecar(path)
        if existing then return existing end
        local temporary = path .. ".tmp"
        local file = self.fs.open(temporary, "wb")
        if not file then return nil, "cover_open_failed" end
        local wrote, result = pcall(file.write, file, bytes)
        local closed, close_result = pcall(file.close, file)
        if not wrote or not result or not closed or not close_result then
            self.fs.remove(temporary); return nil, "cover_write_failed"
        end
        if not self.fs.rename(temporary, path) then self.fs.remove(temporary); return nil, "cover_publish_failed" end
        -- Verify the published file, not merely the bytes handed to write().
        self.validated_sidecars[path] = nil
        if not self:_lookup_sidecar(path) then
            self.fs.remove(path)
            return nil, "cover_verify_failed"
        end
        return path
    end
    if image and tostring(image.path):sub(1, 5) == "opds:" then return nil, "missing_pointer" end
    local key = self:_key(connection, image)
    if not key or type(bytes) ~= "string" or bytes == ""
        or type(metadata) ~= "table" then return nil, "invalid_cover" end
    local existing = self.cache:lookup_record(key)
    if existing then return existing end
    local extension = Formats.extension(image.name or image.path)
        or Formats.extension_for_format(metadata.format)
    if not extension then return nil, "invalid_cover_extension" end
    local _, part_path = self.cache:paths_for(key, extension)
    local file, open_error = self.open_file(part_path, "wb")
    if not file then return nil, open_error or "cover_open_failed" end
    local wrote, write_result = pcall(file.write, file, bytes)
    local closed, close_result = pcall(file.close, file)
    if not wrote or write_result == nil or not closed or close_result == false then
        self.cache:discard_part(key, extension)
        return nil, "cover_write_failed"
    end
    local path, publish_error = self.cache:publish({
        key = key,
        kind = "cover",
        identity = Identity.connection(connection),
        remote_path = image.path,
        extension = extension,
        validated = true,
        extension_mismatch = metadata.extension_mismatch == true,
        format = metadata.format,
        width = metadata.width,
        height = metadata.height,
    }, part_path)
    if not path then self.cache:discard_part(key, extension) end
    return path, publish_error
end

return Cover
