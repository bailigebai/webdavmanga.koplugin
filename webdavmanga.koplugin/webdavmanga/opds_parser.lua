local Parser = {}
local PSE_STREAM = "http://vaemendis.net/opds-pse/stream"

local ENTITY = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function unescape(value)
    value = tostring(value or "")
    return value:gsub("&([^;]+);", function(entity)
        local named = ENTITY[entity]
        if named then return named end
        local hex = entity:match("^#x([%da-fA-F]+)$")
        local decimal = entity:match("^#(%d+)$")
        local codepoint = hex and tonumber(hex, 16) or decimal and tonumber(decimal)
        if not codepoint or codepoint < 0 or codepoint > 255 then return "&" .. entity .. ";" end
        return string.char(codepoint)
    end)
end

local function attributes(source)
    local result = {}
    for key, quote, value in tostring(source or ""):gmatch(
        "([%w:_-]+)%s*=%s*([\"'])(.-)%2") do
        result[key] = unescape(value)
    end
    return result
end

local function local_attribute(attrs, wanted)
    if attrs[wanted] ~= nil then return attrs[wanted] end
    for key, value in pairs(attrs) do
        if key:match("[:_]" .. wanted .. "$") then return value end
    end
end

local function integer(value)
    local number = tonumber(value)
    if number and number == number and number < math.huge and number == math.floor(number) then
        return number
    end
end

local function strip_query(path)
    return (path:gsub("[?#].*$", ""))
end

local function normalize_path(path)
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return prefix .. table.concat(parts, "/")
end

local function resolve(base, href)
    href = unescape(href)
    if href:match("^%a[%w+.-]*://") then return href end
    local scheme, authority, path = tostring(base or ""):match("^(%a[%w+.-]*://)([^/]+)(/.*)$")
    if not scheme then return href end
    -- Keep network-path references recognizable so the request boundary can
    -- reject them before source credentials are attached.
    if href:sub(1, 2) == "//" then return href end
    if href:sub(1, 1) == "?" then return scheme .. authority .. strip_query(path) .. href end
    if href:sub(1, 1) == "/" then return scheme .. authority .. normalize_path(href) end
    local base_path = strip_query(path)
    local directory = base_path:match("^(.*)/") or ""
    return scheme .. authority .. normalize_path(directory .. "/" .. href)
end

local function text_of(body, tag)
    local value = body:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    return value and unescape(value:gsub("<[^>]+>", "")):gsub("^%s*(.-)%s*$", "%1") or nil
end

local function links_of(body, base)
    local links = {}
    for raw in body:gmatch("<link%s+([^>]-)/?>") do
        local link = attributes(raw)
        if link.href then
            link.href = resolve(base, link.href)
            links[#links + 1] = link
        end
    end
    return links
end

local function is_image_link(link)
    local rel = tostring(link.rel or ""):lower()
    local kind = tostring(link.type or ""):lower()
    if rel == PSE_STREAM then return false end
    return rel == "http://opds-spec.org/image"
        or rel == "http://opds-spec.org/cover"
        or rel == "http://opds-spec.org/thumbnail"
        or kind:match("^image/") ~= nil
end

local function classify(links, image_url, stream)
    if stream then return "volume" end
    for _, link in ipairs(links) do
        local rel = tostring(link.rel or ""):lower()
        if rel == "subsection" or rel == "http://opds-spec.org/subsection"
            or rel == "http://opds-spec.org/crawlable" then
            return "series"
        end
    end
    if image_url then return "page" end
    return "volume"
end

local ATOM_NAMESPACE = "http://www.w3.org/2005/Atom"

local function has_atom_root(xml)
    local root, raw_attributes, after_open = xml:match("^%s*<([%w_:.-]+)([^>]*)>()")
    if not root then return false end
    local prefix = root:match("^([%w_.-]+):feed$")
    if root ~= "feed" and not prefix then return false end
    local namespace_key = prefix and ("xmlns:" .. prefix) or "xmlns"
    if attributes(raw_attributes)[namespace_key] ~= ATOM_NAMESPACE then return false end
    if raw_attributes:match("/%s*$") then
        return xml:find("%S", after_open) == nil
    end
    local escaped_root = root:gsub("(%W)", "%%%1")
    local _, after_close = xml:find("</" .. escaped_root .. "%s*>", after_open)
    return after_close ~= nil and xml:find("%S", after_close + 1) == nil
end

function Parser.parse(xml, base_url)
    if type(xml) ~= "string" or xml == "" then return nil, "empty OPDS response" end
    xml = xml:gsub("^\239\187\191", "")
        :gsub("<%?xml.-%?>", ""):gsub("<!%-%-.-%-%->", "")
    local is_atom_feed = has_atom_root(xml)
    xml = xml:gsub("<(/?)[%a_][%w_.-]*:", "<%1")
    local feed_body = xml:gsub("<entry[^>]*>.-</entry%s*>", "")
    local catalog = {
        id = text_of(feed_body, "id"),
        title = text_of(feed_body, "title") or "OPDS",
        author = text_of(feed_body:match("<author[^>]*>(.-)</author>") or "", "name"),
        entries = {},
        is_atom_feed = is_atom_feed,
        next_url = nil,
        search_url = nil,
    }
    for raw in feed_body:gmatch("<link%s+([^>]-)/?>") do
        local link = attributes(raw)
        if link.href and link.rel == "next" then catalog.next_url = resolve(base_url, link.href) end
        if link.href and (link.rel == "previous" or link.rel == "prev") then
            catalog.previous_url = resolve(base_url, link.href)
        end
        if link.href and is_image_link(link) and not catalog.image_url then
            catalog.image_url = resolve(base_url, link.href)
        end
        if link.href and link.rel == "search" then catalog.search_url = resolve(base_url, link.href) end
    end
    for body in xml:gmatch("<entry[^>]*>(.-)</entry%s*>") do
        local links = links_of(body, base_url)
        local image_url
        local href
        local stream
        for _, link in ipairs(links) do
            if is_image_link(link) and not image_url then image_url = link.href end
            local rel = tostring(link.rel or ""):lower()
            if rel == PSE_STREAM then
                stream = { template = link.href, count = integer(local_attribute(link, "count")),
                    last_read = integer(local_attribute(link, "lastRead")), type = link.type }
            end
            if not href and (rel == "subsection" or rel == "http://opds-spec.org/subsection"
                or rel:match("acquisition") or rel == "http://vaemendis.net/opds-pse/stream") then
                href = link.href
            end
        end
        catalog.entries[#catalog.entries + 1] = {
            id = text_of(body, "id") or href,
            name = text_of(body, "title") or "未命名",
            kind = classify(links, image_url, stream),
            stream = stream,
            href = href,
            image_url = image_url,
            links = links,
            content = text_of(body, "content"),
        }
    end
    return catalog
end

Parser.resolve = resolve

return Parser
