local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

package.preload["luxl"] = function()
    local luxl = {
        EVENT_START = 0,
        EVENT_END = 1,
        EVENT_ATTR_NAME = 3,
        EVENT_ATTR_VAL = 4,
    }

    local function add(tokens, event, offset, size)
        tokens[#tokens + 1] = { event, offset, size }
    end

    function luxl.new(xml)
        local tokens, position = {}, 1
        while true do
            local first, last, body = xml:find("<([^>]+)>", position)
            if not first then break end
            local body_offset = first
            if body:match("^%s*/") then
                local name_start, name_end = body:find("[%w_:.-]+", 2)
                if name_start then add(tokens, luxl.EVENT_END,
                    body_offset + name_start - 1, name_end - name_start + 1) end
            elseif not body:match("^%s*[?!]") then
                local name_start, name_end = body:find("[%w_:.-]+")
                if name_start then
                    add(tokens, luxl.EVENT_START, body_offset + name_start - 1,
                        name_end - name_start + 1)
                    local attribute_position = name_end + 1
                    while true do
                        local attr_start, attr_end, name, quote, value = body:find(
                            "([%w_:.-]+)%s*=%s*([\"'])(.-)[\"']", attribute_position)
                        if not attr_start then break end
                        local segment = body:sub(attr_start, attr_end)
                        local quote_start = assert(segment:find(quote, 1, true))
                        add(tokens, luxl.EVENT_ATTR_NAME, body_offset + attr_start - 1, #name)
                        add(tokens, luxl.EVENT_ATTR_VAL,
                            body_offset + attr_start + quote_start - 1, #value)
                        attribute_position = attr_end + 1
                    end
                    if body:match("/%s*$") then
                        add(tokens, luxl.EVENT_END, body_offset + name_start - 1,
                            name_end - name_start + 1)
                    end
                end
            end
            position = last + 1
        end
        return {
            Lexemes = function()
                local index = 0
                return function()
                    index = index + 1
                    local token = tokens[index]
                    if token then return token[1], token[2], token[3] end
                end
            end,
        }
    end

    return luxl
end

local function xor32(left, right)
    local result, place = 0, 1
    for _ = 1, 32 do
        if left % 2 ~= right % 2 then result = result + place end
        left, right, place = math.floor(left / 2), math.floor(right / 2), place * 2
    end
    return result
end

local function crc32(value)
    local crc = 4294967295
    for index = 1, #value do
        crc = xor32(crc, value:byte(index))
        for _ = 1, 8 do
            local low = crc % 2
            crc = math.floor(crc / 2)
            if low == 1 then crc = xor32(crc, 3988292384) end
        end
    end
    return 4294967295 - crc
end

local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function zip_fixture(entries)
    local local_parts, central_parts, offset = {}, {}, 0
    for _, entry in ipairs(entries) do
        local name, data = entry.name, entry.data or ""
        local method, flags = entry.method or 0, entry.flags or 0
        local compressed = entry.compressed or data
        local checksum = entry.crc32 or crc32(data)
        local local_header = "PK\003\004" .. le16(20) .. le16(flags) .. le16(method)
            .. le16(0) .. le16(0) .. le32(checksum) .. le32(#compressed)
            .. le32(#data) .. le16(#name) .. le16(0) .. name .. compressed
        local_parts[#local_parts + 1] = local_header
        central_parts[#central_parts + 1] = "PK\001\002" .. le16(20) .. le16(20)
            .. le16(flags) .. le16(method) .. le16(0) .. le16(0) .. le32(checksum)
            .. le32(#compressed) .. le32(#data) .. le16(#name) .. le16(0)
            .. le16(0) .. le16(0) .. le16(0) .. le32(0) .. le32(offset) .. name
        offset = offset + #local_header
    end
    local local_bytes, central = table.concat(local_parts), table.concat(central_parts)
    return local_bytes .. central .. "PK\005\006" .. le16(0) .. le16(0)
        .. le16(#entries) .. le16(#entries) .. le32(#central) .. le32(#local_bytes) .. le16(0)
end

local container = [[<?xml version="1.0"?>
<container><rootfiles><rootfile full-path="OEBPS/content.opf" /></rootfiles></container>]]

local function epub_entries(opf, extra)
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = container },
        { name = "OEBPS/content.opf", data = opf },
    }
    for _, entry in ipairs(extra or {}) do entries[#entries + 1] = entry end
    return entries
end

local function remote(bytes, requests)
    return {
        size = #bytes,
        read_at = function(offset, count)
            if requests then requests[#requests + 1] = { offset = offset, count = count } end
            return bytes:sub(offset + 1, offset + count)
        end,
    }
end

local function inspect(entries, requests, options, metadata_work_path, inspect_options)
    local bytes = zip_fixture(entries)
    local descriptor = remote(bytes, requests)
    descriptor.metadata_work_path = metadata_work_path
    return require("webdavmanga.archive_pages"):new(options):inspect_remote(
        descriptor, "epub", "/comic.epub", inspect_options)
end

local direct_opf = [[<package><manifest>
<item id="page2" href="002.png" media-type="image/png" />
<item id="page1" href="001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page1" /><itemref idref="page2" /></spine></package>]]
local requests = {}
local book, error_code = inspect(epub_entries(direct_opf, {
    { name = "OEBPS/002.png", data = "png" },
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), requests)
expect(error_code == nil and book and book.index:count() == 2,
    "direct image spine entries must produce an EPUB page index")
expect(book.index:get(1).archive_entry_name == "OEBPS/001.jpg", "spine order expected")
expect(book.index:get(2).archive_entry_name == "OEBPS/002.png", "mixed images expected")
expect(book.index:get(1).path == "/comic.epub#zip/5" and book.layout == "archive_images",
    "EPUB pages must retain the archive item contract")
expect(#requests >= 8, "EPUB inspection must fetch only indexed metadata entries")
for _, request in ipairs(requests) do
    expect(request.offset >= 0 and request.count >= 0,
        "EPUB metadata requests must remain bounded")
end

local progressive_manifest, progressive_spine, progressive_images = {}, {}, {}
for index = 1, 7 do
    progressive_manifest[#progressive_manifest + 1] =
        ('<item id="p%d" href="%03d.jpg" media-type="image/jpeg" />'):format(index, index)
    progressive_spine[#progressive_spine + 1] =
        ('<itemref idref="p%d" />'):format(index)
    progressive_images[#progressive_images + 1] = {
        name = ("OEBPS/%03d.jpg"):format(index), data = "jpeg",
    }
end
local progressive_opf = "<package><manifest>" .. table.concat(progressive_manifest)
    .. "</manifest><spine>" .. table.concat(progressive_spine) .. "</spine></package>"
local progressive_book, progressive_error = inspect(epub_entries(progressive_opf,
    progressive_images), nil, nil, nil, { page_limit = 5 })
expect(progressive_book and not progressive_error and progressive_book.index:count() == 5,
    "EPUB startup must map only its first five spine pages")
expect(progressive_book.incomplete == true and progressive_book.total_pages == 7,
    "EPUB startup must retain the known full spine length for background completion")

local xhtml_opf = [[<package><manifest>
<item id="page" href="Text/page.xhtml" media-type="application/xhtml+xml" />
<item id="panel" href="Text/panel%2001.gif" media-type="image/gif" />
</manifest><spine><itemref idref="page" /></spine></package>]]
local xhtml = [[<html xmlns="http://www.w3.org/1999/xhtml"><body>
<img alt="panel" src="panel%2001.gif" />
</body></html>]]
local xhtml_book, xhtml_error = inspect(epub_entries(xhtml_opf, {
    { name = "OEBPS/Text/page.xhtml", data = xhtml },
    { name = "OEBPS/Text/panel 01.gif", data = "gif" },
}))
expect(xhtml_error == nil and xhtml_book.index:count() == 1
    and xhtml_book.index:get(1).archive_entry_name == "OEBPS/Text/panel 01.gif",
    "one XHTML img must resolve relative percent-encoded image paths")

local common_xhtml = [[<html xmlns="http://www.w3.org/1999/xhtml"><head>
<link rel="stylesheet" href="style.css" /></head>
<body class="page" style="margin:0"><section><figure><picture>
<source srcset="../Images/001.jpg" />
<img style="width:100%" src="../Images/001.jpg" />
</picture></figure></section></body></html>]]
local common_opf = [[<package><manifest>
<item id="page" href="Text/page.xhtml" media-type="application/xhtml+xml" />
<item id="panel" href="Images/001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></spine></package>]]
local common_book, common_error = inspect(epub_entries(common_opf, {
    { name = "OEBPS/Text/page.xhtml", data = common_xhtml },
    { name = "OEBPS/Images/001.jpg", data = "jpeg" },
}))
expect(common_error == nil and common_book and common_book.index:count() == 1
    and common_book.index:get(1).archive_entry_name == "OEBPS/Images/001.jpg",
    "a picture with duplicate references to one manifest image must be one EPUB page")

local simple_svg_book, simple_svg_error = inspect(epub_entries(common_opf, {
    { name = "OEBPS/Text/page.xhtml", data = [[<html xmlns="http://www.w3.org/1999/xhtml">
        <body><figure><svg xmlns="http://www.w3.org/2000/svg">
        <image href="../Images/001.jpg" /></svg></figure></body></html>]] },
    { name = "OEBPS/Images/001.jpg", data = "jpeg" },
}))
expect(simple_svg_error == nil and simple_svg_book and simple_svg_book.index:count() == 1
    and simple_svg_book.index:get(1).archive_entry_name == "OEBPS/Images/001.jpg",
    "a simple SVG image in a figure must remain a single EPUB page")

local styled_xhtml_opf = [[<package><manifest>
<item id="page" href="Text/page.xhtml" media-type="application/xhtml+xml" />
<item id="panel" href="Images/panel.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></spine></package>]]
local styled_xhtml = [[<html xmlns="http://www.w3.org/1999/xhtml"><head>
<meta charset="utf-8" /><link rel="stylesheet" href="style.css" />
<style>.page { margin: 0; }</style></head><body>
<div class="page"><img class="panel" src="../Images/panel.jpg" /></div>
</body></html>]]
local styled_book, styled_error = inspect(epub_entries(styled_xhtml_opf, {
    { name = "OEBPS/Text/page.xhtml", data = styled_xhtml },
    { name = "OEBPS/Images/panel.jpg", data = "jpeg" },
}))
expect(styled_error == nil and styled_book and styled_book.index:count() == 1,
    "common XHTML head/style tags must not reject an image EPUB")

local cover_opf = [[<package><manifest>
<item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml" />
<item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image" />
<item id="page1" href="Text/001.xhtml" media-type="application/xhtml+xml" />
<item id="image1" href="Images/001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="cover-page" /><itemref idref="page1" /></spine></package>]]
local cover_xhtml = [[<?xml-stylesheet href="../Styles/book.css"?>
<html><body><div style="margin:0"><img src="../Images/cover.jpg" /></div></body></html>]]
local page_xhtml = [[<html><body><img src="../Images/001.jpg" /></body></html>]]
local function inspect_cover(source)
    return inspect(epub_entries(cover_opf, {
        { name = "OEBPS/Text/cover.xhtml", data = source },
        { name = "OEBPS/Text/001.xhtml", data = page_xhtml },
        { name = "OEBPS/Images/cover.jpg", data = "cover" },
        { name = "OEBPS/Images/001.jpg", data = "page" },
    }))
end
-- Run this boundary with LuaJIT and EPUB_REAL_LUXL=1 to use KOReader's
-- actual lexer/FFI. Keep the surrounding historical host fixtures unchanged.
local host_luxl
if os.getenv("EPUB_REAL_LUXL") == "1" then
    host_luxl = require("luxl")
    local frontend = assert(os.getenv("KOREADER_FRONTEND"), "real EPUB lexer needs KOREADER_FRONTEND")
    package.loaded.luxl = dofile(frontend .. "/luxl.lua")
end
local cover_book, cover_error = inspect_cover(cover_xhtml)
expect(cover_error == nil and cover_book and cover_book.index:count() == 2,
    "a cover XHTML may carry an XML stylesheet and remain an image EPUB")
expect(cover_book.index:get(1).archive_entry_name == "OEBPS/Images/cover.jpg"
    and cover_book.index:get(2).archive_entry_name == "OEBPS/Images/001.jpg",
    "EPUB stylesheet compatibility must preserve spine order")
local quoted_cover = inspect_cover([[<?xml-stylesheet type="text/css" href='../Styles/book.css' media="screen"?>
<html><body><img src="../Images/cover.jpg" /></body></html>]])
expect(quoted_cover and quoted_cover.index:count() == 2,
    "cover stylesheet must support single-quoted href among other attributes")
local accepted_unsafe_hrefs = {}
for _, href in ipairs({ "https://example.invalid/book.css", "//example.invalid/book.css",
    "/book.css", "../../../book.css", "%2e%2e/%2e%2e/%2e%2e/book.css",
    "&#47;&#47;example.invalid/book.css", "&#x2f;&#x2f;example.invalid/book.css",
    "&#47;book.css", "&#x2f;book.css",
    "&#46;&#46;/&#46;&#46;/&#46;&#46;/book.css",
    "&#x2e;&#x2e;/&#x2e;&#x2e;/&#x2e;&#x2e;/book.css" }) do
    local rejected, reason = inspect_cover(cover_xhtml:gsub("%.%./Styles/book%.css", function() return href end))
    if rejected ~= nil or reason ~= "epub_not_image_book" then
        accepted_unsafe_hrefs[#accepted_unsafe_hrefs + 1] = href
    end
end
expect(#accepted_unsafe_hrefs == 0,
    "cover XML stylesheet accepted unsafe hrefs: " .. table.concat(accepted_unsafe_hrefs, ", "))
for _, instruction in ipairs({
    [[<?xml-stylesheet href="https://example.invalid/book.css" href="../Styles/book.css"?>]],
    [[<?xml-stylesheet title="href='../Styles/book.css'"?>]],
    [[<?xml-stylesheet href="../Styles/book.css" malformed?>]],
}) do
    local rejected, reason = inspect_cover(instruction .. [[<html><body><img src="../Images/cover.jpg" /></body></html>]])
    expect(rejected == nil and reason == "epub_not_image_book",
        "cover stylesheet must reject duplicate, missing or malformed attributes")
end
if host_luxl then package.loaded.luxl = host_luxl end

local svg_cover_opf = [[<package><manifest>
<item id="coverpage" href="titlepage.xhtml" media-type="application/xhtml+xml" />
<item id="cover" href="cover.jpeg" media-type="image/jpeg" />
</manifest><spine><itemref idref="coverpage" /></spine></package>]]
local svg_cover_xhtml = [[<html xmlns="http://www.w3.org/1999/xhtml"
    xmlns:xlink="http://www.w3.org/1999/xlink"><head><style type="text/css">
    body { text-align: center; }
    </style></head><body><div><svg xmlns="http://www.w3.org/2000/svg"
    xmlns:xlink="http://www.w3.org/1999/xlink" width="100%" height="100%">
    <image width="845" height="1200" xlink:href="cover.jpeg" />
    </svg></div></body></html>]]
local svg_cover_book, svg_cover_error = inspect(epub_entries(svg_cover_opf, {
    { name = "OEBPS/titlepage.xhtml", data = svg_cover_xhtml },
    { name = "OEBPS/cover.jpeg", data = "jpeg" },
}))
expect(svg_cover_error == nil and svg_cover_book and svg_cover_book.index:count() == 1
    and svg_cover_book.index:get(1).archive_entry_name == "OEBPS/cover.jpeg",
    "Calibre SVG image covers must resolve as the first EPUB page")

for _, active_tag in ipairs({ "animate", "script" }) do
    local active_cover, active_error = inspect(epub_entries(svg_cover_opf, {
        { name = "OEBPS/titlepage.xhtml", data = ([[<html><body><svg>
            <image href="cover.jpeg" /><%s /></svg></body></html>]]):format(active_tag) },
        { name = "OEBPS/cover.jpeg", data = "jpeg" },
    }))
    expect(active_cover == nil and active_error == "epub_not_image_book",
        "SVG cover must reject active " .. active_tag .. " content")
end

local complex_svg_cover_opf = [[<package><manifest>
<item id="titlepage" href="Text/titlepage.xhtml" media-type="application/xhtml+xml" />
<item id="cover-image" href="Images/cover.svg" media-type="image/svg+xml" properties="cover-image" />
<item id="page" href="Images/001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="titlepage" /><itemref idref="page" /></spine></package>]]
local complex_svg_cover_xhtml = [[<html xmlns="http://www.w3.org/1999/xhtml"
    xmlns:svg="http://www.w3.org/2000/svg"><head><style>
    .cover { fill: #fff; }
    </style></head><body><div class="cover"><svg:svg viewBox="0 0 100 100">
    <svg:defs><svg:path d="M0 0h100v100H0z" /></svg:defs>
    <svg:use href="../Images/cover.svg" /><svg:image xlink:href="../Images/cover.svg" />
    </svg:svg></div></body></html>]]
local complex_svg_cover_book, complex_svg_cover_error = inspect(epub_entries(
    complex_svg_cover_opf, {
        { name = "OEBPS/Text/titlepage.xhtml", data = complex_svg_cover_xhtml },
        { name = "OEBPS/Images/cover.svg", data = "svg" },
        { name = "OEBPS/Images/001.jpg", data = "jpeg" },
    }))
expect(complex_svg_cover_error == nil and complex_svg_cover_book
    and complex_svg_cover_book.index:count() == 2
    and complex_svg_cover_book.index:get(1).archive_entry_name == "OEBPS/Images/cover.svg",
    "complex SVG title pages must remain valid image EPUB covers")

local reverse_opf = [[<package><manifest>
<item id="late" href="010.jpg" media-type="image/jpeg" />
<item id="early" href="002.png" media-type="image/png" />
</manifest><spine><itemref idref="late" /><itemref idref="early" /></spine></package>]]
local reverse_book = assert(inspect(epub_entries(reverse_opf, {
    { name = "OEBPS/002.png", data = "png" },
    { name = "OEBPS/010.jpg", data = "jpeg" },
})))
expect(reverse_book.index:get(1).archive_entry_name == "OEBPS/010.jpg"
    and reverse_book.index:get(2).archive_entry_name == "OEBPS/002.png",
    "EPUB pages must follow spine order rather than filename order")

local inflated = { container, direct_opf }
local deflated_next_calls = 0
local removed = {}
local deflated_book, deflated_error = inspect({
    { name = "META-INF/container.xml", data = container, method = 8, compressed = "container" },
    { name = "OEBPS/content.opf", data = direct_opf, method = 8, compressed = "opf" },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.png", data = "png" },
}, nil, {
    archiver = { Reader = { new = function()
        return {
            open = function() return true end,
            next = function() deflated_next_calls = deflated_next_calls + 1; return true end,
            extractToMemory = function() return table.remove(inflated, 1) end,
            close = function() return true end,
        }
    end } },
    remove_file = function(path) removed[#removed + 1] = path; return os.remove(path) end,
})
expect(deflated_error == nil and deflated_book and deflated_book.index:count() == 2,
    "deflated EPUB metadata entries must use bounded one-entry extraction")
expect(deflated_next_calls == 2,
    "each compressed EPUB metadata entry must enumerate its temporary ZIP")
expect(#removed == 2, "temporary metadata archives must be removed")

local owned_work = os.tmpname()
os.remove(owned_work)
owned_work = owned_work .. ".zipwork"
local owned_opened, owned_removed = 0, 0
local owned_next_calls = 0
local owned_inflated = { container, direct_opf }
local owned_book, owned_error = inspect({
    { name = "META-INF/container.xml", data = container, method = 8, compressed = "container" },
    { name = "OEBPS/content.opf", data = direct_opf, method = 8, compressed = "opf" },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.png", data = "png" },
}, nil, {
    temp_name = function() error("a parent-owned metadata path must not allocate a global temporary name") end,
    archiver = { Reader = { new = function() return {
        open = function(_, path)
            expect(path == owned_work, "metadata extraction must open the exact parent-owned work path")
            local file = assert(io.open(path, "rb"))
            expect(file:read(4) == "PK\003\004", "parent-owned work file must contain the one-entry ZIP")
            file:close(); owned_opened = owned_opened + 1; return true
        end,
        next = function() owned_next_calls = owned_next_calls + 1; return true end,
        extractToMemory = function() return table.remove(owned_inflated, 1) end,
        close = function() return true end,
    } end } },
    remove_file = function(path)
        expect(path == owned_work, "metadata cleanup must target only the parent-owned work path")
        owned_removed = owned_removed + 1; return os.remove(path)
    end,
}, owned_work)
expect(owned_book and owned_error == nil and owned_book.index:count() == 2,
    "EPUB inspection must preserve and use the supplied metadata work path")
expect(owned_opened == 2 and owned_removed == 2,
    "compressed container and OPF must sequentially reuse and clean one owned work file")
expect(owned_next_calls == 2,
    "parent-owned compressed EPUB metadata entries must enumerate each ZIP")
os.remove(owned_work)

local function expect_rejected(entries, expected, message)
    local rejected, rejected_error = inspect(entries)
    expect(rejected == nil and rejected_error == expected, message)
end

expect_rejected({ { name = "mimetype", data = "application/epub+zip" } },
    "epub_container_missing", "EPUB without container.xml must be rejected")

local drm_entries = epub_entries(direct_opf, {
    { name = "META-INF/encryption.xml", data = "<encryption />" },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.png", data = "png" },
})
expect_rejected(drm_entries, "epub_drm", "encrypted EPUBs must use the DRM error")

local duplicate_opf = [[<package><manifest>
<item id="page" href="001.jpg" media-type="image/jpeg" />
<item id="page" href="002.png" media-type="image/png" />
</manifest><spine><itemref idref="page" /></spine></package>]]
expect_rejected(epub_entries(duplicate_opf, {
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.png", data = "png" },
}), "epub_not_image_book", "duplicate manifest IDs must be rejected")

local missing_spine_opf = [[<package><manifest>
<item id="page" href="001.jpg" media-type="image/jpeg" />
</manifest><extension><itemref idref="page" /></extension></package>]]
expect_rejected(epub_entries(missing_spine_opf, {
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "an itemref outside an actual spine must not create a spine")

local empty_spine_opf = [[<package><manifest>
<item id="page" href="001.jpg" media-type="image/jpeg" />
</manifest><spine></spine></package>]]
expect_rejected(epub_entries(empty_spine_opf, {
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "an empty actual spine must be rejected")

local outside_spine_opf = [[<package><manifest>
<item id="page" href="001.jpg" media-type="image/jpeg" />
</manifest><extension><itemref idref="page" /></extension>
<spine><itemref idref="page" /></spine></package>]]
expect_rejected(epub_entries(outside_spine_opf, {
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "itemref elements outside the actual spine must be rejected")

expect_rejected(epub_entries(direct_opf),
    "epub_not_image_book", "spine images missing from the ZIP must be rejected")

local mismatched_opf = [[<package><manifest>
<item id="page" href="001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></manifest></package>]]
expect_rejected(epub_entries(mismatched_opf, {
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "mismatched OPF end tags must be rejected")

local function path_opf(href)
    return ([[<package><manifest><item id="page" href="%s" media-type="image/jpeg" />
        </manifest><spine><itemref idref="page" /></spine></package>]]):format(href)
end
for _, href in ipairs({ "../001.jpg", "/001.jpg", "Images\\001.jpg", "bad%ZZ.jpg" }) do
    expect_rejected(epub_entries(path_opf(href), {
        { name = "OEBPS/001.jpg", data = "jpeg" },
    }), "epub_not_image_book", "unsafe EPUB path must be rejected: " .. href)
end

local multiple_xhtml = [[<html><body><img src="001.jpg" /><img src="002.png" /></body></html>]]
expect_rejected(epub_entries([[<package><manifest>
<item id="page" href="page.xhtml" media-type="application/xhtml+xml" />
<item id="one" href="001.jpg" media-type="image/jpeg" />
<item id="two" href="002.png" media-type="image/png" />
</manifest><spine><itemref idref="page" /></spine></package>]], {
    { name = "OEBPS/page.xhtml", data = multiple_xhtml },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.png", data = "png" },
}), "epub_not_image_book", "XHTML with multiple content images must be rejected")

local unsafe_multiple_xhtml = [[<html><body>
<img src="../outside.jpg" /><img src="001.jpg" />
</body></html>]]
expect_rejected(epub_entries([[<package><manifest>
<item id="page" href="page.xhtml" media-type="application/xhtml+xml" />
<item id="one" href="001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></spine></package>]], {
    { name = "OEBPS/page.xhtml", data = unsafe_multiple_xhtml },
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "every XHTML img src must count toward the single-image limit")

local function expect_complex_xhtml_rejected(xhtml_source, message)
    expect_rejected(epub_entries([[<package><manifest>
<item id="page" href="page.xhtml" media-type="application/xhtml+xml" />
<item id="one" href="001.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></spine></package>]], {
        { name = "OEBPS/page.xhtml", data = xhtml_source },
        { name = "OEBPS/001.jpg", data = "jpeg" },
    }), "epub_not_image_book", message)
end

expect_complex_xhtml_rejected([[<html><head><style>
body { background-image: url('background.jpg'); }
</style></head><body><img src="001.jpg" /></body></html>]],
    "XHTML with CSS background-image must be rejected")

expect_complex_xhtml_rejected([[<html><body><svg><rect width="1" height="1" /></svg>
<img src="001.jpg" /></body></html>]], "XHTML with other composite visual content must be rejected")

for _, case in ipairs({
    { [[<html><body><math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>
        <img src="001.jpg" /></body></html>]],
        "MathML beside an image must not be classified as one-image content" },
    { [[<html><body><m:math xmlns:m="http://www.w3.org/1998/Math/MathML">
        <m:mfrac><m:mn>1</m:mn><m:mn>2</m:mn></m:mfrac></m:math>
        <img src="001.jpg" /></body></html>]],
        "prefixed MathML must not be classified as one-image content" },
    { [[<html><body><img src="001.jpg" /><img src="002.jpg" /></body></html>]],
        "two distinct manifest images must be rejected" },
    { [[<html><body><script src="page.js"></script><img src="001.jpg" /></body></html>]],
        "script with a valid image must be rejected" },
    { [[<html><body style="background-image:url(001.jpg)"><img src="001.jpg" /></body></html>]],
        "CSS background image with a valid image must be rejected" },
    { [[<html><body style="background:url(001.jpg)"><img src="001.jpg" /></body></html>]],
        "CSS background shorthand with a valid image must be rejected" },
    { [[<html><body style="background:red"><img src="001.jpg" /></body></html>]],
        "flat CSS background shorthand must be rejected" },
    { [[<html><head><style>body { background:linear-gradient(red, blue); }</style></head>
        <body><img src="001.jpg" /></body></html>]],
        "gradient CSS background shorthand must be rejected" },
    { [[<html><body><picture><source srcset="001.jpg" /></picture></body></html>]],
        "source alone must not count as a displayable image" },
    { [[<html><body><img src="https://example.invalid/001.jpg" /></body></html>]],
        "absolute image URL must be rejected" },
    { [[<html><body><img src="//example.invalid/001.jpg" /></body></html>]],
        "protocol-relative image URL must be rejected" },
    { [[<html><body><a href="https://example.invalid/page.xhtml">
        <img src="001.jpg" /></a></body></html>]],
        "absolute anchor URL must be rejected" },
    { [[<html><head><style>@import "https://example.invalid/style.css";</style></head>
        <body><img src="001.jpg" /></body></html>]],
        "external CSS import must be rejected" },
    { [[<html><body><picture><source srcset="001.jpg, 002.jpg 2x" />
        <img src="001.jpg" /></picture></body></html>]],
        "second srcset image must be rejected" },
    { [[<html><body><picture><source srcset="001.jpg, https://example.invalid/001.jpg 2x" />
        <img src="001.jpg" /></picture></body></html>]],
        "remote srcset image must be rejected" },
    { [[<html><body><img src="001.jpg"
        srcset="001.jpg, https://example.invalid/001.jpg 2x" /></body></html>]],
        "remote img srcset image must be rejected" },
    { [[<html><body background="001.jpg"><img src="001.jpg" /></body></html>]],
        "legacy background attribute must be rejected" },
    { [[<?xml-stylesheet href="style.css"?><html><body><img src="001.jpg" /></body></html>]],
        "XML stylesheet instruction must be rejected" },
}) do
    expect_complex_xhtml_rejected(case[1], case[2])
end

for _, tag in ipairs({ "animate", "animateTransform", "animateMotion", "set",
    "script", "foreignObject", "use", "filter", "mask", "pattern",
    "clipPath", "text" }) do
    expect_complex_xhtml_rejected(([[<html xmlns:svg="http://www.w3.org/2000/svg"><body>
        <svg:svg><svg:image href="001.jpg" /><svg:%s /></svg:svg>
        </body></html>]]):format(tag),
        "prefixed SVG " .. tag .. " must not compose a single-image page")
end

local background_color_book, background_color_error = inspect(epub_entries([[
<package><manifest><item id="page" href="page.xhtml" media-type="application/xhtml+xml" />
<item id="one" href="001.jpg" media-type="image/jpeg" /></manifest>
<spine><itemref idref="page" /></spine></package>]], {
    { name = "OEBPS/page.xhtml", data = [[<html><body style="background-color:red">
        <img src="001.jpg" /></body></html>]] },
    { name = "OEBPS/001.jpg", data = "jpeg" },
}))
expect(background_color_error == nil and background_color_book
    and background_color_book.index:count() == 1
    and background_color_book.index:get(1).archive_entry_name == "OEBPS/001.jpg",
    "ordinary background-color styling must remain a valid single-image page")

local two_image_opf = [[<package><manifest>
<item id="page" href="page.xhtml" media-type="application/xhtml+xml" />
<item id="one" href="001.jpg" media-type="image/jpeg" />
<item id="two" href="002.jpg" media-type="image/jpeg" />
</manifest><spine><itemref idref="page" /></spine></package>]]
expect_rejected(epub_entries(two_image_opf, {
    { name = "OEBPS/page.xhtml", data = [[<html><body>
        <img src="001.jpg" /><img src="002.jpg" /></body></html>]] },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.jpg", data = "jpeg" },
}), "epub_not_image_book", "two valid manifest images still make a composite page")
expect_rejected(epub_entries(two_image_opf, {
    { name = "OEBPS/page.xhtml", data = [[<html><body><img src="001.jpg"
        srcset="001.jpg, 002.jpg 2x" /></body></html>]] },
    { name = "OEBPS/001.jpg", data = "jpeg" },
    { name = "OEBPS/002.jpg", data = "jpeg" },
}), "epub_not_image_book", "a second img srcset candidate must not be ignored")

expect_complex_xhtml_rejected([[<html><body style="background-image: url(background.jpg)">
<img src="001.jpg" /></body></html>]], "inline CSS backgrounds must be rejected")

expect_complex_xhtml_rejected([[<html><body>
<img alt="missing source" /><img src="001.jpg" />
</body></html>]], "every XHTML img must count even when src is missing")

expect_complex_xhtml_rejected([[<html><body><img src="001.jpg" />
</html></body>]], "mismatched XHTML end tags must be rejected")

expect_rejected(epub_entries([[<package><manifest>
<item id="page" href="001.jpg" media-type="application/octet-stream" />
</manifest><spine><itemref idref="page" /></spine></package>]], {
    { name = "OEBPS/001.jpg", data = "jpeg" },
}), "epub_not_image_book", "only allowed image media types may become EPUB pages")

print(("rebuild_0374_epub_pages_spec: %d checks"):format(checks))
