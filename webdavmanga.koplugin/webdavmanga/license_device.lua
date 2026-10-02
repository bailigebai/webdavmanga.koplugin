local Device = {}
Device.__index = Device

local function valid_hex(value)
    return type(value) == "string" and #value == 64
        and value:match("^[0-9a-f]+$") ~= nil
end

local function default_hash(value)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        return nil, "hash_unavailable"
    end
    local called, result = pcall(sha2.sha256, value)
    if not called or type(result) ~= "string" then return nil, "hash_failed" end
    result = result:lower()
    return valid_hex(result) and result or nil, valid_hex(result) and nil or "hash_failed"
end

local function serial_from(device)
    if type(device) ~= "table" then return nil end
    if type(device.getSerialNumber) == "function" then
        local ok, value = pcall(device.getSerialNumber, device)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    for _, key in ipairs({ "serial_number", "serial", "device_serial", "id" }) do
        if type(device[key]) == "string" and device[key] ~= "" then return device[key] end
    end
    return nil
end

function Device:new(options)
    options = options or {}
    return setmetatable({
        device = options.device,
        store = options.store,
        hash = options.hash or default_hash,
        get_serial = options.get_serial,
        random_bytes = options.random_bytes,
        install_key = options.install_key or "install_id_hash",
    }, self)
end

function Device:_digest(value)
    local ok, result, error_code = pcall(self.hash, value)
    if not ok then return nil, "hash_failed" end
    if not valid_hex(result) then return nil, error_code or "hash_failed" end
    return result
end

function Device:_stored()
    if not self.store or type(self.store.readSetting) ~= "function" then return nil end
    local ok, stored = pcall(self.store.readSetting, self.store, self.install_key, nil)
    if not ok then return nil end
    return valid_hex(stored) and stored or nil
end

function Device:_save(value)
    if not self.store or type(self.store.saveSetting) ~= "function" then
        return nil, "save_failed"
    end
    local ok, result = pcall(self.store.saveSetting, self.store, self.install_key, value)
    if not ok or result == false then return nil, "save_failed" end
    if type(self.store.flush) == "function" then
        local flush_ok, flush_result = pcall(self.store.flush, self.store)
        if not flush_ok or flush_result == false then return nil, "save_failed" end
    end
    local read_ok, readback = pcall(self.store.readSetting, self.store,
        self.install_key, nil)
    if not read_ok then return nil, "save_failed" end
    return readback == value and true or nil, readback == value and nil or "save_failed"
end

function Device:get_id()
    local serial
    if self.get_serial then
        local serial_ok, serial_value = pcall(self.get_serial)
        if serial_ok then serial = serial_value end
    else
        serial = serial_from(self.device)
    end
    if type(serial) == "string" and serial ~= "" then return self:_digest(serial) end
    local stored = self:_stored()
    if stored then return stored end
    local random
    if self.random_bytes then
        local random_ok, random_value = pcall(self.random_bytes, 32)
        if random_ok then random = random_value end
    end
    if type(random) ~= "string" or #random < 16 then
        local opened, handle = pcall(io.open, "/dev/urandom", "rb")
        if opened and handle then
            local read_ok, random_value = pcall(handle.read, handle, 32)
            pcall(handle.close, handle)
            if read_ok then random = random_value end
        end
    end
    if type(random) ~= "string" or #random < 16 then return nil, "device_id_unavailable" end
    local digest, error_code = self:_digest(random)
    if not digest then return nil, error_code end
    return self:_save(digest)
end

return Device
