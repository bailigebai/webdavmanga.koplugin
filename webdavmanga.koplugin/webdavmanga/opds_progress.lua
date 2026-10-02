local Progress = {}
Progress.__index = Progress

function Progress:new(options)
    return setmetatable({ highest = {}, store = options and options.progress_store }, self)
end

-- PSE lastRead and Komga's read-progress page are counts (one based).
-- Reserve monotonically before dispatch so an older callback cannot send a
-- backwards write. A failed write is retried only on a later forward page.
function Progress:on_page(desc, index)
    if desc.server_kind == "kavita" then return { read_only = true } end
    if desc.server_kind ~= "komga" then return nil end
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0
        or index > (tonumber(desc.page_count) or 0) then return nil end
    local key = tostring(desc.source_id) .. "\0" .. tostring(desc.series_id) .. "\0" .. tostring(desc.chapter_id)
    local highest = math.max(self.highest[key] or 0, tonumber(desc.server_last_read) or 0)
    if self.store then highest = math.max(highest, self.store:server_page(desc)) end
    local base, book = tostring(desc.stream_template):match("^(.-)/books/([^/]+)/pages/")
    if not base or book ~= desc.chapter_id or not book:match("^[%w_-]+$") then return nil end
    if self.store and not self.store:reserve_server_page(desc, math.max(highest, index)) then return nil end
    if index <= highest then return nil end
    self.highest[key] = index
    return { method = "PATCH", source_id = desc.source_id,
        url = base .. "/books/" .. book .. "/read-progress",
        body = { page = index, completed = index == desc.page_count } }
end

return Progress
