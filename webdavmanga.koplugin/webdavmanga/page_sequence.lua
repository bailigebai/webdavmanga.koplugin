local PageSequence = {}

local function whole_segments()
    return { "whole" }
end

function PageSequence.segments(width, height, reader_settings)
    reader_settings = reader_settings or {}
    if reader_settings.split_enabled ~= true
        or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return whole_segments()
    end

    local ratio = width / height
    local minimum = tonumber(reader_settings.split_min_ratio) or 1.20
    local maximum = tonumber(reader_settings.split_max_ratio) or 2.20
    if ratio < minimum or ratio > maximum then return whole_segments() end
    local first = reader_settings.split_first_segment
    -- Preserve the pre-0.3.19 behavior for injected/legacy settings that do
    -- not have the new field yet. Persisted settings always default to left.
    if first ~= "left" and first ~= "right" then
        first = reader_settings.direction == "manga" and "right" or "left"
    end
    return first == "left" and { "left", "right" } or { "right", "left" }
end

function PageSequence.viewport(width, height, segment, cut_percent)
    width = tonumber(width) or 0
    height = tonumber(height) or 0
    local cut = math.floor(width * (tonumber(cut_percent) or 50) / 100)
    if segment == "left" then
        return { x = 0, y = 0, w = cut, h = height }
    end
    if segment == "right" then
        return { x = cut, y = 0, w = width - cut, h = height }
    end
    return { x = 0, y = 0, w = width, h = height }
end

local function segment_index(segment, segments)
    for index, value in ipairs(segments or {}) do
        if value == segment then return index end
    end
    return nil
end

function PageSequence.next(position, segments, physical_count)
    local current_index = tonumber(position and position.index)
    local count = math.floor(tonumber(physical_count) or 0)
    if not current_index or current_index < 1 or current_index > count then return nil end

    local current_segment_index = segment_index(position.segment, segments)
    if current_segment_index and segments[current_segment_index + 1] then
        return { index = current_index, segment = segments[current_segment_index + 1] }
    end
    if current_index >= count then return nil end
    return { index = current_index + 1, segment = "whole" }
end

function PageSequence.previous(position, segments, physical_count)
    local current_index = tonumber(position and position.index)
    local count = math.floor(tonumber(physical_count) or 0)
    if not current_index or current_index < 1 or current_index > count then return nil end

    local current_segment_index = segment_index(position.segment, segments)
    if current_segment_index and segments[current_segment_index - 1] then
        return { index = current_index, segment = segments[current_segment_index - 1] }
    end
    if current_index <= 1 then return nil end
    return { index = current_index - 1, segment = "whole" }
end

return PageSequence
