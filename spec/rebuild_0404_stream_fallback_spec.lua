local Bridge = require("webdavmanga.document_bridge")
local Browser = require("webdavmanga.ui_browser")
local BookIndex = require("webdavmanga.book_index")
local Errors = require("webdavmanga.errors")
local ArchivePages = require("webdavmanga.archive_pages")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local JPEG_BYTES = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
    0, 1, 0, 1, 1, 1, 0x11, 0, 0xFF, 0xD9)
-- The archive integration gate selects the existing archive cases only. The
-- default remains the complete historical PDF/MOBI/archive release suite.
local archive_only = os.getenv("WEBDAVMANGA_ARCHIVE_GATE_ONLY") == "1"
local archive_formats = {zip=true,cbz=true,epub=true,cbt=true,cbr=true,rar=true,cb7=true,["7z"]=true}
local function scoped(list)
    if not archive_only then return list end
    local selected={}
    for _,case in ipairs(list) do
        if archive_formats[type(case)=="table" and case[1] or case] then selected[#selected+1]=case end
    end
    return selected
end
local secrets = { "unique-user", "unique-password", "/private-shelf/", "secret-title",
    "token=secret-query", "https://private-host", "native-exception-secret" }
local function absent(path) local f = io.open(path, "rb"); if f then f:close(); return false end; return true end
local function fixture(format, reason, options)
    options = options or {}
    local s = { tasks = {}, paths = {}, logs = {}, downloads = 0, opened = 0, prompts = 0, native = 0 }
    local entry = { name = "secret-title." .. format,
        path = "/private-shelf/secret-title." .. format, size = options.bytes and #options.bytes or 128, file_kind = "document",
        connection = { username = secrets[1], password = secrets[2],
            server_url = "https://private-host?token=secret-query" } }
    s.entry = entry
    -- This matrix exercises the MuPDF fallback channel. Image-PDF priority and
    -- its handoff are covered by rebuild_0386_pdf_image_bridge_spec.
    if format == "pdf" then entry._skip_pdf_image_stream = true end
    if options.no_size then entry.size = nil end
    local records = {}
    local cache = {
        key_for = function(_, identity, path) return identity .. path end,
        lookup_record = function(_, key)
            local record = records[key]
            return record and record.path, record
        end,
        paths_for = function(_, key, ext, token)
            local path = os.tmpname(); os.remove(path); s.paths[#s.paths + 1] = path
            return path .. ".final", path
        end,
        clear_matching_cache = function() end,
        publish = function(_, record, path)
            if options.storage then return nil, "cache_limit" end
            if record.kind == "document" then s.document = true end
            if record.kind == "document" then
                local final = path .. ".final"
                assert(os.rename(path, final)); s.paths[#s.paths + 1] = final
                return final
            end
            if (format == "epub" or format == "7z" or format == "cb7"
                or format == "rar" or format == "cbr") and record.kind == "page" then
                local final = path .. ".final"
                assert(os.rename(path, final)); s.paths[#s.paths + 1] = final
                record.path = final; records[record.key] = record
                return final
            end
            os.remove(path); return path .. ".final"
        end,
        remove = function(_, key)
            local record = records[key]
            if record then os.remove(record.path); records[key] = nil end
            return true
        end,
        discard_part = function() end,
    }
    local function inspect(_, descriptor, kind, remote_path, scan_options)
        if options.partial then
            local target = type(remote_path) == "table" and remote_path.path or remote_path
            local file = assert(io.open(target, "wb")); file:write("partial first page"); file:close()
        end
        if options.range then
            local data, err = descriptor.read_at(0, 8)
            descriptor.read_at(8, 8)
            if not data then return nil, err end
        end
        if reason then return nil, reason end
        if options.invalid_index then return { index = BookIndex.from_items({}) } end
        local path = entry.path
        local page = { name = "001.jpg", is_file = true,
            archive_remote_path = path, archive_source_size = 128,
            archive_entry_name = "001.jpg", archive_size = 8,
            archive_version = "128:0::", etag = "" }
        if format == "cbt" then
            page.path, page.archive_kind = path .. "#tar/1", "tar"
            page.archive_entry_offset, page.archive_method = 0, 0
        elseif format == "cbz" or format == "zip" or format == "epub" then
            page.path, page.archive_kind = path .. "#zip/1", "zip"
            page.archive_local_offset, page.archive_method, page.archive_flags = 0, 0, 0
            page.archive_crc32, page.archive_compressed_size = 0, 8
        else
            page.path, page.archive_kind = path .. "#archive/1", "libarchive"
            page.archive_format, page.archive_entry_ordinal = format, 1
        end
        if format == "mobi" or format == "azw" or format == "azw3" or format == "pdf" or options.mupdf then
            page = { name = "001.jpg", path = path .. "#page/1", is_file = true }
        end
        local opening_metadata
        if scan_options and scan_options.opening_targets then
            if options.extract_error then return nil, options.extract_error end
            local file = assert(io.open(scan_options.opening_targets[1], "wb"))
            file:write(JPEG_BYTES); file:close()
            page.archive_size = #JPEG_BYTES
            opening_metadata = {{size=#JPEG_BYTES,width=1,height=1,format="jpeg"}}
        end
        return { index = BookIndex.from_items({ page }), opening_metadata = opening_metadata,
            total_pages = 1, incomplete = false,
            first_metadata = { size = 8, width = 2, height = 2, format = "jpeg" } }
    end
    local bridge = Bridge:new{
        cache = cache, identity = "identity-secret", logger = { warn = function(...)
            local values = {}; for i = 1, select("#", ...) do values[i] = tostring(select(i, ...)) end
            s.logs[#s.logs + 1] = table.concat(values, " ")
        end },
        client_factory = function() return {
            read_range = not options.no_range and function(_, path, first, last)
                if options.client_error then return nil, options.client_error end
                if options.range_error then return nil, nil, options.range_error end
                return options.bytes and options.bytes:sub(first + 1, last + 1) or string.rep("x", last - first + 1),
                    { ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, entry.size) }
            end,
            download_document = function(_, path, target)
                s.downloads = s.downloads + 1
                local bytes = options.bytes or "document"
                local f = assert(io.open(target, "wb")); f:write(bytes); f:close()
                return { size = #bytes }
            end,
        } end,
        async = { run = function(work, done, options)
            local task = { work = work, done = done, options = options }
            s.tasks[#s.tasks + 1] = task
            if s.cancel_in_run then s.handle:cancel() end
            return { cancel = function() task.canceled = true end }
        end },
        mobi_pages = { inspect_remote = inspect, index_from_items = function(_, items) return BookIndex.from_items(items) end,
            inspect_lazy = function() return nil end },
        archive_pages = options.archive_pages or { can_stream = function() return options.no_codec ~= true end,
            inspect_remote = inspect, extract_remote = function(_, page, read_at, path)
                local image = format == "epub" and JPEG_BYTES or "image"
                local f = assert(io.open(path, "wb")); f:write(image); f:close()
                if options.extract_error then return nil, options.extract_error end
                return { size = #image, width = format == "epub" and 1 or 2,
                    height = format == "epub" and 1 or 2, format = "jpeg" }
            end },
        file_size = function(path)
            local file = io.open(path, "rb")
            if not file then return 0 end
            local size = file:seek("end"); file:close(); return size
        end,
        mupdf_pages = { remote_capability = function()
            return not options.no_capability and (format == "pdf" or options.mupdf == true)
        end,
            inspect_remote = function(self, descriptor, path, first_page)
                return inspect(self, descriptor, path, first_page)
            end, inspect_local = function() return nil end },
        open_reader = function(context) s.opened = s.opened + 1; s.layout = context.layout; return true end,
        ui_manager = { showReader = function(_, path)
            local file = assert(io.open(path, "rb")); s.native_bytes = file:read("*a"); file:close()
            s.native = s.native + 1; return true
        end },
    }
    local callbacks = { on_error = function(err) s.error = err end,
        on_open_handle = function(handle) s.handle = handle end,
        on_document_fallback_prompt = function(kind, err, retry, structured_error)
            s.prompts = s.prompts + 1; s.format, s.reason, s.retry = kind, err, retry
            s.stream_error = structured_error; return true
        end }
    if options.no_callback then callbacks.on_document_fallback_prompt = nil end
    if options.legacy_pdf then
        callbacks.on_document_fallback_prompt = nil
        callbacks.on_pdf_fallback_prompt = function(err, retry) s.reason, s.retry = err, retry; return true end
    end
    function s:run(i)
        local t = assert(self.tasks[i]); local ok, result = pcall(t.work)
        t.done(ok, result, ok and nil or result); self.completed = i; return t, result
    end
    function s:drain(first)
        local i = first or 1
        while i <= #self.tasks do self:run(i); i = i + 1 end
    end
    function s:cleanup() for _, path in ipairs(self.paths) do os.remove(path) end end
    if options.local_file then
        entry.local_path = os.tmpname(); s.paths[#s.paths + 1] = entry.local_path
        local file = assert(io.open(entry.local_path, "wb")); file:write(options.bytes or "document"); file:close()
    end
    s.callbacks = callbacks
    if not options.defer_open then bridge:open(entry, callbacks) end
    return s, bridge
end

-- A refused adapter must never turn a click-to-open into an unconfirmed download.
-- These literal cases enter the real Bridge before any inspection task exists.
local preflight_cases = {
    { "pdf", "no_capability" }, { "pdf", "no_size" },
    { "mobi", "no_size" }, { "mobi", "no_range" },
}
if not archive_only then
    local failures = {}
    for _, case in ipairs(preflight_cases) do
        local options = { [case[2]] = true }
        local s = fixture(case[1], nil, options)
        local ok, err = pcall(function()
            s:drain()
            expect(s.prompts == 1 and s.downloads == 0 and #s.tasks == 0,
                case[1] .. ":" .. case[2] .. " must wait for confirmation; prompts=" .. s.prompts
                    .. " downloads=" .. s.downloads .. " tasks=" .. #s.tasks)
            expect(s.retry and s.handle and s.native == 0 and s.opened == 0,
                "preflight refusal must provide a cancellable confirmation, not open a reader")
            s.retry(); s.retry(); s:drain()
            expect(s.prompts == 1 and s.downloads == 1 and s.native == 1,
                "confirmed retry downloads once without another prompt")
            local last = s.tasks[#s.tasks]
            last.done(true, { error = "late preflight callback" })
            last.done(true, { size = 8 })
            expect(s.prompts == 1 and s.downloads == 1 and s.native == 1 and s.error == nil,
                "late completion cannot repeat download, native open or report an error after success")
            for _, secret in ipairs(secrets) do
                expect(not table.concat(s.logs):find(secret, 1, true), "preflight diagnostics redact inputs")
            end
        end)
        s:cleanup()
        if not ok then failures[#failures + 1] = tostring(err) end
        local direct_options = { [case[2]] = true, local_file = true }
        local direct = fixture(case[1], nil, direct_options)
        direct:drain()
        expect(direct.native == 1 and direct.prompts == 0 and direct.downloads == 0,
            "already local PDF/MOBI must never ask to download")
        direct:cleanup()
    end
    expect(#failures == 0, table.concat(failures, "\n"))
end

-- Real ZIP directory parsing / ArchivePages classification, with only the installed
-- native codec boundary failing. No decoder reads the unsupported-method payload.
local function le(value, count)
    local bytes = {}
    for i = 1, count do bytes[i] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function unsupported_zip(name)
    local common = le(0, 2) .. le(12, 2) .. le(0, 4) .. le(0, 4)
        .. le(1, 4) .. le(1, 4) .. le(#name, 2) .. le(0, 2)
    local header = "PK\003\004" .. le(46, 2) .. common .. name .. "x"
    local directory = "PK\001\002" .. le(46, 2) .. le(46, 2) .. common
        .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4) .. le(0, 4) .. name
    return header .. directory .. "PK\005\006" .. le(0, 4) .. le(1, 2) .. le(1, 2)
        .. le(#directory, 4) .. le(#header, 4) .. le(0, 2)
end
local completed_cases = {
    { "zip", "zip_unsupported_method", unsupported_zip("001.jpg") },
    { "epub", "zip_unsupported_method", unsupported_zip("META-INF/container.xml") },
    { "cbr", "libarchive_open_failed", "Rar!\026\007\000" .. string.rep("\0", 25) },
    { "cb7", "archive_header_failed", "7z\188\175\039\028" .. string.rep("\0", 26) },
    { "7z", "archive_header_failed", "7z\188\175\039\028" .. string.rep("\0", 26) },
}
for _, case in ipairs(completed_cases) do
    local function adapter()
        return ArchivePages:new{ archive_stream = {
            available = function() return true end,
            open = function()
                if case[2] == "archive_header_failed" then return {} end
                return nil, "libarchive_open_failed"
            end,
            next = function() return nil, "archive_header_failed" end,
            close = function() end,
        } }
    end
    local s = fixture(case[1], nil, { bytes = case[3], archive_pages = adapter() })
    s:run(1)
    expect(s.reason == case[2] and #s.tasks == 1 and s.downloads == 0 and s.native == 0,
        "real archive failure must wait for confirmation: " .. case[1])
    s.retry(); s.retry()
    s:drain(2)
    expect(s.completed == 3 and #s.tasks == 3, "confirmed archive must finish third local parsing task")
    expect(s.downloads == 1 and s.native == 1 and s.native_bytes == case[3]
        and s.prompts == 1 and s.opened == 0 and not s.error,
        "confirmed full archive must reach native reader after local adapter failure: " .. case[1])
    s.tasks[3].done(true, { error = case[2] })
    expect(s.native == 1 and s.downloads == 1 and s.prompts == 1,
        "late local failure callback must not repeat native open or download")
    s:cleanup()
    local direct = fixture(case[1], nil, { bytes = case[3], archive_pages = adapter(), local_file = true })
    direct:drain()
    expect(direct.native == 0 and direct.downloads == 0 and direct.prompts == 0 and direct.error,
        "unconfirmed direct local archive failure must retain its original error: " .. case[1])
    direct:cleanup()
end

-- Breaks: auto retry, missing format routes, duplicate callback/download, leaked paths.
local cases = { { "mobi", "not_mobi" }, { "azw", "encrypted_mobi" }, { "azw3", "not_mobi" },
    { "epub", "epub_not_image_book" }, { "cbz", "zip_unsupported_method" },
    { "zip", "zip_unsupported_method" }, { "cbt", "tar_header_invalid" },
    { "cbr", "libarchive_unavailable" }, { "rar", "libarchive_unavailable" },
    { "cb7", "libarchive_unavailable" }, { "7z", "libarchive_unavailable" }, { "pdf", "pdf_multiple_images" } }
for _, case in ipairs(scoped(cases)) do
    local s = fixture(case[1], case[2]); local task, result = s:run(1)
    expect(s.retry and s.format == case[1] and s.reason == case[2] and #s.tasks == 1 and s.downloads == 0,
        case[1] .. " failure must wait for explicit complete-download confirmation")
    for _, path in ipairs(s.paths) do expect(absent(path), "cancel must leave no document or part") end
    task.done(true, result)
    expect(s.prompts == 1, "duplicate completion must not repeat prompt")
    local logs = table.concat(s.logs, "\n")
    for _, stage in ipairs({ "route", case[1] == "epub" and "epub_spine" or "index", "fallback" }) do
        expect(logs:find("WebDavManga stream: " .. stage .. " " .. case[1], 1, true), "diagnostic missing " .. stage)
    end
    expect(logs:find(case[2], 1, true), "diagnostic must retain stable reason")
    for _, secret in ipairs(secrets) do expect(not logs:find(secret, 1, true), "diagnostics must redact " .. secret) end
    s.retry(); s.retry()
    expect(#s.tasks == 2, "duplicate retry must schedule only one complete download")
    s:drain(2)
    expect(s.downloads == 1 and s.document, "confirmation must publish exactly one complete document")
    expect(s.completed == #s.tasks, "main format matrix must drain every scheduled local task")
    if case[1] ~= "pdf" then
        expect(s.native == 1 and not s.error and s.prompts == 1,
            "confirmed format matrix must finish in native reader after parser rejection")
    end
    expect(not s.entry._skip_archive_stream and not s.entry._skip_mobi_stream,
        "retry must not mutate original entry")
    s:cleanup()
end

for _, format in ipairs(scoped({ "mobi", "azw3", "epub", "cbr", "cb7", "7z", "pdf" })) do
    local s = fixture(format, "range_unavailable", { no_callback = true }); s:run(1)
    expect(s.error and s.error.stage == "stream" and #s.tasks == 1 and s.downloads == 0,
        "missing prompt callback must fail visibly without downloading: " .. format); s:cleanup()
end
for _, format in ipairs({ "cbr", "rar", "cb7", "7z" }) do
    local s = fixture(format, "libarchive_unavailable", { no_codec = true }); s:run(1)
    expect(s.reason == "libarchive_unavailable" and s.downloads == 0,
        "missing codec must still reach archive confirmation: " .. format); s:cleanup()
end
for _, format in ipairs({ "rar", "7z", "cb7" }) do
    local s, bridge = fixture(format, nil, { archive_pages = ArchivePages:new{
        archive_stream = { available = function() return false end,
            open = function() return nil, "libarchive_unavailable" end } } })
    s:run(1)
    expect(s.retry and s.downloads == 0 and s.native == 0, "missing codec must await confirmation before native open")
    s.retry()
    local index = 2
    while index <= #s.tasks do s:run(index); index = index + 1 end
    expect(s.downloads == 1 and s.native == 1 and s.native_bytes == "document" and not s.error,
        "complete archive without plugin codec must reach native reader: " .. format)
    expect(s.prompts == 1 and s.opened == 0, "local fallback must not prompt or pretend to open plugin pages")
    s:cleanup()
    local direct = fixture(format, nil, { archive_pages = bridge.archive_pages, local_file = true })
    expect(direct.native == 1 and #direct.tasks == 0 and not direct.error and direct.downloads == 0,
        "direct local archive without codec must retain immediate native routing")
    direct:cleanup()
end
for _, format in ipairs({ "cbr", "cb7" }) do
    local s, bridge = fixture(format, nil, { mupdf = true, archive_pages = ArchivePages:new{
        archive_stream = { available = function() return false end,
            open = function() return nil, "libarchive_unavailable" end } } })
    local capability = bridge:stream_capability(s.entry)
    expect(not capability.supported and capability.reason == "libarchive_unavailable",
        "available MuPDF must not hide missing archive callback capability")
    s:run(1)
    expect(s.opened == 0 and s.prompts == 1 and s.reason == "libarchive_unavailable"
        and s.downloads == 0 and not s.error,
        "missing archive callback must await explicit confirmation even with MuPDF: " .. format)
    expect(table.concat(s.logs):find("route " .. format .. " archive_pages", 1, true)
        and not table.concat(s.logs):find("route " .. format .. " mupdf_pages", 1, true),
        "route diagnostics must retain the archive callback route")
    s.retry(); s.retry(); s:drain(2)
    expect(s.downloads == 1 and s.prompts == 1 and s.opened == 0 and s.native == 1,
        "explicit confirmation must download exactly once and preserve local native open")
    s:cleanup()
end
for _, mode in ipairs({ "handle", "all" }) do
    local s, bridge = fixture("epub", "epub_not_image_book"); s:run(1)
    if mode == "handle" then s.handle:cancel() else bridge:cancel_all() end
    s.retry()
    expect(#s.tasks == 1 and s.downloads == 0, "canceled prompt must invalidate its retry: " .. mode)
    s:cleanup()
end
for _, format in ipairs(scoped({ "mobi", "pdf", "epub" })) do
    local s = fixture(format, "range_unavailable")
    s.tasks[1].done(false, nil, "async timeout")
    s.tasks[1].options.on_reaped()
    s.retry()
    expect(#s.tasks == 2, "reaped timeout must leave explicit confirmation usable: " .. format)
    s:cleanup()
end
for _, format in ipairs({ "cbr", "rar", "cb7", "7z" }) do
    local s, bridge = fixture(format, nil, { archive_pages = ArchivePages:new{
        archive_stream = { available = function() return false end,
            open = function() return nil, "libarchive_unavailable" end } } })
    expect(not bridge:stream_capability(s.entry).supported, "unavailable codec must not be advertised as supported")
    s:run(1)
    expect(s.reason == "libarchive_unavailable" and #s.tasks == 1,
        "real ArchivePages must retain missing-codec classification"); s:cleanup()
end
if not archive_only then
for _, options in ipairs({ { mupdf = true }, { legacy_pdf = true } }) do
    local s = fixture("pdf", "range_unavailable", options); s:run(1)
    expect(s.retry and #s.tasks == 1, "both PDF engines and compatibility callback require confirmation")
    local adapter = "mupdf_pages"
    expect(table.concat(s.logs):find("route pdf " .. adapter, 1, true)
        and table.concat(s.logs):find("fallback pdf " .. adapter, 1, true),
        "PDF diagnostics must name the actual selected adapter")
    s.retry(); expect(#s.tasks == 2, "PDF confirmation must bypass every stream engine"); s:cleanup()
end
for _, mupdf in ipairs({ false, true }) do
    local s = fixture("pdf", "pdf_first_page_invalid", { mupdf = mupdf, partial = true }); s:run(1)
    for _, path in ipairs(s.paths) do expect(absent(path), "failed PDF must remove owned first-page part before prompt") end
    s:cleanup()
end
local invalid = fixture("pdf", nil, { mupdf = true, invalid_index = true }); invalid:run(1)
expect(invalid.retry and invalid.reason == "invalid_mupdf_index" and #invalid.tasks == 1,
    "invalid MuPDF index must use the same explicit fallback contract")
invalid:cleanup()
end

for _, format in ipairs(scoped({ "mobi", "pdf", "epub", "cbz", "cbt", "cbr", "cb7", "7z" })) do
    local s = fixture(format, nil, { range = true }); s:run(1)
    if format == "epub" then s:run(2) end
    expect(s.opened == 1 and s.prompts == 0 and s.downloads == 0, "successful first page must stream: " .. format)
    local logs = table.concat(s.logs, "\n")
    expect(logs:find("first_page " .. format, 1, true), "first-page result must be diagnosed")
    expect(not logs:find("stream: range", 1, true), "successful Range must not log per read"); s:cleanup()
end
local s = fixture("epub", nil, { range = true, range_error = "content_range_missing" }); s:run(1)
local logs = table.concat(s.logs, "\n")
local _, count = logs:gsub("stream: range ", "")
expect(count == 1 and logs:find("offset=0", 1, true) and logs:find("count=8", 1, true)
    and logs:find("content_range_missing", 1, true), "failed Range logs numeric bounds once per attempt")
s:cleanup()
if not archive_only then
local blocked = fixture("mobi", nil, { range = true, range_error = "content_range_missing" }); blocked:run(1)
expect(table.concat(blocked.logs):find("count=128", 1, true),
    "blocked Range diagnostics must record the actual HTTP block size")
blocked:cleanup()
end
local network = fixture("epub", nil, { range = true, client_error = Errors.transport("unique-password") })
network:run(1)
expect(not network.error and network.reason == "transport" and network.prompts == 1
    and network.retry and network.downloads == 0
    and table.concat(network.logs):find("range_probe epub archive_pages transport", 1, true),
    "real Client two-value failure must retain its stream stage and await confirmation")
network:cleanup()
for _, err in ipairs({ Errors.storage("native-exception-secret"), Errors.transport("unique-password"),
    "native-exception-secret /private-shelf/secret-title?token=secret-query" }) do
    local f = fixture("epub", err); f:run(1)
    local text = table.concat(f.logs, "\n")
    for _, secret in ipairs(secrets) do expect(not text:find(secret, 1, true), "raw failure must be sanitized") end
    if type(err) == "table" and err.code == "transport" then
        expect(not f.error and f.reason == "transport" and f.prompts == 1 and f.retry and f.downloads == 0
            and text:find("range_probe epub archive_pages transport", 1, true),
            "EPUB transport failure must retain its stage and await confirmation")
    elseif type(err) == "table" then expect(f.error and f.error.code == err.code and not f.retry,
        "operational error must retain classification without download prompt") end
    f:cleanup()
end
local f = fixture("cbz", nil, { storage = true }); f:run(1)
expect(f.error and f.error.code == "storage" and not f.retry and f.downloads == 0,
    "cache publishing failure must remain storage error"); f:cleanup()

-- Exercise real Browser dialog wiring (UI is the external boundary).
for _, format in ipairs(scoped({ "azw3", "epub", "pdf", "cbr" })) do
    local prompt, closed, retries, error_value, progress_count, progress_model, canceled = nil, 0, 0, nil, 0, nil, 0
    local ui = { show_progress = function(_, model) progress_count = progress_count + 1; progress_model = model
            return { close = function() closed = closed + 1 end } end,
        show_info = function() end, confirm = function(_, model) prompt = model; return true end }
    local browser = Browser:new{ settings = { get_connection = function() return { root_path = "/" } end },
        settings_ui = {}, directory_store = {}, ui = ui,
        open_reader = function() end,
        open_document = function(entry, cb)
            expect(type(cb.on_document_fallback_prompt) == "function", "Browser must provide generic fallback callback")
            return cb.on_document_fallback_prompt(format, "range_unavailable", function()
                retries = retries + 1
                cb.on_open_handle({ cancel = function() canceled = canceled + 1 end })
            end)
        end }
    browser:_open_document_with_progress({ name = "book." .. format }, { on_error = function(e) error_value = e end })
    expect(prompt and prompt.text:find(format:upper(), 1, true) and prompt.text:find("Range", 1, true)
        and closed == 1 and retries == 0, "Browser must show format and reason after closing opening progress")
    prompt.on_cancel(); prompt.on_confirm()
    expect(retries == 0, "canceled confirmation must not become a later download")
    browser:_open_document_with_progress({ name = "book." .. format }, {})
    prompt.on_confirm(); prompt.on_confirm()
    expect(retries == 1, "Browser confirm must dispatch retry only once")
    expect(progress_count == 3, "confirmed download must have its own cancellable progress")
    progress_model.on_cancel()
    expect(canceled == 1, "download progress cancel must reach the replacement request handle")
    ui.confirm = nil
    browser:_open_document_with_progress({ name = "book." .. format }, { on_error = function(e) error_value = e end })
    expect(retries == 1 and error_value, "missing confirmation UI must fail visibly, never retry")
end

expect(Errors.message(Errors.document("stream", "cbr:libarchive_open_failed")):find("设备", 1, true),
    "native archive open/codec failure must explain device capability")
expect(Errors.message(Errors.document("stream", "pdf:range_unavailable")):find("Range", 1, true),
    "PDF network failure must not be relabeled as PDF complexity")

-- Use the production default UI adapter; replace only KOReader widget/device edges.
do
    local shown, prompt = {}, nil
    local function widget(kind)
        return { new = function(_, model)
            model.widget_kind = kind
            if kind == "confirm" then model.cancel_callback = model.cancel_callback or function() end end
            return model
        end }
    end
    local modules = {
        ["ui/widget/confirmbox"] = widget("confirm"),
        ["ui/widget/infomessage"] = widget("info"),
        ["ui/widget/menu"] = widget("menu"),
        ["ui/widget/buttondialog"] = widget("progress"),
        ["ui/widget/progresswidget"] = widget("bar"),
        ["ui/uimanager"] = { show = function(_, model)
            shown[#shown + 1] = model
            if model.widget_kind == "confirm" then prompt = model end
        end, close = function() end },
        device = { screen = { getWidth = function() return 600 end,
            getHeight = function() return 800 end, scaleBySize = function(_, n) return n end } },
    }
    local previous = {}
    for name, module in pairs(modules) do previous[name] = package.loaded[name]; package.loaded[name] = module end
    for _, dismissal in ipairs({ "cancel", "back", "outside" }) do
        local retries, canceled, notified = 0, 0, 0
        local browser = Browser:new{
            settings = { get_connection = function() return { root_path = "/" } end },
            settings_ui = {}, directory_store = {}, open_reader = function() end,
            open_document = function(_, cb)
                cb.on_open_handle({ cancel = function() canceled = canceled + 1 end })
                return cb.on_document_fallback_prompt("cbr", "libarchive_unavailable", function()
                    retries = retries + 1
                end)
            end,
        }
        browser:_open_document_with_progress({ name = "book.cbr" }, {
            on_cancel = function() notified = notified + 1 end,
        })
        expect(prompt and prompt.text:find("CBR", 1, true) and retries == 0,
            "default adapter must present the real Browser fallback dialog")
        -- ConfirmBox sends cancel button, back and outside dismissal to this callback.
        prompt.cancel_callback()
        prompt.ok_callback()
        expect(canceled == 1 and notified == 1 and retries == 0,
            "default ConfirmBox dismissal must cancel and invalidate late confirm: " .. dismissal)
        prompt.cancel_callback()
        expect(canceled == 1 and notified == 1, "default dialog cancellation must be terminal")
    end
    if not archive_only then
        for _, case in ipairs(preflight_cases) do
            for _, dismissal in ipairs({ "cancel", "back", "outside", "close" }) do
                local s, bridge = fixture(case[1], nil, { [case[2]] = true, defer_open = true })
                local late_retry
                local browser = Browser:new{
                    settings = { get_connection = function() return {} end },
                    settings_ui = {}, directory_store = {}, open_reader = function() end,
                    open_document = function(entry, cb)
                        local prompt_callback = cb.on_document_fallback_prompt
                        cb.on_document_fallback_prompt = function(format, reason, retry)
                            late_retry = retry
                            return prompt_callback(format, reason, retry)
                        end
                        return bridge:open(entry, cb)
                    end,
                }
                prompt = nil
                browser:_open_document_with_progress(s.entry, s.callbacks)
                expect(prompt and late_retry and s.downloads == 0 and #s.tasks == 0,
                    "real Browser/Bridge preflight must show confirmation before work")
                for _, secret in ipairs(secrets) do
                    expect(not prompt.text:find(secret, 1, true), "preflight dialog redacts inputs")
                end
                if dismissal == "close" then bridge:cancel_all() else prompt.cancel_callback() end
                prompt.ok_callback(); late_retry(); late_retry(); s:drain()
                expect(s.downloads == 0 and #s.tasks == 0 and s.native == 0 and s.opened == 0,
                    case[1] .. ":" .. case[2] .. " late retry after " .. dismissal .. " must remain inert")
                for _, path in ipairs(s.paths) do expect(absent(path), "dismissal leaves no owned file") end
                s:cleanup()
            end
        end
    end
    for name in pairs(modules) do package.loaded[name] = previous[name] end
end

-- Native exception text must never reach archive logs even before Bridge handles it.
local native_logs = {}
local pages = ArchivePages:new{ logger = { warn = function(...) local t = {...}; native_logs[#native_logs + 1] = table.concat(t, " ") end },
    archiver = { Reader = { new = function() error("native-exception-secret /private-shelf/") end } } }
local work = os.tmpname()
pages:_open_deflated({ name = "secret-title", flags = 0, method = 8, crc32 = 0, compressed_size = 1, size = 1 },
    function() return "x" end, 0, work)
os.remove(work)
expect(not table.concat(native_logs):find("native-exception-secret", 1, true), "archive native exceptions must be redacted")
-- Task 4 boundaries: a lost stage, operational network-table passthrough, or
-- missing cancellation guard must be visible at the actual Browser boundary.
local regressions = {}
local function regression(name, run)
    local ok, err = pcall(run)
    if not ok then regressions[#regressions + 1] = name .. ": " .. tostring(err) end
end
for _, case in ipairs(scoped({
    { "pdf", "content_range_mismatch" },
    { "pdf", "pdf_xref_invalid" },
    { "epub", "zip_directory_invalid" },
    { "epub", "epub_container_missing" },
    { "epub", "epub_not_image_book" },
})) do
    local state = fixture(case[1], case[2], {})
    state:run(1)
    expect(state.prompts == 1 and state.reason == case[2]
        and state.downloads == 0 and state.native == 0,
        case[1] .. ":" .. case[2] .. " must wait for one confirmation")
    expect(type(state.retry) == "function", "fallback must expose one retry closure")
    state.retry(); state.retry(); state:drain(2)
    expect(state.downloads == 1 and state.prompts == 1, "confirmed retry must download once")
    state:cleanup()
end
for _, format in ipairs(scoped({ "pdf", "epub" })) do
    local state = fixture(format, nil, { range = true, client_error = Errors.transport("private-host") })
    state:run(1)
    regression(format .. " transport", function()
        expect(state.prompts == 1 and state.reason == "transport" and not state.error
            and state.downloads == 0 and state.native == 0, "network error must await one sanitized confirmation")
        expect(state.stream_error and state.stream_error.stream_stage == "range_probe"
            and state.stream_error.detail == format .. ":transport", "network prompt must retain sanitized range_probe error")
        expect(not table.concat(state.logs):find("private-host", 1, true)
            and not Errors.message(state.stream_error):find("private-host", 1, true), "network detail must not leak")
        state.retry(); state.retry(); state:drain(2)
        expect(state.downloads == 1 and state.prompts == 1, "network retry must download exactly once")
    end)
    state:cleanup()
end
if not archive_only then
    for _, phase in ipairs({ "preflight", "fallback_progress" }) do
        local s, bridge = fixture("pdf", "pdf_xref_invalid", { defer_open = true, no_capability = phase == "preflight" })
        s.callbacks.on_open_handle = function(handle)
            s.handle = handle
            if phase == "preflight" then handle:cancel() end
        end
        s.callbacks.on_open_progress = function(event)
            if phase == "fallback_progress" and event.stage == "fallback" then s.handle:cancel() end
        end
        bridge:open(s.entry, s.callbacks); s:drain()
        regression(phase .. " cancel", function()
            expect(s.prompts == 0 and s.downloads == 0 and s.native == 0,
                "cancellation during fallback handoff must suppress prompt and download")
        end)
        s:cleanup()
    end
    for _, mode in ipairs({ "handle", "worker", "cancelled_event" }) do
        local s, bridge = fixture("pdf", "pdf_xref_invalid", { defer_open = true })
        s.cancel_in_run = mode == "worker"
        s.callbacks.on_open_handle = function(handle)
            s.handle = handle
            if mode == "handle" then handle:cancel() end
        end
        bridge:open(s.entry, s.callbacks)
        if mode == "cancelled_event" then s.tasks[1].options.on_cancelled() end
        regression("MuPDF synchronous " .. mode, function()
            if mode == "handle" then
                expect(#s.tasks == 0, "canceled handle delivery must not start MuPDF worker")
            elseif mode == "worker" then
                expect(#s.tasks == 1 and s.tasks[1].canceled, "cancellation during run must cancel returned MuPDF worker")
            end
            expect(next(bridge.pending_mupdf) == nil, "MuPDF cancellation must release pending ownership")
            s:drain()
            expect(s.prompts == 0 and s.downloads == 0 and s.native == 0, "late canceled MuPDF result must stay inert")
        end)
        s:cleanup()
    end
    do
        local s, bridge = fixture("pdf", nil, { defer_open = true, partial = true })
        local closed, opened_notifications = 0, 0
        s.callbacks.on_open_progress = function(event)
            if event.stage == "first_page" then s.handle:cancel() end
        end
        s.callbacks.close_plugin = function() closed = closed + 1 end
        s.callbacks.on_opened = function() opened_notifications = opened_notifications + 1 end
        bridge:open(s.entry, s.callbacks)
        local task, result = s:run(1)
        task.done(true, result)
        regression("MuPDF first-page progress cancel", function()
            expect(s.opened == 0 and closed == 0 and opened_notifications == 0 and not s.error,
                "MuPDF first-page progress cancellation must not close plugin, open Reader or notify opened")
            expect(next(bridge.pending_mupdf) == nil and s.prompts == 0 and s.downloads == 0,
                "canceled MuPDF must release ownership without prompt or download")
            for _, path in ipairs(s.paths) do expect(absent(path), "canceled MuPDF must remove its owned part") end
        end)
        s:cleanup()
    end
end
do
    local s, bridge = fixture("epub", nil, { extract_error = "zip_crc_mismatch", defer_open = true })
    local prompt, staged
    local browser = Browser:new{
        settings = { get_connection = function() return {} end }, settings_ui = {}, directory_store = {}, open_reader = function() end,
        ui = { show_progress = function() return { close = function() end } end,
            show_info = function() end, confirm = function(_, model) prompt = model; return true end },
        open_document = function(entry, cb)
            local show = cb.on_document_fallback_prompt
            cb.on_document_fallback_prompt = function(format, reason, retry, err)
                staged = err
                return show(format, reason, retry, err)
            end
            return bridge:open(entry, cb)
        end,
    }
    browser:_open_document_with_progress(s.entry, {}); s:run(1); s:run(2)
    regression("first-page UI", function()
        expect(staged and staged.stream_stage == "first_page" and staged.reason == "zip_crc_mismatch",
            "EPUB first-page CRC error must survive Bridge callback")
        expect(prompt and prompt.text:find("第一页", 1, true) and not prompt.text:find("ZIP 目录", 1, true),
            "actual Browser must retain first_page rather than re-infer zip_directory")
        expect(s.downloads == 0 and s.native == 0, "first-page failure must wait for UI confirmation")
        prompt.on_confirm(); prompt.on_confirm(); s:drain(3)
        expect(s.downloads == 1, "actual UI confirmation must download once")
    end)
    s:cleanup()
end
-- Caller-supplied tables cannot override a different reason/format or render
-- their detail; valid structured metadata is reconstructed into a fresh error.
for _, supplied in ipairs({
    { code = "document", stage = "stream", format = "epub", reason = "zip_crc_mismatch", stream_stage = "first_page", detail = "private-host" },
    { code = "document", stage = "stream", format = "pdf", reason = "zip_crc_mismatch", stream_stage = "first_page", detail = "private-host" },
    { code = "document", stage = "stream", format = "epub", reason = "epub_drm", stream_stage = "first_page", detail = "private-host" },
    { code = "document", stage = "stream", format = "epub", reason = "zip_crc_mismatch", stream_stage = "private-host", detail = "private-host" },
    { code = "transport", format = "epub", reason = "zip_crc_mismatch", stream_stage = "first_page", detail = "private-host" },
}) do
    local observed
    local browser = Browser:new{
        settings = { get_connection = function() return {} end }, settings_ui = {}, directory_store = {}, open_reader = function() end,
        ui = { show_progress = function() return { close = function() end } end, show_info = function() end },
        open_document = function(_, cb)
            return cb.on_document_fallback_prompt("epub", "zip_crc_mismatch", function() error("unconfirmed retry") end, supplied)
        end,
    }
    browser:_open_document_with_progress({ name = "book.epub" }, { on_error = function(err) observed = err end })
    regression("UI validation " .. supplied.code .. ":" .. supplied.stream_stage .. ":" .. supplied.reason .. ":" .. supplied.format, function()
        local valid = supplied.code == "document" and supplied.stage == "stream" and supplied.format == "epub"
            and supplied.reason == "zip_crc_mismatch" and supplied.stream_stage == "first_page"
        expect(observed and observed ~= supplied and observed.stream_stage == (valid and "first_page" or "zip_directory")
            and observed.reason == "zip_crc_mismatch" and observed.detail == "epub:zip_crc_mismatch",
            "Browser must validate matching structured metadata and rebuild a safe error")
        expect(not Errors.message(observed):find("private-host", 1, true), "supplied raw details cannot reach UI")
    end)
end
expect(#regressions == 0, table.concat(regressions, "\n"))
print(("rebuild_0404_stream_fallback_spec (%s): %d checks"):format(archive_only and "archive gate" or "all formats", checks))
