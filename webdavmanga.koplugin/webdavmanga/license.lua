local Crypto = require("webdavmanga.license_crypto")

local SAFE_TRANSPORT_ERRORS = {
    invalid_key = true,
    key_bound_to_other_device = true,
    rate_limited = true,
    origin_not_allowed = true,
    method_not_allowed = true,
    service_unavailable = true,
    https_required = true,
    dns_failed = true,
    timeout = true,
    tls_failed = true,
    invalid_json = true,
    invalid_response = true,
    response_too_large = true,
    request_too_large = true,
    redirect_rejected = true,
    invalid_request = true,
}

local function safe_transport_error(value)
    return type(value) == "string" and SAFE_TRANSPORT_ERRORS[value]
        and value or "service_unavailable"
end

local License = {}
License.__index = License

function License:new(options)
    options = options or {}
    return setmetatable({
        store = options.store,
        crypto = options.crypto or Crypto,
        device = options.device,
        transport = options.transport,
        product = options.product or Crypto.PRODUCT,
        endpoint = options.endpoint,
        public_key = options.public_key,
    }, self)
end

function License:_device_id()
    if not self.device or type(self.device.get_id) ~= "function" then
        return nil, "device_id_unavailable"
    end
    local ok, value, error_code = pcall(self.device.get_id, self.device)
    if not ok or type(value) ~= "string" then return nil, error_code or "device_id_unavailable" end
    return value
end

function License:_verify(receipt, device_id)
    if type(receipt) ~= "table" then return false, "invalid_response" end
    if receipt.product ~= self.product then return false, "invalid_product" end
    if receipt.device_id ~= device_id then return false, "invalid_device_id" end
    local ok, valid, error_code = pcall(self.crypto.verify_receipt,
        receipt, self.public_key)
    if not ok or valid ~= true then return false, error_code or "invalid_signature" end
    return true
end

function License:is_authorized()
    local receipt = self.store and self.store:load() or nil
    if not receipt then return false end
    local device_id = self:_device_id()
    if not device_id then return false end
    local valid = self:_verify(receipt, device_id)
    return valid == true
end

function License:status()
    local receipt = self.store and self.store:load() or nil
    if not receipt then
        return { authorized = false, receipt = nil }
    end
    local device_id, device_error = self:_device_id()
    local authorized = false
    local error_code = device_error
    if receipt and device_id then
        local valid, verify_error = self:_verify(receipt, device_id)
        authorized, error_code = valid == true, verify_error
    end
    return { authorized = authorized, device_id = device_id,
        receipt = receipt, error_code = error_code }
end

function License:prepare_activation(raw_key)
    local normalized, normalize_error = self.crypto.normalize_key(raw_key)
    if not normalized then return nil, normalize_error or "invalid_key_format" end
    local device_id, device_error = self:_device_id()
    if not device_id then return nil, device_error or "device_id_unavailable" end
    local key_id, hash_error = self.crypto.key_hash(normalized)
    if not key_id then return nil, hash_error or "hash_failed" end
    return {
        key = normalized,
        normalized = normalized,
        device_id = device_id,
        key_id = key_id,
    }
end

local function valid_prepared(prepared)
    return type(prepared) == "table"
        and type(prepared.key or prepared.normalized) == "string"
        and type(prepared.device_id) == "string"
        and type(prepared.key_id) == "string"
end

function License:request_activation(prepared)
    if not valid_prepared(prepared) then return nil, "invalid_request" end
    if not self.transport or type(self.transport.activate) ~= "function" then
        return nil, "service_unavailable"
    end
    local normalized = prepared.key or prepared.normalized
    local ok, response, transport_error = pcall(self.transport.activate,
        self.transport, {
            product = self.product,
            key = normalized,
            device_id = prepared.device_id,
        })
    if not ok then return nil, "service_unavailable" end
    if type(response) ~= "table" or response.ok ~= true or type(response.receipt) ~= "table" then
        local server_error = type(response) == "table" and response.error or nil
        return nil, safe_transport_error(server_error
            or transport_error or "invalid_response")
    end
    local receipt = response.receipt
    if receipt.key_id ~= prepared.key_id then return nil, "invalid_key_id" end
    local valid, verify_error = self:_verify(receipt, prepared.device_id)
    if not valid then return nil, verify_error end
    return receipt
end

function License:commit_activation(receipt, prepared)
    if not valid_prepared(prepared) or type(receipt) ~= "table" then
        return false, "invalid_response"
    end
    if receipt.key_id ~= prepared.key_id then return false, "invalid_key_id" end
    local valid, verify_error = self:_verify(receipt, prepared.device_id)
    if not valid then return false, verify_error end
    if not self.store or type(self.store.save_atomic) ~= "function"
        then return false, "save_failed"
    end
    local ok, saved = pcall(self.store.save_atomic, self.store, receipt)
    if not ok or saved ~= true then return false, "save_failed" end
    return true, receipt
end

function License:activate(raw_key, callback)
    local called = false
    local function finish(ok, result)
        if called then return end
        called = true
        if callback then callback(ok, result) end
        return ok, result
    end
    local prepared, prepare_error = self:prepare_activation(raw_key)
    if not prepared then return finish(false, prepare_error) end
    local receipt, request_error = self:request_activation(prepared)
    if not receipt then return finish(false, request_error) end
    local committed, commit_result = self:commit_activation(receipt, prepared)
    if not committed then return finish(false, commit_result) end
    return finish(true, commit_result)
end

function License:clear_local()
    if not self.store or type(self.store.clear_atomic) ~= "function" then
        return false, "save_failed"
    end
    local ok, cleared, error_code = pcall(self.store.clear_atomic, self.store)
    if not ok or cleared ~= true then return false, error_code or "save_failed" end
    return true
end

return License
