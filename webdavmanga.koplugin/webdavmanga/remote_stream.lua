local RemoteStream = {}
RemoteStream.__index = RemoteStream

local DEFAULT_BLOCK_SIZE = 64 * 1024
local DEFAULT_MAX_BLOCKS = 8

local function header_value(headers, wanted)
    wanted = tostring(wanted or ""):lower()
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == wanted then return value end
    end
    return nil
end

local function parse_content_range(value)
    if type(value) ~= "string" then return nil end
    local first, last, total = value:match(
        "^%s*bytes%s+(%d+)%-(%d+)%/(%d+)%s*$")
    first, last, total = tonumber(first), tonumber(last), tonumber(total)
    if not first or not last or not total or first < 0 or last < first
        or total <= last then
        return nil
    end
    return first, last, total
end

local function integer(value, fallback)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or value < 1 or math.floor(value) ~= value then
        return fallback
    end
    return value
end

function RemoteStream:new(options)
    options = options or {}
    local size = tonumber(options.size)
    if not size or size <= 0 or math.floor(size) ~= size then
        return nil, "invalid_remote_size"
    end
    if type(options.read_range) ~= "function" then
        return nil, "range_reader_unavailable"
    end
    local object = setmetatable({}, self)
    object.size = size
    object.read_range = options.read_range
    object.block_size = math.max(1, math.min(
        integer(options.block_size, DEFAULT_BLOCK_SIZE), 1024 * 1024))
    object.max_blocks = math.max(1, math.min(
        integer(options.max_blocks, DEFAULT_MAX_BLOCKS), 64))
    object.strict_range = options.strict_range ~= false
    object.exact_reads = options.exact_reads == true
    object.blocks = {}
    object.clock = 0
    object.hits = 0
    object.misses = 0
    return object
end

function RemoteStream:_touch(index, block)
    self.clock = self.clock + 1
    block.used = self.clock
    self.blocks[index] = block
end

function RemoteStream:_evict_if_needed()
    local count = 0
    for _ in pairs(self.blocks) do count = count + 1 end
    while count > self.max_blocks do
        local oldest_index, oldest_used
        for index, block in pairs(self.blocks) do
            if not oldest_used or block.used < oldest_used then
                oldest_index, oldest_used = index, block.used
            end
        end
        if oldest_index == nil then break end
        self.blocks[oldest_index] = nil
        count = count - 1
    end
end

function RemoteStream:_read_range(first, last)
    local body, headers, detail = self.read_range(first, last)
    if type(body) ~= "string" then
        return nil, detail or "range_request_failed"
    end
    local expected = last - first + 1
    if #body ~= expected then
        return nil, "range_length_mismatch"
    end

    local response_first, response_last, response_total = parse_content_range(
        header_value(headers, "content-range"))
    if self.strict_range and not response_first then
        return nil, "content_range_missing"
    end
    if response_first then
        if response_first ~= first or response_last ~= last
            or response_total ~= self.size then
            return nil, "content_range_mismatch"
        end
    end
    return body
end

function RemoteStream:_fetch(index)
    local cached = self.blocks[index]
    if cached then
        self.hits = self.hits + 1
        self:_touch(index, cached)
        return cached
    end

    self.misses = self.misses + 1
    local first = index * self.block_size
    if first >= self.size then return nil, "range_past_eof" end
    local last = math.min(self.size - 1, first + self.block_size - 1)
    local body, error_message = self:_read_range(first, last)
    if not body then return nil, error_message end

    local block = { first = first, last = last, data = body }
    self:_touch(index, block)
    self:_evict_if_needed()
    return block
end

-- Return a bounded byte slice beginning at an absolute file offset.
-- The native stream adapter calls this without ever asking for the whole file.
function RemoteStream:read_at(offset, max_bytes)
    offset = tonumber(offset)
    if not offset or offset ~= math.floor(offset) or offset < 0 then
        return nil, "invalid_range_offset"
    end
    if offset >= self.size then return "" end

    if self.exact_reads then
        local count = tonumber(max_bytes)
        if not count or count <= 0 or count ~= math.floor(count) then
            return nil, "invalid_range_length"
        end
        local last = math.min(self.size - 1, offset + count - 1)
        return self:_read_range(offset, last)
    end

    local index = math.floor(offset / self.block_size)
    local block, error_message = self:_fetch(index)
    if not block then return nil, error_message end
    local relative = offset - block.first
    local available = #block.data - relative
    local limit = tonumber(max_bytes)
    if not limit or limit <= 0 or limit ~= math.floor(limit) then
        limit = available
    else
        limit = math.min(limit, available)
    end
    return block.data:sub(relative + 1, relative + limit)
end

function RemoteStream:stats()
    local blocks = 0
    for _ in pairs(self.blocks) do blocks = blocks + 1 end
    return {
        blocks = blocks,
        hits = self.hits,
        misses = self.misses,
        bytes = blocks * self.block_size,
    }
end

return RemoteStream
