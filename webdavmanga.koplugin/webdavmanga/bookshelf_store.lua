-- The generated cache registry is data, never executable Lua. Compact JSON
-- also lets Cache budget the exact registration bytes before a new publish.
local Store = {}; Store.__index = Store

function Store:new(options)
    local o = setmetatable({}, self)
    o.path = assert(options.path)
    o.fs = options.fs or {open=io.open, rename=os.rename, remove=os.remove}
    o.json = options.json or require("json")
    o.data = {schema_version=3, entries={}}
    local file = o.fs.open(o.path, "rb")
    if file then
        local bytes = file:read(16 * 1024 * 1024 + 1); file:close()
        if type(bytes) == "string" and #bytes <= 16 * 1024 * 1024 then
            local ok, decoded = pcall(o.json.decode, bytes)
            if ok and type(decoded) == "table" then o.data = decoded end
        end
    end
    return o
end

function Store:readSetting(key, default)
    if self.data[key] == nil then return default end
    return self.data[key]
end
function Store:saveSetting(key, value) self.data[key] = value end

function Store:cache_index_size(entries)
    local data = {}; for k,v in pairs(self.data) do data[k] = v end
    data.entries = entries
    local ok, bytes = pcall(self.json.encode, data)
    if not ok or type(bytes) ~= "string" then return math.huge end
    return #bytes
end

function Store:flush()
    local ok, bytes = pcall(self.json.encode, self.data)
    if not ok or type(bytes) ~= "string" or #bytes > 16 * 1024 * 1024 then return false end
    local part = self.path .. ".part"
    local file = self.fs.open(part, "wb")
    if not file then return false end
    local wrote, result = pcall(file.write, file, bytes)
    local closed, close_result = pcall(file.close, file)
    if not wrote or not result or not closed or close_result == false
        or not self.fs.rename(part, self.path) then
        self.fs.remove(part)
        return false
    end
    return true
end

return Store
