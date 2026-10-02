local PdfImageStream = require("webdavmanga.pdf_image_stream")

local checks, requests = 0, {}
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function object(number, body)
    return tostring(number) .. " 0 obj\n" .. body .. "\nendobj\n"
end

local function make_fixture()
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local pdf, offsets = "%PDF-1.3\n", {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body)
    end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 5 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode "
        .. "/Length " .. tostring(#jpeg) .. " >>\nstream\n" .. jpeg .. "\nendstream")
    append(5, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    local xref = #pdf
    pdf = pdf .. "xref\n0 6\n0000000000 65535 f \n"
    for number = 1, 5 do
        pdf = pdf .. ("%010d 00000 n \n"):format(offsets[number])
    end
    pdf = pdf .. "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"
        .. tostring(xref) .. "\n%%EOF\n"
    return pdf, jpeg
end

local bytes, jpeg = make_fixture()
local target = os.tmpname()
local book, inspect_error = PdfImageStream:new():inspect_remote({
    size = #bytes,
    read_at = function(offset, count)
        requests[#requests + 1] = { offset = offset, count = count }
        return bytes:sub(offset + 1, offset + count)
    end,
}, "/Books/comic.pdf", target)

expect(book and book.index and book.index:count() == 1,
    "classic image PDF should produce one page: " .. tostring(inspect_error))
local page = book.index:get(1)
expect(page.pdf_image == true and page.pdf_remote_path == "/Books/comic.pdf",
    "page must carry plugin PDF image source metadata")
expect(page.pdf_image_length == #jpeg and page.pdf_image_offset >= 0,
    "page must point to the exact JPEG stream range")
local file = assert(io.open(target, "rb"))
local extracted = file:read("*a")
file:close()
expect(extracted == jpeg, "inspection must extract the first image only")
for _, request in ipairs(requests) do
    expect(request.count <= 65536, "PDF inspection must keep every range bounded")
end
os.remove(target)

local complex = bytes:gsub("/Root 1 0 R", "/Root 1 0 R /Encrypt 5 0 R")
local unsupported = PdfImageStream:new():inspect_remote({
    size = #complex,
    read_at = function(offset, count)
        return complex:sub(offset + 1, offset + count)
    end,
}, "/Books/complex.pdf")
expect(unsupported == nil, "unsupported PDF must be rejected for fallback prompt")

print(("rebuild_0386_pdf_image_stream_spec: %d checks"):format(checks))
