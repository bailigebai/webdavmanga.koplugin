local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Errors = require("webdavmanga.errors")

local expected = {
    invalid_key = "密钥无效",
    key_bound_to_other_device = "已绑定到其他设备",
    rate_limited = "请求过于频繁",
    origin_not_allowed = "当前网络来源不被允许",
    method_not_allowed = "请求方法不被允许",
    service_unavailable = "授权服务暂时不可用",
    https_required = "授权连接必须使用 HTTPS",
    dns_failed = "无法解析授权服务器地址",
    timeout = "授权请求超时",
    tls_failed = "授权服务器证书验证失败",
    invalid_json = "授权服务返回的数据无效",
    response_too_large = "授权服务响应过大",
    redirect_rejected = "授权服务拒绝重定向",
}

for code, phrase in pairs(expected) do
    local err = Errors.license(code)
    local message = Errors.message(err)
    expect(type(message) == "string" and message:find(phrase, 1, true) ~= nil,
        "license error " .. code .. " should have a Chinese user message")
end

local secret = Errors.message(Errors.license("invalid_key", "raw-key-secret"))
expect(not secret:find("raw%-key%-secret"),
    "license error details must not expose raw keys or device identifiers")

expect(Errors.message(Errors.license("unknown_server_error")):find("授权", 1, true) ~= nil,
    "unknown license errors should remain actionable")

print(("license_error_spec: %d checks"):format(checks))
