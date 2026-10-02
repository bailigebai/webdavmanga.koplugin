local PdfImageStream = require("webdavmanga.pdf_image_stream")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function object(number, body)
    return tostring(number) .. " 0 obj\n" .. body .. "\nendobj\n"
end

local function make_fixture(page_count)
    local pdf, offsets, page_offsets, images = "%PDF-1.4\n", {}, {}, {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body)
    end
    local kids = {}
    for page = 1, page_count do kids[#kids + 1] = tostring(page + 2) .. " 0 R" end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [" .. table.concat(kids, " ")
        .. "] /Count " .. tostring(page_count) .. " >>")
    for page = 1, page_count do
        local page_number, image_number = page + 2, page_count + page + 2
        local content_number = page_count * 2 + page + 2
        page_offsets[page] = #pdf
        append(page_number, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents "
            .. tostring(content_number) .. " 0 R /Resources << /XObject << /Im"
            .. tostring(page) .. " " .. tostring(image_number) .. " 0 R >> >> >>")
        images[page] = string.char(
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xD9)
        append(image_number, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
            .. "/Filter /DCTDecode /Length " .. tostring(#images[page])
            .. " >>\nstream\n" .. images[page] .. "\nendstream")
        local content = "/Im" .. tostring(page) .. " Do"
        append(content_number, "<< /Length " .. #content .. " >>\nstream\n" .. content .. "\nendstream")
        pdf = pdf .. string.rep("% page padding\n", 6000)
    end
    local xref = #pdf
    local object_count = page_count * 3 + 3
    pdf = pdf .. "xref\n0 " .. tostring(object_count) .. "\n0000000000 65535 f \n"
    for number = 1, object_count - 1 do
        pdf = pdf .. ("%010d 00000 n \n"):format(offsets[number])
    end
    pdf = pdf .. "trailer\n<< /Size " .. tostring(object_count)
        .. " /Root 1 0 R >>\nstartxref\n" .. tostring(xref) .. "\n%%EOF\n"
    return pdf, page_offsets, images
end

local bytes, page_offsets, images = make_fixture(24)
local requested_page_two = false
local function read_at(offset, count)
    if offset >= page_offsets[2] and offset < page_offsets[2] + 65536 then
        requested_page_two = true
    end
    return bytes:sub(offset + 1, offset + count)
end

local first_target = os.tmpname()
local parser = PdfImageStream:new()
local book, inspect_error = parser:inspect_remote({ size = #bytes, read_at = read_at },
    "/Books/large.pdf", first_target)
expect(book and book.index and book.index:count() == 24,
    "startup must retain the complete PDF page count: " .. tostring(inspect_error))
expect(not requested_page_two,
    "startup must not read page two while validating the first page")
local second = book.index:get(2)
expect(second and second.pdf_page_object and not second.pdf_image_offset,
    "later PDF pages must remain unresolved until requested")

requested_page_two = false
local second_target = os.tmpname()
local metadata, extract_error = parser:extract_remote(second, read_at, second_target)
expect(metadata and requested_page_two,
    "requesting page two must resolve that page on demand: " .. tostring(extract_error))
local file = assert(io.open(second_target, "rb"))
expect(file:read("*a") == images[2], "page two must extract the correct JPEG bytes")
file:close()
os.remove(first_target)
os.remove(second_target)

print(("rebuild_0389_pdf_lazy_index_spec: %d checks"):format(checks))
