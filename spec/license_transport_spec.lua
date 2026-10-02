local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local LicenseTransport = require("webdavmanga.license_transport")

local seen
local transport = LicenseTransport:new{
    endpoint = "https://license.example/activate",
    ca_file = "/data/ca-bundle.crt",
    timeout_seconds = 7,
    max_response_bytes = 128,
    json = {
        encode = function(value)
            return '{"product":"' .. tostring(value.product) .. '"}'
        end,
        decode = function(body)
            if body == '{"ok":true,"receipt":{}}' then
                return { ok = true, receipt = {} }
            end
            return nil, "invalid JSON"
        end,
    },
    request = function(request)
        seen = request
        return { status = 200, body = '{"ok":true,"receipt":{}}' }
    end,
}
local response, error_code = transport:activate{
    product = "webdavmanga-premium",
    key = "2345-6789-ABCD",
    device_id = string.rep("a", 64),
}
expect(response == nil and error_code == "invalid_response",
    "an activation response without a complete receipt must fail closed")
expect(seen.url == "https://license.example/activate"
    and seen.method == "POST" and seen.follow_redirects == false,
    "activation must use HTTPS POST without redirects")
expect(seen.timeout_seconds == 7 and seen.max_response_bytes == 128,
    "activation must propagate timeout and response size limits")
expect(seen.ca_file == "/data/ca-bundle.crt",
    "activation must propagate the configured CA bundle to the TLS adapter")
expect(seen.headers["Content-Type"] == "application/json"
    and seen.headers["Content-Length"] == #seen.body,
    "activation must send a bounded JSON request")
expect(not tostring(seen):find("a" .. string.rep("a", 20), 1, true),
    "request metadata must not stringify or log the raw device id")

local WebDavTransport = require("webdavmanga.transport")
local certificate = {
    extensions = function()
        return { ["2.5.29.17"] = { dNSName = { "license.example" } } }
    end,
    subject = function() return {} end,
}
expect(WebDavTransport.certificate_matches_hostname(certificate, "license.example"),
    "the activation adapter must retain the existing TLS hostname verifier")
expect(not WebDavTransport.certificate_matches_hostname(certificate, "evil.example"),
    "the activation adapter must reject a certificate for another host")

local function fake_json(body)
    if body == '{"ok":true,"receipt":{}}' then
        return { ok = true, receipt = {} }
    end
    if body == '{"ok":false,"error":"invalid_key"}' then
        return { ok = false, error = "invalid_key" }
    end
    return nil, "bad json"
end

local function new_transport(request, options)
    options = options or {}
    options.endpoint = options.endpoint or "https://license.example/activate"
    options.request = request
    options.json = options.json or { encode = function() return "{}" end, decode = fake_json }
    return LicenseTransport:new(options)
end

local insecure = new_transport(function() error("must not request HTTP") end,
    { endpoint = "http://license.example/activate" })
local insecure_result, insecure_error = insecure:activate({ product = "x" })
expect(insecure_result == nil and insecure_error == "https_required",
    "HTTP endpoints must be rejected before a request")

local redirect_seen
local redirect = new_transport(function(request)
    redirect_seen = request
    return { status = 302, headers = { location = "https://other.example" }, body = "" }
end)
local redirect_result, redirect_error = redirect:health()
expect(redirect_result == nil and redirect_error == "redirect_rejected"
    and redirect_seen.follow_redirects == false,
    "redirect responses must fail closed")

local oversized = new_transport(function()
    return { status = 200, body = string.rep("x", 20) }
end, { max_response_bytes = 8 })
local oversized_result, oversized_error = oversized:health()
expect(oversized_result == nil and oversized_error == "response_too_large",
    "responses over the configured bound must be rejected")

local malformed = new_transport(function()
    return { status = 200, body = "not-json" }
end)
local malformed_result, malformed_error = malformed:health()
expect(malformed_result == nil and malformed_error == "invalid_json",
    "invalid JSON must be mapped to a stable error code")

local unavailable = new_transport(function()
    return nil, "DNS lookup failed"
end)
local unavailable_result, unavailable_error = unavailable:health()
expect(unavailable_result == nil and unavailable_error == "dns_failed",
    "DNS failures must not escape the activation flow")

local timed_out = new_transport(function()
    return nil, "timeout while connecting"
end)
local timed_out_result, timed_out_error = timed_out:health()
expect(timed_out_result == nil and timed_out_error == "timeout",
    "timeouts must map to a stable error code")

local tls_failed = new_transport(function()
    return nil, "TLS certificate verify failed"
end)
local tls_result, tls_error = tls_failed:health()
expect(tls_result == nil and tls_error == "tls_failed",
    "TLS failures must map to a stable error code")

local http_error = new_transport(function()
    return { status = 401, body = '{"ok":false,"error":"invalid_key"}' }
end)
local http_result, http_error_code = http_error:activate({ product = "x" })
expect(http_result and http_result.ok == false and http_result.error == "invalid_key"
    and http_error_code == "invalid_key",
    "server license errors must remain structured and classified")

local successful_http_error = new_transport(function()
    return { status = 200, body = '{"ok":false,"error":"invalid_key"}' }
end)
local successful_result, successful_error = successful_http_error:activate({ product = "x" })
expect(successful_result and successful_result.ok == false
    and successful_error == "invalid_key",
    "a 2xx response carrying an explicit server error must remain classified")

print(("license_transport_spec: %d checks"):format(checks))
