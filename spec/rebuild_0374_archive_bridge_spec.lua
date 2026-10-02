local Bridge = require("webdavmanga.document_bridge")
local BookIndex = require("webdavmanga.book_index")
local Errors = require("webdavmanga.errors")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local JPEG_BYTES = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
    0, 1, 0, 1, 1, 1, 0x11, 0, 0xFF, 0xD9)
-- KOReader supplies json on-device. The host runner has no KOReader C modules;
-- this codec double preserves the plain-table boundary without executing text.
local encoded, serial = {}, 0
package.preload.json = function() return {
    encode = function(value)
        serial = serial + 1
        local bytes = '{"test_index":' .. serial .. '}'
        encoded[bytes] = value
        return bytes
    end,
    decode = function(bytes) return encoded[bytes] end,
} end

local function image(path, size, ordinal)
    ordinal = ordinal or 1
    return {
        name = "00" .. ordinal .. ".jpg", path = path .. "#zip/" .. ordinal,
        is_file = true, archive_kind = "zip", archive_remote_path = path,
        archive_source_size = size, archive_entry_name = "00" .. ordinal .. ".jpg",
        archive_local_offset = (ordinal - 1) * 40, archive_method = 0,
        archive_flags = 0, archive_crc32 = 0, archive_compressed_size = 3,
        archive_size = 3,
    }
end
local sparse_items = { image("/Books/sparse.cbz", 200, 1),
    image("/Books/sparse.cbz", 200, 2), image("/Books/sparse.cbz", 200, 3) }
sparse_items[2] = nil
expect(BookIndex.from_table({ version = 1, count = 3, items = sparse_items }) == nil,
    "manifest must reject a missing middle page instead of returning a truncated index")
local sparse_index = BookIndex.from_items({})
sparse_index.items = sparse_items
expect(sparse_index:to_table() == nil, "manifest encoding must reject missing middle pages too")
local files = {}
local function temp()
    local path = os.tmpname(); files[#files + 1] = path; return path
end
local function write(path, bytes)
    local file = assert(io.open(path, "wb")); assert(file:write(bytes)); file:close()
end
local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close(); return true
end
local function fixture(options)
    options = options or {}
    local state = { tasks = {}, scheduled = {}, records = {}, paths = {}, events = {}, opened = 0,
        native = 0, downloads = 0, inspections = 0, extracted = 0, local_extracted = 0,
        discarded = 0, connections = {}, keys = {}, removed = {}, logs = {}, prompts = 0,
        inspect_limits = {} }
    local connection = { server_url = "http://nas", username = "u", root_path = "/Books" }
    local cache = {
        key_for = function(_, identity, path, kind)
            local key = identity .. "|" .. path .. (kind and "|" .. kind or "")
            state.keys[#state.keys + 1] = key
            return key
        end,
        lookup_record = function(_, key)
            local r = state.records[key]; return r and r.path, r
        end,
        paths_for = function(_, key, ext, token)
            local id = key .. ext .. token
            state.paths[id] = state.paths[id] or { temp(), temp() }
            if ext == "manifest" then state.manifest_part = state.paths[id][2] end
            return unpack(state.paths[id])
        end,
        publish = function(_, record, part)
            if options.publish_error and record.kind == "page" then return nil, "disk_full" end
            local file = io.open(part, "rb")
            expect(file ~= nil, "published cache must have worker output"); file:close()
            state.events[#state.events + 1] = "publish_" .. record.kind
            local previous = state.records[record.key]
            if previous then os.remove(previous.path) end
            record.path = temp(); os.remove(record.path); assert(os.rename(part, record.path))
            state.records[record.key] = record; return record.path
        end,
        discard_part = function() state.discarded = state.discarded + 1 end,
        clear_matching_cache = function(_, predicate)
            for key, record in pairs(state.records) do
                if predicate(record, key) then
                    state.removed[#state.removed + 1] = key
                    os.remove(record.path)
                    state.records[key] = nil
                end
            end
            return true
        end,
    }
    local client = { connection = connection,
        read_range = function(_, _, first, last)
            if options.client_error then return nil, nil, options.client_error end
            if options.range_error then return nil, nil, "range_rejected" end
            return string.rep("x", last - first + 1), {
                ["content-range"] = ("bytes %d-%d/%d"):format(first, last, state.entry.size) }
        end,
        download_document = function(_, _, target)
            state.downloads = state.downloads + 1; write(target, string.rep("x", 200))
            return { size = 200, format = options.kind or "cbz", etag = "v1" }
        end,
    }
    local pages = {
        inspect_remote = function(_, descriptor, kind, path, inspect_options)
            state.inspections = state.inspections + 1
            state.inspect_limits[#state.inspect_limits + 1] = inspect_options and inspect_options.page_limit or false
            if options.metadata_work then
                state.metadata_work_path = descriptor.metadata_work_path
                if not state.metadata_work_path then return nil, "metadata_work_path_missing" end
                write(state.metadata_work_path, "unfinished compressed EPUB metadata")
            end
            local bytes = descriptor.read_at(0, 1)
            if not bytes then return nil, "zip_read_failed" end
            if options.text_epub then return nil, "epub_not_image_book" end
            if options.inspect_error then return nil, options.inspect_error end
            local items = { image(path, descriptor.size, 2), image(path, descriptor.size) }
            local incomplete = false
            if options.progressive then
                items = {}
                local count = inspect_options and inspect_options.page_limit
                    and (kind == "epub" and 3 or 20) or 45
                for position = 1, count do
                    items[position] = image(path, descriptor.size, position)
                end
                incomplete = count < 45
                if inspect_options and type(inspect_options.on_progress) == "function" then
                    for _, progress_count in ipairs({ 25, 40 }) do
                        local partial = {}
                        for position = 1, progress_count do
                            partial[position] = image(path, descriptor.size, position)
                        end
                        assert(inspect_options.on_progress(BookIndex.from_items(partial), 45) ~= false)
                    end
                end
            end
            local index = BookIndex.from_items(items)
            if options.invalid_index then index:get(1).archive_local_offset = -1 end
            local continuation = incomplete and kind == "epub" and {
                version = 1, source_version = inspect_options.source_version,
                generation = inspect_options.generation,
                source_size = descriptor.size, remote_path = path,
                next_cursor = 4,
            } or nil
            return { index = index, incomplete = incomplete,
                total_pages = options.progressive and 45 or index:count(),
                continuation = continuation }
        end,
        extract_remote = function(_, _, read_at, target)
            state.extracted = state.extracted + 1
            assert(read_at(0, 1)); write(target, options.kind == "epub" and JPEG_BYTES or "jpg")
            if options.extract_error then return nil, "zip_crc_mismatch" end
            return { format = "jpeg", width = 1, height = 1,
                size = options.kind == "epub" and #JPEG_BYTES or 3 }
        end,
        extract_local = function(_, page, target)
            state.local_extracted = state.local_extracted + 1
            assert(page.archive_local_path); write(target, "jpg")
            if options.local_error then
                return nil, type(options.local_error) == "string" and options.local_error or "zip_crc_mismatch"
            end
            return { format = "jpeg", width = 1, height = 1, size = 3 }
        end,
    }
    local bridge = Bridge:new{
        cache = cache, identity = "nas-u", archive_pages = pages,
        logger = { warn = function(...)
            state.logs[#state.logs + 1] = table.concat({ ... }, " ")
        end },
        client_factory = function(selected)
            state.connections[#state.connections + 1] = selected and selected.server_url
            return client
        end,
        async = { run = function(work, done, opts)
            local task = { work = work, done = done, opts = opts }
            state.tasks[#state.tasks + 1] = task
            return { cancel = function() task.canceled = true end }
        end },
        scheduler = {
            scheduleIn = function(_, _, callback)
                state.scheduled[#state.scheduled + 1] = callback
                return true
            end,
            unschedule = function(_, callback)
                for position = #state.scheduled, 1, -1 do
                    if state.scheduled[position] == callback then
                        table.remove(state.scheduled, position)
                    end
                end
                return true
            end,
        },
        file_size = function(path)
            local f = io.open(path, "rb"); if not f then return 0 end
            local size = f:seek("end"); f:close(); return size
        end,
        open_reader = function(context)
            state.opened = state.opened + 1; state.context = context
            state.events[#state.events + 1] = "open"
            return true
        end,
        ui_manager = {
            showReader = function(_, path) state.native = state.native + 1; state.native_path = path; return true end,
            showReaderStream = function() error("archive must never use native streaming") end,
        },
    }
    state.entry = { name = "comic." .. (options.kind or "cbz"), path = "/Books/comic." .. (options.kind or "cbz"),
        size = 200, etag = "v1", file_kind = "document", connection = connection,
        allow_complete_fallback = options.allow_complete_fallback == true }
    state.callbacks = {
        on_document_fallback_prompt = function(format, reason, retry)
            state.prompts = state.prompts + 1
            state.prompt_format, state.prompt_reason, state.retry = format, reason, retry
            return true
        end,
        on_open_handle = function(handle) state.handle = handle end,
        on_open_progress = function(event) state.events[#state.events + 1] = event.stage end,
        on_error = function(err) state.error = err end,
        on_closed = function() state.closed = true end,
    }
    function state:run(position)
        local task = assert(self.tasks[position])
        local ok, result = pcall(task.work)
        task.done(ok, result, not ok and result or nil)
        return result
    end
    function state:run_scheduled()
        local callback = table.remove(self.scheduled, 1)
        if callback then callback() end
        return callback ~= nil
    end
    return bridge, state, cache
end

do
    local progressive, s = fixture{ kind = "epub", progressive = true }
    s.entry.size = 10000
    progressive:open(s.entry, s.callbacks)
    s:run(1)
    expect(s.opened == 0 and #s.tasks == 2,
        "EPUB index worker hands three owned parts to the staging worker")
    s:run(2)
    expect(s.opened == 1 and s.context.chapter_index:count() == 3
        and s.context.stream_state and s.context.stream_state.complete == false,
        "progressive EPUB must open after the first three pages")
    expect(s.inspect_limits[1] == 3,
        "the initial remote inspection must request exactly three pages")
    expect(#s.tasks == 3, "opening a partial index must schedule one background resumed scan")
    local shared = s.context.chapter_index
    local growth_notifications = 0
    s.context.stream_state.on_index_growth = function()
        growth_notifications = growth_notifications + 1
    end
    local background = s.tasks[3]
    local background_result = background.work()
    expect(shared:count() == 3,
        "worker progress must cross the process boundary before changing the live index")
    expect(s:run_scheduled() and shared:count() == 40
        and s.context.stream_state.complete == false,
        "background snapshots must grow the live index before the full scan finishes")
    expect(growth_notifications == 1,
        "background snapshot notifies Reader that more pages can be warmed")
    background.done(true, background_result)
    expect(shared == s.context.chapter_index and shared:count() == 45,
        "background completion must update the reader's shared BookIndex in place")
    expect(growth_notifications == 2,
        "full index completion notifies Reader of the final growth")
    expect(s.context.stream_state.complete == true
        and s.context.stream_state.total_pages == 45
        and s.context.stream_state.error == nil,
        "background completion must unlock full-index navigation")
end

for _, kind in ipairs({ "cbz", "epub" }) do
    local bridge, s = fixture{ kind = kind }
    local next_task = 1
    local function complete_click()
        local wanted = s.opened + 1
        while s.opened < wanted and s.tasks[next_task] do
            s:run(next_task)
            next_task = next_task + 1
        end
    end
    expect(bridge:open(s.entry, s.callbacks) == true, "archive click must start asynchronously")
    expect(s.opened == 0 and s.native == 0 and s.inspections == 0 and s.handle,
        "archive click must return with cancel handle before any inspection")
    complete_click()
    expect(s.opened == 1 and s.native == 0 and s.downloads == 0,
        "archive documents must open in manga reader after worker inspection")
    expect(s.context.layout == "archive_images" and s.context.chapter_index:count() == 2,
        "archive context must retain its page index")
    expect(s.extracted == (kind == "epub" and 2 or 1) and s.events[#s.events] == "open",
        "all required EPUB opening pages, or the first CBZ page, publish before Reader")
    local published = false
    for _, event in ipairs(s.events) do if event == "publish_page" then published = true end end
    expect(published and s.context.cover_hint.image.path == "/Books/comic." .. kind .. "#zip/1",
        "reader requires a published first page and stable cover hint")
    local later = s.context.chapter_index:get(2)
    expect(later.archive_remote_path == s.entry.path and later.archive_entry_name == "002.jpg"
        and later.archive_local_path == nil and later.archive_source_size == 200
        and later.archive_local_offset == 40 and later.archive_compressed_size == 3
        and later.archive_method == 0 and later.archive_crc32 == 0
        and later.etag == "v1" and later.archive_version,
        "later pages must preserve Range descriptors and source version without a full local document")
    s.context.source_context.on_return(); expect(s.closed, "reader return callback must survive routing")
    bridge:open(s.entry, s.callbacks); complete_click()
    expect(s.inspections == 1, "same identity/path/size/ETag must reuse manifest")
    s.entry.etag = "v2"; bridge:open(s.entry, s.callbacks); complete_click()
    expect(s.inspections == 2, "changed ETag must invalidate manifest")
    s.entry.size = 201; bridge:open(s.entry, s.callbacks); complete_click()
    expect(s.inspections == 3, "changed size must invalidate manifest")
    s.entry.modified = "2026-09-12"; bridge:open(s.entry, s.callbacks); complete_click()
    expect(s.inspections == 4, "changed modification time must invalidate manifest")
end

local canceled, cs = fixture()
canceled:open(cs.entry, cs.callbacks); cs.handle:cancel(); cs:run(1)
expect(cs.tasks[1].canceled and cs.opened == 0 and cs.downloads == 0 and cs.discarded > 0,
    "cancel must stop worker, discard owned parts and ignore late completion")
expect(next(cs.records) == nil and cs.prompts == 0,
    "late canceled archive callback must not publish a page/manifest or prompt")
local no_etag, ns = fixture()
-- A canceled worker may finish after a replacement has written the same book.
-- Its cleanup must remain confined to its own token, including metadata parts.
do
    local current, s = fixture{ kind = "epub", metadata_work = true }
    current:open(s.entry, s.callbacks)
    local a, a_handle = s.tasks[1], s.handle
    local a_result = a.work()
    local a_metadata = s.metadata_work_path
    a_handle:cancel()
    current:open(s.entry, s.callbacks)
    local b = s.tasks[2]
    local b_result = b.work()
    local b_metadata = s.metadata_work_path
    files[#files + 1], files[#files + 2] = a_metadata, b_metadata
    write(a_metadata, "late A bytes")
    a.done(true, a_result); a.done(true, { error = "epub_not_image_book" }); a.opts.on_reaped()
    expect(s.opened == 0 and s.prompts == 0 and s.native == 0 and next(s.records) == nil,
        "stale A must neither publish, prompt nor open while B is pending")
    expect(not exists(a_metadata) and exists(b_metadata) and next(current.pending_archive) ~= nil,
        "A cleanup must remove only A metadata and preserve B ownership")
    b.done(true, b_result)
    expect(s.opened == 0 and s.tasks[3],
        "replacement B still validates its two opening images before Reader entry")
    s:run(3)
    expect(s.opened == 1 and s.prompts == 0 and s.downloads == 0 and next(current.pending_archive) == nil,
        "replacement B must publish and open exactly once without a download")
    a.done(true, a_result); b.done(true, b_result)
    expect(s.opened == 1 and s.prompts == 0, "duplicate completions must not reopen or prompt")
    for _, record in pairs(s.records) do
        expect(exists(record.path), "stale cleanup must preserve B's published page and manifest")
    end
end
ns.entry.etag = ""; no_etag:open(ns.entry, ns.callbacks); ns:run(1)
expect(ns.opened == 1 and ns.downloads == 0, "an empty optional ETag must not reject a valid archive")
local canceled_all, ca = fixture()
canceled_all:open(ca.entry, ca.callbacks); canceled_all:cancel_all(); ca:run(1)
expect(ca.tasks[1].canceled and ca.opened == 0 and next(canceled_all.pending_archive) == nil,
    "closing the plugin must cancel and clean all archive indexing requests")

local bound, bs = fixture()
bound:open(bs.entry, bs.callbacks)
bs.entry.connection.server_url = "http://changed"
bs:run(1)
expect(bs.connections[2] == "http://nas", "archive worker must retain the click's connection snapshot")
bs.entry.identity = "other-nas"; bound:open(bs.entry, bs.callbacks); bs:run(2)
expect(bs.inspections == 2, "different connection identity must not reuse another connection's manifest")
bs.entry.path = "/Books/another.cbz"; bound:open(bs.entry, bs.callbacks); bs:run(3)
expect(bs.inspections == 3, "different remote path must not reuse another book's manifest")

local fallback, fs = fixture{ range_error = true }
fallback:open(fs.entry, fs.callbacks); fs:run(1)
expect(#fs.tasks == 1 and fs.retry and fs.native == 0 and fs.downloads == 0,
    "Range rejection must await complete-download confirmation")
fs.retry()
fs.tasks[1].done(true, { error = "zip_read_failed" })
expect(#fs.tasks == 2, "duplicate failure must not start a second fallback")
fs:run(2); fs:run(3)
expect(fs.downloads == 1 and fs.local_extracted == 1 and fs.opened == 1 and fs.native == 0,
    "downloaded CBZ must reuse local extraction and open manga reader")
expect(fs.context.chapter_index:get(2).archive_local_path ~= nil,
    "later pages of full-cache archives must keep the local source")

for _, case in ipairs({
    { reason = "zip_directory_invalid", stage = "zip_directory" },
    { reason = "epub_container_missing", stage = "epub_container" },
    { reason = "epub_not_image_book", stage = "epub_spine" },
    { reason = "zip_crc_mismatch", stage = "first_page", extract = true },
    { reason = "range_request_failed", stage = "range_probe", range = true },
    { reason = "transport", stage = "range_probe", network = true },
}) do
    for _, prompt in ipairs({ true, false }) do
        local bridge, s = fixture{ kind = "epub",
            inspect_error = not case.extract and not case.range and not case.network and case.reason or nil,
            extract_error = case.extract,
            client_error = case.network and Errors.transport("private-host password=secret")
                or case.range and case.reason or nil }
        if not prompt then s.callbacks.on_document_fallback_prompt = nil end
        bridge:open(s.entry, s.callbacks); s:run(1)
        if case.extract then s:run(2) end
        expect(s.downloads == 0 and s.native == 0 and s.opened == 0
            and #s.tasks == (case.extract and 2 or 1),
            "EPUB failure must not open or download before confirmation: " .. case.reason)
        if prompt then
            expect(s.prompts == 1 and s.prompt_format == "epub" and s.prompt_reason == case.reason
                and type(s.retry) == "function" and not s.error,
                "EPUB failure must offer one sanitized retry: " .. case.reason)
        else
            expect(s.error and s.error.code == "document" and s.error.stage == "stream"
                and s.error.format == "epub" and s.error.stream_stage == case.stage
                and s.error.reason == case.reason,
                "EPUB failure must retain structured stream stage: " .. case.reason)
        end
        local logs = table.concat(s.logs, "\n")
        expect(logs:find(" " .. case.stage .. " epub archive_pages " .. case.reason, 1, true),
            "EPUB diagnostic must retain its failure stage: " .. case.reason)
        expect(not logs:find("private-host", 1, true) and not logs:find("secret", 1, true)
            and not logs:find("/Books/", 1, true)
            and (not s.error or not Errors.message(s.error):find("private-host", 1, true)),
            "EPUB logs and user errors must not expose server details")
    end
end

local text_bridge, ts = fixture{ kind = "epub", text_epub = true, allow_complete_fallback = true }
text_bridge:open(ts.entry, ts.callbacks); ts:run(1); ts.retry(); ts:run(2); ts:run(3)
expect(ts.downloads == 1 and ts.opened == 0 and ts.native == 1,
    "text EPUB must reach native reader only after complete download and local classification")

local local_bridge, ls = fixture()
ls.entry.local_path = temp(); write(ls.entry.local_path, string.rep("x", 200))
local_bridge:open(ls.entry, ls.callbacks); ls:run(1)
expect(ls.local_extracted == 1 and ls.opened == 1 and ls.downloads == 0,
    "existing complete local archive must use extract_local")

for _, changed in ipairs({ "size", "etag", "modified" }) do
    local bridge, s, cache = fixture()
    s.entry.modified = "old-date"
    local source = temp(); write(source, string.rep("x", 200))
    s.records[cache:key_for("nas-u", s.entry.path)] = {
        path = source, kind = "document", size = 200, etag = "v1", modified = "old-date" }
    if changed == "size" then s.entry.size = 201
    elseif changed == "etag" then s.entry.etag = "v2"
    else s.entry.modified = "new-date" end
    bridge:open(s.entry, s.callbacks); s:run(1)
    expect(s.extracted == 1 and s.local_extracted == 0,
        "changed " .. changed .. " must bypass the old complete document cache")
    local retained = io.open(source, "rb")
    expect(retained ~= nil, "version mismatch must not delete the complete source file"); retained:close()
end

local versions, vs, vc = fixture()
versions:open(vs.entry, vs.callbacks); vs:run(1)
local first_key = vc:key_for("nas-u", "/Books/comic.cbz#zip/1")
local first_path = assert(vs.records[first_key].path)
expect(exists(first_path), "first archive page must exist before version invalidation")
local other = temp(); write(other, "another book")
vs.records.unrelated = { path = other, remote_path = "/Books/other.cbz#zip/1", kind = "page", modified = "old" }
versions:open(vs.entry, vs.callbacks); vs:run(2)
expect(#vs.removed == 0, "matching source version must retain generated pages")
first_path = assert(vs.records[first_key].path)
expect(exists(first_path), "latest archive page must exist before source version changes")
vs.entry.etag = "v2"; versions:open(vs.entry, vs.callbacks); vs:run(3)
expect(#vs.removed == 1 and vs.removed[1] == first_key and vs.records.unrelated
    and not exists(first_path),
    "changed archive version must invalidate only that book's generated pages")
local removed_page_key = vc:key_for("nas-u", "/Books/comic.cbz#zip/99")
vs.records[removed_page_key] = { kind = "page", remote_path = "/Books/comic.cbz#zip/99", path = temp(), modified = "old" }
versions:open(vs.entry, vs.callbacks); vs:run(4)
expect(vs.records[removed_page_key] == nil,
    "a page removed from the new ZIP directory must also lose its stale cache entry")
for _, changed in ipairs({ "size", "etag", "modified" }) do
    local bridge, s, cache = fixture()
    bridge:open(s.entry, s.callbacks); s:run(1)
    local cover_key = cache:key_for("nas-u", "/Books/comic.cbz#zip/1", "cover")
    local foreign_key = cache:key_for("other-nas", "/Books/comic.cbz#zip/1")
    s.records[cover_key] = { kind = "cover", remote_path = "/Books/comic.cbz#zip/1", path = temp(), modified = "old" }
    s.records[foreign_key] = { kind = "page", remote_path = "/Books/comic.cbz#zip/1", path = temp(), modified = "old" }
    if changed == "size" then s.entry.size = 201
    elseif changed == "etag" then s.entry.etag = "v2" else s.entry.modified = "new-date" end
    bridge:open(s.entry, s.callbacks); s:run(2)
    expect(#s.removed == 2 and not s.records[cover_key] and s.records[foreign_key],
        "changed " .. changed .. " must expire this book's page/cover but retain another connection's cache")
end

local failed, ps = fixture{ publish_error = true }
failed:open(ps.entry, ps.callbacks); ps:run(1)
expect(ps.opened == 0 and #ps.tasks == 1 and not ps.retry,
    "page publish failure must report storage failure without downloading")
expect(ps.native == 0 and ps.downloads == 0 and ps.error and ps.error.code == "storage",
    "storage failure must retain its classification")

for _, options in ipairs({
    { local_error = "zip_crc_mismatch" }, { local_error = "zip_image_invalid" },
    { local_error = "epub_not_image_book" }, { invalid_index = true }, { publish_error = true },
    { inspect_error = "zip_read_failed" }, { inspect_error = "epub_container_missing" },
}) do
    options.kind = "epub"
    local bridge, s = fixture(options)
    s.entry.local_path = temp(); write(s.entry.local_path, string.rep("x", 200))
    bridge:open(s.entry, s.callbacks); s:run(1)
    expect(s.opened == 0 and s.native == 0 and s.error and s.downloads == 0,
        "local EPUB operational failure must report an error without opening native reader: "
            .. tostring(options.local_error or options.inspect_error or (options.invalid_index and "invalid_index") or "publish_error"))
end
local bad_image_epub, bie = fixture{ kind = "epub", extract_error = true, local_error = true,
    allow_complete_fallback = true }
bad_image_epub:open(bie.entry, bie.callbacks); bie:run(1); bie:run(2)
bie.retry(); bie:run(3); bie:run(4)
expect(bie.downloads == 1 and bie.opened == 0 and bie.native == 1 and not bie.error,
    "confirmed complete EPUB must reach native reader when local plugin extraction still fails")
for _, code in ipairs({ "epub_not_image_book", "epub_drm", "zip_encrypted", "zip64_unsupported" }) do
    local bridge, s = fixture{ kind = "epub", inspect_error = code, allow_complete_fallback = true }
    bridge:open(s.entry, s.callbacks); s:run(1); s.retry(); s:run(2)
    expect(s.native == 0 and s.downloads == 1, "EPUB native fallback requires a completed local classification")
    s:run(3)
    expect(s.native == 1 and not s.error and s.opened == 0 and s.downloads == 1,
        "explicit unsupported EPUB classification should retain its one-download native fallback: " .. code)
end

for _, stop in ipairs({ "cancel", "cancel_all", "on_cancelled", "timeout" }) do
    local bridge, s = fixture{ kind = "epub", metadata_work = true, allow_complete_fallback = true }
    bridge:open(s.entry, s.callbacks)
    local task = s.tasks[1]
    local planned_path = s.manifest_part .. ".zipwork"
    files[#files + 1] = planned_path
    local result = task.work()
    expect(s.metadata_work_path == planned_path and exists(planned_path),
        "EPUB metadata work must use the task-owned path allocated before the worker")
    local unrelated = temp(); write(unrelated, "other task metadata")
    if stop == "cancel" then s.handle:cancel()
    elseif stop == "cancel_all" then bridge:cancel_all()
    elseif stop == "on_cancelled" then task.opts.on_cancelled()
    else task.done(false, nil, "async timeout") end
    expect(not exists(planned_path) and exists(unrelated) and s.opened == 0 and s.native == 0,
        stop .. " must remove only this task's known EPUB metadata work file")
    -- A child can finish a write after cancellation but before it is reaped.
    write(planned_path, "late child write"); task.opts.on_reaped()
    expect(not exists(planned_path), "reap must remove any late EPUB metadata work file")
    write(planned_path, "late result write"); task.done(true, result)
    expect(not exists(planned_path) and s.opened == 0 and s.native == 0,
        "late callbacks must clean EPUB metadata work without opening a reader")
    expect(#s.tasks == 1 and (stop ~= "timeout" or s.retry),
        "timeout may offer confirmation but neither timeout nor late results may download automatically")
end

local invalid, ms = fixture()
invalid:open(ms.entry, ms.callbacks); ms:run(1)
local manifest
for _, record in pairs(ms.records) do if record.kind == "manifest" then manifest = record end end
write(manifest.path, string.rep("x", 8 * 1024 * 1024 + 1))
invalid:open(ms.entry, ms.callbacks); ms:run(2)
expect(ms.inspections == 2 and ms.opened == 2, "oversized manifest must be ignored and rebuilt")
for _, record in pairs(ms.records) do if record.kind == "manifest" then manifest = record end end
write(manifest.path, 'error("cache text must never execute")')
invalid:open(ms.entry, ms.callbacks); ms:run(3)
expect(ms.inspections == 3 and ms.opened == 3, "malformed cache text must never execute")

local index = BookIndex.from_items({ image("/Books/a.cbz", 200, 2), image("/Books/a.cbz", 200) })
local value = assert(index:to_table())
value.items[1], value.items[2] = value.items[2], value.items[1]
expect(BookIndex.from_table(value):get(1).name == "002.jpg", "manifest decode must preserve EPUB spine order")
value.items[1].archive_size = 128 * 1024 * 1024 + 1
expect(BookIndex.from_table(value) == nil, "manifest must reject oversized pages")
value.items[1].archive_size = 3; value.items[1].archive_local_offset = -1
expect(BookIndex.from_table(value) == nil, "manifest must reject negative offsets")
value.items[1].archive_local_offset = 40; value.items[1].archive_method = 99
expect(BookIndex.from_table(value) == nil, "manifest must reject unsupported ZIP methods")
value.items[1].archive_method = 0; value.items[1].archive_crc32 = 0 / 0
expect(BookIndex.from_table(value) == nil, "manifest must reject non-finite numeric fields")
value.items[1].archive_crc32 = 0; value.items[1].unexpected = "data"
expect(BookIndex.from_table(value) == nil, "manifest must reject unknown fields")
value.items[1].unexpected = nil; value.count = 20001
expect(BookIndex.from_table(value) == nil, "manifest must reject more than 20000 pages")
value.count = 1
expect(BookIndex.from_table(value) == nil, "manifest must reject a mismatched page count")

local Progress = require("webdavmanga.progress")
local stored = {}
local progress = Progress:new{ store = {
    readSetting = function(_, key, default) return stored[key] or default end,
    saveSetting = function(_, key, v) stored[key] = v end,
}, md5 = function(v) return v end }
local page = image("/Books/comic.cbz", 200)
page.archive_local_path = ls.entry.local_path; page.etag = "v1"
progress:save("chapter", page.path, 1, "whole", {
    connection = ls.entry.connection, manga = ls.entry, chapter = ls.entry, total = 2,
    layout = "archive_images", cover_hint = { image = page },
})
local history = progress:list_history(ls.entry.connection)[1]
expect(history.cover_hint.image.archive_entry_name == "001.jpg"
    and history.cover_hint.image.archive_local_path == ls.entry.local_path and history.manga.etag == "v1",
    "history must preserve archive extraction fields and file version")
local resolved
require("webdavmanga.cover"):new{ library = {
    set_cover = function() return true end, get_cover = function() end,
}, directory_store = {} }:resolve(ls.entry.connection, history, {
    on_ready = function(v) resolved = v end,
})
expect(resolved and resolved.archive_entry_name == "001.jpg" and resolved.archive_source_size == 200,
    "archive history cover must pass cover validation with extraction metadata")

local shown
for _, module in ipairs({ "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/menu" }) do
    package.preload[module] = function() return { new = function(_, model) return model end } end
end
package.preload["ui/uimanager"] = function() return {
    show = function(_, widget) shown = widget end, close = function() end, setDirty = function() end,
} end
package.preload["ui/widget/buttondialog"] = function() return { new = function(_, model)
    function model:setTitle(title) self.title = title end
    return model
end } end
package.preload["ui/widget/progresswidget"] = function() return { new = function(_, model)
    function model:setPercentage(value) self.percentage = value end
    return model
end } end
package.preload.device = function() return { screen = {
    getWidth = function() return 1000 end, getHeight = function() return 1400 end,
    scaleBySize = function(_, value) return value end,
} } end
local Browser = require("webdavmanga.ui_browser")
local browser = Browser:new{ settings = { get_connection = function() return ls.entry.connection end },
    settings_ui = {}, directory_store = {}, open_reader = function() end }
local indicator = browser.ui:show_progress{ title = "正在打开漫画书籍", subtitle = "comic.cbz" }
for _, stage in ipairs({ { "index", "正在建立页面目录" }, { "first_page", "正在验证第一页" },
    { "fallback", "正在切换为完整下载" } }) do
    indicator:update{ stage = stage[1], progress = 0.5 }
    expect(shown.title:find(stage[2], 1, true) and shown.title:find("comic.cbz", 1, true),
        "opening progress must display " .. stage[1] .. " with the book name")
end
local grid_model, reopened, returned
browser.cover_grid = { show = function(_, model) grid_model = model end,
    leave_for = function(_, callback) return callback() end }
browser.progress = { list_history = function() return { history } end }
browser.open_document = function(entry, callbacks) reopened = entry; returned = callbacks.on_closed; return true end
browser:show_history(); grid_model.items[1].on_open()
expect(reopened and reopened.path == "/Books/comic.cbz" and reopened.etag == "v1" and returned,
    "archive history must re-enter the cancellable document bridge with file version and return callback")
history.layout = "mupdf_pages"
history.manga.name = "comic.pdf"
history.manga.path = "/Books/comic.pdf"
reopened, returned = nil, nil
browser:show_history(); grid_model.items[1].on_open()
expect(reopened and reopened.path == "/Books/comic.pdf" and returned,
    "MuPDF history must re-enter the cancellable document bridge")
for _, path in ipairs(files) do os.remove(path) end
print(("rebuild_0374_archive_bridge_spec: %d checks"):format(checks))
