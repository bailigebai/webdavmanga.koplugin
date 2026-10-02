local Driver = {}
local Url = require("webdavmanga.opds_url")
local drivers = {
    kavita = require("webdavmanga.opds_drivers.kavita"),
    suwayomi = require("webdavmanga.opds_drivers.suwayomi"),
    komga = require("webdavmanga.opds_drivers.komga"),
}

local function safe_language_tag(value)
    if #value > 64 then return false end
    local language, rest = value:match("^([a-zA-Z]+)(.*)$")
    if not language or #language < 2 or #language > 3 then return false end
    if rest == "" then return true end
    if rest:sub(1, 1) ~= "-" or rest:sub(-1) == "-" or rest:find("--", 1, true) then return false end
    for part in rest:gmatch("[^-]+") do
        if #part > 8 or part:find("[^a-zA-Z0-9]") then return false end
    end
    return true
end

local function safe_query_value(key, value)
    if value == "{pageNumber}" or value == "{width}" or value == "{maxWidth}"
        or value == "{height}" or value == "{maxHeight}" then return true end
    if key == "seriesId" or key == "chapterId" or key == "bookId" then
        return value:match("^[%w_-]+$") ~= nil
    end
    if key == "width" or key == "maxWidth" or key == "height" or key == "maxHeight" then
        return value:match("^%d+$") ~= nil
    end
    if key == "page" or key == "pageNumber" or key == "size" then return value:match("^%d+$") ~= nil end
    if key == "opds" then return value == "true" or value == "false" end
    if key == "sort" then return value == "number_asc" or value == "number_desc" end
    if key == "lang" then return safe_language_tag(value) end
    return false
end

-- Placeholders are deliberately not request-ready: the page layer must resolve
-- them from the selected source, or fail closed when credentials are unavailable.
function Driver.redact_url(url)
    local parsed = Url.parse(url)
    if not parsed then return nil, false end
    local restore = url:find("{apiKey}", 1, true) ~= nil or url:find("{query:", 1, true) ~= nil
    if parsed.authority:find("@", 1, true) then restore = true end
    local authority = parsed.authority:match(".*@(.+)$") or parsed.authority
    local path, path_redacted = Url.redact_kavita_path(parsed.path)
    restore = restore or path_redacted
    local base = parsed.scheme .. "://" .. authority .. path
    local query = parsed.query
    if not query then return base, restore end
    local parts = {}
    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=(.*)$")
        key, value = key or pair, value or ""
        if not key:match("^[%w_-]+$") then
            key = "redacted" .. tostring(#parts + 1)
        end
        if not safe_query_value(key, value) then
            value = "{query:" .. key .. "}"
            restore = true
        end
        parts[#parts + 1] = key .. "=" .. value
    end
    return base .. "?" .. table.concat(parts, "&"), restore
end

function Driver.resolve(connection, context, entry, metadata_feed)
    connection, context, entry = connection or {}, context or {}, entry or {}
    if type(connection.id) ~= "string" or connection.id == "" then return nil, "missing_source_id" end
    local kind = connection.server_kind or "auto"
    if kind == "auto" then
        local evidence = { feed = context.feed or metadata_feed, feed_url = context.feed_url or connection.server_url }
        for _, candidate in ipairs({ "kavita", "suwayomi", "komga" }) do
            if drivers[candidate].detect(evidence) then
                if kind ~= "auto" then return nil, "ambiguous_server" end
                kind = candidate
            end
        end
    end
    local driver = drivers[kind]
    if not driver then return nil, "unsupported_server" end
    local resolved, err = driver.resolve(connection, context, entry, metadata_feed)
    if not resolved then return nil, err end
    local stream = resolved.stream
    if type(stream) ~= "table" then return nil, "missing_stream" end
    local count = stream.count
    if type(count) ~= "number" or count ~= count or count < 1 or count > 100000 or count ~= math.floor(count) then
        return nil, "invalid_page_count"
    end
    if not Url.parse(stream.template) then return nil, "invalid_stream_template" end
    if type(resolved.chapter_id) ~= "string" or resolved.chapter_id == "" then return nil, "missing_chapter_id" end
    local descriptor = {
        source_id = connection.id, server_kind = kind,
        series_id = resolved.series_id, series_name = resolved.series_name or context.series_name,
        chapter_id = resolved.chapter_id, chapter_name = resolved.chapter_name or entry.name,
        page_count = count,
    }
    local last_read = stream.last_read
    if type(last_read) == "number" and last_read >= 0 and last_read <= count
        and last_read == math.floor(last_read) then descriptor.server_last_read = last_read end
    for key, url in pairs({ stream_template = stream.template,
        cover_url = resolved.cover_url or entry.image_url,
        series_cover_url = resolved.series_cover_url or context.series_cover_url,
        series_feed_url = resolved.series_feed_url }) do
        local clean, restore = Driver.redact_url(url)
        descriptor[key] = clean
        if restore then descriptor.requires_source_restore = true end
    end
    local request = Url.parse(descriptor.stream_template)
    if not request or not (request.path .. "?" .. (request.query or "")):find("{pageNumber}", 1, true) then
        return nil, "invalid_stream_template"
    end
    return descriptor
end

return Driver
