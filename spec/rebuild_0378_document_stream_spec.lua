local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local Bridge = require("webdavmanga.document_bridge")
local bridge = Bridge:new{
    cache = {},
    client_factory = function() return {} end,
    open_reader = function() return true end,
    archive_pages = { inspect_remote = function() end },
    mupdf_pages = { inspect_remote = function() end },
    pdf_image_stream = {}, -- Exercise the independent MuPDF fallback capability.
    mobi_pages = { inspect_remote = function() end },
}

local pdf = bridge:stream_capability{ name = "chapter.pdf" }
expect(pdf.kind == "mupdf_pages" and pdf.supported == true,
    "PDF should report page streaming when the MuPDF adapter is available")
local epub = bridge:stream_capability{ name = "chapter.epub" }
expect(epub.kind == "archive_pages" and epub.supported == true,
    "EPUB should report archive page streaming when the archive adapter is available")
local azw3 = bridge:stream_capability{ name = "chapter.azw3" }
expect(azw3.supported == true and azw3.kind == "mobi_images",
    "AZW3 must use the existing MOBI image adapter")

local no_reader = Bridge:new{ cache = {}, client_factory = function() return {} end }
local unavailable = no_reader:stream_capability{ name = "chapter.pdf" }
expect(unavailable.supported == false and unavailable.fallback == "complete_download",
    "PDF must fall back when the host page adapter is unavailable")

local image_bridge = Bridge:new{
    cache = {}, client_factory = function() return {} end,
    open_reader = function() return true end,
    mupdf_pages = { inspect_remote = function() end, remote_capability = function() return false end },
}
local image_pdf = image_bridge:stream_capability{ name = "chapter.pdf" }
expect(image_pdf.supported == true and image_pdf.kind == "pdf_images",
    "complete image-PDF parser must advertise streaming even without remote MuPDF")
for _, incomplete in ipairs({ {}, { inspect_remote = function() end },
    { extract_remote = function() end }, { inspect_remote = true, extract_remote = true } }) do
    image_bridge.pdf_image_stream = incomplete
    local missing = image_bridge:stream_capability{ name = "chapter.pdf" }
    expect(missing.supported == false and missing.kind == "native_fallback"
        and missing.reason == "mupdf_remote_unavailable",
        "incomplete image-PDF parser must preserve the unavailable MuPDF fallback")
    image_bridge.mupdf_pages.remote_capability = function() return true end
    local available = image_bridge:stream_capability{ name = "chapter.pdf" }
    expect(available.supported == true and available.kind == "mupdf_pages",
        "incomplete image-PDF parser must preserve available remote MuPDF")
    image_bridge.mupdf_pages.remote_capability = function() return false end
end

print(("rebuild_0378_document_stream_spec: %d checks"):format(checks))
