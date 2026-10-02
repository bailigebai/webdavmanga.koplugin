local M = {}

M.MAX_SAFE = 9007199254740991

function M.parse(value, base, width)
    if type(value) ~= "string" or (width and #value ~= width)
        or #value == 0 then
        return nil
    end
    base = base or 10
    if base ~= 10 and base ~= 16 then return nil end
    local result = 0
    for index = 1, #value do
        local byte = value:byte(index)
        local digit
        if byte >= 48 and byte <= 57 then
            digit = byte - 48
        elseif base == 16 and byte >= 65 and byte <= 70 then
            digit = byte - 55
        elseif base == 16 and byte >= 97 and byte <= 102 then
            digit = byte - 87
        else
            return nil
        end
        if digit >= base
            or result > math.floor((M.MAX_SAFE - digit) / base) then
            return nil
        end
        result = result * base + digit
    end
    return result
end

function M.normalize(value)
    local number
    if type(value) == "string" then
        number = M.parse(value, 10)
    elseif type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and value >= 0 and value <= M.MAX_SAFE
        and math.floor(value) == value then
        number = value
    end
    if number == nil then return nil end
    return number, ("%.0f"):format(number)
end

return M
