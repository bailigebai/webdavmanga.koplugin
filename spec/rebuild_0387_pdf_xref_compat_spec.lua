local PdfImageStream = require("webdavmanga.pdf_image_stream")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function be32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256)
end

local function object(number, body, generation)
    return tostring(number) .. " " .. tostring(generation or 0)
        .. " obj\n" .. body .. "\nendobj\n"
end

local function xref_entry(kind, offset, generation)
    return string.char(kind) .. be32(offset or 0) .. string.char(generation or 0)
end

local function xref_stream_fixture(filtered)
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local pdf, offsets = "%PDF-1.5\n", {}
    local function append(number, body, generation)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body, generation)
    end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>", 1)
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 8 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/Filter /DCTDecode /Length " .. tostring(#jpeg) .. " >>\nstream\n"
        .. jpeg .. "\nendstream")
    append(8, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    local entries = xref_entry(0, 0, 255)
    for number = 1, 4 do entries = entries .. xref_entry(1, offsets[number], 0) end
    entries = entries .. xref_entry(1, 0, 0) .. xref_entry(0, 0, 0)
        .. xref_entry(0, 0, 0) .. xref_entry(1, offsets[8], 0)
    local xref_offset = #pdf
    append(5, "<< /Type /XRef /Size 9 /Root 1 0 R /W [1 4 1] "
        .. (filtered and "/Filter /FlateDecode " or "")
        .. "/Index [0 9] /Length " .. tostring(#entries) .. " >>\nstream\n"
        .. entries .. "\nendstream")
    pdf = pdf .. "startxref\n" .. tostring(xref_offset) .. "\n%%EOF\n"
    return pdf, jpeg
end

local bytes, jpeg = xref_stream_fixture()
local target = os.tmpname()
local book, error_code = PdfImageStream:new():inspect_remote({
    size = #bytes,
    read_at = function(offset, count) return bytes:sub(offset + 1, offset + count) end,
}, "/Books/xref-stream.pdf", target)
expect(book and book.index and book.index:count() == 1,
    "uncompressed xref stream should index image PDF: " .. tostring(error_code))
local image = book and book.index:get(1)
expect(image and image.pdf_image and image.pdf_image_length == #jpeg,
    "xref stream should preserve image range metadata")
local file = assert(io.open(target, "rb"))
expect(file:read("*a") == jpeg, "xref stream should extract first JPEG")
file:close()
os.remove(target)

local function classic_multi_fixture(indirect_kids, compact_image_subtype)
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local pdf, offsets = "%PDF-1.4\n", {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body)
    end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids "
        .. (indirect_kids and "5 0 R" or "[3 0 R]") .. " /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 8 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype" .. (compact_image_subtype and "" or " ")
        .. "/Image /Width 1 /Height 1 "
        .. "/Filter /DCTDecode /Length " .. tostring(#jpeg) .. " >>\nstream\n"
        .. jpeg .. "\nendstream")
    if indirect_kids then append(5, "[3 0 R]") end
    append(8, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    local xref_offset = #pdf
    pdf = pdf .. "xref\n0 1\n0000000000 65535 f\n1 1\n"
        .. ("%010d 00001 n\n"):format(offsets[1])
        .. "2 " .. tostring(indirect_kids and 4 or 3) .. "\n"
    for number = 2, indirect_kids and 5 or 4 do
        pdf = pdf .. ("%010d 00000 n\n"):format(offsets[number])
    end
    pdf = pdf .. "8 1\n" .. ("%010d 00000 n\n"):format(offsets[8])
        .. "trailer\n<< /Size 9"
        .. " /Root 1 1 R >>\nstartxref\n"
        .. tostring(xref_offset) .. "\n%%EOF\n"
    return pdf, jpeg
end

local classic_bytes, classic_jpeg = classic_multi_fixture()
local classic_target = os.tmpname()
local classic_book, classic_error = PdfImageStream:new():inspect_remote({
    size = #classic_bytes,
    read_at = function(offset, count)
        return classic_bytes:sub(offset + 1, offset + count)
    end,
}, "/Books/multi-xref.pdf", classic_target)
expect(classic_book and classic_book.index and classic_book.index:count() == 1,
    "multiple xref subsections and nonzero generations should remain readable: "
        .. tostring(classic_error))
local classic_file = assert(io.open(classic_target, "rb"))
expect(classic_file:read("*a") == classic_jpeg,
    "multiple xref subsections should preserve image bytes")
classic_file:close()
os.remove(classic_target)

local indirect_kids = classic_multi_fixture(true)
local indirect_kids_book, indirect_kids_error = PdfImageStream:new():inspect_remote({
    size = #indirect_kids,
    read_at = function(offset, count)
        return indirect_kids:sub(offset + 1, offset + count)
    end,
}, "/Books/indirect-kids.pdf")
expect(indirect_kids_book and indirect_kids_book.index:count() == 1,
    "indirect Kids arrays should remain readable: " .. tostring(indirect_kids_error))

local compact_subtype = classic_multi_fixture(false, true)
local compact_book, compact_error = PdfImageStream:new():inspect_remote({
    size = #compact_subtype,
    read_at = function(offset, count)
        return compact_subtype:sub(offset + 1, offset + count)
    end,
}, "/Books/compact-image-subtype.pdf")
expect(compact_book and compact_book.index:count() == 1,
    "compact /Subtype/Image syntax should remain readable: " .. tostring(compact_error))

local filtered_bytes = xref_stream_fixture(true)
local inflate_called = false
local filtered_book, filtered_error = PdfImageStream:new{
    decompress = function(data, expected_size)
        inflate_called = true
        expect(#data == expected_size, "xref decompressor should receive bounded data")
        return data
    end,
}:inspect_remote({
    size = #filtered_bytes,
    read_at = function(offset, count)
        return filtered_bytes:sub(offset + 1, offset + count)
    end,
}, "/Books/filtered-xref.pdf")
expect(filtered_book and filtered_book.index and filtered_book.index:count() == 1
    and inflate_called, "Flate xref stream should use the bounded decompressor")

local function incremental_fixture()
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local pdf, offsets = "%PDF-1.4\n", {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. object(number, body)
    end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 8 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/Filter /DCTDecode /Length " .. tostring(#jpeg) .. " >>\nstream\n"
        .. jpeg .. "\nendstream")
    append(8, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    local old_xref = #pdf
    pdf = pdf .. "xref\n0 5\n0000000000 65535 f\n"
    for number = 1, 4 do pdf = pdf .. ("%010d 00000 n\n"):format(offsets[number]) end
    pdf = pdf .. "8 1\n" .. ("%010d 00000 n\n"):format(offsets[8])
        .. "trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n"
        .. tostring(old_xref) .. "\n%%EOF\n"
        .. string.rep("% incremental padding\n", 4096)
    append(5, "<< /Producer (incremental update) >>")
    local latest_xref = #pdf
    pdf = pdf .. "xref\n5 1\n" .. ("%010d 00000 n\n"):format(offsets[5])
        .. "trailer\n<< /Size 9 /Prev " .. tostring(old_xref) .. " >>\nstartxref\n"
        .. tostring(latest_xref) .. "\n%%EOF\n"
    return pdf
end

local incremental = incremental_fixture()
local incremental_book, incremental_error = PdfImageStream:new():inspect_remote({
    size = #incremental,
    read_at = function(offset, count)
        return incremental:sub(offset + 1, offset + count)
    end,
}, "/Books/incremental.pdf")
expect(incremental_book and incremental_book.index:count() == 1,
    "incremental trailer should inherit Root through Prev: " .. tostring(incremental_error))

local function object_stream_fixture(marker, broken)
    local jpeg = string.char(
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01,
        0x01, 0x11, 0x00, 0xFF, 0xD9)
    local bodies = {
        "<< /Type /Catalog /Pages " .. (broken and "99" or "2") .. " 0 R /Padding ("
            .. string.rep("x", 2048) .. ") >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] /Contents 8 0 R /Resources << /XObject << /Im1 4 0 R >> >> >>",
    }
    local header, body = {}, ""
    for number = 1, #bodies do
        header[#header + 1] = tostring(number) .. " " .. tostring(#body)
        body = body .. bodies[number] .. "\n"
    end
    header = table.concat(header, " ") .. " "
    local decoded_objects = header .. body
    local pdf, offsets = "%PDF-1.5\n", {}
    local function append(number, value)
        offsets[number] = #pdf
        pdf = pdf .. object(number, value)
    end
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 "
        .. "/Filter /DCTDecode /Length 7 0 R >>\nstream\n" .. jpeg .. "\nendstream")
    marker = marker or "z"
    append(5, "<< /Type /ObjStm /N 3 /First " .. tostring(#header)
        .. " /Filter /FlateDecode /Length " .. tostring(#marker)
        .. " >>\nstream\n" .. marker .. "\nendstream")
    append(7, tostring(#jpeg))
    append(8, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    local xref_offset = #pdf
    local entries = xref_entry(0, 0, 255)
        .. xref_entry(2, 5, 0)
        .. xref_entry(2, 5, 1)
        .. xref_entry(2, 5, 2)
        .. xref_entry(1, offsets[4], 0)
        .. xref_entry(1, offsets[5], 0)
        .. xref_entry(1, xref_offset, 0)
        .. xref_entry(1, offsets[7], 0)
        .. xref_entry(1, offsets[8], 0)
    append(6, "<< /Type /XRef /Size 9 /Root 1 0 R /W [1 4 1] "
        .. "/Index [0 9] /Length " .. tostring(#entries) .. " >>\nstream\n"
        .. entries .. "\nendstream")
    pdf = pdf .. "startxref\n" .. tostring(xref_offset) .. "\n%%EOF\n"
    return pdf, decoded_objects
end

local object_stream_pdf, decoded_objects = object_stream_fixture("a")
local broken_object_stream_pdf, broken_decoded_objects = object_stream_fixture("b", true)
local inflate_attempts = 0
local object_stream_parser = PdfImageStream:new{
    decompress = function(data, capacity)
        inflate_attempts = inflate_attempts + 1
        local decoded = data == "a" and decoded_objects or broken_decoded_objects
        if capacity < #decoded then return nil, "output buffer too small" end
        return decoded
    end,
}
local compressed_book, compressed_error = object_stream_parser:inspect_remote({
    size = #object_stream_pdf,
    read_at = function(offset, count)
        return object_stream_pdf:sub(offset + 1, offset + count)
    end,
}, "/Books/object-stream.pdf")
expect(compressed_book and compressed_book.index:count() == 1,
    "compressed Catalog/Pages/Page and indirect Length should open: "
        .. tostring(compressed_error))
expect(compressed_book and compressed_book.index:get(1).pdf_image_length == #jpeg,
    "indirect image Length must resolve to the referenced numeric object")
expect(inflate_attempts > 1 and inflate_attempts < 6,
    "object stream decompression should grow once and reuse its bounded result")
local stale_book, stale_error = object_stream_parser:inspect_remote({
    size = #broken_object_stream_pdf,
    read_at = function(offset, count)
        return broken_object_stream_pdf:sub(offset + 1, offset + count)
    end,
}, "/Books/second-object-stream.pdf")
expect(stale_book == nil and stale_error == "pdf_object_missing",
    "reusing the parser must not reuse a previous document's object stream")

local padding = string.rep("% padding padding padding padding\n", 4096)
local padded_classic = classic_bytes:gsub("startxref", function()
    return padding .. "startxref"
end, 1)
local largest_request = 0
local padded_book, padded_error = PdfImageStream:new():inspect_remote({
    size = #padded_classic,
    read_at = function(offset, count)
        largest_request = math.max(largest_request, count)
        return padded_classic:sub(offset + 1, offset + count)
    end,
}, "/Books/padded-classic.pdf")
expect(padded_book and padded_book.index:count() == 1,
    "classic xref with a large trailing update area should open: " .. tostring(padded_error))
expect(largest_request <= 64 * 1024,
    "classic xref inspection must not request multi-megabyte metadata chunks")

print(("rebuild_0387_pdf_xref_compat_spec: %d checks"):format(checks))
