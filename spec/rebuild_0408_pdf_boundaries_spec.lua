local PdfImageStream = require("webdavmanga.pdf_image_stream")
local Bridge = require("webdavmanga.document_bridge")
local checks, failures = 0, {}
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function case(name, run)
    local ok, err = pcall(run)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local jpeg = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
local function object(number, body) return number .. " 0 obj\n" .. body .. "\nendobj\n" end
local function fixture(content, options)
    options = options or {}
    local pdf, offsets = "%PDF-1.5\n", {}
    local function append(number, body)
        offsets[number] = #pdf; pdf = pdf .. object(number, body)
    end
    append(1, "<< /Type /Catalog /Pages 2 0 R >>")
    append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    append(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 "
        .. (options.multiple and "2" or "1") .. " 1] "
        .. (options.page_extra or "") .. (content and " /Contents 6 0 R " or "")
        .. " /Resources << /Font << /F1 7 0 R >> /XObject << /Im1 4 0 R "
        .. (options.multiple and "/Im2 5 0 R " or "") .. ">> >> >>")
    for number = 4, 5 do
        append(number, "<< /Type /XObject /Subtype /Image /Width 1 /Height 1"
            .. " /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode"
            .. (options.image_extra or "") .. " /Length " .. #jpeg
            .. " >>\nstream\n" .. jpeg .. "\nendstream")
    end
    local encoded = options.filtered and "z" or content or ""
    append(6, "<< /Length " .. (options.length or #encoded)
        .. (options.filtered and " /Filter /FlateDecode" or "")
        .. " >>\nstream\n" .. encoded .. "\nendstream")
    append(7, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    local xref = #pdf
    pdf = pdf .. "xref\n0 8\n0000000000 65535 f \n"
    for number = 1, 7 do pdf = pdf .. ("%010d 00000 n \n"):format(offsets[number]) end
    pdf = pdf .. "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n" .. xref .. "\n%%EOF\n"
    return pdf, xref
end
local function descriptor(bytes)
    return { size = #bytes, read_at = function(offset, count)
        return bytes:sub(offset + 1, offset + count)
    end }
end
local simple = "q 1 0 0 1 0 0 cm /Im1 Do Q"
local compound = "q 1 0 0 1 0 0 cm /Im1 Do Q q 1 0 0 1 1 0 cm /Im2 Do Q"
for _, sample in ipairs({
    { "two side-by-side JPEGs", compound, { multiple = true }, "pdf_multiple_images" },
    { "same image painted twice", simple .. " " .. simple, {}, "pdf_multiple_images" },
    { "text overlay", simple .. " BT /F1 12 Tf (caption) Tj ET" },
    { "vector overlay", simple .. " 0 0 1 1 re f" },
    { "unknown graphics state", "/GS1 gs " .. simple },
    { "missing Contents", false },
    { "unmatched graphics restore", simple .. " Q" },
    { "annotation overlay", simple, { page_extra = "/Annots [8 0 R]" } },
    { "escaped annotation name", simple, { page_extra = "/Ann#6fts [8 0 R]" }, "pdf_object_dictionary_missing" },
    { "image mask", simple, { image_extra = "/SMask 5 0 R" } },
    { "escaped image mask name", simple, { image_extra = "/SM#61sk 5 0 R" }, "pdf_object_dictionary_missing" },
    { "clipped image", "q .5 0 0 1 0 0 cm /Im1 Do Q" },
}) do
    case(sample[1], function()
        local bytes = fixture(sample[2], sample[3])
        local book, reason = PdfImageStream:new():inspect_remote(descriptor(bytes), "/book.pdf")
        expect(not book and reason == (sample[4] or "pdf_page_not_image"),
            "unproven page content must be rejected without discarding visible content: " .. tostring(reason))
    end)
end
case("simple single image", function()
    for _, filtered in ipairs({ false, true }) do
        local bytes = fixture(simple, { filtered = filtered })
        local calls = 0
        local parser = PdfImageStream:new{ decompress = function(encoded, capacity)
            calls = calls + 1
            expect(encoded == "z" and capacity <= 256 * 1024, "Contents decode has a hard output capacity")
            return simple
        end }
        local target = os.tmpname()
        local book, err = parser:inspect_remote(descriptor(bytes), "/book.pdf", target)
        local file = io.open(target, "rb")
        local actual = file and file:read("*a")
        if file then file:close() end
        os.remove(target)
        expect(book and actual == jpeg and calls == (filtered and 1 or 0),
            "plain and Flate single-image Contents must preserve the original JPEG: " .. tostring(err))
    end
end)
case("real parser to MuPDF", function()
    local bytes = fixture(compound, { multiple = true })
    local tasks, opened, prompts, downloads, mupdf_calls = {}, nil, 0, 0, 0
    local part = os.tmpname()
    local bridge = Bridge:new{
        cache = { key_for = function(_, _, path) return path end,
            lookup_record = function() end, paths_for = function(_, _, _, token)
                return part .. "." .. token .. ".png", part .. "." .. token
            end,
            discard_part = function(_, _, _, token) os.remove(part .. "." .. token) end,
            publish = function(_, _, path) os.remove(path); return path .. ".png" end },
        client_factory = function() return {
            read_range = function(_, _, first, last)
                return bytes:sub(first + 1, last + 1),
                    { ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, #bytes) }
            end,
            download_document = function() downloads = downloads + 1 end,
        } end,
        async = { run = function(work, done)
            tasks[#tasks + 1] = { work = work, done = done }; return { cancel = function() end }
        end },
        mupdf_pages = { remote_capability = function() return true end,
            inspect_remote = function()
                mupdf_calls = mupdf_calls + 1
                return { index = { items = { { name = "1.png", path = "/book.pdf#mupdf/1", mupdf_page = 1 } } },
                    first_metadata = { format = "png", width = 2, height = 1, size = 1 } }
            end },
        open_reader = function(context) opened = context.layout; return true end,
    }
    bridge:open({ name = "book.pdf", path = "/book.pdf", size = #bytes, connection = {} }, {
        on_document_fallback_prompt = function() prompts = prompts + 1 end,
    })
    tasks[1].done(true, tasks[1].work())
    local handed_off = #tasks == 2 and opened == nil
    if tasks[2] then tasks[2].done(true, tasks[2].work()) end
    os.remove(part)
    expect(handed_off and mupdf_calls == 1 and opened == "mupdf_pages" and prompts == 0 and downloads == 0,
        "real compound-page parser rejection must open the MuPDF second channel, not a partial JPEG")
end)

case("Flate Contents dictionary order", function()
    local bytes = fixture(simple, { filtered = true })
    bytes = bytes:gsub("/Length 1 /Filter /FlateDecode", "/Filter /FlateDecode /Length 1")
    local book = PdfImageStream:new{ decompress = function() return simple end }
        :inspect_remote(descriptor(bytes), "/ordered.pdf")
    expect(book ~= nil, "single-image Contents must not depend on Filter/Length dictionary order")
end)

-- Sparse virtual files exercise declared 32 MiB streams without allocating them.
local function virtual(segments, size)
    local state = { large_read = false, largest = 0 }
    state.size = size
    state.read_at = function(offset, count)
        state.largest = math.max(state.largest, count)
        if count > 65536 then state.large_read = true; return nil end
        local bytes = string.rep(" ", count)
        for _, segment in ipairs(segments) do
            local first, last = math.max(offset, segment[1]), math.min(offset + count, segment[1] + #segment[2])
            if last > first then
                bytes = bytes:sub(1, first - offset)
                    .. segment[2]:sub(first - segment[1] + 1, last - segment[1])
                    .. bytes:sub(last - offset + 1)
            end
        end
        return bytes
    end
    return state
end
local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end
for _, kind in ipairs({ "XRef", "ObjStm", "Contents" }) do
    for _, filtered in ipairs({ false, true }) do
        case(kind .. " 32MiB " .. tostring(filtered), function()
            local size, length, calls = 64 * 1024 * 1024, 32 * 1024 * 1024, 0
            local filter = filtered and " /Filter /FlateDecode" or ""
            local segments = { { 0, "%PDF-1.5\n" } }
            if kind == "Contents" then
                local bytes, xref = fixture(simple, { length = length, filtered = filtered })
                segments[#segments + 1] = { 0, bytes }
                segments[#segments + 1] = { size - 64, "startxref\n" .. xref .. "\n%%EOF\n" }
            else
                local data = string.char(2) .. be32(5) .. string.char(0)
                    .. string.char(1) .. be32(4096) .. string.char(0)
                local dict = kind == "XRef" and ("/Length " .. length .. filter)
                    or ("/Length " .. #data)
                segments[#segments + 1] = { 128, object(6, "<< /Type /XRef /Size 7 /Root 1 0 R"
                    .. " /W [1 4 1] /Index [1 1 5 1] " .. dict .. " >>\nstream\n" .. data .. "\nendstream") }
                segments[#segments + 1] = { 4096, object(5, "<< /Type /ObjStm /N 1 /First 4 /Length "
                    .. length .. filter .. " >>\nstream\nx\nendstream") }
                segments[#segments + 1] = { size - 64, "startxref\n128\n%%EOF\n" }
            end
            local source = virtual(segments, size)
            local book, reason = PdfImageStream:new{ decompress = function()
                calls = calls + 1; return nil
            end }:inspect_remote(source, "/oversized.pdf")
            local wanted = kind == "XRef" and "pdf_xref_too_large"
                or kind == "ObjStm" and "pdf_object_stream_too_large" or "pdf_object_too_large"
            expect(not source.large_read and calls == 0 and not book and reason == wanted,
                "oversized " .. kind .. " must reject before reading/inflating its payload: " .. tostring(reason))
        end)
    end
end
case("Contents inflated limit", function()
    local bytes = fixture(simple, { filtered = true })
    local book, reason = PdfImageStream:new{ decompress = function(_, capacity)
        expect(capacity <= 256 * 1024, "Contents inflate capacity must be bounded")
        return string.rep(" ", 256 * 1024 + 1)
    end }:inspect_remote(descriptor(bytes), "/inflated.pdf")
    expect(not book and reason == "pdf_object_too_large", "oversized decoded Contents must be rejected")
end)
expect(#failures == 0, table.concat(failures, "\n"))
print(("rebuild_0408_pdf_boundaries_spec: %d checks"):format(checks))
