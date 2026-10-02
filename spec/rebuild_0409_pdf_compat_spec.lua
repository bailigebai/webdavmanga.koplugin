local PdfImageStream = require("webdavmanga.pdf_image_stream")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function object(number, body)
    return tostring(number) .. " 0 obj\n" .. body .. "\nendobj\n"
end

local function make_fixture(two_images)
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local pdf, offsets = "%PDF-1.3\n", {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body)
    end
    local xobjects = two_images and "/Im1 4 0 R /Im2 6 0 R" or "/Im1 4 0 R"
    local content = "/GS1 gs q 1 0 0 1 0 0 cm /Im1 Do Q"
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 5 0 R "
        .. "/Resources << /XObject << " .. xobjects
        .. " >> /ExtGState << /GS1 7 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode "
        .. "/Length " .. tostring(#jpeg) .. " >>\nstream\n" .. jpeg .. "\nendstream")
    append(5, "<< /Length " .. tostring(#content) .. " >>\nstream\n" .. content .. "\nendstream")
    append(6, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode "
        .. "/Length " .. tostring(#jpeg) .. " >>\nstream\n" .. jpeg .. "\nendstream")
    append(7, "<< /Type /ExtGState /ca 1 /CA 1 /BM /Normal >>")
    local highest = 7
    local xref = #pdf
    pdf = pdf .. "xref\n0 " .. tostring(highest + 1) .. "\n0000000000 65535 f \n"
    for number = 1, highest do
        pdf = pdf .. ("%010d 00000 n \n"):format(offsets[number])
    end
    pdf = pdf .. "trailer\n<< /Size " .. tostring(highest + 1) .. " /Root 1 0 R >>\nstartxref\n"
        .. tostring(xref) .. "\n%%EOF\n"
    return pdf, jpeg
end

local bytes, jpeg = make_fixture(false)
local target = os.tmpname()
local book, error_code = PdfImageStream:new():inspect_remote({
    size = #bytes,
    read_at = function(offset, count)
        return bytes:sub(offset + 1, offset + count)
    end,
}, "/Books/single-image.pdf", target)
expect(book and book.index and book.index:count() == 1,
    "unique image XObject should remain streamable: " .. tostring(error_code))
local file = assert(io.open(target, "rb"))
expect(file:read("*a") == jpeg, "compatibility path must validate and extract the sole image")
file:close()
os.remove(target)

local complex = make_fixture(true)
local rejected, reject_error = PdfImageStream:new():inspect_remote({
    size = #complex,
    read_at = function(offset, count)
        return complex:sub(offset + 1, offset + count)
    end,
}, "/Books/multiple-images.pdf")
expect(rejected == nil and reject_error == "pdf_multiple_images",
    "multiple-image pages must remain rejected: " .. tostring(reject_error))

print(("rebuild_0409_pdf_compat_spec: %d checks"):format(checks))
