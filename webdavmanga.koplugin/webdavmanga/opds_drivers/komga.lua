local Komga = {}
local Url = require("webdavmanga.opds_url")

function Komga.detect(context)
    return Url.server_evidence(context, "komga", "/opds/v1.2")
end

function Komga.resolve(connection, context, entry, metadata)
    local stream = entry.stream
    local path = tostring(stream and stream.template or ""):match("^[^?#]+") or ""
    local id = path:match("/books/([%w_-]+)/pages/")
    if not id then return nil, "missing_chapter_id" end
    local feed_url = context.series_feed_url or context.feed_url
    local feed_path = tostring(feed_url or ""):match("^[^?#]+") or ""
    local series_id = feed_path:match("/series/([%w_-]+)/?$")
    local series_feed_url = series_id and feed_url or nil
    if metadata then
        if metadata.id ~= id then return nil, "chapter_identity_mismatch" end
        if series_id and metadata.seriesId and metadata.seriesId ~= series_id then
            return nil, "series_identity_mismatch"
        end
        if not series_id and type(metadata.seriesId) == "string" and metadata.seriesId:match("^[%w_-]+$") then
            series_id = metadata.seriesId
        end
    end
    return { chapter_id = id, series_id = series_id, stream = stream,
        series_feed_url = series_feed_url }
end

return Komga
