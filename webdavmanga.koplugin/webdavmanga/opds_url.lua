local Url = {}

-- This is the sole authenticated catalog request boundary. Do not report the
-- rejected value: a path or query can contain an API key.
local function origin(value)
    if type(value) ~= "string" or value:find("[%s%z\1-\31\127\\]") then return nil end
    local scheme, authority = value:match("^([%a][%w+.-]*)://([^/?#]+)")
    scheme = scheme and scheme:lower()
    if (scheme ~= "http" and scheme ~= "https") or not authority
        or authority:find("[@%%]") then return nil end
    local host, port
    if authority:sub(1,1) == "[" then
        host, port = authority:match("^(%[[%x:%.]+%]):(%d+)$")
        host = host or authority:match("^(%[[%x:%.]+%])$")
        if not host or not host:find(":",1,true) then return nil end
    else
        host, port = authority:match("^([%w%.%-]+):(%d+)$")
        host = host or authority:match("^([%w%.%-]+)$")
        if not host or host:find("..",1,true) or host:sub(1,1) == "." then return nil end
    end
    port = port and tonumber(port) or (scheme == "https" and 443 or 80)
    if port < 1 or port > 65535 then return nil end
    return scheme .. "://" .. host:lower() .. ":" .. tostring(port)
end

function Url.request_target(source_url, target)
    local expected = origin(source_url)
    if not expected or type(target) ~= "string" or target == ""
        or target:find("[%s%z\1-\31\127\\]") or target:sub(1,2) == "//" then
        return nil, "unsafe_catalog_url"
    end
    if not target:match("^[%a][%w+.-]*:") then
        local base, path = source_url:match("^([%a][%w+.-]*://[^/?#]+)([^?#]*)")
        if target:sub(1,1) == "/" then target = base .. target
        elseif target:sub(1,1) == "?" then target = base .. path .. target
        else target = base .. (path:match("^(.*)/") or "") .. "/" .. target end
    end
    if origin(target) ~= expected then return nil, "unsafe_catalog_url" end
    return target:gsub("#.*$", "")
end

function Url.parse(value)
    if type(value) ~= "string" then return nil end
    local scheme, authority, path, rest = value:match("^([%a][%w+.-]*)://([^/?#]*)([^?#]*)(.*)$")
    scheme = scheme and scheme:lower()
    if (scheme ~= "http" and scheme ~= "https") or authority == "" then return nil end
    rest = rest:gsub("#.*$", "")
    return { scheme = scheme, authority = authority, path = path, query = rest:match("^%?(.*)$") }
end

local function decoded_path(path)
    return (path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function Url.redact_kavita_path(path)
    local parts, previous, before_previous, changed = {}, nil, nil, false
    -- Only literal slashes delimit segments. An escaped slash inside the key is
    -- secret key data; decoding it must never leave a suffix outside redaction.
    for segment in (path .. "/"):gmatch("(.-)/") do
        if before_previous == "api" and previous == "opds" and segment ~= "" then
            parts[#parts + 1], changed = "{apiKey}", true
        else
            parts[#parts + 1] = segment
        end
        before_previous, previous = previous, decoded_path(segment):lower()
    end
    return table.concat(parts, "/"), changed
end

function Url.server_evidence(context, server, route)
    local author = tostring((context.feed or {}).author or ""):lower()
    if author:match("%f[%w_]" .. server .. "%f[^%w_]") then return true end
    local parsed = Url.parse(context.feed_url)
    if not parsed then return false end
    local path = decoded_path(parsed.path):lower()
    local start = 1
    while true do
        local _, last = path:find(route, start, true)
        if not last then return false end
        local following = path:sub(last + 1, last + 1)
        if following == "" or following == "/" then return true end
        start = last + 1
    end
end

return Url
