local Errors = require("webdavmanga.errors")
local Path = require("webdavmanga.path")
local StrictInteger = require("webdavmanga.strict_integer")

local M = {}

local MAX_RESPONSE_BYTES = 256 * 1024

local DAV_NAMESPACE = "DAV:"
local GUARDED_DAV_ELEMENTS = {
    multistatus = true, response = true, propstat = true, status = true,
    responsedescription = true,
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function has_forbidden_xml_control(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d then
            return true
        end
    end
    return false
end

local PREDEFINED_ENTITIES = {
    amp = true, apos = true, gt = true, lt = true, quot = true,
}

local function valid_xml_codepoint(codepoint)
    return codepoint == 0x09 or codepoint == 0x0a or codepoint == 0x0d
        or (codepoint >= 0x20 and codepoint <= 0xd7ff)
        or (codepoint >= 0xe000 and codepoint <= 0xfffd)
        or (codepoint >= 0x10000 and codepoint <= 0x10ffff)
end

local function numeric_entity_value(digits, base)
    if digits == "" then return nil end
    local value = 0
    for index = 1, #digits do
        local byte = digits:byte(index)
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
        if digit >= base or value > math.floor((0x10ffff - digit) / base) then
            return nil
        end
        value = value * base + digit
    end
    return valid_xml_codepoint(value) and value or nil
end

local function valid_entity_reference(reference)
    local name = reference:match("^&([%a]+);$")
    if name then return PREDEFINED_ENTITIES[name] == true end
    local decimal = reference:match("^&#([0-9]+);$")
    if decimal then return numeric_entity_value(decimal, 10) ~= nil end
    local hexadecimal = reference:match("^&#x([0-9a-fA-F]+);$")
    if hexadecimal then return numeric_entity_value(hexadecimal, 16) ~= nil end
    return false
end

local function validate_character_data(state, value, final)
    for index = 1, #value do
        local byte = value:sub(index, index)
        if state.char_entity then
            state.char_entity = state.char_entity .. byte
            if #state.char_entity > 32 then
                return nil, "XML entity reference is too long"
            end
            if byte == ";" then
                if not valid_entity_reference(state.char_entity) then
                    return nil, "invalid XML entity reference"
                end
                state.char_entity = nil
            elseif byte == "&" or byte == "<" then
                return nil, "invalid XML entity reference"
            end
        elseif byte == "&" then
            state.char_entity = "&"
            state.char_brackets = 0
        elseif byte == "]" then
            state.char_brackets = math.min((state.char_brackets or 0) + 1, 2)
        elseif byte == ">" and state.char_brackets == 2 then
            return nil, "literal ]]> is forbidden in XML character data"
        else
            state.char_brackets = 0
        end
    end
    if final then
        if state.char_entity then return nil, "unterminated XML entity reference" end
        state.char_brackets = 0
    end
    return true
end

local function validate_utf8(state, chunk, final)
    local value = (state.utf8_tail or "") .. chunk
    state.utf8_tail = ""
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local length
        if first <= 0x7f then
            length = 1
        elseif first >= 0xc2 and first <= 0xdf then
            length = 2
        elseif first >= 0xe0 and first <= 0xef then
            length = 3
        elseif first >= 0xf0 and first <= 0xf4 then
            length = 4
        else
            return nil, "invalid UTF-8 leading byte"
        end
        if index + length - 1 > #value then
            state.utf8_tail = value:sub(index)
            break
        end
        local second = length > 1 and value:byte(index + 1)
        if length > 1 and (second < 0x80 or second > 0xbf) then
            return nil, "invalid UTF-8 continuation byte"
        end
        if (first == 0xe0 and second < 0xa0)
            or (first == 0xed and second > 0x9f)
            or (first == 0xf0 and second < 0x90)
            or (first == 0xf4 and second > 0x8f) then
            return nil, "invalid UTF-8 scalar value"
        end
        for continuation = 2, length - 1 do
            local byte = value:byte(index + continuation)
            if byte < 0x80 or byte > 0xbf then
                return nil, "invalid UTF-8 continuation byte"
            end
        end
        local codepoint = first
        if length == 2 then
            codepoint = (first - 0xc0) * 0x40 + (second - 0x80)
        elseif length == 3 then
            codepoint = (first - 0xe0) * 0x1000
                + (second - 0x80) * 0x40 + (value:byte(index + 2) - 0x80)
        elseif length == 4 then
            codepoint = (first - 0xf0) * 0x40000
                + (second - 0x80) * 0x1000
                + (value:byte(index + 2) - 0x80) * 0x40
                + (value:byte(index + 3) - 0x80)
        end
        if not valid_xml_codepoint(codepoint) then
            return nil, "UTF-8 scalar is not legal XML character data"
        end
        index = index + length
    end
    if final and state.utf8_tail ~= "" then
        return nil, "truncated UTF-8 sequence"
    end
    return true
end

local function tag_end_at(text, start_at)
    if text:sub(start_at, start_at + 3) == "<!--" then
        local close_at = text:find("-->", start_at + 4, true)
        return close_at and close_at + 2 or nil
    end
    if text:sub(start_at, start_at + 8) == "<![CDATA[" then
        local close_at = text:find("]]>", start_at + 9, true)
        return close_at and close_at + 2 or nil
    end
    if text:sub(start_at, start_at + 1) == "<?" then
        local close_at = text:find("?>", start_at + 2, true)
        return close_at and close_at + 1 or nil
    end
    local quote
    for position = start_at + 1, #text do
        local byte = text:sub(position, position)
        if quote then
            if byte == quote then quote = nil end
        elseif byte == '"' or byte == "'" then
            quote = byte
        elseif byte == ">" then
            return position
        end
    end
    return nil
end

local function split_qname(name)
    if type(name) ~= "string" then return nil end
    local prefix, local_name = name:match(
        "^([%a_][%w_.%-]*):([%a_][%w_.%-]*)$")
    if prefix then return prefix, local_name end
    if name:match("^[%a_][%w_.%-]*$") then return "", name end
    return nil
end

local function xml_name(name)
    return type(name) == "string"
        and name:match("^[%a_:][%w_.:%-]*$") ~= nil
end

local function declaration_attribute(text, position)
    local whitespace_start, whitespace_end = text:find("^%s+", position)
    if whitespace_start ~= position then return nil, nil, nil end
    position = whitespace_end + 1
    local tail = text:sub(position)
    local name = tail:match("^([%a_][%w_.%-]*)")
    if not name then return nil, nil, nil end
    position = position + #name
    while text:sub(position, position):match("%s") do position = position + 1 end
    if text:sub(position, position) ~= "=" then return nil, nil, nil end
    position = position + 1
    while text:sub(position, position):match("%s") do position = position + 1 end
    local quote = text:sub(position, position)
    if quote ~= "'" and quote ~= '"' then return nil, nil, nil end
    local value_end = text:find(quote, position + 1, true)
    if not value_end then return nil, nil, nil end
    return name, text:sub(position + 1, value_end - 1), value_end + 1
end

local function parse_xml_declaration(text)
    local attributes = {}
    local position = 1
    while position <= #text do
        if trim(text:sub(position)) == "" then break end
        local name, value, next_position = declaration_attribute(text, position)
        if not name then return nil, "malformed XML declaration" end
        attributes[#attributes + 1] = { name = name, value = value }
        position = next_position
    end
    if #attributes < 1 or #attributes > 3
        or attributes[1].name ~= "version"
        or (attributes[1].value ~= "1.0" and attributes[1].value ~= "1.1") then
        return nil, "invalid XML declaration version"
    end
    local next_index = 2
    local encoding
    if attributes[next_index] and attributes[next_index].name == "encoding" then
        if not attributes[next_index].value:match("^[%a][%w._%-]*$") then
            return nil, "invalid XML declaration encoding"
        end
        if attributes[next_index].value:lower() ~= "utf-8" then
            return nil, "XML declaration encoding is incompatible with UTF-8 input"
        end
        encoding = "utf-8"
        next_index = next_index + 1
    end
    if attributes[next_index] then
        if attributes[next_index].name ~= "standalone"
            or (attributes[next_index].value ~= "yes"
                and attributes[next_index].value ~= "no") then
            return nil, "invalid XML declaration standalone"
        end
        next_index = next_index + 1
    end
    if attributes[next_index] then return nil, "invalid XML declaration order" end
    return { special = "xml_declaration", encoding = encoding }
end

local function parse_tag(raw_tag)
    if raw_tag:sub(1, 4) == "<!--" then
        local content = raw_tag:sub(5, -4)
        if content:find("--", 1, true) or content:sub(-1) == "-" then
            return nil, "invalid XML comment"
        end
        return { special = "comment" }
    end
    if raw_tag:sub(1, 9) == "<![CDATA[" then
        return { special = "cdata", text = raw_tag:sub(10, -4) }
    end
    if raw_tag:sub(1, 2) == "<?" then
        local body = raw_tag:sub(3, -3)
        local target, data = body:match("^([%a_:][%w_.:%-]*)(.*)$")
        if not target or not xml_name(target)
            or (data ~= "" and not data:sub(1, 1):match("%s")) then
            return nil, "invalid XML processing instruction"
        end
        if target:lower() == "xml" then
            if target ~= "xml" then return nil, "reserved XML processing target" end
            return parse_xml_declaration(data)
        end
        return { special = "pi", target = target }
    end
    if raw_tag:sub(1, 2) == "<!" then return nil, "unsupported XML declaration" end

    local inside = trim(raw_tag:sub(2, -2))
    if inside:sub(1, 1) == "/" then
        local qualified_name = trim(inside:sub(2))
        if not split_qname(qualified_name) then return nil, "malformed XML close tag" end
        return { qualified_name = qualified_name, closing = true }
    end

    local self_closing = inside:sub(-1) == "/"
    if self_closing then inside = trim(inside:sub(1, -2)) end
    local qualified_name = inside:match("^([^%s/>]+)")
    if not split_qname(qualified_name) then return nil, "malformed XML start tag" end
    local attributes = {}
    local seen_attributes = {}
    local position = #qualified_name + 1
    while position <= #inside do
        while position <= #inside and inside:sub(position, position):match("%s") do
            position = position + 1
        end
        if position > #inside then break end
        local tail = inside:sub(position)
        local attribute_name = tail:match("^([%a_][%w_.:%-]*)")
        if not attribute_name or not split_qname(attribute_name)
            or seen_attributes[attribute_name] then
            return nil, "malformed XML attribute"
        end
        seen_attributes[attribute_name] = true
        position = position + #attribute_name
        while position <= #inside and inside:sub(position, position):match("%s") do
            position = position + 1
        end
        if inside:sub(position, position) ~= "=" then
            return nil, "malformed XML attribute assignment"
        end
        position = position + 1
        while position <= #inside and inside:sub(position, position):match("%s") do
            position = position + 1
        end
        local quote = inside:sub(position, position)
        if quote ~= '"' and quote ~= "'" then return nil, "unquoted XML attribute" end
        local value_end = inside:find(quote, position + 1, true)
        if not value_end then return nil, "unterminated XML attribute" end
        local value = inside:sub(position + 1, value_end - 1)
        if value:find("<", 1, true) then return nil, "invalid XML attribute value" end
        attributes[#attributes + 1] = { name = attribute_name, value = value }
        position = value_end + 1
    end
    return {
        qualified_name = qualified_name,
        closing = false,
        self_closing = self_closing,
        attributes = attributes,
    }
end

local function resolve_namespace(stack, declarations, base_bindings, prefix)
    if declarations[prefix] ~= nil then return declarations[prefix] end
    for index = #stack, 1, -1 do
        local inherited = stack[index].declarations[prefix]
        if inherited ~= nil then return inherited end
    end
    if base_bindings and base_bindings[prefix] ~= nil then
        return base_bindings[prefix]
    end
    if prefix == "xml" then return "http://www.w3.org/XML/1998/namespace" end
    if prefix == "" then return "" end
    return nil
end

local function expanded_frame(stack, tag, base_bindings)
    local declarations = {}
    for _, attribute in ipairs(tag.attributes or {}) do
        if attribute.name == "xmlns" then
            if declarations[""] ~= nil then return nil, "duplicate default namespace" end
            declarations[""] = attribute.value
        else
            local namespace_prefix = attribute.name:match("^xmlns:([%a_][%w_.%-]*)$")
            if namespace_prefix then
                if declarations[namespace_prefix] ~= nil or attribute.value == "" then
                    return nil, "invalid namespace binding"
                end
                if namespace_prefix == "xml"
                    and attribute.value ~= "http://www.w3.org/XML/1998/namespace" then
                    return nil, "invalid xml namespace binding"
                end
                declarations[namespace_prefix] = attribute.value
            end
        end
    end
    local prefix, local_name = split_qname(tag.qualified_name)
    local namespace = resolve_namespace(stack, declarations, base_bindings, prefix)
    if namespace == nil then return nil, "unbound XML namespace prefix" end
    if GUARDED_DAV_ELEMENTS[local_name] and namespace ~= DAV_NAMESPACE then
        return nil, "non-DAV " .. local_name .. " element"
    end
    return {
        qualified_name = tag.qualified_name,
        prefix = prefix,
        local_name = local_name,
        namespace = namespace,
        declarations = declarations,
    }
end

local function flattened_bindings(stack, base_bindings)
    local result = {}
    for prefix, value in pairs(base_bindings or {}) do result[prefix] = value end
    for _, frame in ipairs(stack) do
        for prefix, value in pairs(frame.declarations) do result[prefix] = value end
    end
    return result
end

local function strict_http_status(value)
    value = trim(value)
    local version, code_text, remainder = value:match(
        "^HTTP/(%d+%.%d+) (%d%d%d)(.*)$")
    if not version or (remainder ~= "" and remainder:sub(1, 1) ~= " ")
        or remainder:find("[%c]") then
        return nil, "invalid DAV status line"
    end
    return tonumber(code_text)
end

local function strict_nonnegative_integer(value)
    value = trim(value)
    local number = StrictInteger.parse(value, 10)
    if number == nil then
        return nil, "integer outside safe range"
    end
    return number
end

local function contains_dot_segment(path)
    path = tostring(path or ""):gsub("\\", "/")
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return true end
    end
    return false
end

local function contains_requested_collection(full_path, requested)
    if requested == "" then return true end
    local start_at = 1
    while true do
        local first, last = full_path:find(requested, start_at, true)
        if not first then return false end
        local following = full_path:sub(last + 1, last + 1)
        if following == "" or following == "/" then return true end
        start_at = first + 1
    end
end

local function map_zspace_href(full_path, requested)
    local transport_path = Path.webdav_request_path(requested)
    if transport_path == requested then return nil end
    local start_at = 1
    while true do
        local first, last = full_path:find(transport_path, start_at, true)
        if not first then return nil end
        local following = full_path:sub(last + 1, last + 1)
        if following == "" or following == "/" then
            return requested .. full_path:sub(last + 1)
        end
        start_at = first + 1
    end
end

local function stream_href(href, decode_url, html_decode, requested)
    local decoded = trim(html_decode(href or ""))
    decoded = decoded:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/]+(.*)$") or decoded
    decoded = decoded:match("^[^?#]*") or decoded
    decoded = html_decode(decode_url(decoded))
    if contains_dot_segment(decoded) then return nil end
    local full_path = Path.normalize_remote(decoded):gsub("/+$", "")
    local mapped = map_zspace_href(full_path, requested)
    if mapped then return mapped end
    if not contains_requested_collection(full_path, requested) then return nil end
    return full_path
end

local function assign_captured(details, frame, value)
    local target = frame.propstat and frame.propstat.properties or details.properties
    if frame.local_name == "href" then
        if details.href ~= nil then return nil, "duplicate DAV href" end
        details.href = value
    elseif frame.local_name == "status" then
        local code, status_error = strict_http_status(value)
        if not code then return nil, status_error end
        if frame.propstat then
            if frame.propstat.status ~= nil then return nil, "duplicate DAV propstat status" end
            frame.propstat.status = code
        else
            if details.status ~= nil then return nil, "duplicate DAV response status" end
            details.status = code
        end
    elseif frame.local_name == "getcontentlength" then
        if target.size_present then return nil, "duplicate DAV getcontentlength" end
        target.size_present = true
        target.size_text = value
    elseif frame.local_name == "getetag" then
        if target.etag ~= nil then return nil, "duplicate DAV getetag" end
        target.etag = value
    elseif frame.local_name == "getlastmodified" then
        if target.modified ~= nil then return nil, "duplicate DAV getlastmodified" end
        target.modified = value
    end
    return true
end

local function close_detail_frame(details, frame)
    if frame.capture then
        return assign_captured(details, frame, table.concat(frame.text))
    end
    return true
end

local function response_details(block, inherited_bindings)
    local details = { properties = {}, propstats = {} }
    local stack = {}
    local position = 1
    local root_seen = false
    while position <= #block do
        local tag_start = block:find("<", position, true)
        local text = tag_start and block:sub(position, tag_start - 1)
            or block:sub(position)
        local top = stack[#stack]
        if top and top.capture and text ~= "" then top.text[#top.text + 1] = text end
        if not tag_start then break end
        local tag_end = tag_end_at(block, tag_start)
        if not tag_end then return nil, "unterminated response tag" end
        local tag, tag_error = parse_tag(block:sub(tag_start, tag_end))
        if not tag then return nil, tag_error end
        if tag.special then
            if tag.special == "cdata" then
                top = stack[#stack]
                if top and top.capture then top.text[#top.text + 1] = tag.text end
            end
        elseif tag.closing then
            local frame = stack[#stack]
            if not frame or frame.qualified_name ~= tag.qualified_name then
                return nil, "crossed or mismatched response element"
            end
            stack[#stack] = nil
            local closed, close_error = close_detail_frame(details, frame)
            if not closed then return nil, close_error end
        else
            local parent = stack[#stack]
            if parent and parent.capture then
                return nil, "captured DAV value contains child elements"
            end
            local frame, frame_error = expanded_frame(stack, tag, inherited_bindings)
            if not frame then return nil, frame_error end
            if not root_seen then
                if frame.local_name ~= "response" or frame.namespace ~= DAV_NAMESPACE then
                    return nil, "response block has invalid root"
                end
                root_seen = true
            elseif #stack == 0 then
                return nil, "multiple response roots"
            end
            frame.propstat = parent and parent.propstat or nil
            if frame.namespace == DAV_NAMESPACE and frame.local_name == "propstat" then
                frame.propstat = { properties = {} }
                details.propstats[#details.propstats + 1] = frame.propstat
            end
            if frame.namespace == DAV_NAMESPACE and frame.local_name == "collection" then
                local target = frame.propstat and frame.propstat.properties or details.properties
                target.is_folder = true
            end
            local captures_response_href = frame.namespace == DAV_NAMESPACE
                and frame.local_name == "href" and parent
                and parent.namespace == DAV_NAMESPACE
                and parent.local_name == "response"
                and details.href == nil
            if captures_response_href or (frame.namespace == DAV_NAMESPACE and (
                frame.local_name == "status"
                or frame.local_name == "getcontentlength"
                or frame.local_name == "getetag"
                or frame.local_name == "getlastmodified")) then
                frame.capture = true
                frame.text = {}
            end
            stack[#stack + 1] = frame
            if tag.self_closing then
                stack[#stack] = nil
                local closed, close_error = close_detail_frame(details, frame)
                if not closed then return nil, close_error end
            end
        end
        position = tag_end + 1
    end
    if #stack ~= 0 or not root_seen then return nil, "incomplete response block" end
    return details
end

local function merge_properties(target, source)
    if source.is_folder then target.is_folder = true end
    if source.size_present then
        local size, size_error = strict_nonnegative_integer(source.size_text)
        if size == nil then return nil, size_error end
        if target.size == nil then target.size = size end
    end
    if target.etag == nil then target.etag = source.etag end
    if target.modified == nil then target.modified = source.modified end
    return true
end

local function response_record(block, parser)
    local details, detail_error = response_details(block, parser.response_bindings)
    if not details then return nil, detail_error end
    if details.href == nil then return nil end
    local full_path = stream_href(details.href, parser.decode_url,
        parser.html_decode, parser.requested)
    if not full_path then return nil end
    local selected = {}
    if #details.propstats > 0 then
        local successful = false
        for _, propstat in ipairs(details.propstats) do
            if propstat.status == nil
                or (propstat.status >= 200 and propstat.status < 300) then
                local merged, merge_error = merge_properties(selected, propstat.properties)
                if not merged then return nil, merge_error end
                successful = true
            end
        end
        if not successful then return nil end
    else
        if details.status and (details.status < 200 or details.status >= 300) then
            return nil
        end
        local merged, merge_error = merge_properties(selected, details.properties)
        if not merged then return nil, merge_error end
    end
    return {
        full_path = full_path,
        name = full_path:match("([^/]+)$") or "",
        is_folder = selected.is_folder and true or nil,
        is_file = not selected.is_folder and true or nil,
        size = selected.size,
        modified = selected.modified and parser.html_decode(trim(selected.modified)) or nil,
        etag = selected.etag and parser.html_decode(trim(selected.etag)) or nil,
    }
end

local RESPONSE_COMPLETE_STATES = {
    direct = true,
    propstats = true,
    after_error = true,
    after_description = true,
    after_location = true,
}

local PROPSTAT_COMPLETE_STATES = {
    complete = true,
    after_error = true,
    after_description = true,
}

local LOCATION_COMPLETE_STATES = {
    complete = true,
}

local function advance_response_grammar(parent, child)
    if child.namespace ~= DAV_NAMESPACE then
        return nil, "non-DAV element in DAV response grammar"
    end
    local state = parent.grammar_state
    local name = child.local_name
    if state == "need_href" then
        if name ~= "href" then return nil, "DAV response must begin with href" end
        parent.grammar_state = "need_branch"
        return true
    end
    if state == "need_branch" then
        if name == "href" then
            parent.grammar_state = "need_direct_status"
            return true
        elseif name == "status" then
            parent.grammar_state = "direct"
            return true
        elseif name == "propstat" then
            parent.grammar_state = "propstats"
            return true
        end
        return nil, "DAV response requires status or propstat after href"
    end
    if state == "need_direct_status" then
        if name == "href" then
            return true
        elseif name == "status" then
            parent.grammar_state = "direct"
            return true
        end
        return nil, "DAV response extra hrefs must be followed by status"
    end
    if state == "propstats" and name == "propstat" then return true end
    if state == "direct" or state == "propstats" then
        if name == "error" then
            parent.grammar_state = "after_error"
            return true
        elseif name == "responsedescription" then
            parent.grammar_state = "after_description"
            return true
        elseif name == "location" then
            parent.grammar_state = "after_location"
            return true
        end
    elseif state == "after_error" then
        if name == "responsedescription" then
            parent.grammar_state = "after_description"
            return true
        elseif name == "location" then
            parent.grammar_state = "after_location"
            return true
        end
    elseif state == "after_description" and name == "location" then
        parent.grammar_state = "after_location"
        return true
    end
    return nil, "DAV response child is duplicated, mixed, or out of order"
end

local function advance_propstat_grammar(parent, child)
    if child.namespace ~= DAV_NAMESPACE then
        return nil, "non-DAV element in DAV propstat grammar"
    end
    local state = parent.grammar_state
    local name = child.local_name
    if state == "need_prop" and name == "prop" then
        parent.grammar_state = "need_status"
        return true
    elseif state == "need_status" and name == "status" then
        parent.grammar_state = "complete"
        return true
    elseif state == "complete" then
        if name == "error" then
            parent.grammar_state = "after_error"
            return true
        elseif name == "responsedescription" then
            parent.grammar_state = "after_description"
            return true
        end
    elseif state == "after_error" and name == "responsedescription" then
        parent.grammar_state = "after_description"
        return true
    end
    return nil, "DAV propstat child is missing, duplicated, or out of order"
end

local function advance_location_grammar(parent, child)
    if parent.grammar_state ~= "need_href"
        or child.namespace ~= DAV_NAMESPACE or child.local_name ~= "href" then
        return nil, "DAV location must contain exactly one DAV href"
    end
    parent.grammar_state = "complete"
    return true
end

local function advance_parent_grammar(parent, child)
    if not parent or parent.namespace ~= DAV_NAMESPACE then return true end
    if parent.local_name == "response" then
        return advance_response_grammar(parent, child)
    elseif parent.local_name == "propstat" then
        return advance_propstat_grammar(parent, child)
    elseif parent.local_name == "location" then
        return advance_location_grammar(parent, child)
    end
    return true
end

local function validate_grammar_character_data(parent, value)
    if parent and parent.namespace == DAV_NAMESPACE
        and parent.local_name == "location" and value ~= "" then
        return nil, "DAV location cannot contain character data"
    end
    return true
end

local function complete_grammar_frame(frame)
    if frame.namespace ~= DAV_NAMESPACE then return true end
    if frame.local_name == "response" then
        if not RESPONSE_COMPLETE_STATES[frame.grammar_state] then
            return nil, "DAV response is missing href, status, or propstat"
        end
    elseif frame.local_name == "propstat" then
        if not PROPSTAT_COMPLETE_STATES[frame.grammar_state] then
            return nil, "DAV propstat requires prop followed by status"
        end
    elseif frame.local_name == "location" then
        if not LOCATION_COMPLETE_STATES[frame.grammar_state] then
            return nil, "DAV location must contain exactly one DAV href"
        end
    end
    return true
end

local StreamParser = {}
StreamParser.__index = StreamParser

function StreamParser:_fail(detail)
    if type(detail) == "table" and detail.code then
        self.failed = detail
    else
        self.failed = Errors.decode(detail)
    end
    return nil, self.failed
end

function StreamParser:_emit(block)
    local parsed, record, parse_error = pcall(response_record, block, self)
    if not parsed then return self:_fail("response decode failed") end
    if parse_error then return self:_fail(parse_error) end
    if not record then return true end
    local called, accepted, callback_error = pcall(self.on_response, record)
    if not called then return self:_fail("response callback failed") end
    if accepted == false or (accepted == nil and callback_error ~= nil) then
        return self:_fail(callback_error or "response callback rejected record")
    end
    self.emitted_count = self.emitted_count + 1
    return true
end

function StreamParser:_handle_tag(tag)
    if tag.special then
        local parent = self.stack[#self.stack]
        if tag.special == "xml_declaration" then
            if self.root_seen or self.xml_declaration_seen
                or self.prolog_content_seen or self.in_response then
                return nil, "XML declaration must be first"
            end
            self.xml_declaration_seen = true
            self.declared_encoding = tag.encoding or "utf-8"
        elseif tag.special == "cdata" then
            if parent and parent.description then
                return nil, "DAV responsedescription cannot contain CDATA"
            end
            if parent and parent.namespace == DAV_NAMESPACE
                and parent.local_name == "location" then
                return nil, "DAV location cannot contain CDATA"
            end
            if not self.in_response then return nil, "CDATA outside a response" end
        elseif not self.root_seen then
            self.prolog_content_seen = true
        end
        return true
    end
    if tag.closing then
        local frame = self.stack[#self.stack]
        if not frame or frame.qualified_name ~= tag.qualified_name then
            return nil, "crossed or mismatched XML close tag"
        end
        local complete, complete_error = complete_grammar_frame(frame)
        if not complete then return nil, complete_error end
        self.stack[#self.stack] = nil
        if frame.local_name == "response" and frame.namespace == DAV_NAMESPACE then
            return true, "response_close"
        end
        if frame.local_name == "multistatus" and frame.namespace == DAV_NAMESPACE then
            self.root_closed = true
        end
        return true
    end

    local parent = self.stack[#self.stack]
    local frame, frame_error = expanded_frame(self.stack, tag)
    if not frame then return nil, frame_error end
    if parent and parent.description then
        return nil, "DAV responsedescription must contain only character data"
    end
    local advanced, grammar_error = advance_parent_grammar(parent, frame)
    if not advanced then return nil, grammar_error end
    if parent and parent.local_name == "multistatus"
        and parent.namespace == DAV_NAMESPACE and self.root_description_seen then
        return nil, "DAV responsedescription must be the final multistatus child"
    end
    if #self.stack == 0 then
        if self.root_seen or frame.local_name ~= "multistatus"
            or frame.namespace ~= DAV_NAMESPACE then
            return nil, "document root must be DAV multistatus"
        end
        self.root_seen = true
    elseif self.root_closed then
        return nil, "element after multistatus root"
    elseif frame.local_name == "multistatus" and frame.namespace == DAV_NAMESPACE then
        return nil, "nested DAV multistatus"
    elseif frame.local_name == "response" and frame.namespace == DAV_NAMESPACE then
        if not parent or parent.local_name ~= "multistatus"
            or parent.namespace ~= DAV_NAMESPACE then
            return nil, "DAV response must be a multistatus child"
        end
        if self.root_description_seen then
            return nil, "DAV response cannot follow responsedescription"
        end
        frame.grammar_state = "need_href"
    elseif frame.local_name == "responsedescription"
        and frame.namespace == DAV_NAMESPACE then
        if not parent or parent.namespace ~= DAV_NAMESPACE then
            return nil, "DAV responsedescription has invalid parent"
        elseif parent.local_name == "multistatus" then
            if self.response_count == 0 then
                return nil, "DAV responsedescription must follow a response"
            end
            if self.root_description_seen then
                return nil, "duplicate DAV responsedescription"
            end
            self.root_description_seen = true
        elseif parent.local_name ~= "response" and parent.local_name ~= "propstat" then
            return nil, "DAV responsedescription has invalid parent"
        else
            -- The parent's ordered grammar transition above validates placement
            -- and cardinality for response and propstat descriptions.
        end
        frame.description = true
    elseif frame.local_name == "propstat" and frame.namespace == DAV_NAMESPACE then
        if not parent or parent.local_name ~= "response"
            or parent.namespace ~= DAV_NAMESPACE then
            return nil, "DAV propstat must be a response child"
        end
        frame.grammar_state = "need_prop"
    elseif frame.local_name == "location" and frame.namespace == DAV_NAMESPACE then
        if not parent or parent.local_name ~= "response"
            or parent.namespace ~= DAV_NAMESPACE then
            return nil, "DAV location must be a response child"
        end
        frame.grammar_state = "need_href"
    elseif frame.local_name == "status" and frame.namespace == DAV_NAMESPACE then
        if not parent or parent.namespace ~= DAV_NAMESPACE
            or (parent.local_name ~= "propstat" and parent.local_name ~= "response") then
            return nil, "DAV status has invalid parent"
        end
    end
    if frame.local_name == "response" and frame.namespace == DAV_NAMESPACE
        and tag.self_closing then
        return nil, "self-closing DAV response"
    end
    self.stack[#self.stack + 1] = frame
    local event
    if frame.local_name == "response" and frame.namespace == DAV_NAMESPACE then
        event = "response_open"
    end
    if tag.self_closing then
        local complete, complete_error = complete_grammar_frame(frame)
        if not complete then return nil, complete_error end
        self.stack[#self.stack] = nil
        if frame.local_name == "multistatus" and frame.namespace == DAV_NAMESPACE then
            self.root_closed = true
        end
    end
    return true, event
end

function StreamParser:_process()
    while true do
        if self.in_response then
            local tag_start = self.tail:find("<", self.scan_at, true)
            if not tag_start then
                local text = self.tail:sub(self.scan_at)
                local parent = self.stack[#self.stack]
                local grammar_valid, grammar_error =
                    validate_grammar_character_data(parent, text)
                if not grammar_valid then return self:_fail(grammar_error) end
                local valid, validation_error = validate_character_data(
                    self, text, false)
                if not valid then return self:_fail(validation_error) end
                if parent and parent.description and text ~= "" then
                    self.response_discarded_bytes = self.response_discarded_bytes + #text
                    self.tail = self.tail:sub(1, self.scan_at - 1)
                end
                self.scan_at = #self.tail + 1
                if #self.tail + self.response_discarded_bytes > MAX_RESPONSE_BYTES then
                    return self:_fail("response element exceeds 256 KiB")
                end
                return true
            end
            local parent = self.stack[#self.stack]
            local grammar_valid, grammar_error = validate_grammar_character_data(
                parent, self.tail:sub(self.scan_at, tag_start - 1))
            if not grammar_valid then return self:_fail(grammar_error) end
            local valid, validation_error = validate_character_data(
                self, self.tail:sub(self.scan_at, tag_start - 1), true)
            if not valid then return self:_fail(validation_error) end
            if parent and parent.description and tag_start > self.scan_at then
                local discarded = tag_start - self.scan_at
                self.response_discarded_bytes = self.response_discarded_bytes + discarded
                self.tail = self.tail:sub(1, self.scan_at - 1)
                    .. self.tail:sub(tag_start)
                tag_start = self.scan_at
            end
            local tag_end = tag_end_at(self.tail, tag_start)
            if not tag_end then
                self.scan_at = tag_start
                if #self.tail + self.response_discarded_bytes > MAX_RESPONSE_BYTES then
                    return self:_fail("response element exceeds 256 KiB")
                end
                return true
            end
            if tag_end + self.response_discarded_bytes > MAX_RESPONSE_BYTES then
                return self:_fail("response element exceeds 256 KiB")
            end
            local info, tag_error = parse_tag(self.tail:sub(tag_start, tag_end))
            if not info then return self:_fail(tag_error) end
            local handled, event_or_error = self:_handle_tag(info)
            if not handled then return self:_fail(event_or_error) end
            if event_or_error == "response_close" then
                    local block = self.tail:sub(1, tag_end)
                    self.tail = self.tail:sub(tag_end + 1)
                    self.in_response = false
                    self.scan_at = 1
                    self.response_discarded_bytes = 0
                    self.response_count = self.response_count + 1
                    local ok, err = self:_emit(block)
                    if not ok then return nil, err end
            else
                self.scan_at = tag_end + 1
            end
        else
            local tag_start = self.tail:find("<", 1, true)
            if not tag_start then
                local parent = self.stack[#self.stack]
                local valid, validation_error = validate_character_data(
                    self, self.tail, false)
                if not valid then return self:_fail(validation_error) end
                if not (parent and parent.description)
                    and trim(self.tail) ~= "" then
                    return self:_fail("text outside XML elements")
                end
                if not self.root_seen and self.tail ~= "" then
                    self.prolog_content_seen = true
                end
                self.tail = ""
                return true
            end
            local valid, validation_error = validate_character_data(
                self, self.tail:sub(1, tag_start - 1), true)
            if not valid then return self:_fail(validation_error) end
            if tag_start > 1 then
                local parent = self.stack[#self.stack]
                if not (parent and parent.description)
                    and trim(self.tail:sub(1, tag_start - 1)) ~= "" then
                    return self:_fail("text outside DAV response")
                end
                if not self.root_seen then self.prolog_content_seen = true end
                self.tail = self.tail:sub(tag_start)
            end
            local tag_end = tag_end_at(self.tail, 1)
            if not tag_end then
                if #self.tail > MAX_RESPONSE_BYTES then
                    return self:_fail("unterminated XML tag exceeds 256 KiB")
                end
                return true
            end
            local info, tag_error = parse_tag(self.tail:sub(1, tag_end))
            if not info then return self:_fail(tag_error) end
            local handled, event_or_error = self:_handle_tag(info)
            if not handled then return self:_fail(event_or_error) end
            if event_or_error == "response_open" then
                self.in_response = true
                self.response_bindings = flattened_bindings(self.stack)
                self.response_discarded_bytes = 0
                self.scan_at = tag_end + 1
            else
                self.tail = self.tail:sub(tag_end + 1)
            end
        end
    end
end

function StreamParser:push(chunk)
    if self.failed then return nil, self.failed end
    if self.finished then return self:_fail("stream already finished") end
    if type(chunk) ~= "string" then return self:_fail("response chunk must be a string") end
    if has_forbidden_xml_control(chunk) then
        return self:_fail("forbidden XML control character")
    end
    local valid_utf8, utf8_error = validate_utf8(self, chunk, false)
    if not valid_utf8 then return self:_fail(utf8_error) end
    if chunk == "" then return true end
    self.tail = self.tail .. chunk
    return self:_process()
end

function StreamParser:finish()
    if self.failed then return nil, self.failed end
    if self.finished then return true end
    local ok, err = self:_process()
    if not ok then return nil, err end
    local valid_utf8, utf8_error = validate_utf8(self, "", true)
    if not valid_utf8 then return self:_fail(utf8_error) end
    local valid, validation_error = validate_character_data(self, "", true)
    if not valid then return self:_fail(validation_error) end
    if self.in_response then return self:_fail("unterminated response element") end
    if self.tail:find("<", 1, true) then
        return self:_fail("unterminated XML tag")
    end
    if #self.stack ~= 0 or not self.root_seen or not self.root_closed then
        return self:_fail("incomplete DAV multistatus document")
    end
    if self.response_count == 0 then
        return self:_fail("missing response elements")
    end
    self.finished = true
    self.tail = ""
    return true
end

function M.new_stream(options)
    options = options or {}
    return setmetatable({
        requested = Path.normalize_remote(options.request_path),
        decode_url = options.decode_url or function(value) return value end,
        html_decode = options.html_decode or function(value) return value end,
        on_response = assert(options.on_response, "on_response is required"),
        tail = "",
        scan_at = 1,
        response_discarded_bytes = 0,
        stack = {},
        in_response = false,
        response_count = 0,
        emitted_count = 0,
        char_brackets = 0,
        char_entity = nil,
        utf8_tail = "",
        root_description_seen = false,
        xml_declaration_seen = false,
        prolog_content_seen = false,
        finished = false,
    }, StreamParser)
end

return M
