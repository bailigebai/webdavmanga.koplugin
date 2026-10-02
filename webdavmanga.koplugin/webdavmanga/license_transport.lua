local Transport = {}
Transport.__index = Transport

local DEFAULT_TIMEOUT_SECONDS = 15
local DEFAULT_MAX_RESPONSE_BYTES = 64 * 1024
local DEFAULT_MAX_REQUEST_BYTES = 16 * 1024

local function is_https(url)
    return type(url) == "string"
        and url:match("^https://[^%s/]+[^%s]*$") ~= nil
end

local function classify_network_error(detail)
    local text = tostring(detail or ""):lower()
    if text:find("dns", 1, true) or text:find("resolve", 1, true)
        or text:find("name or service", 1, true) then
        return "dns_failed"
    elseif text:find("timeout", 1, true) or text:find("timed out", 1, true) then
        return "timeout"
    elseif text:find("tls", 1, true) or text:find("ssl", 1, true)
        or text:find("certificate", 1, true)
        or text:find("handshake", 1, true) then
        return "tls_failed"
    end
    return "service_unavailable"
end

local function response_status(response)
    if type(response) ~= "table" then return nil end
    return tonumber(response.status or response.code or response.http_status)
end

local function response_body(response)
    if type(response) ~= "table" then return nil end
    return response.body or response.response_body or response.data
end

local function server_error_code(status, decoded)
    if type(decoded) == "table" and decoded.error ~= nil then
        return tostring(decoded.error)
    end
    status = tonumber(status)
    if status == 401 or status == 422 then return "invalid_key" end
    if status == 403 then return "origin_not_allowed" end
    if status == 405 then return "method_not_allowed" end
    if status == 429 then return "rate_limited" end
    if status and status >= 500 then return "service_unavailable" end
    return "http_error"
end

local function default_request(request)
    local ok, WebDavTransport = pcall(require, "webdavmanga.transport")
    if not ok or type(WebDavTransport) ~= "table" then
        return nil, "service unavailable"
    end
    local base_socketutil
    local socketutil_ok, socketutil_value = pcall(require, "socketutil")
    if socketutil_ok then base_socketutil = socketutil_value end
    local bounded_socketutil
    if base_socketutil then
        bounded_socketutil = {
            FILE_BLOCK_TIMEOUT = request.timeout_seconds,
            FILE_TOTAL_TIMEOUT = request.timeout_seconds,
            set_timeout = function(_, block, total)
                return base_socketutil:set_timeout(block, total)
            end,
            reset_timeout = function(_)
                return base_socketutil:reset_timeout()
            end,
        }
    end
    local transport
    local constructed, value = pcall(WebDavTransport.new, WebDavTransport,
        {
            socketutil = bounded_socketutil,
            ca_file = request.ca_file,
        })
    if not constructed then return nil, tostring(value) end
    transport = value
    local ltn12 = transport.ltn12
    local chunks, sink_error, bytes = {}, nil, 0
    local limit = tonumber(request.max_response_bytes) or DEFAULT_MAX_RESPONSE_BYTES
    local sink = function(chunk, err)
        if chunk then
            bytes = bytes + #chunk
            if bytes > limit then
                sink_error = "response exceeds maximum size"
                return nil, sink_error
            end
            chunks[#chunks + 1] = chunk
        end
        if err then sink_error = tostring(err); return nil, err end
        return 1
    end
    local code, headers, status = transport:_request{
        url = request.url,
        method = request.method,
        redirect = false,
        headers = request.headers,
        source = request.body and ltn12.source.string(request.body) or nil,
        sink = sink,
    }
    if sink_error then return nil, sink_error end
    if code == nil then return nil, status or "request failed" end
    return { status = code, headers = headers, body = table.concat(chunks), detail = status }
end

function Transport:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.endpoint = options.endpoint
    object.timeout_seconds = tonumber(options.timeout_seconds) or DEFAULT_TIMEOUT_SECONDS
    object.ca_file = options.ca_file
    object.max_response_bytes = tonumber(options.max_response_bytes)
        or DEFAULT_MAX_RESPONSE_BYTES
    object.max_request_bytes = tonumber(options.max_request_bytes)
        or DEFAULT_MAX_REQUEST_BYTES
    object.json = options.json or require("json")
    object.request = options.request or default_request
    return object
end

function Transport:_json_request(method, url, payload)
    if not is_https(url) then return nil, "https_required" end
    local body
    if payload ~= nil then
        local encoded_ok, encoded, encode_error = pcall(self.json.encode, payload)
        if not encoded_ok or type(encoded) ~= "string" then
            return nil, "invalid_request"
        end
        body = encoded
        if #body > self.max_request_bytes then return nil, "request_too_large" end
    end
    local request = {
        url = url,
        method = method,
        body = body,
        timeout_seconds = self.timeout_seconds,
        max_response_bytes = self.max_response_bytes,
        ca_file = self.ca_file,
        follow_redirects = false,
        headers = {
            ["Accept"] = "application/json",
            ["Cache-Control"] = "no-store",
        },
    }
    if body then
        request.headers["Content-Type"] = "application/json"
        request.headers["Content-Length"] = #body
    end
    local call_ok, response, request_error, request_body, request_detail =
        pcall(self.request, request)
    if not call_ok then return nil, classify_network_error(response) end
    if response == nil then return nil, classify_network_error(request_error) end
    if type(response) ~= "table" then
        if type(response) == "number" then
            response = {
                status = response,
                headers = request_error,
                body = request_body,
                detail = request_detail,
            }
        else
            return nil, "invalid_response"
        end
    end
    local status = response_status(response)
    if not status then return nil, "invalid_response" end
    if status >= 300 and status < 400 then return nil, "redirect_rejected" end
    local raw = response_body(response)
    if type(raw) ~= "string" then return nil, "invalid_response" end
    if #raw > self.max_response_bytes then return nil, "response_too_large" end
    local decoded
    if raw ~= "" then
        local decode_ok, value = pcall(self.json.decode, raw)
        if not decode_ok or type(value) ~= "table" then return nil, "invalid_json" end
        decoded = value
    end
    if status < 200 or status >= 300 then
        return decoded, server_error_code(status, decoded)
    end
    if type(decoded) ~= "table" then return nil, "invalid_response" end
    if decoded.ok == false then return decoded, server_error_code(status, decoded) end
    return decoded
end

function Transport:_activation_response(response)
    if type(response) ~= "table" or response.ok ~= true
        or type(response.receipt) ~= "table" then
        return nil, "invalid_response"
    end
    for _, field in ipairs({ "version", "product", "device_id", "key_id",
        "issued_at", "signature" }) do
        if response.receipt[field] == nil then return nil, "invalid_response" end
    end
    return response
end

function Transport:activate(payload)
    if type(payload) ~= "table" then return nil, "invalid_request" end
    local response, error_code = self:_json_request("POST", self.endpoint, payload)
    if not response then return nil, error_code end
    if error_code then return response, error_code end
    return self:_activation_response(response)
end

function Transport:health()
    if not is_https(self.endpoint) then return nil, "https_required" end
    local health_url = self.endpoint:gsub("/activate/?$", "/health")
    if health_url == self.endpoint then health_url = self.endpoint:gsub("/+$", "") .. "/health" end
    return self:_json_request("GET", health_url)
end

return Transport
