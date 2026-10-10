local BookIndex = require("webdavmanga.book_index")

local PdfImageStream = {}
PdfImageStream.__index = PdfImageStream

-- Keep indexing bounded: xref metadata is small, while page image bytes stay
-- on the existing per-page Range path.
local TAIL_BYTES = 64 * 1024
local READ_BYTES = 64 * 1024
local MAX_OBJECT_BYTES = 256 * 1024
local MAX_OBJECT_STREAM_BYTES = 2 * 1024 * 1024
local MAX_XREF_BYTES = 8 * 1024 * 1024
local MAX_PAGES = 20000
local MAX_OBJECTS = MAX_PAGES * 10
local MAX_IMAGE_BYTES = 64 * 1024 * 1024
local MAX_ICC_BYTES = 65519 -- one bounded JPEG APP2 ICC segment
local MAX_SAFE_INTEGER = 9007199254740991

local function integer(value)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < 0
        or value > MAX_SAFE_INTEGER then return nil end
    return value
end

local function read_exact(source, offset, count)
    offset, count = integer(offset), integer(count)
    if not offset or not count or offset + count > source.size then return nil end
    local chunks, position, remaining = {}, offset, count
    while remaining > 0 do
        local bytes = source.read_at(position, math.min(remaining, READ_BYTES))
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > remaining then return nil end
        chunks[#chunks + 1] = bytes
        position, remaining = position + #bytes, remaining - #bytes
    end
    return table.concat(chunks)
end

local function skip_space(text, position)
    while position <= #text do
        local char = text:sub(position, position)
        if char:match("[%z\t\n\f\r ]") then
            position = position + 1
        elseif char == "%" then
            position = text:find("[\r\n]", position + 1) or (#text + 1)
        else
            break
        end
    end
    return position
end

local function token_at(text, position)
    local finish = position
    while finish <= #text and not text:sub(finish, finish):match("[%z\t\n\f\r %(%)<>%[%]{}/%%]") do
        finish = finish + 1
    end
    return text:sub(position, finish - 1), finish
end

-- A bounded lexer, not a general PDF interpreter. Values are skipped as whole
-- objects so strings, comments and nested dictionaries cannot supply parent keys.
-- Duplicate keys, escaped names and unsupported syntax are deliberately refused.
local scan_value
scan_value = function(text, position, depth)
    if depth > 64 then return nil end
    position = skip_space(text, position)
    local char = text:sub(position, position)
    if text:sub(position, position + 1) == "<<" then
        local fields = {}
        position = skip_space(text, position + 2)
        while text:sub(position, position + 1) ~= ">>" do
            if text:sub(position, position) ~= "/" then return nil end
            local key, after = token_at(text, position + 1)
            if key == "" or key:find("#", 1, true) or fields[key] then return nil end
            local start = skip_space(text, after)
            position = scan_value(text, start, depth + 1)
            if not position then return nil end
            -- Nested dictionaries only need duplicate detection, not copied values.
            fields[key] = depth == 0 and text:sub(start, position - 1) or true
            position = skip_space(text, position)
        end
        return position + 2, fields
    elseif char == "[" then
        position = skip_space(text, position + 1)
        while text:sub(position, position) ~= "]" do
            position = scan_value(text, position, depth + 1)
            if not position then return nil end
            position = skip_space(text, position)
        end
        return position + 1
    elseif char == "(" then
        local nesting = 1
        position = position + 1
        while position <= #text do
            char = text:sub(position, position)
            if char == "\\" then
                position = position + 1
            elseif char == "(" then
                nesting = nesting + 1
                if nesting > 64 then return nil end
            elseif char == ")" then
                nesting = nesting - 1
                if nesting == 0 then return position + 1 end
            end
            position = position + 1
        end
    elseif char == "<" then
        local finish = text:find(">", position + 1, true)
        if finish and not text:sub(position + 1, finish - 1):find("[^%x%z\t\n\f\r ]") then
            return finish + 1
        end
    elseif char == "/" then
        local name, finish = token_at(text, position + 1)
        if name ~= "" and not name:find("#", 1, true) then return finish end
    else
        local token, finish = token_at(text, position)
        if token == "true" or token == "false" or token == "null" then return finish end
        if not token:match("^[+-]?%d*%.?%d+$") then return nil end
        if token:match("^%d+$") then
            local generation, after = token_at(text, skip_space(text, finish))
            if generation:match("^%d+$") then
                local marker, last = token_at(text, skip_space(text, after))
                if marker == "R" then return last end
            end
        end
        return finish
    end
end

local function dictionary_end(text, start)
    if text:sub(start, start + 1) ~= "<<" then return nil end
    local after = scan_value(text, start, 0)
    return after and after - 1
end

local function dictionary(text)
    local start = skip_space(text, 1)
    local header = text:sub(start):match("^%d+%s+%d+%s+obj%f[%W]()")
    if header then start = skip_space(text, start + header - 1) end
    local finish = dictionary_end(text, start)
    if finish then return text:sub(start, finish), start, finish end
end

local function field(text, key)
    if type(text) ~= "string" or text:sub(1, 2) ~= "<<" then return nil end
    local after, fields = scan_value(text, 1, 0)
    if after and skip_space(text, after) > #text then return fields[key] end
end

local function scalar(text, key)
    local value = field(text, key)
    return value and value:gsub("%%[^\r\n]*", " "):match("^%s*(.-)%s*$")
end

local function reference(text, key)
    local value = scalar(text, key)
    return value and integer(value:match("^(%d+)%s+%d+%s+R$"))
end

local function direct_dictionary(text, key)
    local value = field(text, key)
    if value and value:sub(1, 2) == "<<" then return value end
end

local function filter_name(text)
    local value = scalar(text, "Filter")
    return value and (value:match("^/([%w]+)$") or value:match("^%[%s*/([%w]+)%s*%]$"))
end

local function references(array)
    local result = {}
    for object_number in tostring(array or ""):gmatch("(%d+)%s+%d+%s+R") do
        result[#result + 1] = integer(object_number)
    end
    return result
end

local function merge_offsets(target, source)
    for number, offset in pairs(source or {}) do
        if target[number] == nil then target[number] = offset end
    end
end

local function merge_compressed(target, source)
    for number, value in pairs(source or {}) do
        if target[number] == nil then target[number] = value end
    end
end

local function parse_integer_list(value)
    local result = {}
    for number in tostring(value or ""):gmatch("(%d+)") do
        result[#result + 1] = integer(number)
    end
    return result
end

local function parse_xref_table(text)
    local marker = text:find("xref", 1, true)
    if not marker then return nil, "pdf_xref_stream_unsupported" end
    local lines = {}
    for line in text:sub(marker + 4):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    local offsets, index, sections, trailer_line = {}, 1, 0, nil
    while index <= #lines do
        local line = lines[index]:match("^%s*(.-)%s*$")
        index = index + 1
        if line == "" then
            -- Ignore blank lines permitted by PDF producers.
        elseif line == "trailer" then
            trailer_line = index - 1
            break
        else
            local first, count = line:match("^(%d+)%s+(%d+)$")
            first, count = integer(first), integer(count)
            if not first or not count or count < 1 or count > MAX_OBJECTS then
                return nil, "pdf_xref_invalid"
            end
            sections = sections + 1
            for position = 0, count - 1 do
                local entry = lines[index]
                index = index + 1
                local offset, generation, flag
                if entry then
                    offset, generation, flag = entry:match(
                        "^%s*(%d+)%s+(%d+)%s+([nf])%s*$")
                end
                offset, generation = integer(offset), integer(generation)
                if not offset or generation == nil or not flag then
                    return nil, "pdf_xref_invalid"
                end
                local number = first + position
                if flag == "n" and offsets[number] == nil then offsets[number] = offset end
            end
        end
    end
    if not trailer_line then return nil, "pdf_trailer_missing" end
    local trailer_start = text:find("trailer", marker + 4, true)
    local trailer = trailer_start and text:sub(trailer_start + 7)
    trailer = trailer and dictionary(trailer)
    if not trailer then return nil, "pdf_trailer_invalid" end
    return offsets, trailer, {}, sections
end

local function read_classic_xref(source, offset, initial)
    local text, total = initial or "", #(initial or "")
    while true do
        local trailer = text:find("trailer", 1, true)
        local dictionary_start = trailer and text:find("<<", trailer + 7, true)
        local dictionary_finish = dictionary_start and dictionary_end(text, dictionary_start)
        if dictionary_finish then return text:sub(1, dictionary_finish) end
        if total >= MAX_XREF_BYTES or offset + total >= source.size then
            return nil, trailer and "pdf_trailer_invalid" or "pdf_xref_too_large"
        end
        local count = math.min(READ_BYTES, MAX_XREF_BYTES - total,
            source.size - offset - total)
        local bytes = read_exact(source, offset + total, count)
        if not bytes then return nil, "pdf_xref_read_failed" end
        text, total = text .. bytes, total + #bytes
    end
end

local function big_endian(bytes, position, width)
    if width == 0 then return 0 end
    if width < 0 or width > 8 or position < 1 or position + width - 1 > #bytes then return nil end
    local value = 0
    for index = position, position + width - 1 do
        value = value * 256 + (bytes:byte(index) or 0)
        if value > MAX_SAFE_INTEGER then return nil end
    end
    return value
end

local function default_inflate(bytes, expected_size)
    local loaded, zlib = pcall(require, "ffi/zlib")
    if not loaded or type(zlib) ~= "table" or type(zlib.zlib_uncompress) ~= "function" then
        return nil, "pdf_xref_filter_unsupported"
    end
    local ok, result = pcall(zlib.zlib_uncompress, bytes, expected_size)
    if not ok or type(result) ~= "string" then return nil, "pdf_xref_decompress_failed" end
    return result
end

local function default_encode_png(target, pixels, width, height, components)
    local loaded, png = pcall(require, "ffi/png")
    if not loaded or type(png.encodeToFile) ~= "function" then return false end
    return png.encodeToFile(target, pixels, width, height, components)
end

local function decode_image_pixels(decompress, bytes, expected)
    if not bytes then return nil, "pdf_image_read_failed" end
    local ok, pixels = pcall(decompress or default_inflate, bytes, expected)
    if not ok or type(pixels) ~= "string" or #pixels ~= expected then
        return nil, "pdf_image_decompress_failed"
    end
    return pixels
end

local function stream_offset(text, object_offset)
    local _, _, finish = dictionary(text)
    if not finish then return nil end
    local marker = skip_space(text, finish + 1)
    if text:sub(marker, marker + 5) ~= "stream" then return nil end
    local position = marker + 6
    local first, second = text:sub(position, position), text:sub(position + 1, position + 1)
    if first == "\r" then
        position = position + (second == "\n" and 2 or 1)
    elseif first == "\n" then
        position = position + 1
    else
        return nil
    end
    return object_offset + position - 1
end

local function object_header_at(source, offset)
    if not offset or offset >= source.size then return nil, "pdf_object_missing" end
    local chunks, total = {}, 0
    while total < MAX_OBJECT_BYTES and offset + total < source.size do
        local count = math.min(READ_BYTES, MAX_OBJECT_BYTES - total, source.size - offset - total)
        local bytes = source.read_at(offset + total, count)
        if type(bytes) ~= "string" or #bytes == 0 or #bytes > count then
            return nil, "pdf_object_read_failed"
        end
        chunks[#chunks + 1], total = bytes, total + #bytes
        local text = table.concat(chunks)
        local finish = text:find("endobj", 1, true)
        local stream = text:find("stream", 1, true)
        if finish then return text:sub(1, finish + 5), offset end
        if stream then return text, offset end
    end
    return nil, "pdf_object_too_large"
end

local function parse_xref_stream(source, object_text, object_offset, decompressor)
    local dict = dictionary(object_text)
    if not dict then return nil, nil, nil, "pdf_xref_invalid" end
    local widths = parse_integer_list(scalar(dict, "W"))
    if #widths ~= 3 or widths[1] > 8 or widths[2] > 8 or widths[3] > 8
        or widths[1] + widths[2] + widths[3] < 1 then
        return nil, nil, nil, "pdf_xref_invalid"
    end
    local size = integer(scalar(dict, "Size"))
    if not size or size < 1 or size > MAX_OBJECTS then return nil, nil, nil, "pdf_xref_invalid" end
    local raw_index = parse_integer_list(scalar(dict, "Index"))
    if #raw_index == 0 then raw_index = { 0, size } end
    if #raw_index % 2 ~= 0 then return nil, nil, nil, "pdf_xref_invalid" end
    local entry_width = widths[1] + widths[2] + widths[3]
    local entry_count = 0
    for position = 1, #raw_index, 2 do
        local first, count = raw_index[position], raw_index[position + 1]
        if not first or not count or count < 1 or first + count > size then
            return nil, nil, nil, "pdf_xref_invalid"
        end
        entry_count = entry_count + count
        if entry_count > MAX_OBJECTS then return nil, nil, nil, "pdf_xref_invalid" end
    end
    local decoded_size = entry_count * entry_width
    if decoded_size < 1 or decoded_size > MAX_XREF_BYTES then
        return nil, nil, nil, "pdf_xref_invalid"
    end
    local length = integer(scalar(dict, "Length"))
    if length and length > MAX_XREF_BYTES then return nil, nil, nil, "pdf_xref_too_large" end
    local stream_at = stream_offset(object_text, object_offset)
    if not length or not stream_at or stream_at + length > source.size then
        return nil, nil, nil, "pdf_xref_length_unsupported"
    end
    local data = read_exact(source, stream_at, length)
    if not data then return nil, nil, nil, "pdf_xref_read_failed" end
    local filter = filter_name(dict)
    if field(dict, "Filter") then
        if filter ~= "FlateDecode" and filter ~= "Fl" then
            return nil, nil, nil, "pdf_xref_filter_unsupported"
        end
        local decoded, decode_error = (decompressor or default_inflate)(data, decoded_size)
        if type(decoded) ~= "string" then return nil, nil, nil, decode_error or "pdf_xref_decompress_failed" end
        if #decoded > MAX_XREF_BYTES then return nil, nil, nil, "pdf_xref_too_large" end
        data = decoded
    end
    if #data < decoded_size then return nil, nil, nil, "pdf_xref_length_mismatch" end
    local offsets, compressed, cursor = {}, {}, 1
    for position = 1, #raw_index, 2 do
        local first, count = raw_index[position], raw_index[position + 1]
        for object_number = first, first + count - 1 do
            local kind = big_endian(data, cursor, widths[1]); cursor = cursor + widths[1]
            local field2 = big_endian(data, cursor, widths[2]); cursor = cursor + widths[2]
            local field3 = big_endian(data, cursor, widths[3]); cursor = cursor + widths[3]
            if kind == nil or field2 == nil or field3 == nil then
                return nil, nil, nil, "pdf_xref_invalid"
            end
            if widths[1] == 0 then kind = 1 end
            if kind == 1 then
                if field2 >= source.size then return nil, nil, nil, "pdf_xref_invalid" end
                offsets[object_number] = field2
            elseif kind == 2 then
                compressed[object_number] = { object_stream = field2, index = field3 }
            elseif kind ~= 0 then
                return nil, nil, nil, "pdf_xref_invalid"
            end
        end
    end
    return offsets, dict, compressed, nil
end

local function inflate_bounded(decompress, bytes, initial_size, maximum_size)
    local capacity = math.max(1, math.min(initial_size, maximum_size))
    local last_error
    while true do
        local decoded
        decoded, last_error = decompress(bytes, capacity)
        if type(decoded) == "string" then
            if #decoded > maximum_size then return nil, "pdf_object_stream_too_large" end
            return decoded
        end
        if capacity >= maximum_size then return nil, last_error end
        capacity = math.min(maximum_size, capacity * 2)
    end
end

function PdfImageStream:new(options)
    options = options or {}
    return setmetatable({
        image_probe = options.image_probe or require("webdavmanga.image_probe"),
        max_pages = tonumber(options.max_pages) or MAX_PAGES,
        logger = options.logger,
        decompress = options.decompress,
        encode_png = options.encode_png or default_encode_png,
        compressed = {},
        object_stream_cache = nil,
    }, self)
end

function PdfImageStream:_log(phase, detail)
    local logger = self.logger
    if logger and type(logger.warn) == "function" then
        pcall(logger.warn, "WebDavManga PDF:", tostring(phase), tostring(detail or ""))
    end
end

function PdfImageStream:_object(source, offsets, number, stack)
    local offset = offsets[number]
    if offset ~= nil then
        local text, object_offset = object_header_at(source, offset)
        if not text then return nil, object_offset end
        if tonumber(text:match("^%s*(%d+)%s+%d+%s+obj")) ~= number then
            return nil, "pdf_object_invalid"
        end
        return { text = text, dictionary = dictionary(text), offset = object_offset }
    end
    local compressed = self.compressed and self.compressed[number]
    if not compressed then return nil, "pdf_object_missing" end
    stack = stack or {}
    if stack[number] then return nil, "pdf_object_stream_cycle" end
    stack[number] = true
    local stream_number = compressed.object_stream
    local decoded = self.object_stream_cache
    if not decoded or decoded.number ~= stream_number then
        local stream_object, stream_error = self:_object(source, offsets, stream_number, stack)
        if not stream_object then return nil, stream_error end
        local stream_dict = stream_object.dictionary
        if not stream_dict or scalar(stream_dict, "Type") ~= "/ObjStm" then
            return nil, "pdf_object_stream_invalid"
        end
        local count = integer(scalar(stream_dict, "N"))
        local first = integer(scalar(stream_dict, "First"))
        local length = integer(scalar(stream_dict, "Length"))
        if length and length > MAX_OBJECT_STREAM_BYTES then return nil, "pdf_object_stream_too_large" end
        local stream_at = stream_offset(stream_object.text, stream_object.offset)
        if not count or not first or not length or not stream_at
            or count < 1 or count > MAX_OBJECTS or stream_at + length > source.size then
            return nil, "pdf_object_stream_invalid"
        end
        local bytes = read_exact(source, stream_at, length)
        if not bytes then return nil, "pdf_object_stream_read_failed" end
        local filter = filter_name(stream_dict)
        if field(stream_dict, "Filter") then
            if filter ~= "FlateDecode" and filter ~= "Fl" then
                return nil, "pdf_object_stream_filter_unsupported"
            end
            local inflated, inflate_error = inflate_bounded(self.decompress or default_inflate,
                bytes, math.max(1024, first + length, #bytes * 8),
                MAX_OBJECT_STREAM_BYTES)
            if type(inflated) ~= "string" then
                return nil, inflate_error or "pdf_object_stream_decompress_failed"
            end
            bytes = inflated
        end
        if first > #bytes then return nil, "pdf_object_stream_invalid" end
        local headers, cursor = {}, 1
        for _ = 1, count do
            local object_number, object_offset = bytes:sub(cursor):match("^%s*(%d+)%s+(%d+)")
            if not object_number or not object_offset then return nil, "pdf_object_stream_invalid" end
            object_number, object_offset = integer(object_number), integer(object_offset)
            if not object_number or not object_offset then return nil, "pdf_object_stream_invalid" end
            headers[object_number] = object_offset
            local consumed = bytes:sub(cursor):match("^%s*%d+%s+%d+%s*()")
            cursor = cursor + (consumed or 1) - 1
        end
        decoded = { number = stream_number, bytes = bytes, first = first, headers = headers }
        self.object_stream_cache = decoded
    end
    local bytes, first, headers = decoded.bytes, decoded.first, decoded.headers
    local target_offset = headers[number]
    if target_offset == nil then return nil, "pdf_object_stream_member_missing" end
    local body_start = first + target_offset + 1
    local next_offset
    for _, candidate in pairs(headers) do
        if candidate > target_offset and (next_offset == nil or candidate < next_offset) then
            next_offset = candidate
        end
    end
    local body_end = first + (next_offset or #bytes - first)
    if body_start < 1 or body_start > #bytes + 1 or body_end < body_start then
        return nil, "pdf_object_stream_member_invalid"
    end
    stack[number] = nil
    local body = bytes:sub(body_start, body_end)
    local body_dictionary = dictionary(body)
    if body:match("^%s*$") then return nil, "pdf_object_stream_member_invalid" end
    return { text = tostring(number) .. " 0 obj\n" .. body .. "\nendobj",
        dictionary = body_dictionary, offset = 0 }
end

function PdfImageStream:_parse_xref_at(source, offset, state)
    state = state or { visited = {}, offsets = {}, compressed = {}, sections = 0 }
    if state.visited[offset] then return state end
    state.visited[offset] = true
    local probe_size = math.min(READ_BYTES, source.size - offset)
    local probe = read_exact(source, offset, probe_size)
    if not probe then return nil, "pdf_xref_read_failed" end
    local leading = probe:match("^%s*(%w+)")
    local object_text, object_offset
    if leading == "xref" then
        local xref_error
        object_text, xref_error = read_classic_xref(source, offset, probe)
        if not object_text then return nil, xref_error end
        object_offset = offset
    else
        object_text, object_offset = object_header_at(source, offset)
        if not object_text then return nil, object_offset end
    end
    local offsets, compressed, trailer, prev, kind
    if leading == "xref" then
        offsets, trailer, compressed = parse_xref_table(object_text)
        if not offsets then return nil, trailer end
        kind = "table"
    else
        local dict = dictionary(object_text)
        if not dict or scalar(dict, "Type") ~= "/XRef" then return nil, "pdf_xref_invalid" end
        offsets, trailer, compressed, prev = parse_xref_stream(source, object_text,
            object_offset, self.decompress)
        if not offsets then return nil, prev end
        kind = "stream"
    end
    state.sections = state.sections + 1
    merge_offsets(state.offsets, offsets)
    merge_compressed(state.compressed, compressed)
    local active_dictionary = trailer
    state.kind = state.kind or kind
    state.trailer = state.trailer or active_dictionary
    state.root = state.root or reference(active_dictionary, "Root")
    state.encrypted = state.encrypted or field(active_dictionary, "Encrypt") ~= nil
    prev = prev or integer(scalar(active_dictionary, "Prev"))
    local xref_stream = integer(scalar(active_dictionary, "XRefStm"))
    if xref_stream and not state.visited[xref_stream] then
        local stream_state, stream_error = self:_parse_xref_at(source, xref_stream, state)
        if not stream_state then return nil, stream_error end
    end
    if prev and not state.visited[prev] then
        local previous_state, previous_error = self:_parse_xref_at(source, prev, state)
        if not previous_state then return nil, previous_error end
    end
    return state
end

function PdfImageStream:_dictionary_value(source, offsets, text, key)
    local direct = direct_dictionary(text, key)
    if direct then return direct end
    local object_number = reference(text, key)
    if not object_number then return nil end
    local object, error_code = self:_object(source, offsets, object_number)
    if not object then return nil, error_code end
    return object.dictionary
end

function PdfImageStream:_number_value(source, offsets, text, key)
    local object_number = reference(text, key)
    if object_number then
        local object = self:_object(source, offsets, object_number)
        return object and integer(object.text:match("^%s*%d+%s+%d+%s+obj%s+(%d+)%s+endobj%s*$")) or nil
    end
    return integer(scalar(text, key))
end

function PdfImageStream:_page_resources(source, offsets, page_object)
    local object, error_code = self:_object(source, offsets, page_object)
    local visited, depth = {}, 0
    while object and object.dictionary do
        local resources, resources_error = self:_dictionary_value(source, offsets,
            object.dictionary, "Resources")
        if resources then return resources end
        error_code = error_code or resources_error
        local parent = reference(object.dictionary, "Parent")
        if not parent then break end
        if visited[parent] or depth >= 64 then return nil, "pdf_page_tree_invalid" end
        visited[parent], depth = true, depth + 1
        object, error_code = self:_object(source, offsets, parent)
    end
    return nil, error_code or "pdf_resources_missing"
end

function PdfImageStream:_safe_graphics_states(source, offsets, resources)
    local dictionary_value = self:_dictionary_value(source, offsets, resources, "ExtGState")
    if not dictionary_value then return {} end
    local states = {}
    for name, number in dictionary_value:gmatch("/([%w_.-]+)%s+(%d+)%s+%d+%s+R") do
        local object = self:_object(source, offsets, tonumber(number))
        local dict = object and object.dictionary
        local after, values = dict and scan_value(dict, 1, 0)
        local valid = after and skip_space(dict, after) > #dict
        values = values or {}
        for key in pairs(values) do
            if key ~= "Type" and key ~= "ca" and key ~= "CA" and key ~= "BM" then
                valid = false
            end
        end
        if values.Type and values.Type ~= "/ExtGState" then valid = false end
        if values.ca and tonumber(values.ca) ~= 1 then valid = false end
        if values.CA and tonumber(values.CA) ~= 1 then valid = false end
        if values.BM and values.BM ~= "/Normal" then valid = false end
        if valid then states[name] = true end
    end
    return states
end

function PdfImageStream:_first_page_object(source, offsets, number, visited)
    visited = visited or {}
    if visited[number] then return nil, "pdf_page_tree_invalid" end
    visited[number] = true
    local object, error_code = self:_object(source, offsets, number)
    if not object or not object.dictionary then
        return nil, error_code or "pdf_object_dictionary_missing"
    end
    if scalar(object.dictionary, "Type") == "/Page" then return number end
    local kids = scalar(object.dictionary, "Kids")
    kids = kids and kids:match("^%[(.*)%]$")
    if not kids then
        local kids_number = reference(object.dictionary, "Kids")
        local kids_object = kids_number and self:_object(source, offsets, kids_number)
        kids = kids_object and kids_object.text:match("%[(.-)%]")
    end
    local child = references(kids)[1]
    if not child then return nil, "pdf_page_tree_invalid" end
    return self:_first_page_object(source, offsets, child, visited)
end

local function content_number(token)
    if not token:match("^[+-]?%d*%.?%d+$") then return nil end
    local value = tonumber(token)
    if not value or value ~= value or math.abs(value) > MAX_SAFE_INTEGER then return nil end
    return value
end

-- These operators change only the color used by later path painting. Image
-- masks are rejected by _image, so they cannot recolor an accepted XObject.
local COLOR_STATE_OPERANDS = { g = 1, G = 1, rg = 3, RG = 3, k = 4, K = 4 }

-- Some comic PDFs place one upright image inside blank page margins. Accept
-- only the exact clip/transform/operator sequence and refuse a crop that
-- hides more than a small image edge. Returning the JPEG keeps all pixels.
local function margined_single_image(bytes, box, image_name, safe_states)
    local tokens = {}
    for token in bytes:gmatch("%S+") do tokens[#tokens + 1] = token end
    local cursor = 1
    local function numbers(count)
        local result = {}
        for index = 1, count do
            result[index] = content_number(tokens[cursor] or "")
            if not result[index] then return nil end
            cursor = cursor + 1
        end
        return result
    end
    local function take(value)
        if tokens[cursor] ~= value then return false end
        cursor = cursor + 1
        return true
    end
    local outer = numbers(6)
    if not outer or not take("cm") or not take("q") then return false end
    local clip = numbers(4)
    if not clip or not take("re") or not take("W*") or not take("n")
        or not take("q") then return false end
    local inner = numbers(6)
    if not inner or not take("cm") then return false end
    for _, operator in ipairs({ "RG", "rg" }) do
        local components = numbers(3)
        if not components or not take(operator) then return false end
        for _, component in ipairs(components) do
            if component < 0 or component > 1 then return false end
        end
    end
    local state = tokens[cursor]
    if not state or not state:match("^/[%w_.-]+$")
        or not safe_states or not safe_states[state:sub(2)] then return false end
    cursor = cursor + 1
    if not take("gs") or not take("/" .. image_name) or not take("Do")
        or not take("Q") or not take("Q") or tokens[cursor] then return false end
    if outer[1] <= 0 or outer[4] >= 0 or outer[2] ~= 0 or outer[3] ~= 0
        or inner[1] <= 0 or inner[4] >= 0 or inner[2] ~= 0 or inner[3] ~= 0
        or clip[3] <= 0 or clip[4] <= 0 then return false end
    local function bounds(x, y, width, height)
        local x1, x2 = outer[1] * x + outer[5], outer[1] * (x + width) + outer[5]
        local y1, y2 = outer[4] * y + outer[6], outer[4] * (y + height) + outer[6]
        return math.min(x1, x2), math.min(y1, y2), math.max(x1, x2), math.max(y1, y2)
    end
    local cx1, cy1, cx2, cy2 = bounds(clip[1], clip[2], clip[3], clip[4])
    local ix1, iy1, ix2, iy2 = bounds(inner[5], inner[6], inner[1], inner[4])
    local width, height = ix2 - ix1, iy2 - iy1
    local page_width, page_height = box[3] - box[1], box[4] - box[2]
    if width < page_width * 0.6 or height < page_height * 0.6 then return false end
    local left, bottom = math.max(cx1, box[1]), math.max(cy1, box[2])
    local right, top = math.min(cx2, box[3]), math.min(cy2, box[4])
    if right <= left or top <= bottom then return false end
    return math.max(0, left - ix1, ix2 - right) <= width * 0.02
        and math.max(0, bottom - iy1, iy2 - top) <= height * 0.02
end

-- Raw JPEG extraction cannot reproduce annotations, clipping, rotation or
-- compositing. Accept only a proven full-page image; everything else uses MuPDF.
function PdfImageStream:_page_box(source, offsets, page)
    local box, visited, depth = nil, {}, 0
    while page and page.dictionary do
        local dict = page.dictionary
        for _, key in ipairs({ "Annots", "Group", "Rotate", "CropBox", "UserUnit", "AA", "A" }) do
            if field(dict, key) then return nil end
        end
        if not box then
            local raw = scalar(dict, "MediaBox")
            raw = raw and raw:match("^%[([^%]]+)%]$")
            if raw then
                box = {}
                for token in raw:gmatch("%S+") do
                    local number = content_number(token)
                    if not number then return nil end
                    box[#box + 1] = number
                end
                if #box ~= 4 or box[3] <= box[1] or box[4] <= box[2] then return nil end
            end
        end
        local parent = reference(dict, "Parent")
        if not parent then return box end
        if visited[parent] then return nil end
        visited[parent] = true
        depth = depth + 1
        if depth > 64 then return nil end
        page = self:_object(source, offsets, parent)
    end
end

function PdfImageStream:_single_image_content(source, offsets, page, image_name,
    safe_graphics_states, compatible_names)
    local function reject(category)
        self:_log("content.reject", category)
        return nil, "pdf_page_not_image"
    end
    local box = self:_page_box(source, offsets, page)
    local number = reference(page.dictionary, "Contents")
    if not box or not number then return reject("page_reference") end
    local object, object_error = self:_object(source, offsets, number)
    if object and not object.dictionary then
        -- Some PDF writers store /Contents in an indirect, single-element
        -- array. Resolve only that exact shape; multiple streams could paint
        -- content that raw image extraction would silently discard.
        local stream_number = object.text:match(
            "^%s*%d+%s+%d+%s+obj%s*%[%s*(%d+)%s+%d+%s+R%s*%]%s*endobj%s*$")
        if not stream_number then return reject("content_reference") end
        object, object_error = self:_object(source, offsets, tonumber(stream_number))
    end
    if not object or not object.dictionary then return nil, object_error or "pdf_page_not_image" end
    local dict = object.dictionary
    local length = self:_number_value(source, offsets, dict, "Length")
    if length and length > MAX_OBJECT_BYTES then return nil, "pdf_object_too_large" end
    local offset = stream_offset(object.text, object.offset)
    if not length or length < 1 or not offset or offset + length > source.size
        or field(dict, "DecodeParms") or field(dict, "F") then
        return reject("stream_dictionary")
    end
    local bytes = read_exact(source, offset, length)
    if not bytes then return nil, "pdf_object_read_failed" end
    if field(dict, "Filter") then
        -- A single Flate filter with no predictors is the only supported codec.
        local filter = filter_name(dict)
        if filter ~= "FlateDecode" and filter ~= "Fl" then return reject("content_filter") end
        local decoded, err = inflate_bounded(self.decompress or default_inflate, bytes,
            math.min(MAX_OBJECT_BYTES, math.max(1024, #bytes * 8)), MAX_OBJECT_BYTES)
        if not decoded then
            if err == "pdf_object_stream_too_large" then return nil, "pdf_object_too_large" end
            return reject("content_inflate")
        end
        bytes = decoded
    end
    local operands, stack, matrix, painted = {}, {}, { 1, 0, 0, 1, 0, 0 }, 0
    local seen, main_painted = {}, false
    bytes = bytes:gsub("%%[^\r\n]*", "")
    if not compatible_names and margined_single_image(bytes, box, image_name,
        safe_graphics_states) then return true end
    for token in bytes:gmatch("%S+") do
        local value = content_number(token)
        if value or token:match("^/[%w_.-]+$") then
            if #operands >= 6 then return reject("operands") end
            operands[#operands + 1] = value or token
        elseif token == "q" and #operands == 0 and #stack < 64 then
            stack[#stack + 1] = matrix
        elseif token == "Q" and #operands == 0 and #stack > 0 then
            matrix = table.remove(stack)
        elseif token == "cm" and #operands == 6 then
            for _, item in ipairs(operands) do
                if type(item) ~= "number" then return reject("transform") end
            end
            if operands[1] <= 0 or operands[4] <= 0 or operands[2] ~= 0 or operands[3] ~= 0 then
                return reject("transform")
            end
            matrix = { matrix[1] * operands[1], 0, 0, matrix[4] * operands[4],
                matrix[1] * operands[5] + matrix[5], matrix[4] * operands[6] + matrix[6] }
            operands = {}
        elseif COLOR_STATE_OPERANDS[token] then
            if #operands ~= COLOR_STATE_OPERANDS[token] then return reject("color_state") end
            for _, component in ipairs(operands) do
                if type(component) ~= "number" or component < 0 or component > 1 then
                    return reject("color_state")
                end
            end
            operands = {}
        elseif token == "gs" and #operands == 1
            and type(operands[1]) == "string"
            and safe_graphics_states
            and safe_graphics_states[operands[1]:sub(2)] then
            operands = {}
        elseif token == "Do" then
            painted = painted + 1
            local name = type(operands[1]) == "string" and operands[1]:sub(2)
            if seen[name] or (painted > 1 and not compatible_names) then
                return nil, "pdf_multiple_images"
            end
            if #operands ~= 1 or not name
                or (compatible_names and not compatible_names[name])
                or (not compatible_names and name ~= image_name)
                or matrix[5] < box[1] or matrix[6] < box[2]
                or matrix[5] + matrix[1] > box[3] or matrix[6] + matrix[4] > box[4] then
                return reject("image_placement")
            end
            if name == image_name then
                if matrix[1] ~= box[3] - box[1] or matrix[4] ~= box[4] - box[2]
                    or matrix[5] ~= box[1] or matrix[6] ~= box[2] then
                    return reject("main_image_extent")
                end
                main_painted = true
            end
            seen[name] = true
            operands = {}
        else
            local is_text = token == "BT" or token == "ET" or token == "Tj"
                or token == "TJ" or token == "Tf" or token == "Td"
                or token == "TD" or token == "Tm" or token == "T*"
                or token == "Tc" or token == "Tw" or token == "Tz"
                or token == "TL" or token == "Tr" or token == "Ts"
            return reject(is_text and "text" or token == "gs" and "graphics_state"
                or "operator")
        end
    end
    if not main_painted or #operands ~= 0 or #stack ~= 0 then return reject("sequence") end
    for name in pairs(compatible_names or {}) do
        if not seen[name] then return reject("image_missing") end
    end
    return true
end

function PdfImageStream:_dominant_image(source, offsets, resources, remote_path, page_number)
    local xobjects, err = self:_dictionary_value(source, offsets, resources, "XObject")
    if not xobjects then return nil, err or "pdf_xobject_missing" end
    local _, fields = scan_value(xobjects, 1, 0)
    local candidates, names, seen = {}, {}, {}
    for name, value in pairs(fields or {}) do
        local number = tonumber(value:match("^(%d+)%s+%d+%s+R$"))
        if not number or seen[number] then return nil, "pdf_multiple_images" end
        local image, image_error = self:_image(source, offsets, number, remote_path, page_number, true)
        if not image then return nil, image_error end
        image.pdf_image_name = name
        candidates[#candidates + 1] = image
        names[name], seen[number] = true, true
    end
    if #candidates == 0 then return nil, "pdf_no_image" end
    table.sort(candidates, function(a, b)
        local aa, ba = a.width * a.height, b.width * b.height
        if aa ~= ba then return aa > ba end
        return a.pdf_image_length > b.pdf_image_length
    end)
    local first, second = candidates[1], candidates[2]
    -- Encoded size is only a deterministic secondary order, never evidence
    -- that equally sized page tiles can be safely discarded.
    if second and second.width * second.height >= first.width * first.height * 0.8 then
        return nil, "pdf_multiple_images"
    end
    local _, resource_fields = scan_value(resources, 1, 0)
    for key in pairs(resource_fields or {}) do
        if key ~= "XObject" and key ~= "ExtGState" and key ~= "ProcSet" then
            return nil, "pdf_page_not_image"
        end
    end
    return first, nil, names
end

function PdfImageStream:_resolve_page(source, offsets, number, remote_path, page_number)
    local page_object, page_error = self:_first_page_object(source, offsets, number)
    if not page_object then
        self:_log("resolve.reject", "page_object")
        return nil, page_error
    end
    local resources, resources_error = self:_page_resources(source, offsets, page_object)
    if not resources then
        self:_log("resolve.reject", "resources")
        return nil, resources_error
    end
    local xobjects, xobject_error = self:_dictionary_value(source, offsets, resources, "XObject")
    if not xobjects then
        self:_log("resolve.reject", "xobjects")
        return nil, xobject_error or "pdf_xobject_missing"
    end
    local image_name, candidate = xobjects:match("^<<%s*/([%w_.-]+)%s+(%d+)%s+%d+%s+R%s*>>$")
    local object, object_error = self:_object(source, offsets, page_object)
    if not object then
        self:_log("resolve.reject", "page_dictionary")
        return nil, object_error
    end
    local safe_graphics_states = self:_safe_graphics_states(source, offsets, resources)
    local single, content_error
    if image_name then
        single, content_error = self:_single_image_content(source, offsets, object,
            image_name, safe_graphics_states)
    else
        content_error = "pdf_page_not_image"
    end
    local chosen, chosen_error
    if single then
        chosen, chosen_error = self:_image(source, offsets, tonumber(candidate), remote_path, page_number)
        content_error = chosen_error
    end
    if not chosen and content_error == "pdf_page_not_image" then
        local names
        chosen, chosen_error, names = self:_dominant_image(source, offsets, resources, remote_path, page_number)
        if chosen then
            local valid, err = self:_single_image_content(source, offsets, object,
                chosen.pdf_image_name, safe_graphics_states, names)
            if not valid then
                self:_log("resolve.reject", "dominant_content")
                return nil, err
            end
        end
    elseif not chosen then
        self:_log("resolve.reject", "strict_content")
        return nil, content_error
    end
    if not chosen then
        self:_log("resolve.reject", "dominant_candidate")
        return nil, chosen_error or "pdf_no_image"
    end
    chosen.pdf_page_object = number
    return chosen
end

function PdfImageStream:_collect_page_objects(source, offsets, number, remote_path,
    pages, visited, depth)
    if depth > 64 or visited[number] then return nil, "pdf_page_tree_invalid" end
    visited[number] = true
    local object, error_code = self:_object(source, offsets, number)
    if not object or not object.dictionary then
        return nil, error_code or "pdf_object_dictionary_missing"
    end
    local dict = object.dictionary
    if scalar(dict, "Type") == "/Page" then
        pages[#pages + 1] = {
            name = ("%05d.jpg"):format(#pages + 1),
            path = tostring(remote_path) .. "#pdf/" .. tostring(#pages + 1),
            is_file = true, size = 0, format = "jpg", page = #pages + 1,
            pdf_image = true, pdf_remote_path = remote_path,
            pdf_source_size = source.size, pdf_page_object = number,
        }
        return true
    end
    local kids = scalar(dict, "Kids")
    kids = kids and kids:match("^%[(.*)%]$")
    if not kids then
        local kids_number = reference(dict, "Kids")
        local kids_object = kids_number and self:_object(source, offsets, kids_number)
        kids = kids_object and kids_object.text:match("%[(.-)%]")
    end
    local children = references(kids)
    local declared_count = integer(scalar(dict, "Count"))
    if #children < 1 or not declared_count or declared_count < #children
        or declared_count > self.max_pages then
        return nil, "pdf_page_tree_invalid"
    end
    -- Flat page trees are the common comic-PDF layout.  `/Count == #Kids`
    -- proves that every child contributes one page, so startup need not fetch
    -- any child page object beyond the first page requested below.
    if declared_count == #children then
        for _, child in ipairs(children) do
            if #pages >= self.max_pages then return nil, "pdf_page_count_too_large" end
            pages[#pages + 1] = {
                name = ("%05d.jpg"):format(#pages + 1),
                path = tostring(remote_path) .. "#pdf/" .. tostring(#pages + 1),
                is_file = true, size = 0, format = "jpg", page = #pages + 1,
                pdf_image = true, pdf_remote_path = remote_path,
                pdf_source_size = source.size, pdf_page_object = child,
            }
        end
        return true
    end
    local before = #pages
    for _, child in ipairs(children) do
        local ok, child_error = self:_collect_page_objects(source, offsets, child,
            remote_path, pages, visited, depth + 1)
        if not ok then return nil, child_error end
    end
    if #pages - before ~= declared_count then return nil, "pdf_page_count_mismatch" end
    return true
end

function PdfImageStream:_open_index(source)
    self.compressed, self.object_stream_cache = {}, nil
    local header = read_exact(source, 0, math.min(8, source.size))
    if not header or header:sub(1, 5) ~= "%PDF-" then return nil, "pdf_header_invalid" end
    local tail_size = math.min(source.size, TAIL_BYTES)
    local tail = read_exact(source, source.size - tail_size, tail_size)
    if not tail then return nil, "pdf_tail_read_failed" end
    local xref_value
    for value in tail:gmatch("startxref%s+(%d+)") do xref_value = value end
    local xref_offset = integer(xref_value)
    self:_log("header", "size=" .. tostring(source.size)
        .. " startxref=" .. tostring(xref_offset))
    if not xref_offset or xref_offset >= source.size then return nil, "pdf_startxref_missing" end
    local state, xref_error = self:_parse_xref_at(source, xref_offset)
    if not state then
        self:_log("xref.failed", tostring(xref_error))
        return nil, xref_error
    end
    self:_log("xref", "kind=" .. tostring(state.kind)
        .. " sections=" .. tostring(state.sections))
    if state.encrypted then return nil, "pdf_encrypted" end
    local root = state.root or reference(state.trailer, "Root")
    if not root then return nil, "pdf_root_missing" end
    self.compressed = state.compressed
    local catalog, catalog_error = self:_object(source, state.offsets, root)
    if not catalog or not catalog.dictionary then
        self:_log("catalog.failed", tostring(catalog_error))
        return nil, catalog_error or "pdf_catalog_invalid"
    end
    local pages_number = reference(catalog.dictionary, "Pages")
    for _, key in ipairs({ "OpenAction", "AA", "Names", "AcroForm" }) do
        if field(catalog.dictionary, key) then return nil, "pdf_page_not_image" end
    end
    if not pages_number then
        self:_log("pages.missing", "catalog has no direct Pages reference")
        return nil, "pdf_pages_missing"
    end
    return { state = state, pages_number = pages_number }
end

function PdfImageStream:_icc_profile(source, offsets, color)
    local number = color:match("^%[%s*/ICCBased%s+(%d+)%s+%d+%s+R%s*%]$")
    if not number then return nil end
    local object = self:_object(source, offsets, tonumber(number))
    local dict = object and object.dictionary
    if not dict or scalar(dict, "N") ~= "3" or field(dict, "DecodeParms")
        or field(dict, "F") then return nil end
    local length = self:_number_value(source, offsets, dict, "Length")
    local offset = stream_offset(object.text, object.offset)
    if not length or length < 1 or length > MAX_ICC_BYTES or not offset
        or offset + length > source.size then return nil end
    local bytes = read_exact(source, offset, length)
    if not bytes then return nil end
    if field(dict, "Filter") then
        local filter = filter_name(dict)
        if filter ~= "FlateDecode" and filter ~= "Fl" then return nil end
        bytes = inflate_bounded(self.decompress or default_inflate, bytes,
            math.min(MAX_ICC_BYTES, math.max(1024, #bytes * 8)), MAX_ICC_BYTES)
    end
    if type(bytes) ~= "string" or #bytes < 128 or #bytes > MAX_ICC_BYTES
        or big_endian(bytes, 1, 4) ~= #bytes or bytes:sub(17, 20) ~= "RGB "
        or bytes:sub(37, 40) ~= "acsp" then return nil end
    return bytes
end

function PdfImageStream:_image(source, offsets, number, remote_path, page_number, compatible)
    local object, error_code = self:_object(source, offsets, number)
    if not object then return nil, error_code end
    local dict = object.dictionary
    if not dict then return nil, "pdf_object_dictionary_missing" end
    if scalar(dict, "Subtype") ~= "/Image" then return nil, "pdf_page_not_image" end
    for _, key in ipairs({ "Mask", "SMask", "ImageMask", "Decode", "DecodeParms", "OC", "F", "FFilter", "FDecodeParms" }) do
        if field(dict, key) then return nil, "pdf_page_not_image" end
    end
    local filter = filter_name(dict)
    local flate = filter == "FlateDecode" or filter == "Fl"
    if flate and not compatible then return nil, "pdf_page_not_image" end
    if not flate and filter ~= "DCTDecode" and filter ~= "DCT" then
        return nil, "pdf_image_filter_unsupported"
    end
    local color = scalar(dict, "ColorSpace")
    local icc_profile
    if color and color:match("^%[") then
        icc_profile = self:_icc_profile(source, offsets, color)
        if not icc_profile then return nil, "pdf_page_not_image" end
        color = "/DeviceRGB"
    end
    if flate and icc_profile then return nil, "pdf_page_not_image" end
    if color and color ~= "/DeviceGray" and color ~= "/DeviceRGB" then
        return nil, "pdf_page_not_image"
    end
    local components = color == "/DeviceGray" and 1 or color == "/DeviceRGB" and 3
    if flate and (not components or scalar(dict, "BitsPerComponent") ~= "8") then
        return nil, "pdf_page_not_image"
    end
    local length = self:_number_value(source, offsets, dict, "Length")
    local width, height = self:_number_value(source, offsets, dict, "Width"),
        self:_number_value(source, offsets, dict, "Height")
    if not length or length < 1 or length > MAX_IMAGE_BYTES then return nil, "pdf_image_length_unsupported" end
    if not width or not height or width < 1 or height < 1 then
        return nil, "pdf_image_dimensions_invalid"
    end
    if width * height > MAX_IMAGE_BYTES / (components or 3) then
        return nil, "pdf_image_dimensions_invalid"
    end
    local image_offset = stream_offset(object.text, object.offset)
    if not image_offset or image_offset + length > source.size then return nil, "pdf_image_range_invalid" end
    if compatible and flate then
        local pixels, err = decode_image_pixels(self.decompress,
            read_exact(source, image_offset, length), width * height * components)
        if not pixels then return nil, err end
    elseif compatible then
        local prefix = read_exact(source, image_offset, math.min(length, READ_BYTES))
        local probe = self.image_probe.inspect_bytes or require("webdavmanga.image_probe").inspect_bytes
        local metadata = prefix and probe(prefix, "jpg", length)
        if not metadata or metadata.width ~= width or metadata.height ~= height then
            return nil, "pdf_image_invalid"
        end
    end
    return {
        name = ("%05d.jpg"):format(page_number),
        path = tostring(remote_path) .. "#pdf/" .. tostring(page_number),
        is_file = true, size = length, format = "jpg", width = width, height = height,
        page = page_number, pdf_image = true, pdf_remote_path = remote_path,
        pdf_source_size = source.size, pdf_image_offset = image_offset,
        pdf_image_length = length,
        pdf_image_flate = flate or nil, pdf_image_components = flate and components or nil,
        pdf_icc_profile = icc_profile,
    }
end

function PdfImageStream:extract_remote(image, read_at, target, session, maximum)
    if type(image) ~= "table" or image.pdf_image ~= true
        or type(read_at) ~= "function" or type(target) ~= "string" then
        return nil, "pdf_image_invalid" end
    local length, offset = integer(image.pdf_image_length), integer(image.pdf_image_offset)
    local source_size = integer(image.pdf_source_size) or (offset and length and offset + length)
    if not source_size then return nil, "pdf_image_range_invalid" end
    local source = { size = source_size, read_at = read_at }
    local resolved_image = image
    if not length or not offset then
        local page_object = integer(image.pdf_page_object)
        if not page_object then return nil, "pdf_image_range_invalid" end
        local opened, open_error = session, nil
        if not opened then opened, open_error = self:_open_index(source) end
        if not opened then return nil, open_error end
        local resolved, resolve_error = self:_resolve_page(source, opened.state.offsets,
            page_object, image.pdf_remote_path, image.page)
        if not resolved then return nil, resolve_error end
        resolved_image = resolved
        length, offset = resolved.pdf_image_length, resolved.pdf_image_offset
    end
    local bytes = read_exact(source, offset, length)
    if not bytes then return nil, "pdf_image_read_failed" end
    if resolved_image.pdf_image_flate then
        local expected = resolved_image.width * resolved_image.height * resolved_image.pdf_image_components
        if maximum and expected+65536>maximum then return nil,"cache_limit" end
        local pixels, err = decode_image_pixels(self.decompress, bytes, expected)
        if not pixels then return nil, err end
        local encoded, wrote = pcall(self.encode_png, target, pixels,
            resolved_image.width, resolved_image.height, resolved_image.pdf_image_components)
        if not encoded or not wrote then
            pcall(os.remove, target); return nil, "pdf_image_write_failed"
        end
    else
        if resolved_image.pdf_icc_profile then
            local profile = resolved_image.pdf_icc_profile
            if bytes:sub(1, 2) ~= string.char(255, 216)
                or bytes:find("ICC_PROFILE\0", 1, true) then
                return nil, "pdf_image_invalid"
            end
            local segment_length = #profile + 16
            local segment = string.char(255, 226, math.floor(segment_length / 256),
                segment_length % 256) .. "ICC_PROFILE\0\1\1" .. profile
            bytes = bytes:sub(1, 2) .. segment .. bytes:sub(3)
        end
        if maximum and #bytes>maximum then return nil,"cache_limit" end
        local file = io.open(target, "wb")
        if not file then return nil, "pdf_image_write_failed" end
        local wrote, closed = file:write(bytes), file:close()
        if not wrote or not closed then pcall(os.remove, target); return nil, "pdf_image_write_failed" end
    end
    local metadata, probe_error = self.image_probe.inspect(target, "jpg", { allow_extension_mismatch = true })
    if not metadata then pcall(os.remove, target); return nil, probe_error or "pdf_image_invalid" end
    if metadata.width ~= resolved_image.width or metadata.height ~= resolved_image.height then
        pcall(os.remove, target); return nil, "pdf_image_dimensions_invalid"
    end
    local output = io.open(target, "rb")
    if not output then return nil, "pdf_image_write_failed" end
    metadata.size = output:seek("end")
    output:close()
    return metadata
end

function PdfImageStream:inspect_remote(descriptor, remote_path, first_target)
    if type(descriptor) ~= "table" or type(descriptor.read_at) ~= "function" then
        return nil, "invalid_remote_pdf" end
    local size = integer(descriptor.size)
    if not size or size < 16 then return nil, "pdf_header_invalid" end
    local source = { size = size, read_at = descriptor.read_at }
    local opened, open_error = self:_open_index(source)
    if not opened then return nil, open_error end
    local pages = {}
    local walk_ok, walk_error = self:_collect_page_objects(source, opened.state.offsets,
        opened.pages_number, remote_path,
        pages, {}, 0)
    if not walk_ok then
        self:_log("pages.failed", tostring(walk_error))
        return nil, walk_error or "pdf_page_tree_invalid"
    end
    if #pages < 1 then return nil, "pdf_no_image" end
    local first, first_error = self:_resolve_page(source, opened.state.offsets,
        pages[1] and pages[1].pdf_page_object, remote_path, 1)
    if not first then return nil, first_error or "pdf_first_page_invalid" end
    -- Loader's resolved-offset path copies JPEG bytes directly. Keep Flate
    -- pages lazy so a later cache miss returns through this decoder as well.
    if not first.pdf_image_flate and not first.pdf_icc_profile then pages[1] = first end
    local index = BookIndex.from_items(pages)
    if not index or index:count() < 1 then return nil, "pdf_no_image" end
    local first_metadata
    if first_target then
        first_metadata, walk_error = self:extract_remote(index:get(1), descriptor.read_at, first_target, opened)
        if not first_metadata then return nil, walk_error end
    end
    return { index = index, layout = "pdf_images", first_metadata = first_metadata,
        session = opened, total_pages = #pages }
end

return PdfImageStream
