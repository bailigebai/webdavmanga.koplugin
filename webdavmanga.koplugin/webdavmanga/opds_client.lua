local Errors = require("webdavmanga.errors")
local Parser = require("webdavmanga.opds_parser")
local Url = require("webdavmanga.opds_url")

local Client = {}
Client.__index = Client

local function transport_error(status)
    local lowered = tostring(status or ""):lower()
    local err
    if lowered:find("tls", 1, true) or lowered:find("certificate", 1, true) then
        err = Errors.transport("tls")
        err.reason = "tls"
    elseif lowered:find("timeout", 1, true) or lowered:find("timed out", 1, true) then
        err = Errors.transport("request_timeout")
        err.reason = "request_timeout"
    elseif lowered == "response exceeds maximum image size" then
        err = Errors.decode("catalog_too_large")
        err.reason = "catalog_too_large"
    elseif lowered:find("connection refused", 1, true) then
        err = Errors.transport("server_unavailable")
        err.reason = "server_unavailable"
    else
        err = Errors.transport("catalog_request_failed")
        err.reason = "catalog_request_failed"
    end
    return err
end

function Client:new(options)
    options = options or {}
    return setmetatable({
        transport = assert(options.transport, "transport is required"),
        maximum_bytes = math.floor(tonumber(options.maximum_bytes) or 4 * 1024 * 1024),
        parser = options.parser or Parser,
    }, self)
end

function Client:fetch(url, auth, source_url)
    local target = Url.request_target(source_url or url, url)
    if not target then return nil, Errors.transport("unsafe_catalog_url") end
    url = target
    local code, headers, status, body = self.transport:get_bytes(
        url, auth or {}, self.maximum_bytes)
    if type(code) ~= "number" then return nil, transport_error(status) end
    if code < 200 or code >= 300 then return nil, Errors.http(code, "catalog_request_failed") end
    if type(body) ~= "string" or #body < 1 or #body > self.maximum_bytes then
        return nil, Errors.decode("invalid OPDS response")
    end
    local catalog, parse_error = self.parser.parse(body, url)
    if not catalog then return nil, Errors.decode(parse_error) end
    if catalog.is_atom_feed ~= true then
        return nil, Errors.decode("invalid Atom feed")
    end
    catalog.headers = headers or {}
    return catalog
end

return Client
