local Probe = {}

local MAX_HEADER_BYTES = 65536
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_PNG_DIMENSION = 2147483647
local MAX_TIFF_DIMENSION = 4294967295
local MAX_SVG_DIMENSION = MAX_SAFE_INTEGER

local function byte(value, index)
    return value and value:byte(index) or nil
end

local function be16(value, index)
    local first, second = byte(value, index), byte(value, index + 1)
    if not first or not second then return nil end
    return first * 256 + second
end

local function le16(value, index)
    local first, second = byte(value, index), byte(value, index + 1)
    if not first or not second then return nil end
    return first + second * 256
end

local function be32(value, index)
    local high, low = be16(value, index), be16(value, index + 2)
    if not high or not low then return nil end
    return high * 65536 + low
end

local function le32(value, index)
    local low, high = le16(value, index), le16(value, index + 2)
    if not low or not high then return nil end
    return low + high * 65536
end

local function positive_dimensions(format, width, height, maximum, allow_fraction)
    width, height = tonumber(width), tonumber(height)
    if not width or not height or width ~= width or height ~= height
        or width == math.huge or height == math.huge
        or width == -math.huge or height == -math.huge
        or width <= 0 or height <= 0
        or (maximum and (width > maximum or height > maximum))
        or (not allow_fraction
            and (math.floor(width) ~= width or math.floor(height) ~= height)) then
        return nil
    end
    return format, width, height
end

local function xor32(left, right)
    local result, place = 0, 1
    for _ = 1, 32 do
        local left_bit, right_bit = left % 2, right % 2
        if left_bit ~= right_bit then result = result + place end
        left = math.floor(left / 2)
        right = math.floor(right / 2)
        place = place * 2
    end
    return result
end

local function crc32(value)
    local crc = 4294967295
    for index = 1, #value do
        crc = xor32(crc, byte(value, index))
        for _ = 1, 8 do
            local low_bit = crc % 2
            crc = math.floor(crc / 2)
            if low_bit == 1 then crc = xor32(crc, 3988292384) end
        end
    end
    return 4294967295 - crc
end

local function valid_file_size(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or value < 0 or value > MAX_SAFE_INTEGER or math.floor(value) ~= value then
        return nil
    end
    return value
end

local function read_prefix(path, dependencies)
    local open_file = dependencies and dependencies.open_file or io.open
    local handle = open_file(path, "rb")
    if not handle then return "", nil end
    local actual_size
    if dependencies and type(dependencies.file_size) == "function" then
        local ok, value = pcall(dependencies.file_size, path)
        if ok then actual_size = valid_file_size(value) end
    end
    if not actual_size and type(handle.seek) == "function" then
        local end_ok, end_position = pcall(handle.seek, handle, "end", 0)
        end_position = end_ok and valid_file_size(end_position) or nil
        if not end_position then
            pcall(handle.close, handle)
            return "", nil
        end
        local reset_ok, reset_position = pcall(handle.seek, handle, "set", 0)
        if not reset_ok or reset_position ~= 0 then
            pcall(handle.close, handle)
            return "", nil
        end
        actual_size = end_position
    end
    local ok, data = pcall(handle.read, handle, MAX_HEADER_BYTES)
    pcall(handle.close, handle)
    if not ok or type(data) ~= "string" then return "", nil end
    if actual_size and actual_size < #data then return "", nil end
    if not actual_size and #data < MAX_HEADER_BYTES then actual_size = #data end
    return data, actual_size
end

local function detect_jpeg(head)
    if head:sub(1, 2) ~= string.char(0xFF, 0xD8) then return nil end
    local position = 3
    while position <= #head do
        while byte(head, position) == 0xFF do position = position + 1 end
        local marker = byte(head, position)
        if not marker then return nil end
        position = position + 1
        if marker == 0xD9 or marker == 0xDA then return nil end
        if marker ~= 0x01 and marker ~= 0xD8
            and not (marker >= 0xD0 and marker <= 0xD7) then
            local segment_length = be16(head, position)
            if not segment_length or segment_length < 2
                or position + segment_length - 1 > #head then return nil end
            local is_start_of_frame = marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
            if is_start_of_frame then
                local components = byte(head, position + 7)
                if not components or components < 1
                    or segment_length ~= 8 + 3 * components then return nil end
                return positive_dimensions("jpeg",
                    be16(head, position + 5), be16(head, position + 3), 65535)
            end
            position = position + segment_length
        end
    end
    return nil
end

local PNG_SIGNATURE = string.char(137) .. "PNG\r\n" .. string.char(26) .. "\n"
local function detect_png(head)
    if #head < 33 or head:sub(1, 8) ~= PNG_SIGNATURE
        or be32(head, 9) ~= 13 or head:sub(13, 16) ~= "IHDR" then return nil end
    local bit_depth, color_type = byte(head, 25), byte(head, 26)
    local valid_depths = {
        [0] = { [1] = true, [2] = true, [4] = true, [8] = true, [16] = true },
        [2] = { [8] = true, [16] = true },
        [3] = { [1] = true, [2] = true, [4] = true, [8] = true },
        [4] = { [8] = true, [16] = true },
        [6] = { [8] = true, [16] = true },
    }
    if not (valid_depths[color_type] and valid_depths[color_type][bit_depth])
        or byte(head, 27) ~= 0 or byte(head, 28) ~= 0
        or (byte(head, 29) ~= 0 and byte(head, 29) ~= 1)
        or crc32(head:sub(13, 29)) ~= be32(head, 30) then return nil end
    return positive_dimensions("png", be32(head, 17), be32(head, 21),
        MAX_PNG_DIMENSION)
end

local function detect_webp(head, actual_size)
    if head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WEBP" then return nil end
    local riff_size, chunk_size = le32(head, 5), le32(head, 17)
    if not riff_size or not chunk_size or riff_size < 12
        or not actual_size then return nil end
    local declared_size = riff_size + 8
    local chunk_end = 20 + chunk_size + (chunk_size % 2)
    if chunk_end > declared_size or declared_size ~= actual_size then return nil end
    local chunk = head:sub(13, 16)
    if chunk == "VP8 " then
        if chunk_size < 10 then return nil end
        if head:sub(24, 26) ~= string.char(0x9D, 0x01, 0x2A) then return nil end
        local raw_width, raw_height = le16(head, 27), le16(head, 29)
        if not raw_width or not raw_height then return nil end
        return positive_dimensions("webp", raw_width % 16384,
            raw_height % 16384, 16383)
    elseif chunk == "VP8L" then
        if chunk_size < 5 then return nil end
        if byte(head, 21) ~= 0x2F then return nil end
        local first, second, third, fourth = byte(head, 22), byte(head, 23),
            byte(head, 24), byte(head, 25)
        if not fourth then return nil end
        local width = 1 + first + (second % 64) * 256
        local height = 1 + math.floor(second / 64) + third * 4 + (fourth % 16) * 1024
        return positive_dimensions("webp", width, height, 16384)
    elseif chunk == "VP8X" then
        if chunk_size ~= 10 or byte(head, 22) ~= 0
            or byte(head, 23) ~= 0 or byte(head, 24) ~= 0 then return nil end
        local width_minus_one = byte(head, 25)
        local width_middle, width_high = byte(head, 26), byte(head, 27)
        local height_minus_one = byte(head, 28)
        local height_middle, height_high = byte(head, 29), byte(head, 30)
        if not height_high then return nil end
        return positive_dimensions("webp",
            1 + width_minus_one + width_middle * 256 + width_high * 65536,
            1 + height_minus_one + height_middle * 256 + height_high * 65536,
            16777216)
    end
    return nil
end

local function detect_gif(head)
    local signature = head:sub(1, 6)
    if #head < 13 or (signature ~= "GIF87a" and signature ~= "GIF89a") then return nil end
    return positive_dimensions("gif", le16(head, 7), le16(head, 9), 65535)
end

local function detect_tiff(head)
    local order = head:sub(1, 2)
    local read16, read32
    if order == "II" and head:sub(3, 4) == string.char(0x2A, 0) then
        read16, read32 = le16, le32
    elseif order == "MM" and head:sub(3, 4) == string.char(0, 0x2A) then
        read16, read32 = be16, be32
    else
        return nil
    end

    local offset = read32(head, 5)
    if not offset then return nil end
    local position = offset + 1
    local count = read16(head, position)
    if not count or count > math.floor((#head - position - 1) / 12) then return nil end
    local next_ifd_position = position + 2 + count * 12
    if next_ifd_position + 3 > #head then return nil end
    position = position + 2
    local width, height
    for _ = 1, count do
        local tag = read16(head, position)
        local value_type = read16(head, position + 2)
        local value_count = read32(head, position + 4)
        if (tag == 256 or tag == 257) and value_count == 1 then
            local value
            if value_type == 3 then value = read16(head, position + 8) end
            if value_type == 4 then value = read32(head, position + 8) end
            if tag == 256 then width = value else height = value end
        end
        position = position + 12
    end
    return positive_dimensions("tiff", width, height, MAX_TIFF_DIMENSION)
end

local function svg_number(value, allow_px)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$") or ""
    if allow_px and value:sub(-2):lower() == "px" then
        value = value:sub(1, -3):match("^%s*(.-)%s*$") or ""
    end
    local mantissa, exponent = value, nil
    if value:find("[eE]") then
        mantissa, exponent = value:match("^(.+)[eE]([%+%-]?%d+)$")
        if not mantissa then return nil end
    end
    local unsigned = mantissa:gsub("^[%+%-]", "")
    if unsigned == "" or (not unsigned:match("^%d+%.?%d*$")
        and not unsigned:match("^%.%d+$")) then return nil end
    local number = tonumber(mantissa .. (exponent and ("e" .. exponent) or ""))
    if not number or number ~= number or number == math.huge or number == -math.huge
        or math.abs(number) > MAX_SAFE_INTEGER then return nil end
    return number
end

local function detect_svg(head)
    if head:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF) then head = head:sub(4) end
    head = head:match("^%s*(.*)$") or ""
    if head:sub(1, 5):lower() == "<?xml" then
        local declaration_end = head:find("?>", 6, true)
        if not declaration_end then return nil end
        head = head:sub(declaration_end + 2):match("^%s*(.*)$") or ""
    end
    local root = head:match("^<([%a_][%w_:%.-]*)[%s>/]")
    local opening_tag = head:match("^(<[^>]+>)")
    if not root or not opening_tag then return nil end
    if root ~= "svg" then
        local prefix = root:match("^([%a_][%w_.-]*):svg$")
        if not prefix then return nil end
        local escaped_prefix = prefix:gsub("([^%w])", "%%%1")
        local binding_count = 0
        for _ in opening_tag:gmatch(
            "%s+xmlns:" .. escaped_prefix .. "%s*=") do
            binding_count = binding_count + 1
        end
        local namespace = opening_tag:match(
            "%s+xmlns:" .. escaped_prefix .. "%s*=%s*\"([^\"]*)\"")
            or opening_tag:match(
                "%s+xmlns:" .. escaped_prefix .. "%s*=%s*'([^']*)'")
        if binding_count ~= 1
            or namespace ~= "http://www.w3.org/2000/svg" then return nil end
    end
    local normalized = opening_tag:lower()
    local width = svg_number(
        normalized:match("[%s]width%s*=%s*['\"]([^'\"]+)['\"]"), true)
    local height = svg_number(
        normalized:match("[%s]height%s*=%s*['\"]([^'\"]+)['\"]"), true)
    local view_box = normalized:match("[%s]viewbox%s*=%s*['\"]([^'\"]+)['\"]")
    if (not width or not height) and view_box then
        local values = {}
        view_box = view_box:gsub(",", " ")
        for value in view_box:gmatch("%S+") do
            values[#values + 1] = svg_number(value, false)
            if not values[#values] then return nil end
        end
        if #values == 4 then
            width = width or values[3]
            height = height or values[4]
        end
    end
    return positive_dimensions("svg", width, height, MAX_SVG_DIMENSION, true)
end

function Probe.matches_extension(format, extension)
    if extension == nil or tostring(extension) == "" then return true end
    local actual = tostring(format or ""):lower():gsub("^%.", "")
    local expected = tostring(extension):lower():gsub("^%.", "")
    if actual == "jpg" then actual = "jpeg" end
    if expected == "jpg" then expected = "jpeg" end
    if actual == "tif" then actual = "tiff" end
    if expected == "tif" then expected = "tiff" end
    return actual == expected
end

local METADATA_LIMITS = {
    jpeg = { maximum = 65535 },
    png = { maximum = MAX_PNG_DIMENSION },
    webp = { maximum = 16777216 },
    gif = { maximum = 65535 },
    tiff = { maximum = MAX_TIFF_DIMENSION },
    svg = { maximum = MAX_SVG_DIMENSION, allow_fraction = true },
}

function Probe.valid_metadata(format, width, height, extension)
    local limits = type(format) == "string" and METADATA_LIMITS[format] or nil
    if not limits or not Probe.matches_extension(format, extension) then return false end
    return positive_dimensions(format, width, height,
        limits.maximum, limits.allow_fraction) ~= nil
end

function Probe.inspect_bytes(head, expected_extension, actual_size, dependencies)
    dependencies = dependencies or {}
    if type(head) ~= "string" then return nil, "unknown_image_signature" end
    local format, width, height = detect_jpeg(head)
    if not format then format, width, height = detect_png(head) end
    if not format then format, width, height = detect_webp(head, actual_size) end
    if not format then format, width, height = detect_gif(head) end
    if not format then format, width, height = detect_tiff(head) end
    if not format then format, width, height = detect_svg(head) end
    if not format then return nil, "unknown_image_signature" end
    local extension_mismatch = false
    if not Probe.matches_extension(format, expected_extension) then
        if dependencies.allow_extension_mismatch ~= true then
            return nil, "extension_signature_mismatch"
        end
        extension_mismatch = true
    end
    local metadata_extension = expected_extension
    if extension_mismatch then metadata_extension = nil end
    if not Probe.valid_metadata(format, width, height, metadata_extension) then
        return nil, "invalid_image_dimensions"
    end
    return {
        format = format,
        width = width,
        height = height,
        extension_mismatch = extension_mismatch or nil,
    }
end

function Probe.inspect(path, expected_extension, dependencies)
    dependencies = dependencies or {}
    local head, actual_size = read_prefix(path, dependencies)
    return Probe.inspect_bytes(head, expected_extension, actual_size, dependencies)
end

return Probe
