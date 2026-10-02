local Resume = {}
local PRELOAD_TOLERANCE = 5

local function page(position)
    local value = position and tonumber(position.page)
    if not value or value ~= value or value == math.huge or value < 1 then return nil end
    return math.floor(value)
end

local function action(kind, position, fallback_name)
    local name = position.chapter_name or fallback_name or position.chapter_id
    local prefix = kind == "start" and "从头阅读 — "
        or (kind == "server" and "▶ 服务器继续 — " or "继续 — ")
    local values = { kind = kind, chapter_id = position.chapter_id, page = page(position),
        label = prefix .. tostring(name) .. "，第 " .. tostring(page(position)) .. " 页" }
    return setmetatable({}, { __index = values,
        __newindex = function() error("resume actions are immutable", 2) end,
        __metatable = false })
end

function Resume.choices(descriptor, local_position, server_position)
    local start = { chapter_id = descriptor.chapter_id, page = 1, chapter_name = descriptor.chapter_name }
    local result = { action("start", start) }
    local baseline = start
    if page(local_position) and type(local_position.chapter_id) == "string" then
        result[#result + 1] = action("local", local_position,
            local_position.chapter_id == descriptor.chapter_id and descriptor.chapter_name or nil)
        baseline = local_position
    end
    if not page(server_position) then return result end
    local ahead = false
    if server_position.chapter_id == baseline.chapter_id then
        ahead = page(server_position) > page(baseline) + PRELOAD_TOLERANCE
    else
        local order = {}
        for index, chapter in ipairs(descriptor.chapter_order or {}) do
            order[type(chapter) == "table" and chapter.chapter_id or chapter] = index
        end
        local current, remote = order[baseline.chapter_id], order[server_position.chapter_id]
        ahead = current ~= nil and remote ~= nil and remote > current
    end
    if ahead then
        result[#result + 1] = action("server", server_position,
            server_position.chapter_id == descriptor.chapter_id and descriptor.chapter_name or nil)
    end
    return result
end

function Resume.series_target(chapters, local_position)
    for _, chapter in ipairs(chapters or {}) do
        if chapter.is_read == false then return chapter end
    end
    if local_position then
        for _, chapter in ipairs(chapters or {}) do
            if chapter.chapter_id == local_position.chapter_id then return chapter end
        end
    end
    return nil
end

return Resume
