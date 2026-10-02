-- POSIX storage capabilities used by the manifest builder.  This module keeps
-- the descriptor returned by O_CREAT|O_EXCL for the lifetime of the file and
-- exposes owner-safe lock release as an explicit capability.
local M = {}

local Handle = {}
Handle.__index = Handle

local function valid_integer(value)
    return type(value) == "number" and value >= 0
        and value == math.floor(value)
end

local function syscall_detail(detail, fallback)
    return tostring(detail or fallback or "POSIX storage failure")
end

function Handle:write(value)
    if self.closed then return nil, "file descriptor is closed" end
    if type(value) ~= "string" then value = tostring(value) end
    local offset = 0
    while offset < #value do
        local written, detail = self.sys.write(
            self.descriptor, value, offset, #value - offset)
        if not valid_integer(written) or written < 1
            or written > #value - offset then
            return nil, syscall_detail(detail, "POSIX write failed")
        end
        offset = offset + written
    end
    return self
end

function Handle:read(count)
    if self.closed then return nil, "file descriptor is closed" end
    if not valid_integer(count) or count < 1 then
        return nil, "invalid POSIX read size"
    end
    local value, detail = self.sys.read(self.descriptor, count)
    if value == nil then return nil, detail end
    if type(value) ~= "string" or #value < 1 or #value > count then
        return nil, "invalid POSIX read result"
    end
    return value
end

function Handle:seek(whence, offset)
    if self.closed then return nil, "file descriptor is closed" end
    whence = whence or "cur"
    offset = offset or 0
    if (whence ~= "set" and whence ~= "cur" and whence ~= "end")
        or type(offset) ~= "number" or offset ~= math.floor(offset) then
        return nil, "invalid POSIX seek"
    end
    local position, detail = self.sys.seek(self.descriptor, whence, offset)
    if not valid_integer(position) then
        return nil, syscall_detail(detail, "POSIX seek failed")
    end
    return position
end

function Handle:flush()
    if self.closed then return nil, "file descriptor is closed" end
    local synced, detail = self.sys.sync(self.descriptor)
    if not synced then return nil, syscall_detail(detail, "POSIX fsync failed") end
    return true
end

function Handle:close()
    if self.closed then return true end
    local closed, detail = self.sys.close(self.descriptor)
    -- On Linux the descriptor is no longer safe to retry after close(2), even
    -- when close reports a late writeback error.
    self.closed = true
    if not closed then return nil, syscall_detail(detail, "POSIX close failed") end
    return true
end

local function new_handle(sys, descriptor)
    return setmetatable({
        sys = sys,
        descriptor = descriptor,
        closed = false,
    }, Handle)
end

local REQUIRED_SYSCALLS = {
    "open_create", "open_read", "write", "read", "seek", "sync", "close",
    "fstat", "lstat", "unlink", "atomic_replace",
}

local function read_lock_payload(handle, payload)
    local positioned, position_error = handle:seek("set", 0)
    if positioned == nil then return nil, position_error end
    local chunks = {}
    local received = 0
    while received < #payload do
        local value, read_error = handle:read(#payload - received)
        if not value then return nil, read_error or "manifest lock is truncated" end
        chunks[#chunks + 1] = value
        received = received + #value
    end
    local extra, extra_error = handle:read(1)
    if extra ~= nil or extra_error ~= nil then
        return nil, extra_error or "manifest lock has trailing data"
    end
    if table.concat(chunks) ~= payload then
        return nil, "manifest lock nonce changed"
    end
    return true
end

function M.from_syscalls(sys)
    if type(sys) ~= "table" then return nil, "POSIX syscalls are unavailable" end
    for _, name in ipairs(REQUIRED_SYSCALLS) do
        if type(sys[name]) ~= "function" then
            return nil, "missing POSIX syscall capability: " .. name
        end
    end
    for _, name in ipairs({
        "O_RDONLY", "O_WRONLY", "O_RDWR", "O_CREAT", "O_EXCL", "OWNER_MODE",
    }) do
        if not valid_integer(sys[name]) then
            return nil, "missing POSIX constant: " .. name
        end
    end

    local adapter = {}

    function adapter.open(path, mode)
        if mode ~= "rb" then
            return nil, "non-exclusive POSIX writes are forbidden"
        end
        local descriptor, detail = sys.open_read(path, sys.O_RDONLY)
        if descriptor == nil then return nil, detail end
        return new_handle(sys, descriptor)
    end

    function adapter.open_existing(path)
        local descriptor, detail, kind = sys.open_read(path, sys.O_RDONLY)
        if descriptor == nil then
            return nil, detail, kind == "not_found"
        end
        return new_handle(sys, descriptor)
    end

    function adapter.open_exclusive(path, mode)
        local access
        if mode == "wb" then access = sys.O_WRONLY
        elseif mode == "wb+" then access = sys.O_RDWR
        else return nil, "unsupported exclusive POSIX mode" end
        local flags = sys.O_CREAT + sys.O_EXCL + access
        local descriptor, detail = sys.open_create(path, flags, sys.OWNER_MODE)
        if descriptor == nil then return nil, detail end
        return new_handle(sys, descriptor)
    end

    function adapter.remove(path)
        local removed, detail = sys.unlink(path)
        if not removed then return nil, detail end
        return true
    end

    function adapter.atomic_replace(source, target)
        local replaced, detail = sys.atomic_replace(source, target)
        if not replaced then return nil, detail end
        return true
    end

    function adapter.sync(handle)
        if getmetatable(handle) ~= Handle or handle.sys ~= sys then
            return nil, "sync requires an owned POSIX descriptor"
        end
        return handle:flush()
    end

    function adapter.size(path)
        local handle, open_error = adapter.open(path, "rb")
        if not handle then return nil, open_error end
        local size, seek_error = handle:seek("end", 0)
        local closed, close_error = handle:close()
        if size == nil then return nil, seek_error end
        if not closed then return nil, close_error end
        return size
    end

    function adapter.release_lock(lock)
        if type(lock) ~= "table" or type(lock.path) ~= "string"
            or type(lock.payload) ~= "string"
            or getmetatable(lock.handle) ~= Handle or lock.handle.sys ~= sys
            or lock.handle.closed then
            return nil, "lock release requires its original POSIX descriptor"
        end
        local nonce_ok, nonce_error = read_lock_payload(lock.handle, lock.payload)
        if not nonce_ok then return nil, nonce_error end
        local descriptor_device, descriptor_inode, descriptor_error =
            sys.fstat(lock.handle.descriptor)
        if descriptor_device == nil or descriptor_inode == nil then
            return nil, syscall_detail(descriptor_inode or descriptor_error,
                "cannot identify manifest lock descriptor")
        end
        local path_device, path_inode, path_error = sys.lstat(lock.path)
        if path_device == nil or path_inode == nil then
            return nil, syscall_detail(path_inode or path_error,
                "cannot identify manifest lock pathname")
        end
        if descriptor_device ~= path_device or descriptor_inode ~= path_inode then
            return nil, "manifest lock pathname identity changed"
        end
        local removed, remove_error = sys.unlink(lock.path)
        if not removed then return nil, syscall_detail(remove_error,
            "manifest lock unlink failed") end
        return true
    end

    return adapter
end

local function ffi_backend()
    local ffi = require("ffi")
    require("ffi/posix_h")
    if ffi.os ~= "Linux" or (ffi.arch ~= "arm" and ffi.arch ~= "arm64"
        and ffi.arch ~= "x64") then
        return nil, "manifest POSIX adapter supports KOReader Linux only"
    end
    ffi.cdef([[
        typedef int (*wdm_open_create_fn)(const char *, int, mode_t);
        typedef int (*wdm_open_read_fn)(const char *, int);
        union wdm_stat_buffer { uint64_t alignment; uint8_t bytes[256]; };
        int fstat(int, union wdm_stat_buffer *);
        int lstat(const char *, union wdm_stat_buffer *);
        int fstat64(int, union wdm_stat_buffer *);
        int lstat64(const char *, union wdm_stat_buffer *);
        int unlink(const char *);
        int rename(const char *, const char *);
    ]])

    -- Casting the variadic libc symbol to fixed signatures is deliberate: on
    -- 32-bit ARM the mode_t argument must be passed with the C ABI type used by
    -- open(2), rather than as LuaJIT's default variadic numeric type.
    local open_create = ffi.cast("wdm_open_create_fn", ffi.C.open)
    local open_read = ffi.cast("wdm_open_read_fn", ffi.C.open)

    local function error_result(prefix)
        local number = ffi.errno()
        local detail = prefix .. " (errno " .. tostring(number) .. ")"
        local described = ffi.C.strerror(number)
        if described ~= nil then detail = prefix .. ": " .. ffi.string(described) end
        return nil, detail, number == 2 and "not_found" or "io"
    end

    local sys = {
        O_RDONLY = tonumber(ffi.C.O_RDONLY),
        O_WRONLY = tonumber(ffi.C.O_WRONLY),
        O_RDWR = tonumber(ffi.C.O_RDWR),
        O_CREAT = tonumber(ffi.C.O_CREAT),
        O_EXCL = 128,
        OWNER_MODE = tonumber(ffi.C.S_IRUSR) + tonumber(ffi.C.S_IWUSR),
    }

    function sys.open_create(path, flags, mode)
        local descriptor = open_create(path, flags, ffi.cast("mode_t", mode))
        if descriptor < 0 then return error_result("exclusive open failed") end
        return tonumber(descriptor)
    end

    function sys.open_read(path, flags)
        local descriptor = open_read(path, flags)
        if descriptor < 0 then return error_result("read open failed") end
        return tonumber(descriptor)
    end

    function sys.write(descriptor, value, offset, length)
        local pointer = ffi.cast("const uint8_t *", value)
        local result = ffi.C.write(descriptor, pointer + offset, length)
        if result < 0 then return error_result("write failed") end
        return tonumber(result)
    end

    function sys.read(descriptor, count)
        local buffer = ffi.new("uint8_t[?]", count)
        local result = ffi.C.read(descriptor, buffer, count)
        if result < 0 then return error_result("read failed") end
        if result == 0 then return nil end
        return ffi.string(buffer, tonumber(result))
    end

    function sys.seek(descriptor, whence, offset)
        local origins = {
            set = tonumber(ffi.C.SEEK_SET),
            cur = tonumber(ffi.C.SEEK_CUR),
            ["end"] = tonumber(ffi.C.SEEK_END),
        }
        local result = ffi.C.lseek(descriptor, ffi.cast("off_t", offset), origins[whence])
        if result < 0 then return error_result("seek failed") end
        return tonumber(result)
    end

    function sys.sync(descriptor)
        if ffi.C.fsync(descriptor) ~= 0 then return error_result("fsync failed") end
        return true
    end

    function sys.close(descriptor)
        if ffi.C.close(descriptor) ~= 0 then return error_result("close failed") end
        return true
    end

    local function identity_from(buffer)
        local bytes = buffer.bytes
        local device = ffi.cast("const uint64_t *", bytes)[0]
        local inode_offset = ffi.arch == "arm" and 96 or 8
        local inode = ffi.cast("const uint64_t *", bytes + inode_offset)[0]
        return device, inode
    end

    function sys.fstat(descriptor)
        local buffer = ffi.new("union wdm_stat_buffer")
        local result
        if ffi.arch == "arm" then result = ffi.C.fstat64(descriptor, buffer)
        else result = ffi.C.fstat(descriptor, buffer) end
        if result ~= 0 then return error_result("fstat failed") end
        return identity_from(buffer)
    end

    function sys.lstat(path)
        local buffer = ffi.new("union wdm_stat_buffer")
        local result
        if ffi.arch == "arm" then result = ffi.C.lstat64(path, buffer)
        else result = ffi.C.lstat(path, buffer) end
        if result ~= 0 then return error_result("lstat failed") end
        return identity_from(buffer)
    end

    function sys.unlink(path)
        if ffi.C.unlink(path) ~= 0 then return error_result("unlink failed") end
        return true
    end

    function sys.atomic_replace(source, target)
        if ffi.C.rename(source, target) ~= 0 then
            return error_result("atomic rename failed")
        end
        return true
    end

    return sys
end

function M.new()
    local called, sys, detail = pcall(ffi_backend)
    if not called then return nil, tostring(sys) end
    if not sys then return nil, detail end
    return M.from_syscalls(sys)
end

return M
