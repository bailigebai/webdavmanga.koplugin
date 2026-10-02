local Bridge = require("webdavmanga.document_bridge")
local Errors = require("webdavmanga.errors")
local BookIndex = require("webdavmanga.book_index")

local checks, tasks, opened, prompted = 0, {}, 0, nil
local pdf_calls, mupdf_calls, downloads = 0, 0, 0
local worker_options
local target = os.tmpname()
local jpeg = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
local function file_size(path)
    local file = io.open(path, "rb"); if not file then return 0 end
    local size = file:seek("end"); file:close(); return size
end
local function extract(_, _, _, output)
    local file = assert(io.open(output, "wb")); file:write(jpeg); file:close()
    return { format = "jpeg", size = #jpeg, width = 1, height = 1 }
end
local records = {}
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local page = {
    name = "00001.jpg", path = "/Books/comic.pdf#pdf/1", is_file = true,
    size = 4, format = "jpg", page = 1, pdf_image = true,
    pdf_remote_path = "/Books/comic.pdf", pdf_source_size = 100,
    pdf_image_offset = 42, pdf_image_length = 4,
}
local bridge = Bridge:new{
    file_size = file_size,
    cache = {
        key_for = function(_, _, path) return path end,
        lookup_record = function(_, key) return records[key] and records[key].path, records[key] end,
        paths_for = function(_, _, _, token) return target .. "." .. token .. ".jpg", target .. "." .. token end,
        publish = function(_, record, part)
            expect(record.pdf_image == true and record.pdf_remote_path == "/Books/comic.pdf",
                "PDF page cache record must retain source metadata")
            record.path = part .. ".jpg"; assert(os.rename(part, record.path)); records[record.key] = record
            return record.path
        end,
        discard_part = function(_, _, _, token) os.remove(target .. "." .. token) end,
    },
    client_factory = function()
        return { read_range = function() return "DATA", {} end,
            download_document = function() downloads = downloads + 1 end }
    end,
    async = { run = function(work, done, options)
        worker_options = options
        local task = { work = work, done = done }; tasks[#tasks + 1] = task
        return { cancel = function() task.cancelled = true end }
    end },
    pdf_image_stream = {
        inspect_remote = function(_, descriptor, path)
            pdf_calls = pdf_calls + 1
            return { index = BookIndex.from_items({ page }), total_pages = 1 }
        end,
        extract_remote = function(self, image, read_at, output)
            expect(image.pdf_remote_path == "/Books/comic.pdf" and type(output) == "string",
                "PDF parser must receive the remote path and first-page target")
            return extract(self, image, read_at, output)
        end,
    },
    mupdf_pages = { remote_capability = function() return true end,
        inspect_remote = function()
            mupdf_calls = mupdf_calls + 1
            return nil, "mupdf_inspection_failed"
        end },
    open_reader = function(context)
        opened = opened + 1
        expect(context.layout == "pdf_images" and context.chapter_index:count() == 1,
            "plugin PDF parser must open the manga reader")
        return true
    end,
}
local entry = { name = "comic.pdf", path = "/Books/comic.pdf", size = 100,
    file_kind = "document", connection = {} }
expect(bridge:open(entry, {
    on_pdf_fallback_prompt = function() prompted = true end,
}), "PDF image open should start asynchronously")
expect(#tasks == 1, "PDF image inspection must run in one worker")
expect(worker_options and worker_options.max_payload_bytes >= 1024 * 1024,
    "PDF page indexes must not use Async's 8 KiB payload default")
local task = tasks[1]; local result = task.work(); task.done(true, result)
expect(pdf_calls == 1 and mupdf_calls == 0,
    "the restored image-PDF adapter must run before current MuPDF")
expect(opened == 1 and not prompted, "valid image PDF must bypass fallback prompt")

for _, invalid in ipairs({ { size = nil }, { size = 0 }, { size = 1.5 } }) do
    local invalid_entry = {}
    for key, value in pairs(entry) do invalid_entry[key] = value end
    invalid_entry.size = invalid.size
    local fallback_handle, fallback_prompt
    local task_count, inspections = #tasks, pdf_calls + mupdf_calls
    bridge:open(invalid_entry, {
        on_open_handle = function(handle) fallback_handle = handle end,
        on_document_fallback_prompt = function(format, reason, retry)
            fallback_prompt = format == "pdf" and type(reason) == "string"
                and type(retry) == "function"
        end,
    })
    expect(fallback_handle and fallback_prompt and downloads == 0,
        "invalid PDF source size must expose a fallback handle/prompt without downloading")
    expect(#tasks == task_count and pdf_calls + mupdf_calls == inspections,
        "invalid PDF source size must not enter either parser")
end

local canceled_handle
bridge:open(entry, {
    on_open_handle = function(handle) canceled_handle = handle end,
    on_pdf_fallback_prompt = function() prompted = true end,
})
local canceled_task = tasks[#tasks]
local before_opened, before_prompted = opened, prompted
canceled_handle.cancel()
local canceled_result = canceled_task.work()
canceled_task.done(true, canceled_result)
expect(canceled_task.cancelled and opened == before_opened and prompted == before_prompted,
    "canceled PDF inspection must not open Reader or prompt after a late result")

bridge:open(entry, {
    on_pdf_fallback_prompt = function() prompted = true end,
})
local canceled_all_task = tasks[#tasks]
bridge:cancel_all()
canceled_all_task.done(true, { error = "pdf_encrypted" })
expect(canceled_all_task.cancelled and opened == before_opened and prompted == before_prompted,
    "cancel_all must suppress a late failed PDF result and its fallback prompt")
expect(next(bridge.pending_pdf) == nil, "cancel_all must release PDF request ownership")

local prompt_tasks = {}
local fallback = Bridge:new{
    cache = {
        key_for = function(_, _, path) return path end,
        lookup_record = function() return nil end,
        paths_for = function(_, _, _, token) return "/cache/page.jpg", target .. "." .. token end,
        publish = function(_, _, part) os.remove(part); return "/cache/page.jpg" end,
        discard_part = function(_, _, _, token) os.remove(target .. "." .. token) end,
    },
    client_factory = function()
        return { read_range = function() return "bad", {} end,
            download_document = function(_, _, path)
                local file = assert(io.open(path, "wb")); file:write("PDF"); file:close()
                return { size = 3 }
            end }
    end,
    async = { run = function(work, done)
        local current = { work = work, done = done }; prompt_tasks[#prompt_tasks + 1] = current
        return { cancel = function() current.cancelled = true end }
    end },
    pdf_image_stream = { inspect_remote = function() return nil, "pdf_encrypted" end },
    mupdf_pages = { remote_capability = function() return false end,
        inspect_local = function() return { index = { count = function() return 1 end, get = function() return page end } } end },
    open_reader = function() return true end,
}
local retried
fallback:open(entry, { on_pdf_fallback_prompt = function(reason, retry)
    expect(reason == "pdf_encrypted", "unavailable MuPDF must retain the image parser failure")
    prompted = true; retried = retry
end })
local prompt_task = prompt_tasks[1]; prompt_task.done(true, prompt_task.work())
expect(prompted and type(retried) == "function" and #prompt_tasks == 1,
    "unsupported PDF must prompt without downloading")
retried()
expect(#prompt_tasks == 2, "confirming the prompt must start exactly one complete download")
prompt_tasks[2].done(true, prompt_tasks[2].work())

-- Review regressions: local write failure is terminal, and cancellation can
-- happen before async.run has returned its worker handle.
local review_failures = {}
for _, mode in ipairs({ "storage", "handle_cancel", "run_cancel", "storage_table", "invalid_path",
    "storage_table_available", "invalid_path_available", "first_page_cancel" }) do
    local local_tasks, local_prompts, local_downloads, local_mupdf = {}, 0, 0, 0
    local local_opened, local_closed, opened_notifications = 0, 0, 0
    local local_error, local_handle
    local terminal_error = mode:find("storage_table", 1, true) == 1 and Errors.storage("disk_full")
        or mode:find("invalid_path", 1, true) == 1 and Errors.invalid_path() or nil
    local local_part = os.tmpname()
    local local_records = {}
    local current = Bridge:new{
        file_size = file_size,
        cache = {
            key_for = function(_, _, path) return path end,
            lookup_record = function(_, key) return local_records[key] and local_records[key].path, local_records[key] end,
            paths_for = function(_, _, _, token)
                return local_part .. ".jpg", token:match("_opening_1$") and local_part or local_part .. "." .. token
            end,
            discard_part = function(_, _, _, token)
                os.remove(token:match("_opening_1$") and local_part or local_part .. "." .. token)
            end,
            publish = function(_, record, part)
                record.path = part .. ".jpg"; assert(os.rename(part, record.path)); local_records[record.key] = record
                return record.path
            end,
        },
        client_factory = function()
            return { read_range = function() return "DATA", {} end,
                download_document = function() local_downloads = local_downloads + 1 end }
        end,
        async = { run = function(work, done)
            local next_task = { work = work, done = done, canceled = false }
            local_tasks[#local_tasks + 1] = next_task
            if mode == "run_cancel" then local_handle:cancel() end
            return { cancel = function() next_task.canceled = true end }
        end },
        pdf_image_stream = { inspect_remote = function()
            if terminal_error then return nil, terminal_error end
            return { index = BookIndex.from_items({ page }), total_pages = 1 }
        end, extract_remote = function(self, image, read_at, output)
            if mode == "first_page_cancel" then return extract(self, image, read_at, output) end
            local file = assert(io.open(output, "wb")); file:write("partial"); file:close()
            return nil, "pdf_image_write_failed"
        end },
        mupdf_pages = { remote_capability = function()
            return terminal_error == nil or mode:find("available", 1, true) ~= nil
        end,
            inspect_remote = function()
                local_mupdf = local_mupdf + 1
                return nil, "mupdf_inspection_failed"
            end },
        open_reader = function() local_opened = local_opened + 1; return true end,
    }
    local ok, failure = pcall(function()
        current:open(entry, {
            on_open_handle = function(handle)
                local_handle = handle
                if mode == "handle_cancel" then handle:cancel() end
            end,
            on_error = function(err) local_error = err end,
            on_document_fallback_prompt = function() local_prompts = local_prompts + 1 end,
            on_open_progress = function(event)
                if mode == "first_page_cancel" and event.stage == "first_page" then local_handle:cancel() end
            end,
            close_plugin = function() local_closed = local_closed + 1 end,
            on_opened = function() opened_notifications = opened_notifications + 1 end,
        })
        if terminal_error then
            local first = local_tasks[1]
            first.done(true, first.work())
            first.done(true, { error = terminal_error })
            expect(local_error and local_error.code == terminal_error.code,
                "image-PDF structured " .. terminal_error.code .. " must remain terminal before adapter handoff")
            expect(#local_tasks == 1 and local_mupdf == 0 and local_prompts == 0 and local_downloads == 0,
                "terminal image-PDF error must not enter MuPDF, prompt or download")
        elseif mode == "first_page_cancel" then
            local first = local_tasks[1]
            local result = first.work(); first.done(true, result); first.done(true, result)
            expect(local_opened == 0 and local_closed == 0 and opened_notifications == 0 and not local_error,
                "image-PDF first-page progress cancellation must not close plugin, open Reader or notify opened")
        elseif mode == "storage" then
            local first = local_tasks[1]
            first.done(true, first.work())
            expect(local_error and local_error.code == "storage",
                "PDF first-page write failure must remain a storage error before MuPDF handoff")
            expect(#local_tasks == 1 and local_mupdf == 0 and local_prompts == 0
                and local_downloads == 0, "storage failure must not schedule another adapter or download prompt")
            first.done(true, { error = "pdf_image_write_failed" })
        elseif mode == "handle_cancel" then
            expect(#local_tasks == 0,
                "synchronous on_open_handle cancellation must not start a PDF worker")
        else
            expect(#local_tasks == 1 and local_tasks[1].canceled,
                "cancellation inside async.run must cancel the subsequently returned worker handle")
            local_tasks[1].done(true, { error = "pdf_image_write_failed" })
        end
        expect(next(current.pending_pdf) == nil and next(current.pending_mupdf) == nil,
            "failed/canceled PDF must release request ownership")
        local file = io.open(local_part, "rb")
        if file then file:close() end
        expect(not file, "failed/canceled PDF must clear its owned part")
        expect(local_prompts == 0 and local_downloads == 0,
            "failed/canceled PDF must remain free of fallback prompts and downloads")
        expect(local_opened == 0, "failed/canceled PDF must never open Reader")
    end)
    os.remove(local_part)
    os.remove(local_part .. ".jpg")
    if not ok then review_failures[#review_failures + 1] = mode .. ": " .. tostring(failure) end
end
expect(#review_failures == 0, table.concat(review_failures, "\n"))

-- Real tokenized part ownership when A completes after replacement B writes.
do
    local parts, local_tasks, handles, discarded = {}, {}, {}, {}
    local owned, local_records = {}, {}
    local published, readers, prompts = 0, 0, 0
    local function exists(path)
        local f = io.open(path, "rb"); if not f then return false end; f:close(); return true
    end
    local current = Bridge:new{
        file_size = file_size,
        cache = {
            key_for = function(_, _, path) return path end,
            lookup_record = function(_, key) return local_records[key] and local_records[key].path, local_records[key] end,
            paths_for = function(_, _, _, token)
                owned[token] = owned[token] or os.tmpname()
                local owner = token:match("^(pdf%d+)_opening_1$")
                if owner then parts[owner] = owned[token] end
                return owned[token] .. ".final", owned[token]
            end,
            discard_part = function(_, _, _, token)
                discarded[#discarded + 1] = token:match("^(pdf%d+)_opening_%d+$") or token
                os.remove(owned[token])
            end,
            publish = function(_, record, part)
                expect(exists(part), "B's own first-page bytes must survive A cleanup")
                published = published + 1; assert(os.rename(part, part .. ".final"))
                record.path = part .. ".final"; local_records[record.key] = record
                return record.path
            end,
        },
        client_factory = function() return { read_range = function() return "DATA", {} end,
            download_document = function() error("unconfirmed PDF download") end } end,
        async = { run = function(work, done, options)
            local t = { work = work, done = done, options = options }; local_tasks[#local_tasks + 1] = t
            return { cancel = function() t.canceled = true end }
        end },
        pdf_image_stream = { inspect_remote = function()
            return { index = BookIndex.from_items({ page }), total_pages = 1 }
        end, extract_remote = extract },
        open_reader = function() readers = readers + 1; return true end,
    }
    local cb = { on_open_handle = function(handle) handles[#handles + 1] = handle end,
        on_document_fallback_prompt = function() prompts = prompts + 1 end }
    current:open(entry, cb)
    local a, a_result = local_tasks[1], local_tasks[1].work()
    handles[1]:cancel()
    current:open(entry, cb)
    local b, b_result = local_tasks[2], local_tasks[2].work()
    local before = #discarded
    a.done(true, a_result); a.done(true, { error = "pdf_xref_invalid" }); a.options.on_reaped()
    expect(published == 0 and readers == 0 and prompts == 0 and exists(parts.pdf2),
        "stale PDF A cannot publish, prompt, open Reader or delete B's part")
    for i = before + 1, #discarded do expect(discarded[i] == "pdf1", "A cleanup must use only A's token") end
    b.done(true, b_result); a.done(true, a_result); b.done(true, b_result)
    expect(published == 1 and readers == 1 and prompts == 0 and exists(parts.pdf2 .. ".final"),
        "B publishes/opens once and late callbacks preserve its final page")
    expect(next(current.pending_pdf) == nil, "completed replacement must release PDF ownership")
    current:open(entry, cb)
    local canceled = local_tasks[3]
    canceled.options.on_cancelled()
    expect(next(current.pending_pdf) == nil, "PDF worker cancellation must release pending ownership immediately")
    canceled.done(true, canceled.work())
    expect(published == 1 and readers == 1 and prompts == 0,
        "worker cancellation followed by a late PDF result must stay inert")
    for _, path in pairs(owned) do os.remove(path); os.remove(path .. ".final") end
end
for _, record in pairs(records) do os.remove(record.path) end
os.remove(target)
print(("rebuild_0386_pdf_image_bridge_spec: %d checks"):format(checks))
