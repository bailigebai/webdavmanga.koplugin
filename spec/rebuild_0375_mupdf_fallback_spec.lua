local Bridge = require("webdavmanga.document_bridge")
local Errors = require("webdavmanga.errors")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local tasks, fallback_stage, errors, confirm = {}, false, 0
local part = os.tmpname()
local cache = {
    key_for = function(_, identity, path) return tostring(identity) .. path end,
    lookup_record = function() return nil end,
    paths_for = function(_, _, _, token) return "/tmp/mupdf-final", part .. "." .. token end,
    publish = function() return "/tmp/mupdf-final" end,
    discard_part = function(_, _, _, token) os.remove(part .. "." .. token) end,
}
local client = {
    read_range = function(_, _, first, last)
        return string.rep("x", last - first + 1),
            { ["Content-Range"] = ("bytes %d-%d/100"):format(first, last) }
    end,
    download_document = function(_, _, target)
        local file = assert(io.open(target, "wb")); file:write("document"); file:close()
        return { size = 8 }
    end,
}
local bridge = Bridge:new{
    cache = cache,
    client_factory = function() return client end,
    async = { run = function(work, done)
        local task = { work = work, done = done }; tasks[#tasks + 1] = task
        return { cancel = function() task.cancelled = true end }
    end },
    file_size = function() return 8 end,
    mupdf_pages = {
        inspect_remote = function() return nil, "range_unavailable" end,
    },
    open_reader = function() error("fallback must not open before download") end,
}
local entry = { name = "comic.pdf", path = "/Books/comic.pdf", size = 100,
    file_kind = "document", connection = {} }
local callbacks = {
    on_open_progress = function(event) if event.stage == "fallback" then fallback_stage = true end end,
    on_error = function() errors = errors + 1 end,
    on_document_fallback_prompt = function(format, reason, retry)
        expect(format == "pdf" and reason == "range_unavailable", "fallback must identify the PDF Range failure")
        confirm = retry
        return true
    end,
}
expect(bridge:open(entry, callbacks) == true, "MuPDF open should start asynchronously")
local first = tasks[1]
local result = first.work(); first.done(true, result)
expect(#tasks == 2 and not confirm,
    "image PDF failure must try MuPDF before asking for complete download")
tasks[2].done(true, tasks[2].work())
expect(#tasks == 2 and fallback_stage and errors == 0 and confirm,
    "Range failure must wait for explicit complete-download confirmation")
confirm(); confirm()
expect(#tasks == 3, "confirmation must schedule exactly one complete-download fallback")
local fallback_task = tasks[3]
fallback_task.done(true, { error = "download_failed" })
expect(errors == 1 and #tasks == 3, "fallback failure must terminate without recursion")

bridge:open(entry, callbacks)
local pdf_task = tasks[#tasks]
pdf_task.done(true, pdf_task.work())
local canceled = tasks[#tasks]
bridge:cancel_all()
expect(canceled.cancelled == true, "cancel_all must stop MuPDF and fallback work")
expect(Errors.message(Errors.image_decode("encrypted_document", "remote")):find("加密", 1, true) ~= nil,
    "encrypted MuPDF documents need a visible error/fallback explanation")
expect(Errors.message(Errors.image_decode("corrupt_document", "remote")):find("损坏", 1, true) ~= nil,
    "corrupt MuPDF documents need a visible error")
os.remove(part)
print(("rebuild_0375_mupdf_fallback_spec: %d checks"):format(checks))
