local Navigation = {}
Navigation.__index = Navigation
local NaturalSort = require("webdavmanga.natural_sort")

function Navigation:new(options)
    options = options or {}
    return setmetatable({ cancel = options.cancel, open_entry = options.open_entry, extend = options.extend,
        is_current = options.is_current, list_local = options.list_local }, self)
end

local function parent(path) return tostring(path):match("^(.*)/[^/]+$") end
function Navigation:neighbors(context)
    context = context or {}
    local entries = context.entries or {}
    if context.kind == "local" then
        local directory = parent(context.path)
        if self.list_local then entries = self.list_local(directory) or {} end
        local filtered = {}
        for _, entry in ipairs(entries) do
            if directory and parent(entry.path) == directory and not entry.is_folder
                and tostring(entry.path):lower():match("%.cbz$") then
                filtered[#filtered + 1] = entry
            end
        end
        NaturalSort.sort(filtered, function(entry) return entry.name or entry.path end)
        entries = filtered
    end
    local neighbors = {}
    for index, entry in ipairs(entries) do
        local current = context.kind == "opds" and entry.chapter_id == context.chapter_id
            or context.kind == "local" and entry.path == context.path
        if current then
            neighbors.previous, neighbors.next = entries[index - 1], entries[index + 1]
            if not neighbors.previous and context.previous_available then
                neighbors.previous = { lazy = true, chapter_name = "上一目录页中的章节" }
            end
            if not neighbors.next and context.next_available then
                neighbors.next = { lazy = true, chapter_name = "下一目录页中的章节" }
            end
            break
        end
    end
    self.current = neighbors
    return neighbors
end

function Navigation:open(direction)
    if self.is_current and not self.is_current() then return false end
    local entry = self.current and self.current[direction]
    if not entry or type(self.open_entry) ~= "function" then return false end
    if self.cancel then self.cancel() end
    local page
    if entry.lazy then
        if not self.extend then return false end
        local pending
        entry, page, pending = self.extend(direction)
        if pending then return true end
        if not entry then return false end
    end
    return self.open_entry(entry, page) == true
end

function Navigation:auto_next(index, count)
    if type(count) ~= "number" or count < 1 or index ~= count then return false end
    return self:open("next")
end

function Navigation.local_context(context, connection, list_local, open_entry)
    local chapter = context and context.chapter
    if not connection or connection.kind ~= "local" or not chapter
        or not tostring(chapter.path):lower():match("%.cbz$") then return context end
    local navigation = Navigation:new{ list_local = list_local, open_entry = open_entry }
    navigation.series_key = "local\0" .. tostring(parent(chapter.path))
    navigation:neighbors{ kind = "local", path = chapter.path }
    context.connection = connection
    context.source_context = context.source_context or {}
    context.source_context.navigation = navigation
    return context
end

return Navigation
