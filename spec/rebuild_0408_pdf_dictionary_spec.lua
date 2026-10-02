local PdfImageStream = require("webdavmanga.pdf_image_stream")
local checks, failures = 0, {}
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function case(name, run)
    local ok, err = pcall(run); if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local jpeg = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
local function fixture(options)
    options = options or {}
    local pdf, offsets = "%PDF-1.5\n", {}
    local function append(number, body)
        offsets[number] = #pdf
        pdf = pdf .. number .. " 0 obj\n" .. body .. "\nendobj\n"
    end
    local content = options.simple and "/Im1 Do" or "/Im1 Do 0 0 1 1 re f"
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1 1] "
        .. (options.page_prefix or "") .. " /Contents 6 0 R"
        .. " /Resources << /XObject << /Im1 4 0 R >> >> >>")
    append(4, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1"
        .. " /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode"
        .. " /Length " .. #jpeg .. " >>\nstream\n" .. jpeg .. "\nendstream")
    append(5, "<< /Length 7 >>\nstream\n/Im1 Do\nendstream")
    append(6, "<< " .. (options.stream_prefix or "") .. " /Length "
        .. (options.indirect and "8 0 R" or #content)
        .. " >>\nstream\n" .. content .. "\nendstream")
    append(7, "7")
    append(8, tostring(#content))
    local xref = #pdf
    pdf = pdf .. "xref\n0 9\n0000000000 65535 f \n"
    for number = 1, 8 do pdf = pdf .. ("%010d 00000 n \n"):format(offsets[number]) end
    return pdf .. "trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n" .. xref .. "\n%%EOF\n"
end
local function inspect(options)
    local bytes = fixture(options)
    return PdfImageStream:new():inspect_remote({
        size = #bytes, read_at = function(offset, count) return bytes:sub(offset + 1, offset + count) end,
    }, "/dictionary.pdf")
end
local spoofed = {
    { "reviewer nested Contents", { page_prefix = "/PieceInfo << /Private << /Contents 5 0 R >> >>" } },
    { "reviewer nested direct Length", { stream_prefix = "/Private << /Length 7 >>" } },
    { "reviewer nested indirect Length", { stream_prefix = "/Private << /Length 7 0 R >>" } },
    { "literal Contents", { page_prefix = "/Private (/Contents 5 0 R)" } },
    { "escaped literal Contents", { page_prefix = "/Private (escaped \\( /Contents 5 0 R \\))" } },
    { "comment Contents", { page_prefix = "% /Contents 5 0 R\n" } },
    { "hex Contents", { page_prefix = "/Private <2f436f6e74656e7473203520302052>" } },
    { "literal Length", { stream_prefix = "/Private (/Length 7)" } },
    { "comment Length", { stream_prefix = "% /Length 7\n" } },
    { "hex Length", { stream_prefix = "/Private <2f4c656e6774682037>" } },
    { "array Length", { stream_prefix = "/Private [<< /Length 7 >> (/Length 7 0 R)]" } },
    { "duplicate Contents", { page_prefix = "/Contents 5 0 R" } },
    { "duplicate Length", { stream_prefix = "/Length 7" } },
    { "unclosed string", { stream_prefix = "/Private ( /Length 7" } },
    { "malformed dictionary", { stream_prefix = "/Private << /Length 7 >" } },
    { "dictionary delimiters in string", { stream_prefix = "/Private (<< /Length 7 >>)" } },
    { "stream delimiter in string", { stream_prefix = "/Private (stream\n/Im1 Do)" } },
    { "stream delimiter in comment", { stream_prefix = "% stream\n% /Im1 Do\n" } },
    { "fake stream payload in string", { stream_prefix = "/Private (stream\n/Im1 Do                              )" } },
    { "duplicate Contents with simple actual content", { simple = true, page_prefix = "/Contents 5 0 R" } },
    { "duplicate Length with simple actual content", { simple = true, stream_prefix = "/Length 7" } },
    { "invalid hex value", { simple = true, stream_prefix = "/Private <not-hex>" } },
    { "excessive dictionary depth", { simple = true,
        stream_prefix = string.rep("/Private << ", 65) .. "/Length 7 " .. string.rep(">> ", 65) } },
}
for _, sample in ipairs(spoofed) do
    case(sample[1], function()
        local book, reason = inspect(sample[2])
        expect(not book and type(reason) == "string",
            "nested/string/comment/ambiguous keys must not hide the actual page overlay: " .. tostring(reason))
    end)
end
for _, options in ipairs({
    { simple = true },
    { simple = true, indirect = true },
    { simple = true, page_prefix = "/PieceInfo << /Private << /Contents 5 0 R >> >>" },
    { simple = true, stream_prefix = "/Private << /Length 999 >>" },
    { simple = true, stream_prefix = "/Private (balanced \\( << /Length 999 >> \\))" },
    { simple = true, stream_prefix = "/Private <3c3c202f4c656e67746820393939203e3e>" },
    { simple = true, stream_prefix = "% /Length 999\n" },
    { simple = true, stream_prefix = "/Private (stream\nnot-content)" },
}) do
    case("valid top-level keys", function()
        local book, reason = inspect(options)
        expect(book and book.index:count() == 1,
            "valid top-level Contents/Length must remain readable despite inert metadata: " .. tostring(reason))
    end)
end
expect(#failures == 0, table.concat(failures, "\n"))
print(("rebuild_0408_pdf_dictionary_spec: %d checks"):format(checks))
