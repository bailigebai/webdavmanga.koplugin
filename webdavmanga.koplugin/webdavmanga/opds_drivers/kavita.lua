local Kavita = {}
local Url = require("webdavmanga.opds_url")

function Kavita.detect(context)
    return Url.server_evidence(context, "kavita")
end

local function query_id(url, wanted)
    local query = tostring(url or ""):match("%?([^#]*)") or ""
    local found
    for key, value in query:gmatch("([^&=]+)=([^&]*)") do
        if key == wanted then
            if not value:match("^%d+$") or (found and found ~= value) then return nil end
            found = value
        end
    end
    return found
end

function Kavita.resolve(connection, context, entry)
    local stream = entry.stream
    local template = stream and stream.template
    local chapter_id = query_id(template, "chapterId")
    if not chapter_id then return nil, "missing_chapter_id" end
    return { chapter_id = chapter_id, series_id = query_id(template, "seriesId"), stream = stream,
        series_feed_url = context.series_feed_url }
end

return Kavita
