local Nodeshare = {}
Nodeshare.__index = Nodeshare

Nodeshare.DEFAULT_WEBDAV_PORT = 5005
Nodeshare.DEFAULT_TCP_TIMEOUT = 5

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function as_error(code, detail)
    local result = { code = code }
    if detail ~= nil then result.detail = tostring(detail) end
    return result
end

local function valid_ipv4(host)
    local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    for _, part in ipairs({ a, b, c, d }) do
        local number = tonumber(part)
        if not number or number > 255 then return false end
    end
    return true
end

local function valid_host(host)
    if host == "" or host:find("%s") or host:find("[%z/\\@%?#]") then return false end
    local ipv4 = valid_ipv4(host)
    if ipv4 ~= nil then return ipv4 end
    if host:find(":", 1, true) then
        return host:match("^[0-9a-fA-F:%.]+$") ~= nil
    end
    return host:match("^[%w%._%-]+$") ~= nil
end

local function parse_authority(authority, scheme)
    if authority:find("@", 1, true) then
        return nil, as_error("invalid_nodeshare_url", "credentials are not allowed in the URL")
    end

    local host, raw_port
    if authority:sub(1, 1) == "[" then
        host, raw_port = authority:match("^%[([^%]]+)%]:?(%d*)$")
    else
        host, raw_port = authority:match("^([^:]+):?(%d*)$")
    end
    if not host or not valid_host(host) then
        return nil, as_error("invalid_nodeshare_url", "invalid host")
    end

    local port
    if raw_port and raw_port ~= "" then
        port = tonumber(raw_port)
    else
        port = scheme == "https" and 443 or 80
    end
    if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
        return nil, as_error("invalid_port")
    end
    return { host = host, port = port }
end

function Nodeshare:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.socket = options.socket
    object.timeout = tonumber(options.timeout) or Nodeshare.DEFAULT_TCP_TIMEOUT
    return object
end

function Nodeshare:parse_endpoint(server_url)
    local value = trim(server_url):gsub("/+$", "")
    if value:find("?", 1, true) or value:find("#", 1, true) then
        return nil, as_error("invalid_nodeshare_url", "query and fragment are not allowed")
    end
    local scheme, authority = value:match("^(https?)://([^/%?#]+)")
    if not scheme or not authority then
        return nil, as_error("invalid_nodeshare_url")
    end
    local endpoint, parse_error = parse_authority(authority, scheme)
    if not endpoint then return nil, parse_error end
    endpoint.scheme = scheme
    endpoint.server_url = value
    return endpoint
end

function Nodeshare:probe(server_url)
    local endpoint, endpoint_error = self:parse_endpoint(server_url)
    if not endpoint then return nil, endpoint_error end

    local socket_module = self.socket
    if not socket_module then
        local loaded, module = pcall(require, "socket")
        if not loaded then return nil, as_error("tcp_unavailable") end
        socket_module = module
    end
    if type(socket_module) ~= "table" or type(socket_module.tcp) ~= "function" then
        return nil, as_error("tcp_unavailable")
    end

    local created, socket_or_error, create_detail = pcall(socket_module.tcp)
    if not created or not socket_or_error then
        return nil, as_error("tcp_unavailable", created and create_detail or socket_or_error)
    end
    local tcp = socket_or_error
    local function close_socket()
        if tcp and type(tcp.close) == "function" then pcall(tcp.close, tcp) end
        tcp = nil
    end

    if type(tcp.settimeout) == "function" then
        local timeout_ok = pcall(tcp.settimeout, tcp, self.timeout)
        if not timeout_ok then
            close_socket()
            return nil, as_error("tcp_unavailable")
        end
    end
    local called, connected, connect_error = pcall(
        tcp.connect, tcp, endpoint.host, endpoint.port)
    close_socket()
    if not called or not connected then
        return nil, as_error("tcp_unreachable", called and connect_error or connected)
    end
    return true, endpoint
end

function Nodeshare.metadata(endpoint)
    if type(endpoint) ~= "table" then return nil end
    return {
        mode = "tcp",
        host = endpoint.host,
        port = endpoint.port,
        scheme = endpoint.scheme,
    }
end

return Nodeshare
