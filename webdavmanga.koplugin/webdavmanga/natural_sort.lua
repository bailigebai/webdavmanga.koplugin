local M = {}

local function tokenize(value)
    local text = tostring(value or "")
    local tokens = {}
    local position = 1
    while position <= #text do
        local tail = text:sub(position)
        local raw
        local numeric = tail:sub(1, 1):match("%d") ~= nil
        if numeric then
            raw = tail:match("^%d+")
        else
            raw = tail:match("^%D+")
        end
        tokens[#tokens + 1] = {
            raw = raw,
            lower = raw:lower(),
            numeric = numeric,
            number = numeric and tonumber(raw) or nil,
        }
        position = position + #raw
    end
    return tokens, text
end

local function compare_values(left, right)
    local left_tokens, left_text = tokenize(left)
    local right_tokens, right_text = tokenize(right)
    local count = math.max(#left_tokens, #right_tokens)
    for index = 1, count do
        local a, b = left_tokens[index], right_tokens[index]
        if a == nil then return -1 end
        if b == nil then return 1 end
        if a.numeric and b.numeric then
            if a.number ~= b.number then
                return a.number < b.number and -1 or 1
            end
            if #a.raw ~= #b.raw then
                return #a.raw < #b.raw and -1 or 1
            end
        elseif a.numeric ~= b.numeric then
            return a.numeric and -1 or 1
        else
            if a.lower ~= b.lower then
                return a.lower < b.lower and -1 or 1
            end
            if a.raw ~= b.raw then
                return a.raw < b.raw and -1 or 1
            end
        end
    end
    local left_lower, right_lower = left_text:lower(), right_text:lower()
    if left_lower ~= right_lower then
        return left_lower < right_lower and -1 or 1
    end
    if left_text ~= right_text then
        return left_text < right_text and -1 or 1
    end
    return 0
end

function M.less(left, right, name_fn)
    name_fn = name_fn or function(value) return value end
    return compare_values(name_fn(left), name_fn(right)) < 0
end

function M.sort(items, name_fn)
    name_fn = name_fn or function(value) return value end
    local decorated = {}
    for index, item in ipairs(items or {}) do
        decorated[index] = { item = item, index = index }
    end
    table.sort(decorated, function(left, right)
        local comparison = compare_values(name_fn(left.item), name_fn(right.item))
        if comparison == 0 then return left.index < right.index end
        return comparison < 0
    end)
    for index, value in ipairs(decorated) do
        items[index] = value.item
    end
    return items
end

return M
