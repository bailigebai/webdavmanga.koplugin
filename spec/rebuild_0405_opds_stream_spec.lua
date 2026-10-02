local Pages = require("webdavmanga.opds_pages")
assert(type(Pages.virtual_index) == "function", "descriptor must expose virtual OPDS pages")
local desc = { source_id = "s", server_kind = "suwayomi", series_id = "series:/一",
    chapter_id = "chapter:/一", chapter_name = "同名", page_count = 27,
    stream_template = "https://server/page/{pageNumber}?w={width}&mw={maxWidth}&h={height}&mh={maxHeight}" }
local index = assert(Pages.virtual_index(desc, "identity"))
assert(index:count() == 27 and index:get(1).path == "identity#opds/1")
assert(index:get(27).path == "identity#opds/27" and index:get(28) == nil and index:get(0) == nil)
assert(type(index:get(1).image_url) == "function", "page URLs must be lazy")

local source = { id = "s", url = "https://server/opds", username = "user", password = "old-secret" }
local requests, pending, writes, freed = {}, {}, {}, 0
local mode = "ok"
local transport = { get_bytes = function(_, url, auth)
    requests[#requests + 1] = { url = url, username = auth.username, password = auth.password }
    if mode == "401" then return 401, {}, "old-secret new-secret " .. url end
    if mode == "timeout" then return nil, {}, "timeout new-secret " .. url end
    return 200, {}, "OK", mode == "invalid" and "bad" or "jpeg"
end }
local transfer = { run = function(work, done, options)
    local handle = { work = work, done = done }
    function handle:cancel() self.cancelled = true; if options.on_cancelled then options.on_cancelled() end end
    pending[#pending + 1] = handle
    return handle
end }
local function finish(handle)
    local ok, body, err = pcall(handle.work)
    handle.done(ok and type(body) == "string", body, ok and err or body)
end
local pages = Pages:new{ transport = transport, transfer = transfer,
    source_provider = function(id) assert(id == "s"); return source end,
    renderer = { renderImageData = function() return { free = function() freed = freed + 1 end } end },
    image_probe = { inspect_bytes = function(body)
        if body == "bad" then return nil, "invalid signature" end
        return { format = "jpeg", width = 600, height = 800 }
    end } }
local original_open = io.open
io.open = function(path, mode_value)
    if tostring(mode_value):find("[wa+]") then writes[#writes + 1] = path; error("body write forbidden") end
    return original_open(path, mode_value)
end
local ready, failure = 0, nil
local callbacks = { on_ready = function() ready = ready + 1 end, on_error = function(err) failure = err end }
local target = function() return 600, 800 end
for page = 1, 27 do
    pages:request(1, index:get(page), target, callbacks)
    finish(pending[#pending])
    assert(requests[page].url == "https://server/page/" .. (page - 1)
        .. "?w=600&mw=600&h=800&mh=800&updateProgress=true", "27-page URLs must cover 0..26")
end
assert(ready == 27 and #writes == 0, "body pages must remain in memory")
local future = {}
for page = 2, 9 do future[#future + 1] = index:get(page) end
pages:prefetch(1, future, target)
local background = pending[#pending]
pages:request(1, index:get(20), target, callbacks)
assert(background.cancelled, "current page must preempt background")
finish(pending[#pending])
pages:prefetch(1, future, target)
for _ = 1, 5 do finish(pending[#pending]) end
assert(pages:buffer_count() == 5, "prefetch must be bounded to five pages")
pages:request(2, index:get(1), target, callbacks)
local stale, ready_before = pending[#pending], ready
pages:cancel_generation(2)
assert(stale.cancelled and pages:buffer_count() == 0)
finish(stale)
assert(ready == ready_before, "stale generations cannot reach Reader")

source.password = "new-secret"
mode = "401"
pages:request(3, index:get(1), target, callbacks); finish(pending[#pending])
assert(requests[#requests].password == "new-secret" and failure.code == "http" and failure.http_status == 401)
assert(not tostring(failure.detail):find("secret", 1, true), "transport errors must be redacted")
mode = "timeout"
pages:request(3, index:get(1), target, callbacks); finish(pending[#pending])
assert(failure.code == "timeout")
mode = "invalid"
pages:request(3, index:get(1), target, callbacks); finish(pending[#pending])
assert(failure.code == "decode")
mode = "ok"
source = nil
local before = #requests
pages:request(3, index:get(1), target, callbacks); finish(pending[#pending])
assert(failure.code == "source_missing" and #requests == before)
source = { id = "s", url = "https://server/api/opds/new%2Fkey?token=new%26token", password = "new-secret" }
local key_desc = { source_id = "s", server_kind = "kavita", page_count = 27,
    stream_template = "https://server/api/opds/{apiKey}/page/{pageNumber}?token={query:token}" }
local keyed = assert(Pages.virtual_index(key_desc, "keyed"))
pages:request(4, keyed:get(1), target, callbacks); finish(pending[#pending])
assert(requests[#requests].url == "https://server/api/opds/new%2Fkey/page/0?token=new%26token")
source.url = "https://server/opds?token=a&token=b"
before = #requests
pages:request(4, keyed:get(1), target, callbacks); finish(pending[#pending])
assert(failure.code == "source_restore_failed" and #requests == before)
assert(#writes == 0)
io.open = original_open

local Progress = require("webdavmanga.opds_progress")
local progress = Progress:new{}
local komga = { source_id = "s", server_kind = "komga", chapter_id = "book-1", page_count = 27,
    server_last_read = 5, stream_template = "https://server/base/api/v1/books/book-1/pages/{pageNumber}" }
assert(progress:on_page(komga, 2) == nil)
local patch = assert(progress:on_page(komga, 6))
assert(patch.method == "PATCH" and patch.url == "https://server/base/api/v1/books/book-1/read-progress")
assert(patch.body.page == 6 and patch.body.completed == false)
assert(progress:on_page(komga, 6) == nil and progress:on_page(komga, 3) == nil)
assert(progress:on_page({ server_kind = "kavita" }, 1).read_only == true)
assert(progress:on_page(desc, 1) == nil, "Suwayomi must use page request only")
assert(type(pages.sync_progress) == "function", "Reader checkpoints must execute supported server progress")
local patches = {}
transport.request_json = function(_, method, url, body, auth)
    patches[#patches + 1] = { method = method, url = url, body = body, auth = auth }
    return true
end
source = { id = "s", url = "https://server/opds", username = "fresh-user", password = "new-secret" }
pages:sync_progress(komga, 6)
pages:sync_progress(komga, 7)
pages:sync_progress(komga, 4)
finish(pending[#pending]); finish(pending[#pending])
assert(#patches == 2 and patches[1].body.page == 6 and patches[2].body.page == 7)
assert(patches[1].auth.username == "fresh-user" and patches[1].auth.password == "new-secret")
pages:sync_progress(komga, 8)
local old_progress = pending[#pending]
pages:cancel_all()
assert(old_progress.cancelled, "chapter exit must cancel server progress handles too")

local MemoryPages = require("webdavmanga.memory_pages")
local decoded, notified, fail_decode = 0, 0, true
local memory = MemoryPages:new{ client_factory = function() return {} end,
    connection_provider = function() return { kind = "opds" } end,
    read_provider = function() return "jpeg" end, transfer = transfer,
    on_bytes = function() notified = notified + 1 end,
    image_probe = { inspect_bytes = function() return { format = "jpeg", width = 1, height = 1 } end },
    renderer = { renderImageData = function()
        decoded = decoded + 1
        if not fail_decode then return {} end
    end } }
memory:request(1, index:get(1), target, callbacks); finish(pending[#pending])
assert(notified == 0 and decoded == 1, "valid signature with decode failure must not publish cover")
fail_decode = false
memory:request(1, index:get(1), target, callbacks); finish(pending[#pending])
assert(notified == 1 and decoded == 2, "cover validates using the single page decode")

local Cover = require("webdavmanga.opds_cover")
assert(type(Cover.candidates) == "function", "cover selection must fall back book, series, first page")
local covers_desc = { source_id = "s", page_count = 27, server_kind = "komga",
    stream_template = "https://server/page/{pageNumber}", cover_url = "https://server/book.jpg",
    series_cover_url = "https://server/series.jpg" }
local candidates = Cover.candidates(covers_desc, { image = { name = "1.jpg", path = "shared-cover" } })
assert(#candidates == 3 and candidates[1].image_url(600, 800, source) == "https://server/book.jpg")
assert(candidates[2].image_url(600, 800, source) == "https://server/series.jpg")
assert(candidates[3].image_url(600, 800, source) == "https://server/page/0")
for _, candidate in ipairs(candidates) do assert(candidate.path == "shared-cover") end
local cover_files, cover_writes, renames, cover_mode = {}, {}, 0, "book-invalid"
local sidecar_fs = { open = function(path, access)
    if access == "wb" then
        cover_writes[#cover_writes + 1] = path
        return { write = function(_, bytes) cover_files[path] = bytes; return true end, close = function() return true end }
    end
    if cover_files[path] then return { read = function() return cover_files[path] end, close = function() return true end } end
end, rename = function(from, to) cover_files[to] = cover_files[from]; cover_files[from] = nil; renames = renames + 1; return true end,
    remove = function(path) cover_files[path] = nil; return true end }
local cover_renderer = { renderImageData = function(_, body)
    if body == "decode-fail" then return nil end
    return { free = function() end }
end }
local cover_probe = { inspect_bytes = function(body)
    if body == "bad" then return nil, "signature" end
    return { format = "jpeg", width = 600, height = 800 }
end }
local cover_store = Cover:new{ cache = { key_for = function() error("no second hashed cover") end },
    fs = sidecar_fs, image_probe = cover_probe, renderer = cover_renderer }
local cover_requests = {}
local cover_pages = Pages:new{ cover_store = cover_store, source_provider = function() return source end,
    renderer = cover_renderer, image_probe = cover_probe, transfer = transfer,
    transport = { get_bytes = function(_, url)
        cover_requests[#cover_requests + 1] = url
        return 200, {}, "OK", url:find("book", 1, true) and "decode-fail" or "jpeg"
    end } }
assert(type(cover_pages.ensure_descriptor_cover) == "function", "descriptor cover must use one series sidecar")
local hint = { image = { name = "1.jpg", path = "opds:s:series:a/page-1.jpg" },
    chapter = { pointer_path = "/p/Series/a.meguru" } }
local cover_ready
cover_pages:ensure_descriptor_cover(covers_desc, {}, hint, function(path) cover_ready = path end)
finish(pending[#pending]); finish(pending[#pending])
assert(cover_ready == "/p/Series/.cover.jpg" and renames == 1 and #cover_requests == 2)
assert(#cover_writes == 1 and cover_files[cover_ready] == "jpeg", "decode failure cannot write even temporary cover")
local other_hint = { image = { name = "1.jpg", path = "opds:s:series:b/page-1.jpg" },
    chapter = { pointer_path = "/p/Series/b.meguru" } }
assert(cover_store:lookup({}, other_hint) == cover_ready, "series chapters and all shelves share one cover")
cover_pages:ensure_descriptor_cover(covers_desc, {}, other_hint)
assert(#cover_requests == 2 and renames == 1)
cover_pages:ensure_descriptor_cover(covers_desc, {}, { image = hint.image })
assert(#cover_requests == 2 and renames == 1, "missing pointer never persists a body fallback")
local closed_hint = { image = hint.image, chapter = { pointer_path = "/p/Closed/a.meguru" } }
cover_pages:ensure_descriptor_cover(covers_desc, {}, closed_hint)
local old_cover = pending[#pending]
cover_pages:cancel_all()
finish(old_cover)
assert(old_cover.cancelled and renames == 1, "late cover callback after exit cannot write")
cover_pages.cover_enabled = function() return false end
before = #pending
cover_pages:ensure_descriptor_cover(covers_desc, {}, closed_hint)
assert(#pending == before and renames == 1, "cover setting off disables reads and writes")
desc.stream_template = "https://server/page/{pageNumber}?updateProgress={query:updateProgress}"
local suwa = assert(Pages.virtual_index(desc, "identity"))
assert(suwa:get(1).image_url(600, 800, source) == "https://server/page/0?updateProgress=true",
    "Suwayomi progress flag is protocol-owned, never an unrestorable source secret")
desc.stream_template = "https://server/api/v1/manga/9/chapter/1/page/{pageNumber}"
    .. "?updateProgress={query:updateProgress}&opds=true"
local suwayomi_live = assert(Pages.virtual_index(desc, "identity"))
assert(suwayomi_live:get(1).image_url(600, 800, source)
        == "https://server/api/v1/manga/9/chapter/1/page/0?opds=true&updateProgress=true",
    "Suwayomi's current OPDS-PSE page template must open without restoring a fake secret")
local Transport = require("webdavmanga.transport")
local json_before = package.loaded.json
package.loaded.json = { encode = function(body) assert(body.page == 6); return '{"page":6,"completed":false}' end }
local captured
local http_transport = setmetatable({
    base64 = function(raw) assert(raw == "fresh-user:new-secret"); return "fresh-encoded" end,
    ltn12 = { source = { string = function(value) return value end }, sink = { table = function() return function() return 1 end end } },
    _request = function(_, request) captured = request; return 204, {}, "No Content" end,
}, { __index = Transport })
assert(http_transport:request_json("PATCH", "https://server/api/v1/books/book-1/read-progress",
    { page = 6, completed = false }, { username = "fresh-user", password = "new-secret" }) == true)
assert(captured.method == "PATCH" and captured.headers.Authorization == "Basic fresh-encoded"
    and captured.redirect == false and captured.source == '{"page":6,"completed":false}')
package.loaded.json = json_before
print("rebuild_0405_opds_stream_spec: passed")
