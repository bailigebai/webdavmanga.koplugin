local Store = require("webdavmanga.license_store")
local Device = require("webdavmanga.license_device")
local License = require("webdavmanga.license")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local values, fail_flush, reads = {}, false, 0
local settings = {
    readSetting = function(_, key, default)
        reads = reads + 1
        local value = values[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_, key, value)
        if key == "receipt" and value == "FAIL" then error("write failed") end
        values[key] = value
    end,
    flush = function()
        if fail_flush then error("flush failed") end
        return true
    end,
}
local store = Store:new{ settings = settings }
expect(store:load() == nil, "empty store should have no receipt")
local device_settings = {}
local device_store = {
    readSetting = function(_, key, default)
        local value = device_settings[key]
        return value == nil and default or value
    end,
    saveSetting = function(_, key, value) device_settings[key] = value end,
    flush = function() end,
}
local device = Device:new{
    device = { serial_number = "stable-kindle-serial" },
    store = device_store,
    hash = function(value)
        return value == "stable-kindle-serial" and string.rep("d", 64) or nil
    end,
}
local device_id = assert(device:get_id())
expect(device_id == string.rep("d", 64), "stable serial should become a device digest")
expect(device_settings.install_id_hash == nil, "raw stable serial must not be persisted")
local false_device_store = {
    readSetting = function() return nil end,
    saveSetting = function() return false end,
    flush = function() return false end,
}
local false_device = Device:new{
    store = false_device_store,
    random_bytes = function() return string.rep("r", 32) end,
    hash = function() return string.rep("e", 64) end,
}
local false_device_id = false_device:get_id()
expect(false_device_id == nil, "device save false must fail closed")
local throwing_device = Device:new{
    store = {
        readSetting = function() error("read failed") end,
        saveSetting = function() error("write failed") end,
        flush = function() error("flush failed") end,
    },
    random_bytes = function() return string.rep("r", 32) end,
    hash = function() return string.rep("e", 64) end,
}
local throwing_device_id = throwing_device:get_id()
expect(throwing_device_id == nil, "device read/write exceptions must fail closed")
local lazy_device_calls = 0
local empty_license = License:new{
    store = Store:new{ settings = {
        readSetting = function(_, _, default) return default end,
        saveSetting = function() error("inactive status must not write") end,
        flush = function() error("inactive status must not flush") end,
    } },
    crypto = { verify_receipt = function() return false end },
    device = { get_id = function()
        lazy_device_calls = lazy_device_calls + 1
        return string.rep("a", 64)
    end },
    product = "webdavmanga-premium",
}
expect(empty_license:is_authorized() == false
    and empty_license:status().authorized == false
    and lazy_device_calls == 0,
    "inactive status and access checks must not create or persist a device id")
local receipt = {
    version = 1, product = "webdavmanga-premium", device_id = string.rep("a", 64),
    key_id = string.rep("b", 64), issued_at = 1700000000, signature = "c2ln",
}
expect(store:save_atomic(receipt) == true, "atomic save should succeed")
local loaded = assert(store:load())
expect(loaded.product == receipt.product and loaded.signature == receipt.signature,
    "saved receipt should be readable")
expect(values.receipt_pending == nil, "pending marker must be cleared after commit")

local old = values.receipt
fail_flush = true
local saved, save_error = store:save_atomic({ version = 1 })
expect(saved == false and save_error == "save_failed", "flush failure must fail closed")
expect(values.receipt == old, "flush failure must preserve the old receipt")
fail_flush = false
local false_flush_settings = {
    readSetting = settings.readSetting,
    saveSetting = settings.saveSetting,
    flush = function() return false end,
}
local false_flush_store = Store:new{ settings = false_flush_settings }
local false_saved = false_flush_store:save_atomic(receipt)
expect(false_saved == false, "explicit false flush must fail closed")
local false_save_store = Store:new{ settings = {
    readSetting = settings.readSetting,
    saveSetting = function() return false end,
    flush = function() return true end,
} }
local false_written = false_save_store:save_atomic(receipt)
expect(false_written == false, "explicit false save must fail closed")
local throwing_read_store = Store:new{ settings = {
    readSetting = function() error("read failed") end,
    saveSetting = function() end, flush = function() end,
} }
expect(throwing_read_store:load() == nil, "read exceptions must return no receipt")

local crypto = {
    normalize_key = function(key) return key end,
    key_hash = function() return string.rep("b", 64) end,
    verify_receipt = function() return true end,
}
local device = { get_id = function() return string.rep("a", 64) end }
local transport = {
    activate = function(_, payload)
        expect(payload.product == "webdavmanga-premium", "activation product must be isolated")
        return { ok = true, receipt = receipt }
    end,
}
local license = License:new{
    store = store, crypto = crypto, device = device, transport = transport,
    product = "webdavmanga-premium", public_key = { verifier = {} },
}
expect(license:is_authorized() == true, "valid stored receipt should authorize offline")
local prepared, prepare_error = license:prepare_activation("2345-6789-ABCD")
expect(type(prepared) == "table" and prepare_error == nil
    and prepared.device_id == string.rep("a", 64)
    and prepared.key_id == string.rep("b", 64),
    "activation preparation must validate key, device and key hash on the UI process")
local remote_receipt, remote_error = license:request_activation(prepared)
expect(remote_receipt == receipt and remote_error == nil,
    "activation request phase must return a verified receipt without committing it")
local committed, committed_result = license:commit_activation(remote_receipt, prepared)
expect(committed == true and committed_result == receipt,
    "activation commit phase must revalidate and atomically store the receipt")
local callback_ok, callback_result
local activated = license:activate("2345-6789-ABCD", function(ok, result)
    callback_ok, callback_result = ok, result
end)
expect(activated == true and callback_ok == true and callback_result == receipt,
    "successful activation should callback with the receipt")
local callback_count = 0
local callback_raised = pcall(function()
    license:activate("2345-6789-ABCD", function()
        callback_count = callback_count + 1
        error("callback test")
    end)
end)
expect(callback_raised == false and callback_count == 1,
    "activation callback should be invoked at most once")

local tampered_store = Store:new{ settings = {
    readSetting = function(_, key, default)
        if key == "receipt" then
            local copy = {}
            for field, value in pairs(receipt) do copy[field] = value end
            copy.device_id = string.rep("c", 64)
            return copy
        end
        return default
    end,
    saveSetting = function() end, flush = function() end,
} }
local offline = License:new{
    store = tampered_store, crypto = crypto, device = device,
    product = "webdavmanga-premium", public_key = { verifier = {} },
}
expect(offline:is_authorized() == false, "tampered offline receipt must not authorize")

local clear_values = {
    receipt = receipt,
    receipt_pending = { version = 1, pending = true },
    install_id_hash = string.rep("f", 64),
    unrelated_setting = "keep-me",
}
local clear_fail_flush = false
local clear_settings = {
    readSetting = function(_, key, default)
        local value = clear_values[key]
        return value == nil and default or value
    end,
    saveSetting = function(_, key, value)
        clear_values[key] = value
        return true
    end,
    flush = function()
        if clear_fail_flush then return false end
        return true
    end,
}
local clear_store = Store:new{ settings = clear_settings }
local clear_license = License:new{
    store = clear_store, crypto = crypto, device = device,
    product = "webdavmanga-premium", public_key = { verifier = {} },
}
expect(clear_license:is_authorized() == true,
    "clear fixture must begin with a valid offline receipt")
local cleared, clear_error = clear_license:clear_local()
expect(cleared == true and clear_error == nil,
    "clear local authorization should succeed atomically")
expect(clear_values.receipt == nil and clear_values.receipt_pending == nil,
    "clear local authorization must remove committed and pending receipts")
expect(clear_values.install_id_hash == string.rep("f", 64)
    and clear_values.unrelated_setting == "keep-me",
    "clear local authorization must preserve device identity and unrelated settings")
expect(clear_license:is_authorized() == false,
    "clearing the local receipt must lock premium features immediately")

clear_values.receipt = receipt
clear_values.receipt_pending = { version = 1, pending = true }
clear_fail_flush = true
local failed_clear, failed_clear_error = clear_license:clear_local()
expect(failed_clear == false and failed_clear_error == "save_failed",
    "clear flush failure must fail closed with a stable error")
expect(clear_values.receipt == receipt
    and type(clear_values.receipt_pending) == "table",
    "clear flush failure must restore both receipt values")
expect(clear_values.install_id_hash == string.rep("f", 64)
    and clear_values.unrelated_setting == "keep-me",
    "failed clear must still preserve device identity and unrelated settings")

print(("license_store_spec: %d checks"):format(checks))
