local Store = {}
Store.__index = Store

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = clone(item) end
    return result
end

local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

function Store:new(options)
    options = options or {}
    return setmetatable({
        settings = options.settings or options.store,
        receipt_key = options.receipt_key or "receipt",
        pending_key = options.pending_key or "receipt_pending",
    }, self)
end

function Store:load()
    if not self.settings or type(self.settings.readSetting) ~= "function" then return nil end
    local ok, receipt = pcall(self.settings.readSetting, self.settings,
        self.receipt_key, nil)
    if not ok then return nil end
    return type(receipt) == "table" and clone(receipt) or nil
end

function Store:_read(key)
    if not self.settings or type(self.settings.readSetting) ~= "function" then
        return nil, false
    end
    local ok, value = pcall(self.settings.readSetting, self.settings, key, nil)
    return value, ok
end

function Store:_flush()
    if type(self.settings.flush) ~= "function" then return true end
    local ok, result = pcall(self.settings.flush, self.settings)
    return ok and result ~= false
end

function Store:_restore(old_receipt, old_pending)
    pcall(self.settings.saveSetting, self.settings, self.receipt_key, old_receipt)
    pcall(self.settings.saveSetting, self.settings, self.pending_key, old_pending)
    pcall(self.settings.flush, self.settings)
end

function Store:save_atomic(receipt)
    if type(receipt) ~= "table" or not self.settings
        or type(self.settings.saveSetting) ~= "function" then
        return false, "save_failed"
    end
    local old_receipt, old_receipt_ok = self:_read(self.receipt_key)
    local old_pending, old_pending_ok = self:_read(self.pending_key)
    if not old_receipt_ok or not old_pending_ok then return false, "save_failed" end
    local function fail()
        self:_restore(old_receipt, old_pending)
        return false, "save_failed"
    end
    local ok, result = pcall(self.settings.saveSetting, self.settings,
        self.pending_key, clone(receipt))
    ok = ok and result ~= false
    if not ok or not self:_flush() then return fail() end
    local pending, pending_ok = self:_read(self.pending_key)
    if not pending_ok or not same(pending, receipt) then return fail() end
    ok, result = pcall(self.settings.saveSetting, self.settings,
        self.receipt_key, clone(receipt))
    ok = ok and result ~= false
    if not ok or not self:_flush() then return fail() end
    local saved, saved_ok = self:_read(self.receipt_key)
    if not saved_ok or not same(saved, receipt) then return fail() end
    ok, result = pcall(self.settings.saveSetting, self.settings, self.pending_key, nil)
    ok = ok and result ~= false
    if not ok or not self:_flush() then return fail() end
    local pending_after, pending_after_ok = self:_read(self.pending_key)
    if not pending_after_ok or pending_after ~= nil then return fail() end
    return true
end

function Store:clear_atomic()
    if not self.settings or type(self.settings.saveSetting) ~= "function" then
        return false, "save_failed"
    end
    local old_receipt, old_receipt_ok = self:_read(self.receipt_key)
    local old_pending, old_pending_ok = self:_read(self.pending_key)
    if not old_receipt_ok or not old_pending_ok then return false, "save_failed" end
    local function fail()
        self:_restore(old_receipt, old_pending)
        return false, "save_failed"
    end
    local ok, result = pcall(self.settings.saveSetting, self.settings,
        self.pending_key, nil)
    if not ok or result == false then return fail() end
    ok, result = pcall(self.settings.saveSetting, self.settings,
        self.receipt_key, nil)
    if not ok or result == false or not self:_flush() then return fail() end
    local receipt, receipt_ok = self:_read(self.receipt_key)
    local pending, pending_ok = self:_read(self.pending_key)
    if not receipt_ok or not pending_ok or receipt ~= nil or pending ~= nil then
        return fail()
    end
    return true
end

return Store
