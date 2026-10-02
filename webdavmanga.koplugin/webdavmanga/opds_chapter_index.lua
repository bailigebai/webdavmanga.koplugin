local Index = {}
Index.__index = Index

function Index:new(entries)
    return setmetatable({ entries = entries or {} }, self)
end

function Index:count() return #self.entries end
function Index:get(position) return self.entries[position] end

function Index:find(path)
    for position, entry in ipairs(self.entries) do
        if entry.path == path then return position end
    end
    return nil
end

function Index:window(center, radius)
    center = math.floor(tonumber(center) or 1)
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    local result = {}
    for position = math.max(1, center - radius), math.min(#self.entries, center + radius) do
        result[#result + 1] = self.entries[position]
    end
    return result
end

return Index
