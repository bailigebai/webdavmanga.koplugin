local ArchivePages = require("webdavmanga.archive_pages")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

-- The host runner has no luxl C module. This emits the same XML events used
-- by the archive parser while the ZIP and Range logic remain production code.
package.preload.luxl = function()
    local luxl = { EVENT_START = 0, EVENT_END = 1,
        EVENT_ATTR_NAME = 3, EVENT_ATTR_VAL = 4 }
    function luxl.new(xml)
        local tokens = {}
        local function add(event, offset, size)
            tokens[#tokens + 1] = { event, offset, size }
        end
        for first, body in xml:gmatch("()<(.-)>") do
            local closing = body:sub(1, 1) == "/"
            if body:sub(1, 1) ~= "?" and body:sub(1, 1) ~= "!" then
                local start, finish = body:find("[%w_:.-]+", closing and 2 or 1)
                if start then
                    add(closing and 1 or 0, first + start - 1, finish - start + 1)
                    if not closing then
                        local cursor = finish + 1
                        while true do
                            local a, b, name, quote, value = body:find(
                                "([%w_:.-]+)%s*=%s*([\"'])(.-)%2", cursor)
                            if not a then break end
                            add(3, first + a - 1, #name)
                            local quoted = body:find(quote, a, true)
                            add(4, first + quoted, #value)
                            cursor = b + 1
                        end
                        if body:match("/%s*$") then add(1, first + start - 1, finish - start + 1) end
                    end
                end
            end
        end
        return { Lexemes = function()
            local cursor = 0
            return function()
                cursor = cursor + 1
                local token = tokens[cursor]
                if token then return token[1], token[2], token[3] end
            end
        end }
    end
    return luxl
end

local function xor32(a, b)
    local value, place = 0, 1
    for _ = 1, 32 do
        if a % 2 ~= b % 2 then value = value + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return value
end
local function crc32(bytes)
    local crc = 4294967295
    for position = 1, #bytes do
        crc = xor32(crc, bytes:byte(position))
        for _ = 1, 8 do
            local low = crc % 2
            crc = math.floor(crc / 2)
            if low == 1 then crc = xor32(crc, 3988292384) end
        end
    end
    return 4294967295 - crc
end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function zip(entries)
    local locals, central, offset = {}, {}, 0
    for ordinal, entry in ipairs(entries) do
        local name, data = entry[1], entry[2]
        local header = "PK\003\004" .. u16(20) .. u16(0) .. u16(0)
            .. u16(0) .. u16(0) .. u32(crc32(data)) .. u32(#data)
            .. u32(#data) .. u16(#name) .. u16(0) .. name .. data
        locals[#locals + 1] = header
        central[#central + 1] = "PK\001\002" .. u16(20) .. u16(20)
            .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(crc32(data))
            .. u32(#data) .. u32(#data) .. u16(#name) .. u16(0)
            .. u16(0) .. u16(0) .. u16(0) .. u32(0) .. u32(offset) .. name
        offset = offset + #header
    end
    local body, directory = table.concat(locals), table.concat(central)
    return body .. directory .. "PK\005\006" .. u16(0) .. u16(0)
        .. u16(#entries) .. u16(#entries) .. u32(#directory) .. u32(#body) .. u16(0)
end

local image = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
    0, 1, 0, 1, 1, 1, 0x11, 0) .. string.rep("a", 30000)
    .. string.char(0xFF, 0xD9)
local function book(kind, count, small, repeat_first)
    local manifest, spine, entries = {}, {}, {
        { "mimetype", "application/epub+zip" },
        { "META-INF/container.xml", '<container><rootfile full-path="OEBPS/content.opf" /></container>' },
    }
    local expected = {}
    for page = 1, count do
        local id, path = "p" .. page, ("%03d.jpg"):format(page)
        local image_href = repeat_first and page == 2 and "001.jpg" or path
        local href = path
        if kind == "direct" then href = image_href end
        if kind ~= "direct" then href = ("%03d.xhtml"):format(page) end
        local media = kind == "direct" and "image/jpeg"
            or "application/xhtml+xml"
        manifest[#manifest + 1] = ('<item id="%s" href="%s" media-type="%s" />'):format(id, href, media)
        if kind ~= "direct" then
            manifest[#manifest + 1] = ('<item id="i%d" href="%s" media-type="image/jpeg" />'):format(page, path)
            local wrapper = kind == "svg"
                and ('<html><body><svg><image href="%s" /></svg></body></html>'):format(image_href)
                or ('<html><body><img src="%s" /></body></html>'):format(image_href)
            entries[#entries + 1] = { "OEBPS/" .. href, wrapper }
        end
        entries[#entries + 1] = { "OEBPS/" .. path, small and "image" or image }
        spine[#spine + 1] = ('<itemref idref="%s" />'):format(id)
        expected[#expected + 1] = "OEBPS/" .. image_href
    end
    if kind == "cover" then
        table.insert(manifest, 1, '<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image" />')
        table.insert(spine, 1, '<itemref idref="cover" />')
        entries[#entries + 1] = { "OEBPS/cover.jpg", small and "image" or image }
        table.insert(expected, 1, "OEBPS/cover.jpg")
    end
    table.insert(entries, 3, { "OEBPS/content.opf", '<package><manifest>'
        .. table.concat(manifest) .. '</manifest><spine>' .. table.concat(spine) .. '</spine></package>' })
    return zip(entries), expected
end

local function inspect(kind, count, options, small)
    local bytes, expected = book(kind, count, small)
    local reads = {}
    local descriptor = { size = #bytes, read_at = function(offset, length)
        reads[#reads + 1] = { offset, length }
        return bytes:sub(offset + 1, offset + length)
    end }
    local result, err = ArchivePages:new():inspect_remote(descriptor, "epub", "/book.epub", options)
    return result, err, reads, expected, bytes
end

for _, kind in ipairs({ "direct", "cover", "xhtml", "svg" }) do
    local result, err, reads, expected, bytes = inspect(kind, 6,
        { page_limit = 3, source_version = "v1", generation = "opening-1" })
    expect(result and not err and result.index:count() == 3,
        kind .. " opening returns three real pages: " .. tostring(err))
    expect(result.incomplete == true and result.total_pages == #expected,
        kind .. " opening reports the full spine length")
    for page = 1, 3 do
        expect(result.index:get(page).archive_entry_name == expected[page],
            kind .. " opening preserves spine order")
    end
    local fourth = expected[4]
    local fourth_entry = nil
    for _, entry in ipairs(result.continuation and result.continuation.entries or {}) do
        if entry.name == fourth then fourth_entry = entry; break end
    end
    expect(result.continuation and fourth_entry,
        kind .. " opening returns validated entries for a resumable fourth page")
    local fourth_header = fourth_entry.archive_local_offset
    for _, read in ipairs(reads) do
        expect(not (read[1] >= fourth_header and read[1] < fourth_header + 30 + #fourth),
            kind .. " opening must not fetch fourth-page content")
        expect(read[2] < #bytes, kind .. " opening must not download the EPUB")
    end
end

print(("rebuild_0411_epub_opening_spec: %d checks"):format(checks))
return { inspect = inspect, book = book }
