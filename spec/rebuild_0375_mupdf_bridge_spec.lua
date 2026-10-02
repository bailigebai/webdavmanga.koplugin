local Bridge = require("webdavmanga.document_bridge")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local tasks, opened, native, inspected, first_published = {}, 0, 0, 0, false
local page = { name = "00001.png", path = "/Books/comic.pdf#mupdf/1", is_file = true,
    size = 100, format = "pdf", page = 1, mupdf_page = 1 }
local bridge = Bridge:new{
    cache = {
        key_for = function() return "k" end, lookup_record = function() return nil end,
        paths_for = function(_, _, _, token) return "/cache/page.png", "/cache/page." .. token .. ".part" end,
        publish = function(_, record) first_published = record.mupdf_page == 1; return "/cache/page.png" end,
    },
    client_factory = function()
        return { read_range = function(_, _, first, last)
            return string.rep("x", last - first + 1), { ["Content-Range"] = ("bytes %d-%d/100"):format(first, last) }
        end }
    end,
    -- RAR/7z require archive callbacks even when remote MuPDF is available.
    archive_pages = { can_stream = function() return false end,
        inspect_remote = function() return nil, "libarchive_unavailable" end },
    async = { run = function(work, done, options)
        local task = { work = work, done = done, options = options }; tasks[#tasks + 1] = task
        return { cancel = function() task.cancelled = true end }
    end },
    mupdf_pages = {
        inspect_remote = function(_, descriptor, path)
            inspected = inspected + 1
            expect(descriptor.read_at(0, 1) ~= nil, "MuPDF inspection must probe Range data")
            return { index = { count = function() return 1 end, get = function() return page end },
                layout = "mupdf_pages", first_metadata = { format = "png", width = 1, height = 1 } }
        end,
    },
    open_reader = function(context)
        opened = opened + 1; expect(context.layout == "mupdf_pages", "MuPDF layout must reach reader")
        expect(context.cover_hint.image == page, "first page must be the cover hint")
        return true
    end,
}
local entry = { name = "comic.pdf", path = "/Books/comic.pdf", size = 100,
    file_kind = "document", connection = {} }
expect(bridge:open(entry, {}) == true, "PDF open should start asynchronously")
expect(opened == 0 and inspected == 0 and #tasks == 1, "inspection must be deferred to worker")
expect(tasks[1].options and tasks[1].options.max_payload_bytes == 8 * 1024 * 1024,
    "PDF page index must not be truncated by Async's 8 KiB default payload limit")
local result = tasks[1].work(); tasks[1].done(true, result)
expect(#tasks == 2 and inspected == 0 and opened == 0,
    "unsupported image PDF must hand off to a deferred MuPDF worker")
tasks[2].done(true, tasks[2].work())
expect(inspected == 1 and opened == 1 and first_published,
    "valid MuPDF first page must publish before opening manga reader")
expect(native == 0, "MuPDF route must not call native ReaderUI")

for _, extension in ipairs({ "cbr", "cb7", "rar", "7z" }) do
    local item = { name = "comic." .. extension, path = "/Books/comic." .. extension,
        size = 100, file_kind = "document", connection = {} }
    local prompted
    expect(not bridge:stream_capability(item).supported, extension .. " must expose missing archive capability")
    bridge:open(item, { on_document_fallback_prompt = function(format, reason, retry)
        prompted = format == extension and reason == "libarchive_unavailable" and type(retry) == "function"
    end })
    tasks[#tasks].done(true, tasks[#tasks].work())
    expect(prompted and inspected == 1 and opened == 1, extension .. " must await confirmation without invoking remote MuPDF")
end
local cbt = { name = "comic.cbt", path = "/Books/comic.cbt", size = 100,
    file_kind = "document", connection = {} }
bridge:open(cbt, {}); tasks[#tasks].done(true, tasks[#tasks].work())
expect(inspected == 2 and opened == 2, "existing PDF and CBT MuPDF paths must remain available")
bridge:open(entry, {})
local pdf_task = tasks[#tasks]
pdf_task.done(true, pdf_task.work())
local pending_task = tasks[#tasks]
bridge:cancel_all()
expect(pending_task.cancelled == true,
    "cancel_all must cancel pending MuPDF inspection")
print(("rebuild_0375_mupdf_bridge_spec: %d checks"):format(checks))
