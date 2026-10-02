local Quadrant = {}

local function valid_dimension(value)
    return type(value) == "number" and value > 0
        and value < math.huge and value == math.floor(value)
end

local function valid_point(point, width, height)
    return type(point) == "table" and type(point.x) == "number"
        and type(point.y) == "number" and point.x >= 0 and point.x < width
        and point.y >= 0 and point.y < height
end

function Quadrant.from_gesture(gesture, width, height)
    if type(gesture) ~= "table" or not valid_dimension(width)
        or not valid_dimension(height) then return nil end

    local x, y
    if gesture.pos ~= nil then
        if not valid_point(gesture.pos, width, height) then return nil end
        x, y = gesture.pos.x, gesture.pos.y
    else
        if not valid_point(gesture.pos1, width, height)
            or not valid_point(gesture.pos2, width, height) then return nil end
        x = (gesture.pos1.x + gesture.pos2.x) / 2
        y = (gesture.pos1.y + gesture.pos2.y) / 2
    end

    local horizontal = x < math.floor(width / 2) and "left" or "right"
    local vertical = y < math.floor(height / 2) and "top" or "bottom"
    return vertical .. "_" .. horizontal
end

function Quadrant.viewport(width, height, id)
    if not valid_dimension(width) or not valid_dimension(height) then return nil end
    local left_w, top_h = math.floor(width / 2), math.floor(height / 2)
    local right_w, bottom_h = width - left_w, height - top_h
    if id == "top_left" then
        return { x = 0, y = 0, w = left_w, h = top_h }
    elseif id == "top_right" then
        return { x = left_w, y = 0, w = right_w, h = top_h }
    elseif id == "bottom_left" then
        return { x = 0, y = top_h, w = left_w, h = bottom_h }
    elseif id == "bottom_right" then
        return { x = left_w, y = top_h, w = right_w, h = bottom_h }
    end
    return nil
end

return Quadrant
