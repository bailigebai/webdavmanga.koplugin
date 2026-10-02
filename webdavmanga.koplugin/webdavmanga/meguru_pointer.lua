local Driver = require("webdavmanga.opds_driver")
local Url = require("webdavmanga.opds_url")
local Pointer = {}
Pointer.__index = Pointer

local MAX_BYTES = 65536
local FIELDS = { "version", "source_id", "server_kind", "series_id", "series_name",
    "chapter_id", "chapter_name", "stream_template", "page_count", "server_last_read",
    "cover_url", "series_cover_url", "series_feed_url" }
local URL_FIELDS = { "stream_template", "cover_url", "series_cover_url", "series_feed_url" }
local writer_serial = 0

local function default_fs()
    local lfs = require("libs/libkoreader-lfs")
    return {
        make_path = require("util").makePath,
        exists = function(path) return lfs.attributes(path) ~= nil end,
        open = io.open, rename = os.rename, remove = os.remove,
        mkdir = lfs.mkdir, rmdir = lfs.rmdir, list = lfs.dir,
        is_dir = function(path) return lfs.attributes(path, "mode") == "directory" end,
    }
end

local function component(value, fallback)
    value = type(value) == "string" and value or fallback
    value = value:gsub("[%z\1-\31\127/\\<>:\"|?*]", "")
    while value:find("..", 1, true) do value = value:gsub("%.%.", "") end
    local parts, size = {}, 0
    for char in value:gmatch(".[\128-\191]*") do
        if size + #char > 96 then break end
        parts[#parts + 1], size = char, size + #char
    end
    value = table.concat(parts):gsub("[ .]+$", "")
    local basename = value:match("^([^.]*)"):upper()
    if basename == "CON" or basename == "NUL" or basename == "AUX" or basename == "PRN"
        or basename:match("^COM[1-9]$") or basename:match("^LPT[1-9]$") then value = "_" .. value end
    return value ~= "" and value or fallback
end

local function valid_text(value)
    return type(value) == "string" and #value > 0 and #value <= 8192
        and not value:find("[%z\1-\31\127]")
end

local function validate(desc, require_version)
    if type(desc) ~= "table" then return nil, "invalid_pointer" end
    if (require_version or desc.version ~= nil) and desc.version ~= 1 then return nil, "invalid_version" end
    for _, key in ipairs({ "source_id", "series_id", "chapter_id" }) do
        if not valid_text(desc[key]) then return nil, "missing_" .. key end
    end
    if desc.server_kind ~= "kavita" and desc.server_kind ~= "suwayomi" and desc.server_kind ~= "komga" then
        return nil, "unsupported_server"
    end
    local count = desc.page_count
    if type(count) ~= "number" or count ~= count or count < 1 or count > 100000 or count ~= math.floor(count) then
        return nil, "invalid_page_count"
    end
    local template = desc.stream_template
    local parsed = valid_text(template) and Url.parse(template)
    if not parsed or not (parsed.path .. "?" .. (parsed.query or "")):find("{pageNumber}", 1, true) then
        return nil, "invalid_stream_template"
    end
    for _, key in ipairs({ "series_name", "chapter_name" }) do
        if desc[key] ~= nil and (type(desc[key]) ~= "string" or #desc[key] > 8192) then
            return nil, "invalid_pointer"
        end
    end
    for _, key in ipairs({ "cover_url", "series_cover_url", "series_feed_url" }) do
        if desc[key] ~= nil and not valid_text(desc[key]) then return nil, "invalid_pointer" end
    end
    local last = desc.server_last_read
    if last ~= nil and (type(last) ~= "number" or last ~= last or last < 0 or last > count or last ~= math.floor(last)) then
        return nil, "invalid_pointer"
    end
    local clean = { version = 1 }
    for _, key in ipairs(FIELDS) do if key ~= "version" then clean[key] = desc[key] end end
    for _, key in ipairs(URL_FIELDS) do
        if clean[key] then
            clean[key] = Driver.redact_url(clean[key])
            if not clean[key] then return nil, "invalid_pointer" end
            if require_version and clean[key] ~= desc[key] then return nil, "unredacted_pointer" end
        end
    end
    return clean
end

local function same_identity(a, b)
    return a.source_id == b.source_id and a.series_id == b.series_id and a.chapter_id == b.chapter_id
end

function Pointer:new(options)
    options = options or {}
    return setmetatable({ root = options.root, per_server = options.per_server ~= false,
        fs = options.fs, json = options.json, find_existing = options.find_existing,
        md5 = options.md5 or function(value) return require("ffi/sha2").md5(value) end }, self)
end

function Pointer:_dependencies()
    self.fs = self.fs or default_fs()
    self.json = self.json or require("json")
end

function Pointer:path_for(desc)
    local valid, err = validate(desc)
    if not valid then return nil, err end
    local root = self.root
    if not valid_text(root) then return nil, "invalid_pointer_root" end
    self:_dependencies()
    root = root:gsub("[/\\]+$", "")
    local function directory(parent, title, identity)
        local ok, digest = pcall(self.md5, identity)
        if not ok or type(digest) ~= "string" or not digest:match("^[a-f0-9]+$") or #digest < 12 then return nil end
        local suffix = " [" .. digest .. "]"
        -- One directory level only. A renamed series keeps its original readable
        -- directory; the pointer root is never recursively crawled.
        if self.fs.list then
            local found
            pcall(function()
                for name in self.fs.list(parent) do
                    if name:sub(-#suffix) == suffix and (not self.fs.is_dir or self.fs.is_dir(parent .. "/" .. name)) then
                        found = parent .. "/" .. name; break
                    end
                end
            end)
            if found then return found end
        end
        return parent .. "/" .. component(title, "Series") .. suffix
    end
    if self.per_server then
        root = directory(root, desc.server_name or desc.source_id, desc.source_id)
        if not root then return nil, "pointer_identity_conflict" end
    end
    root = directory(root, desc.series_name, desc.source_id .. "\0" .. desc.series_id)
    if not root then return nil, "pointer_identity_conflict" end
    return root .. "/"
        .. component(desc.chapter_name, "Book") .. ".meguru"
end

function Pointer:load(path)
    self:_dependencies()
    if type(path) ~= "string" or not path:lower():match("%.meguru$") then return nil, "invalid_pointer" end
    return self:_read(path)
end

function Pointer:_read(path)
    local opened, handle = pcall(self.fs.open, path, "rb")
    if not opened or not handle then return nil, "pointer_read_failed" end
    local read, bytes = pcall(handle.read, handle, MAX_BYTES + 1)
    local closed, close_result = pcall(handle.close, handle)
    if not read or type(bytes) ~= "string" or #bytes > MAX_BYTES or not closed or not close_result then
        return nil, "pointer_read_failed"
    end
    local decoded, desc = pcall(self.json.decode, bytes)
    if not decoded then return nil, "invalid_pointer" end
    return validate(desc, true)
end

function Pointer:save(desc)
    local clean, err = validate(desc)
    if not clean then return nil, err end
    self:_dependencies()
    local path
    if self.find_existing then
        local found, existing = pcall(self.find_existing, clean.source_id, clean.series_id, clean.chapter_id)
        if not found then return nil, "pointer_lookup_failed" end
        path = existing
    end
    if not path then path, err = self:path_for(desc) end
    if not path then return nil, err end
    local directory = path:match("^(.*)/[^/]+$")
    local lock = directory .. "/.meguru-publish.lock"
    if type(self.fs.mkdir) ~= "function" or type(self.fs.rmdir) ~= "function" then return nil, "pointer_lock_unavailable" end
    local made, result = pcall(self.fs.make_path, directory)
    if not made or not result then return nil, "pointer_write_failed" end
    local locked, acquired = pcall(self.fs.mkdir, lock)
    if not locked or not acquired then return nil, "pointer_busy" end
    writer_serial = writer_serial + 1
    local nonce = tostring({}):gsub("[^%w]", "") .. "-" .. writer_serial
    local part, handle = path .. "." .. nonce .. ".part", nil
    local function cleanup(code)
        if handle then pcall(handle.close, handle); handle = nil end
        pcall(self.fs.remove, part)
        pcall(self.fs.rmdir, lock)
        -- A final may have been replaced by another process, including after an
        -- uncertain rename result. Cleanup owns only this writer's temp and lock.
        return nil, code
    end
    local stage = "pointer_write_failed"
    local success = pcall(function()
        local existing
        if self.fs.exists(path) then
            existing = assert(self:load(path))
            if not same_identity(existing, clean) then
                local digest = self.md5(table.concat({clean.source_id, clean.series_id, clean.chapter_id}, "\0"))
                assert(type(digest) == "string" and digest:match("^[a-f0-9]+$") and #digest >= 12)
                path = path:gsub("%.meguru$", " [" .. digest:sub(1,12) .. "].meguru")
                existing = self.fs.exists(path) and assert(self:load(path)) or nil
                stage = "pointer_identity_conflict"
                assert(not existing or same_identity(existing, clean))
            end
        end
        if existing then
            clean.server_last_read = math.max(existing.server_last_read or 0, clean.server_last_read or 0)
            assert(validate(clean))
            local unchanged = true
            for _, key in ipairs(FIELDS) do if existing[key] ~= clean[key] then unchanged = false; break end end
            if unchanged then return end
        end
        stage = "pointer_encode_failed"
        local bytes = self.json.encode(clean)
        assert(type(bytes) == "string" and #bytes <= MAX_BYTES)
        stage = "pointer_write_failed"
        handle = assert(self.fs.open(part, "wb"))
        assert(handle:write(bytes))
        assert(handle:flush())
        assert(handle:close())
        handle = nil
        stage = "pointer_verify_failed"
        local staged = assert(self:_read(part))
        for _, key in ipairs(FIELDS) do assert(staged[key] == clean[key]) end
        stage = "pointer_rename_failed"
        assert(self.fs.rename(part, path))
        stage = "pointer_verify_failed"
        local verified = assert(self:load(path))
        for _, key in ipairs(FIELDS) do assert(verified[key] == clean[key]) end
    end)
    if not success then return cleanup(stage) end
    cleanup()
    return path
end

return Pointer
