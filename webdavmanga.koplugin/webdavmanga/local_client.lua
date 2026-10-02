local Errors = require("webdavmanga.errors")
local Formats = require("webdavmanga.image_formats")
local Manifest = require("webdavmanga.manifest")
local Path = require("webdavmanga.path")

local LocalClient = {}
LocalClient.__index = LocalClient

local COPY_BYTES = 64 * 1024

local function local_decode(detail)
    return Errors.image_decode(detail, "local")
end

local function default_lfs()
    return require("libs/libkoreader-lfs")
end

local function normalized_absolute(value)
    local raw = tostring(value or ""):gsub("\\", "/")
    if raw == "" or raw:find("\0", 1, true) or raw:sub(1, 1) ~= "/" then
        return nil
    end
    for segment in raw:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
    end
    local normalized = Path.normalize_remote(raw)
    return normalized == "" and "/" or normalized
end

function LocalClient:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.connection = assert(options.connection, "connection is required")
    -- Local pages can be handed to KOReader's decoder directly.  Keep the
    -- normal download method below for the explicit offline-copy feature.
    object.direct = true
    object.lfs = options.lfs or default_lfs()
    object.image_probe = options.image_probe or require("webdavmanga.image_probe")
    object.open_file = options.open_file or io.open
    object.file_size = options.file_size or function(path)
        return object.lfs.attributes(path, "size")
    end
    object.remove_file = options.remove_file or os.remove
    object.md5 = options.md5
    object.manifest = options.manifest or Manifest
    object.manifest_fs = options.manifest_fs
    object.manifest_run_size = options.manifest_run_size
    object.root_path = normalized_absolute(object.connection.local_path
        or object.connection.root_path)
    return object
end

function LocalClient:_root()
    if not self.root_path then return nil, Errors.local_path("invalid root") end
    return self.root_path
end

function LocalClient:_local_path(remote_path)
    local root, root_error = self:_root()
    if not root then return nil, root_error end
    local path = normalized_absolute(remote_path)
    if not path or not Path.is_within_remote(path, root) then
        return nil, Errors.local_path("path outside root")
    end
    return path
end

function LocalClient:_symlink_attributes(path)
    local symlinkattributes = self.lfs.symlinkattributes
    if type(symlinkattributes) ~= "function" then
        return nil, "symlink inspection unavailable"
    end
    local ok, attributes = pcall(symlinkattributes, path)
    if not ok then return nil, attributes end
    return attributes
end

function LocalClient:_attributes(path, expected_mode)
    local link_attributes, link_error = self:_symlink_attributes(path)
    if link_attributes and link_attributes.mode == "link" then
        return nil, Errors.local_path("symbolic link is not allowed")
    end
    if not link_attributes and link_error and type(self.lfs.attributes) ~= "function" then
        return nil, Errors.storage(link_error)
    end
    local ok, attributes = pcall(self.lfs.attributes, path)
    if not ok or not attributes then
        return nil, Errors.local_path(attributes or "path unavailable")
    end
    if expected_mode and attributes.mode ~= expected_mode then
        return nil, Errors.local_path("unexpected local path type")
    end
    return attributes
end

function LocalClient:_produce_entries(remote_path, emit)
    local path, path_error = self:_local_path(remote_path)
    if not path then return nil, path_error end
    local directory_attributes, attributes_error = self:_attributes(path, "directory")
    if not directory_attributes then return nil, attributes_error end
    local ok, iterator, directory = pcall(self.lfs.dir, path)
    if not ok or type(iterator) ~= "function" then
        return nil, Errors.local_path(directory or iterator or "cannot list local directory")
    end
    while true do
        local next_ok, name = pcall(iterator, directory)
        if not next_ok then return nil, Errors.local_path(name) end
        if not name then break end
        if name ~= "." and name ~= ".."
            and type(name) == "string" and name ~= ""
            and not name:find("[/\\%z]", 1) then
            local child_path = Path.join_remote(path, name)
            local attributes, child_error = self:_attributes(child_path)
            local entry
            if attributes then
                if attributes.mode == "directory" then
                    entry = {
                        name = name, full_path = child_path, is_folder = true,
                        size = 0, modified = attributes.modification,
                    }
                elseif attributes.mode == "file" then
                    entry = {
                        name = name, full_path = child_path, is_file = true,
                        size = attributes.size, modified = attributes.modification,
                    }
                end
            elseif child_error and child_error.code == "local_path" then
                -- Ignore an unsafe child while keeping the rest of the shelf
                -- usable; direct access to that path still returns an error.
            end
            if entry then
                local emitted, emit_error = emit(entry)
                if not emitted then return nil, emit_error end
            end
        end
    end
    return true
end

function LocalClient:write_directory_manifest(remote_path, part_path)
    local descriptor, build_error = self.manifest.build({
        part_path = part_path,
        request_path = remote_path,
        md5 = self.md5,
        fs = self.manifest_fs,
        run_size = self.manifest_run_size,
    }, function(emit) return self:_produce_entries(remote_path, emit) end)
    if not descriptor then
        if type(build_error) == "table" then build_error.source_kind = "local" end
        return nil, build_error
    end
    local result = {
        part_path = descriptor.part_path,
        size = descriptor.size,
        count = descriptor.count,
        folders = descriptor.folders,
        images = descriptor.images,
        digest = descriptor.digest,
    }
    if descriptor.documents and descriptor.documents > 0 then
        result.documents = descriptor.documents
    end
    return result
end

function LocalClient:resolve(remote_path)
    local source_path, path_error = self:_local_path(remote_path)
    if not source_path then return nil, path_error end
    local source_attributes, attributes_error = self:_attributes(source_path, "file")
    if not source_attributes then return nil, attributes_error end
    if not Formats.is_supported(remote_path) then
        return nil, local_decode("unsupported image format")
    end

    local size = tonumber(source_attributes.size)
    if not size then
        size = tonumber(self.file_size(source_path))
    end
    if not size or size <= 0 then
        return nil, local_decode("local image is empty")
    end

    -- Only inspect the header here.  Full pixel decoding remains in
    -- KOReader's native renderer, while this check supplies safe dimensions
    -- to the reader without copying the image into the plugin cache.
    local image_info, probe_error = self.image_probe.inspect(
        source_path, Formats.extension(remote_path), {
            open_file = self.open_file,
            file_size = function() return size end,
            allow_extension_mismatch = true,
        })
    -- Header inspection is only an optimization for direct local pages.  A
    -- valid image may contain an unusually large metadata block or a format
    -- variant that KOReader can decode but this lightweight probe does not
    -- understand.  Keep the path usable and let the native renderer be the
    -- final authority; the reader will use the decoded buffer dimensions.
    if not image_info then
        image_info = {
            format = Formats.extension(remote_path) or "img",
            width = nil,
            height = nil,
            unverified = true,
            probe_error = probe_error,
        }
    end
    return source_path, {
        size = size,
        modified = source_attributes.modification,
        format = image_info.format,
        width = image_info.width,
        height = image_info.height,
        unverified = image_info.unverified == true or nil,
        probe_error = image_info.probe_error,
        direct = true,
    }
end

function LocalClient:resolve_document(remote_path)
    local source_path, path_error = self:_local_path(remote_path)
    if not source_path then return nil, path_error end
    local source_attributes, attributes_error = self:_attributes(source_path, "file")
    if not source_attributes then return nil, attributes_error end
    if not Formats.is_document(remote_path) then
        return nil, local_decode("unsupported document format")
    end
    local size = tonumber(source_attributes.size) or tonumber(self.file_size(source_path))
    if not size or size <= 0 then
        return nil, local_decode("local document is empty")
    end
    return source_path, {
        size = size,
        modified = source_attributes.modification,
        format = Formats.extension(remote_path),
        direct = true,
    }
end

function LocalClient:download_document(remote_path, part_path, _progress_callback)
    local source_path, path_error = self:_local_path(remote_path)
    if not source_path then return nil, path_error end
    local source_attributes, attributes_error = self:_attributes(source_path, "file")
    if not source_attributes then return nil, attributes_error end
    if not Formats.is_document(remote_path) then
        return nil, local_decode("unsupported document format")
    end
    local source, source_error = self.open_file(source_path, "rb")
    if not source then return nil, Errors.local_path(source_error) end
    local target, target_error = self.open_file(part_path, "wb")
    if not target then source:close(); return nil, Errors.storage(target_error) end
    local copied, copy_error = true, nil
    while true do
        local chunk = source:read(COPY_BYTES)
        if not chunk then break end
        local write_ok, write_result, write_detail = pcall(target.write, target, chunk)
        if not write_ok or write_result == nil then
            copied = false
            copy_error = write_ok and write_detail or write_result
            break
        end
    end
    local source_closed = source:close()
    local target_closed = target:close()
    if not copied or not source_closed or not target_closed then
        self.remove_file(part_path)
        return nil, Errors.storage(copy_error or "local document copy failed")
    end
    local size = tonumber(self.file_size(part_path)) or 0
    if size <= 0 or (source_attributes.size and size ~= source_attributes.size) then
        self.remove_file(part_path)
        return nil, local_decode("local file size changed during copy")
    end
    return {
        size = size,
        modified = source_attributes.modification,
        format = Formats.extension(remote_path),
    }
end

function LocalClient:download(remote_path, part_path, _progress_callback)
    local source_path, path_error = self:_local_path(remote_path)
    if not source_path then return nil, path_error end
    local source_attributes, attributes_error = self:_attributes(source_path, "file")
    if not source_attributes then return nil, attributes_error end
    if not Formats.is_supported(remote_path) then
        return nil, local_decode("unsupported image format")
    end

    local source, source_error = self.open_file(source_path, "rb")
    if not source then return nil, Errors.local_path(source_error) end
    local target, target_error = self.open_file(part_path, "wb")
    if not target then
        source:close()
        return nil, Errors.storage(target_error)
    end
    local copied, copy_error = true, nil
    while true do
        local chunk = source:read(COPY_BYTES)
        if not chunk then break end
        local write_ok, write_result, write_detail = pcall(target.write, target, chunk)
        if not write_ok or write_result == nil then
            copied = false
            copy_error = write_ok and write_detail or write_result
            break
        end
    end
    local source_closed = source:close()
    local target_closed = target:close()
    if not copied or not source_closed or not target_closed then
        self.remove_file(part_path)
        return nil, Errors.storage(copy_error or "local file copy failed")
    end
    local size = tonumber(self.file_size(part_path)) or 0
    if size <= 0 or (source_attributes.size and size ~= source_attributes.size) then
        self.remove_file(part_path)
        return nil, local_decode("local file size changed during copy")
    end
    local image_info, probe_error = self.image_probe.inspect(
        part_path, Formats.extension(remote_path), {
            allow_extension_mismatch = true,
        })
    if not image_info then
        self.remove_file(part_path)
        return nil, local_decode(probe_error)
    end
    return {
        size = size,
        modified = source_attributes.modification,
        format = image_info.format,
        width = image_info.width,
        height = image_info.height,
    }
end

function LocalClient:test_connection()
    local root, root_error = self:_root()
    if not root then return nil, root_error end
    local attributes, attributes_error = self:_attributes(root, "directory")
    if not attributes then return nil, attributes_error end
    return true
end

return LocalClient
