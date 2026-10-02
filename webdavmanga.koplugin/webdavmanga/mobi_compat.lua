local MobiCompat = {}

local function u16(bytes, offset)
    local a, b = bytes:byte(offset, offset + 1)
    if not b then return nil end
    return a * 256 + b
end

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function be32(value)
    return string.char(math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 256) % 256,
        value % 256)
end

function MobiCompat.repair_cached_file(path, open_file)
    open_file = open_file or io.open
    local handle, open_error = open_file(path, "r+b")
    if not handle then return nil, false, open_error or "open_failed" end
    local function close(result, changed, err)
        handle:close()
        return result, changed, err
    end

    local header = handle:read(82)
    if not header or #header < 82 then return close(nil, false, "short_header") end
    if header:sub(61, 68) ~= "BOOKMOBI" then return close(true, false) end
    local total_records = u16(header, 77)
    local record0 = u32(header, 79)
    if not total_records or total_records == 0 or not record0 then
        return close(nil, false, "invalid_record_table")
    end
    if not handle:seek("set", record0 + 8) then
        return close(nil, false, "invalid_record_offset")
    end
    local text_bytes = handle:read(2)
    local text_records = text_bytes and u16(text_bytes, 1)
    if not text_records or text_records + 1 > total_records then
        return close(nil, false, "invalid_text_record_count")
    end
    if not handle:seek("set", record0 + 16) or handle:read(4) ~= "MOBI" then
        return close(nil, false, "missing_mobi_header")
    end
    if not handle:seek("set", record0 + 80) then
        return close(nil, false, "invalid_mobi_header")
    end
    local first_non_book = handle:read(4)
    if not first_non_book or #first_non_book ~= 4 then
        return close(nil, false, "short_mobi_header")
    end
    if first_non_book ~= "\255\255\255\255" then return close(true, false) end
    if not handle:seek("set", record0 + 80)
        or not handle:write(be32(text_records + 1))
        or not handle:flush() then
        return close(nil, false, "write_failed")
    end
    return close(true, true)
end

return MobiCompat
