local Errors = require("webdavmanga.errors")
local Parser = require("webdavmanga.opds_parser")
local Url = require("webdavmanga.opds_url")

local Client = {}
Client.__index = Client

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
    if type(code) ~= "number" then return nil, Errors.transport("catalog_request_failed") end
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
