local Suwayomi = {}
local Url = require("webdavmanga.opds_url")

function Suwayomi.detect(context)
    return Url.server_evidence(context, "suwayomi")
end

local function chapter_id(id)
    if type(id) ~= "string" or not id:match("^urn:[^%s]+$") then return nil end
    if id:match(":metadata:remote$") then return (id:gsub(":metadata:remote$", "", 1)) end
    return (id:gsub(":metadata$", "", 1))
end

function Suwayomi.resolve(connection, context, entry, metadata_feed)
    local id = chapter_id(entry.id)
    if not id then return nil, "missing_chapter_id" end
    local item = entry
    if not item.stream then
        if not metadata_feed then return nil, "metadata_required" end
        item = nil
        for _, candidate in ipairs(metadata_feed.entries or {}) do
            if candidate.stream and chapter_id(candidate.id) == id then
                if item then return nil, "metadata_choice_required" end
                item = candidate
            end
        end
        if not item then return nil, "chapter_identity_mismatch" end
    end
    return { chapter_id = id, stream = item.stream, cover_url = item.image_url,
        chapter_name = entry.name or item.name, series_id = context.series_id,
        series_feed_url = context.series_feed_url or context.feed_url }
end

return Suwayomi
