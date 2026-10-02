local ImageFormats = require("webdavmanga.image_formats")
local Path = require("webdavmanga.path")

local LocalArchive = {}
LocalArchive.__index = LocalArchive

local COPY_BYTES = 64 * 1024

local function default_md5(value)
    return require("ffi/sha2").md5(value)
end

local function normalize_absolute(value)
    local raw = tostring(value or ""):gsub("\\", "/")
    if raw == "" or raw:find("\0", 1, true) or raw:sub(1, 1) ~= "/" then
        return nil
    end
    for segment in raw:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
    end
    local normalized = Path.normalize_remote(raw)
    return normalized ~= "" and normalized or "/"
end

local function failure(code, detail)
    return nil, { code = code, detail = detail }
end

function LocalArchive:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.root = assert(normalize_absolute(options.root), "archive root must be absolute")
    object.library = assert(options.library, "library is required")
    object.lfs = options.lfs
    object.make_path = options.make_path
    object.open_file = options.open_file or io.open
    object.remove_file = options.remove_file or os.remove
    object.rename_file = options.rename_file or os.rename
    object.file_size = options.file_size
    object.image_probe = options.image_probe or require("webdavmanga.image_probe")
    object.md5 = options.md5 or default_md5
    return object
end

function LocalArchive:_filesystem()
    if not self.lfs then self.lfs = require("libs/libkoreader-lfs") end
    if not self.make_path then self.make_path = require("util").makePath end
    if not self.file_size then
        self.file_size = function(path) return self.lfs.attributes(path, "size") end
    end
    return self.lfs
end

function LocalArchive:_link_attributes(path)
    local lfs = self:_filesystem()
    if type(lfs.symlinkattributes) ~= "function" then
        return failure("unsafe_target", "symlink inspection unavailable")
    end
    local ok, attributes = pcall(lfs.symlinkattributes, path)
    if not ok then return failure("unsafe_target", attributes) end
    if not attributes then return failure("unsafe_target", "path unavailable") end
    return attributes
end

function LocalArchive:_validate_target(connection, manga_path)
    if type(connection) ~= "table" or connection.kind ~= "local" then
        return failure("not_local", "only local sources can be deleted")
    end
    local root = normalize_absolute(connection.local_path or connection.root_path)
    local target = normalize_absolute(manga_path)
    if not root or not target or target == root or not Path.is_within_remote(target, root) then
        return failure("unsafe_target", "target must be a child of the local root")
    end
    local root_attributes, root_error = self:_link_attributes(root)
    if not root_attributes then return nil, root_error end
    if root_attributes.mode == "link" or root_attributes.mode ~= "directory" then
        return failure("unsafe_target", "local root is not a real directory")
    end
    local current = root
    local suffix = target:sub(#root + 1)
    for segment in suffix:gmatch("[^/]+") do
        current = Path.join_remote(current, segment)
        local attributes, attributes_error = self:_link_attributes(current)
        if not attributes then return nil, attributes_error end
        if attributes.mode == "link" then
            return failure("unsafe_target", "symbolic links are not allowed")
        end
    end
    return { root = root, target = target }
end

function LocalArchive:_scan(target)
    local lfs = self:_filesystem()
    local snapshot = { files = {}, directories = {} }
    local function walk(path)
        local attributes, attributes_error = self:_link_attributes(path)
        if not attributes then return nil, attributes_error end
        if attributes.mode == "link" then
            return failure("unsafe_target", "symbolic links are not allowed")
        elseif attributes.mode == "file" then
            snapshot.files[#snapshot.files + 1] = path
            return true
        elseif attributes.mode ~= "directory" then
            return failure("unsafe_target", "unsupported filesystem entry")
        end
        local ok, iterator, directory = pcall(lfs.dir, path)
        if not ok or type(iterator) ~= "function" then
            return failure("unsafe_target", directory or iterator or "cannot list directory")
        end
        while true do
            local next_ok, name = pcall(iterator, directory)
            if not next_ok then return failure("unsafe_target", name) end
            if name == nil then break end
            if name ~= "." and name ~= ".." then
                if type(name) ~= "string" or name == ""
                    or name:find("[/\\%z]") then
                    return failure("unsafe_target", "invalid directory entry")
                end
                local walked, walk_error = walk(Path.join_remote(path, name))
                if not walked then return nil, walk_error end
            end
        end
        snapshot.directories[#snapshot.directories + 1] = path
        return true
    end
    local scanned, scan_error = walk(target)
    if not scanned then return nil, scan_error end
    return snapshot
end

function LocalArchive:_valid_archived_cover(path)
    path = normalize_absolute(path)
    if not path or not Path.is_within_remote(path, self.root)
        or not ImageFormats.is_supported(path) then return nil end
    local attributes = self:_link_attributes(path)
    if not attributes or attributes.mode ~= "file" then return nil end
    local extension = ImageFormats.extension(path)
    local ok, info = pcall(self.image_probe.inspect, path, extension)
    if not ok or not info then return nil end
    return path
end

function LocalArchive:_copy_cover(source_path, archive_name)
    local make_called, made, make_error = pcall(self.make_path, self.root)
    if not make_called then return failure("archive_failed", made) end
    if not made then return failure("archive_failed", make_error) end
    local root_attributes, root_error = self:_link_attributes(self.root)
    if not root_attributes then return nil, root_error end
    if root_attributes.mode == "link" or root_attributes.mode ~= "directory" then
        return failure("archive_failed", "archive root is unsafe")
    end
    local extension = ImageFormats.extension(source_path)
    if not extension then return failure("archive_failed", "unsupported cover format") end
    local final_path = Path.join_remote(self.root, archive_name .. "." .. extension)
    local part_path = final_path .. ".part"
    pcall(self.remove_file, part_path)
    local source_called, source, source_error = pcall(self.open_file, source_path, "rb")
    if not source_called then return failure("archive_failed", source) end
    if not source then return failure("archive_failed", source_error) end
    local target_called, target, target_error = pcall(self.open_file, part_path, "wb")
    if not target_called then
        pcall(source.close, source)
        return failure("archive_failed", target)
    end
    if not target then
        pcall(source.close, source)
        return failure("archive_failed", target_error)
    end
    local copied, copy_error = true, nil
    while true do
        local read_ok, chunk = pcall(source.read, source, COPY_BYTES)
        if not read_ok then copied, copy_error = false, chunk; break end
        if chunk == nil then break end
        local write_ok, result, detail = pcall(target.write, target, chunk)
        if not write_ok or result == nil then
            copied, copy_error = false, write_ok and detail or result
            break
        end
    end
    local source_close_called, source_closed = pcall(source.close, source)
    local target_close_called, target_closed = pcall(target.close, target)
    if not copied or not source_close_called or source_closed == nil
        or not target_close_called or target_closed == nil then
        pcall(self.remove_file, part_path)
        return failure("archive_failed", copy_error or "cover copy failed")
    end
    local size_called, raw_size = pcall(self.file_size, part_path)
    local size = size_called and (tonumber(raw_size) or 0) or 0
    local probe_ok, image_info = pcall(self.image_probe.inspect,
        part_path, extension)
    if size <= 0 or not probe_ok or not image_info then
        pcall(self.remove_file, part_path)
        return failure("archive_failed", "archived cover verification failed")
    end
    local rename_called, renamed, rename_error = pcall(
        self.rename_file, part_path, final_path)
    if not rename_called then
        pcall(self.remove_file, part_path)
        return failure("archive_failed", renamed)
    end
    if not renamed then
        pcall(self.remove_file, part_path)
        return failure("archive_failed", rename_error)
    end
    return final_path
end

function LocalArchive:_archive_cover(connection, record, target, cover_image)
    local existing = self:_valid_archived_cover(record.archived_cover_path)
    if existing then return existing end
    local source_path = normalize_absolute(cover_image and cover_image.path)
    if not source_path or not Path.is_within_remote(source_path, target)
        or not ImageFormats.is_supported(source_path) then
        return failure("archive_failed", "a safe local cover is required")
    end
    local attributes, attributes_error = self:_link_attributes(source_path)
    if not attributes then return nil, attributes_error end
    if attributes.mode ~= "file" then
        return failure("archive_failed", "cover is not a regular file")
    end
    local identity = table.concat({ tostring(connection.root_path or ""),
        tostring(record.manga.path or "") }, "\0")
    local archive_name = tostring(self.md5(identity)):gsub("[^%w_%-]", "")
    if archive_name == "" then return failure("archive_failed", "invalid archive name") end
    return self:_copy_cover(source_path, archive_name)
end

function LocalArchive:_remove_snapshot(snapshot)
    local lfs = self:_filesystem()
    for _, path in ipairs(snapshot.files) do
        local called, removed, remove_error = pcall(self.remove_file, path)
        if not called then return failure("delete_failed", removed) end
        if not removed and self:_link_attributes(path) ~= nil then
            return failure("delete_failed", remove_error)
        end
    end
    for _, path in ipairs(snapshot.directories) do
        local called, removed, remove_error = pcall(lfs.rmdir, path)
        if not called then return failure("delete_failed", removed) end
        if not removed and self:_link_attributes(path) ~= nil then
            return failure("delete_failed", remove_error)
        end
    end
    return true
end

function LocalArchive:archive_and_delete(connection, record, cover_image)
    if type(record) ~= "table" or type(record.manga) ~= "table" then
        return failure("unsafe_target", "missing manga record")
    end
    if record.local_deleted then return failure("already_deleted", "manga is already deleted") end
    local validated, validation_error = self:_validate_target(connection, record.manga.path)
    if not validated then return nil, validation_error end
    local first_snapshot, first_error = self:_scan(validated.target)
    if not first_snapshot then return nil, first_error end
    local archived_path, archive_error = self:_archive_cover(
        connection, record, validated.target, cover_image)
    if not archived_path then return nil, archive_error end
    local prepared, prepare_error = self.library:set_local_archive(
        connection, record.manga.path, archived_path, false)
    if not prepared then return failure("metadata_failed", prepare_error) end
    local final_snapshot, final_error = self:_scan(validated.target)
    if not final_snapshot then return nil, final_error end
    local removed, remove_error = self:_remove_snapshot(final_snapshot)
    if not removed then return nil, remove_error end
    local completed, complete_error = self.library:set_local_archive(
        connection, record.manga.path, archived_path, true)
    if not completed then
        completed, complete_error = self.library:set_local_archive(
            connection, record.manga.path, archived_path, true)
    end
    if not completed then return failure("metadata_finalize_failed", complete_error) end
    return completed
end

return LocalArchive


