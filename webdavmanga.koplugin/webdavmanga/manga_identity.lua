local Path = require("webdavmanga.path")

local Identity = {}

local function opds_component(value)
    return (value:gsub("([^A-Za-z0-9._~%-])", function(byte)
        return ("%%%02X"):format(byte:byte())
    end))
end

function Identity.opds_path(resource)
    if type(resource) ~= "table" then return nil end
    for _, key in ipairs({ "source_id", "series_id", "chapter_id" }) do
        if type(resource[key]) ~= "string" or resource[key] == ""
            or resource[key]:find("[%z\1-\31\127]") then return nil end
    end
    return "opds:" .. opds_component(resource.source_id) .. ":" .. opds_component(resource.series_id)
        .. ":" .. opds_component(resource.chapter_id)
end

function Identity.resource_path(value)
    if type(value) == "string" and value:sub(1, 5) == "opds:" then return value end
    return Path.normalize_remote(value or "")
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_server(value)
    local text = trim(value):gsub("\\", "/")
    if text ~= "" and not text:match("^%w+://$") then
        text = text:gsub("/+%s*$", "")
    end
    return text
end

local function normalize_local(value)
    local text = trim(value):gsub("\\", "/"):gsub("/+", "/")
    if #text > 1 then text = text:gsub("/+$", "") end
    return text
end

function Identity.normalize_connection(connection)
    if type(connection) ~= "table" then connection = {} end
    local kind = trim(connection.kind):lower()
    if kind ~= "webdav" and kind ~= "local" and kind ~= "nodeshare" and kind ~= "opds" then kind = "webdav" end
    local local_path = normalize_local(connection.local_path)
    local root_path = Path.normalize_remote(connection.root_path or "")
    local source_id = kind == "opds" and (connection.source_id or connection.id) or nil
    if kind == "local" then
        if local_path == "" then local_path = normalize_local(connection.root_path) end
        if root_path == "" then root_path = Path.normalize_remote(local_path) end
    end
    return {
        kind = kind,
        source_id = source_id,
        server_url = source_id and ("opds://source/" .. source_id) or normalize_server(connection.server_url),
        username = source_id and "" or trim(connection.username),
        root_path = root_path,
        local_path = local_path,
    }
end

local function connection_text(connection)
    local normalized = Identity.normalize_connection(connection)
    return table.concat({
        normalized.kind,
        normalized.server_url,
        normalized.username,
        normalized.root_path,
        normalized.local_path,
    }, "\0")
end

function Identity.connection(connection)
    return connection_text(connection)
end

function Identity.manga(connection, manga_path)
    if type(manga_path) == "string" and manga_path:sub(1, 5) == "opds:" then return manga_path end
    if type(connection) == "string" then
        local _, separators = connection:gsub("%z", "")
        if separators >= 5 then return connection end
        if separators == 2 then
            local server_url, username, root_path = connection:match("^(.-)%z(.-)%z(.*)$")
            connection = {
                kind = "webdav", server_url = server_url,
                username = username, root_path = root_path,
            }
        end
    end
    local base = type(connection) == "string" and connection or connection_text(connection)
    return base .. "\0" .. Path.normalize_remote(manga_path or "")
end

function Identity.connection_variants(connection)
    local normalized = Identity.normalize_connection(connection)
    local current = connection_text(normalized)
    if normalized.kind ~= "webdav" then
        return { current = current, legacy = current }
    end
    -- Records written before identity unification used this exact WebDAV form.
    local legacy = table.concat({
        normalized.server_url, normalized.username, normalized.root_path,
    }, "\0")
    return { current = current, legacy = legacy }
end

return Identity
