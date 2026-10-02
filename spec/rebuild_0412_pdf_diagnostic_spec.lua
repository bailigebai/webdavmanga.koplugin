local fixtures = dofile("spec/rebuild_0411_pdf_dominant_image_spec.lua")
local Pdf = require("webdavmanga.pdf_image_stream")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end

local logs = {}
local parser = Pdf:new{ logger = { warn = function(...)
    local parts = {}
    for _, value in ipairs({...}) do parts[#parts + 1] = tostring(value) end
    logs[#logs + 1] = table.concat(parts, " ")
end } }
local bytes = fixtures.fixture{
    content = "q 100 0 0 100 0 0 cm /Main Do Q BT (x) Tj ET",
}
local book, reason = parser:inspect_remote(fixtures.descriptor(bytes), "/private/secret.pdf")
expect(not book and reason == "pdf_page_not_image", "visible text overlay remains unsafe to discard")
local report = table.concat(logs, "\n")
expect(report:find("resolve.reject dominant_content", 1, true),
    "failed dominant-image validation identifies its safe parsing stage")
expect(report:find("content.reject text", 1, true),
    "visible text overlay reports a fixed diagnostic category")
expect(not report:find("private", 1, true) and not report:find("secret", 1, true),
    "PDF parser diagnostics never record remote filenames or paths")
print(("rebuild_0412_pdf_diagnostic_spec: %d checks"):format(checks))
