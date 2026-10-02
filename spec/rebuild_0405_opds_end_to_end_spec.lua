-- Real production startup and domain modules, including fresh-session cover views. Only
-- host I/O, clock/scheduling and KOReader presentation/decoder edges are virtual.
-- Catches missing startup wires, lost chapter identities, premature checkpoints,
-- eager page downloads and cache shelves which confuse pointers with body files.
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local files, writes, stores, requests, jobs, notices, host_errors = {}, {}, {}, {}, {}, {}, {}
local directories = {}
local now = 100
local function store(path)
    if stores[path] then return stores[path] end
    local values = {}
    local result = { values = values,
        readSetting = function(_, key, fallback) if values[key] == nil then return fallback end; return values[key] end,
        saveSetting = function(_, key, value) values[key] = value end,
        flush = function() return true end }
    stores[path] = result
    return result
end
local fs = { make_path = function(path) directories[path]=true; return true end,
    mkdir=function(path) if directories[path] then return nil end; directories[path]=true; return true end,
    rmdir=function(path) directories[path]=nil; return true end,
    exists = function(path) return files[path] ~= nil end,
    size = function(path) return files[path] and #files[path] end,
    list = function() return function() end end,
    rename = function(from, to) files[to], files[from] = files[from], nil; return true end,
    remove = function(path) files[path] = nil; return true end }
fs.open = function(path, mode)
    if mode == "rb" or mode == "r" then
        if not files[path] then return nil end
        return { read = function() return files[path] end, close = function() return true end }
    end
    expect(path:match("%.meguru%.[%w%-]+%.part$") or path:match("/%.cover%.jpg%.tmp$"),
        "no body, archive, spool, building or alternate cover writes: " .. path)
    writes[#writes + 1] = path
    return { write = function(_, bytes) files[path] = bytes; return true end,
        flush = function() return true end, close = function() return true end }
end
-- JSON is a KOReader native module. This small flat codec actually serializes
-- and parses every pointer field; it does not return an in-memory saved object.
local json = {}
json.encode = function(value)
    local parts = {}
    for k, v in pairs(value) do
        local literal = type(v) == "string" and ('"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"') or tostring(v)
        parts[#parts + 1] = '"' .. k .. '":' .. literal
    end
    table.sort(parts); return "{" .. table.concat(parts, ",") .. "}"
end
json.decode = function(bytes)
    local result, position = {}, 2
    while position < #bytes do
        local _, last, key = bytes:find('"([%w_]+)":', position)
        if not last then return nil end
        local ending
        if bytes:sub(last + 1, last + 1) == '"' then
            ending = last + 2
            while ending <= #bytes do
                local char = bytes:sub(ending, ending)
                if char == '\\' then ending = ending + 2
                elseif char == '"' then break
                else ending = ending + 1 end
            end
        else ending = (bytes:find('[,}]', last + 1)) - 1 end
        local literal = bytes:sub(last + 1, ending)
        if literal:sub(1,1) == '"' then result[key] = literal:sub(2,-2):gsub('\\"','"'):gsub('\\\\','\\')
        elseif literal == "true" then result[key] = true
        elseif literal == "false" then result[key] = false
        else result[key] = tonumber(literal) end
        position = ending + 2
    end
    return result
end
package.loaded.json = json
package.loaded["libs/libkoreader-lfs"] = { mkdir=fs.mkdir,rmdir=fs.rmdir, attributes = function(path, key)
    if directories[path] then return key=="mode" and "directory" or {mode="directory"} end
    if not files[path] then return nil end
    local a = { mode = "file", size = #files[path] }; return key and a[key] or a
end, dir = function() return function() end end }
package.loaded.util = { makePath = fs.make_path, diskUsage = function() return 10^10, 0 end }
package.loaded.luasettings = { open = function(_, path) return store(path) end }
package.loaded.datastorage = { getSettingsDir = function() return "/settings" end,
    getDataDir = function() return "/data" end, getFullDataDir = function() return "/data" end }
package.loaded.dispatcher = { registerAction = function() end }
package.loaded.logger = { err = function(...) host_errors[#host_errors + 1] = {...} end,
    warn = function() end, info = function() end, dbg = function() end }
local container = {}
function container:extend(value) value.__index = value; return setmetatable(value, { __index = self }) end
function container:new(value) setmetatable(value, self); value:init(); return value end
package.loaded["ui/widget/container/widgetcontainer"] = container
local scheduler = { scheduleIn = function(_, delay, callback)
    if delay == 0 then callback() end
    return true
end, unschedule = function() end }
package.loaded["ui/uimanager"] = scheduler
local function hash(value)
    local h = 0; for i = 1, #value do h = (h * 31 + value:byte(i)) % 4294967296 end
    return ("%032x"):format(h)
end
package.loaded["ffi/sha2"] = { md5 = hash }
local transfer = { run = function(work, done, options)
    local job = { work = work, done = done }
    function job:cancel() self.cancelled = true; if options and options.on_cancelled then options.on_cancelled() end end
    jobs[#jobs + 1] = job; return job
end }
local function finish(job, even_cancelled)
    expect(job and not job.finished, "finish one pending host event")
    job.finished = true
    if job.cancelled and not even_cancelled then return end
    local ok, value, err = pcall(job.work)
    job.done(ok and value ~= nil, ok and value or nil, ok and err or value)
end
local function drain()
    for _ = 1, 100 do
        local found
        for _, job in ipairs(jobs) do if not job.finished then found = job; break end end
        if not found then return end
        finish(found)
    end
    error("unbounded background work")
end
local original_open, original_rename, original_remove, original_time = io.open, os.rename, os.remove, os.time
io.open, os.rename, os.remove, os.time = fs.open, fs.rename, fs.remove, function() now = now + 1; return now end
local root_url = "https://fixture.invalid/opds"
local series_url = "https://fixture.invalid/opds/v1.2/series/series-1"
local root_xml = [[<feed xmlns="http://www.w3.org/2005/Atom"><title>Root</title><author><name>Komga</name></author>
<entry><id>series-1</id><title>Series</title><link rel="subsection" type="application/atom+xml" href="/opds/v1.2/series/series-1"/></entry></feed>]]
local series_xml = [[<feed xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns"><title>Series</title><author><name>Komga</name></author>
<entry><id>chapter-1</id><title>Volume</title><link rel="http://vaemendis.net/opds-pse/stream" href="/api/v1/books/chapter-1/pages/{pageNumber}" type="image/jpeg" pse:count="27" pse:lastRead="0"/></entry></feed>]]
-- Real signature/dimension parser receives a small JPEG SOF header. The native
-- decoder below is deliberately an edge double, not evidence of real decoding.
local jpeg = string.char(255,216,255,192,0,17,8,3,32,2,88,3,1,17,0,2,17,0,3,17,0,255,217)
local fail_feed, fail_page, fail_cover_decode = false, false, false
local fail_page_code = 503
local fail_cover_render = false
local fail_display = false
local webdav_requests, progress_requests, cover_updates = 0, 0, 0
local maximum_pages, minimum_server_progress, last_patch = 27, nil, nil
local transport = { get_bytes = function(_, url, auth)
    requests[#requests + 1] = { url = url, username = auth.username }
    if url == root_url then return 200, {}, "OK", root_xml end
    if url == series_url then
        if fail_feed then return 503, {}, "Unavailable", "" end
        return 200, {}, "OK", series_xml
    end
    local page = tonumber(url:match("/pages/(%d+)$") or url:match("/pages/(%d+)%?width=640$"))
    expect(page and page >= 0 and page < maximum_pages, "only zero-based chapter pages may be fetched")
    if fail_page then return fail_page_code, {}, "Unavailable", "" end
    return 200, {}, "OK", jpeg
end, request_json = function(_, method, url, body)
    progress_requests = progress_requests + 1
    expect(method == "PATCH" and url == "https://fixture.invalid/api/v1/books/chapter-1/read-progress",
        "real progress dispatch keeps chapter identity")
    expect(body.page >= 1 and body.page <= maximum_pages, "progress uses reader page coordinates")
    if minimum_server_progress then
        expect(body.page >= minimum_server_progress, "#4 refreshed server high-water must never regress to current-plus-prefetch PATCH 6")
    end
    last_patch = body.page
    return true
end, propfind_stream = function()
    webdav_requests = webdav_requests + 1
    return 503, {}, "Unexpected WebDAV cover lookup"
end }
local shown, forms, grid, errors, painted = {}, {}, nil, {}, 0
local shell = { get_content_size = function() return 600, 800 end,
    show_loading = function() end, show = function() return true end, close_now = function() end,
    show_page = function() if fail_display then return false end; painted = painted + 1; return true end,
    show_error = function(_, model) errors[#errors + 1] = model end }
local function info(_, value) notices[#notices + 1] = value end
local view = { show_menu = function(_, model) shown[#shown + 1] = model; return true end,
    show_resume = function(_, model) forms.resume = model; return true end,
    show_info = info, close_menu = function() end, close_all = function() end }
local render = { renderImageData = function(_, bytes)
    expect(bytes == jpeg, "native decoder receives the fetched bytes")
    if fail_cover_decode then return nil end
    return { w = 600, h = 800, getWidth = function() return 600 end,
        getHeight = function() return 800 end, free = function() end }
end, renderImageFile = function(_, path)
    if fail_cover_decode or fail_cover_render or not files[path] then return nil end
    expect(path:match("/%.cover%.jpg$"), "visible OPDS cover is the canonical local sidecar")
    return { free = function() end }
end }
package.loaded["ui/renderimage"] = render
local Plugin = require("main")
local global_history = {}
local association_reader = {showReader=function() error("pointer must not construct a native Reader") end}
local plugin = Plugin:new{ path = TEST_PLUGIN_ROOT, webdavmanga_deps = {
    document_registry={addProvider=function() end}, reader_ui=association_reader,
    read_history={addItem=function(_,path) global_history[#global_history+1]=path end},
    ca_file = "/fixture-ca", cache_fs = fs, offline_fs = fs, md5 = hash,
    clock = function() return now end, device = {}, global_settings = store("global"),
    transport = transport, render_image = render, scheduler = scheduler,
    async = transfer, memory_transfer = transfer, opds_memory_transfer = transfer,
    reader_ui_adapter = { create_shell = function() return shell end },
    opds_ui_adapter = view, browser_ui_adapter = view, library_ui_adapter = view,
    cover_grid_ui_adapter = { show_grid = function(_, model)
        grid = model
        local ids = {}; for _, entry in ipairs(model.items) do ids[#ids + 1] = entry.id end
        model.on_visible(ids)
        return true
    end, update_cover = function() cover_updates = cover_updates + 1; return true end,
        close_grid = function() end, free_visible = function() end },
    settings_ui_adapter = { show_sources = function(_, model) forms.sources = model end,
        show_opds_connection = function(_, model) forms.connection = model end,
        show_busy = function() return { close = function() end } end,
        confirm = function(_, model) forms.confirm = model end, show_info = info, close_all = function() end },
} }
plugin.settings_ui:show_connection()
expect(forms.sources.on_add_opds(), "unified connection add opens form")
local input = { kind = "opds", name = "Fixture", server_url = root_url, username = "first", server_kind = "auto" }
expect(forms.connection.on_test(input), "connection test starts")
drain()
expect(forms.connection.on_save(input), "tested OPDS connection saves")
local source = assert(plugin.opds_catalog:active())
expect(source.server_kind == "auto" and #plugin.opds_catalog:list() == 1,
    "tested connection retains automatic driver selection in unified settings")
plugin.settings_ui:show_connection(); forms.sources.on_edit(source.id)
input.username, input.name = "current", "Renamed"
expect(forms.connection.on_save(input), "connection edits persist")
source = plugin.opds_catalog:active()
expect(source.username == "current" and source.name == "Renamed", "catalog reads edited unified source")
local public_menu = {}
plugin:addToMainMenu(public_menu)
public_menu.webdavmanga.sub_item_table_func()[1].callback()
expect(shown[#shown] ~= nil, "public bookshelf callback must dispatch the selected OPDS source")
local function item(text)
    drain()
    for _, candidate in ipairs(shown[#shown].items) do if candidate.text == text then return candidate end end
    error("missing action: " .. text)
end
item("Series").callback(); drain()
expect(requests[#requests].url == series_url, "root opens series via real parsed link")
local before = #requests
shown[#shown].on_refresh(); drain()
expect(#requests == before + 1 and requests[#requests].url == series_url, "refresh fetches exact visible feed")
shown[#shown].on_back(); drain()
expect(requests[#requests].url == root_url, "back returns to root")
fail_feed = true; item("Series").callback(); drain()
expect(shown[#shown].title == "OPDS 加载失败", "feed failure presents recovery")
fail_feed = false; item("重试").callback(); drain()
expect(requests[#requests].url == series_url, "retry preserves failed series URL")
item("▶ 巡这个系列").callback()
local stale = forms.resume.items[1].callback
forms.resume.on_cancel(); stale()
expect(#writes == 0 and painted == 0 and #plugin.progress:list_all_history() == 0, "cancelled choice has no persistence or Reader")
item("▶ 巡这个系列").callback()
local handed_off = forms.resume.items[1].callback()
expect(handed_off, "selected series target hands off to real Reader: " .. table.concat(notices, " / "))
expect(plugin.reader.pending_request.index == 1 and painted == 0, "opening schedules current page before checkpoint")
fail_page = true; drain()
expect(#errors == 1 and #plugin.progress:list_all_history() == 0, "failed first page never writes history/progress")
fail_page = false; errors[#errors].on_retry(); drain()
expect(painted == 1 and plugin.reader.position.index == 1, "retry paints current first page")
local context = plugin.reader.context
local pointer_path = context.chapter.pointer_path
local sidecar = pointer_path:match("^(.+)/") .. "/.cover.jpg"
expect(files[sidecar] == jpeg, "only canonical series cover persists")
local first_pages = {}
for _, r in ipairs(requests) do local p = tonumber(r.url:match("/pages/(%d+)$")); if p then first_pages[p] = true end end
for p = 0, 5 do expect(first_pages[p], "default current plus five following pages") end
expect(not first_pages[6], "default prefetch does not exceed five following pages")
plugin.reader:request_page(2, "whole")
local background = plugin.opds_pages.inner.active
expect(background and not background.foreground, "consuming a prefetched page schedules the next background page")
plugin.reader:request_page(10, "whole")
expect(background.handle.cancelled and plugin.opds_pages.inner.active.foreground,
    "a requested current page preempts pending background HTTP")
drain()
expect(plugin.reader.position.index == 10, "preemption paints the requested page")
for page = 2, 27 do
    plugin.reader:request_page(page, "whole"); drain()
    expect(plugin.reader.position.index == page, "all 27 pages paint through the real Reader")
end
local seen = {}
for _, r in ipairs(requests) do
    local p = tonumber(r.url:match("/pages/(%d+)$")); if p then seen[p] = true; expect(r.username == "current", "HTTP uses current source credentials") end
end
for p = 0, 26 do expect(seen[p], "real HTTP boundary saw page " .. p) end
expect(#plugin.progress:list_all_history() == 1 and plugin.progress:list_all_history()[1].index == 27,
    "successful paints update one exact history record")
local connection, manga_path = context.connection, context.manga.path
local category = assert(plugin.library:create_category(connection, "Favorite"))
assert(plugin.library:set_categories(connection, manga_path, { category.id }))
assert(plugin.library:set_rating(connection, manga_path, 5, 5))
plugin.reader:force_close("back"); drain()
expect(requests[#requests].url == series_url, "Reader return restores series")
for _, mode in ipairs({"401", "decode", "display", "cancel", "stale", "success"}) do
    local before_history = plugin.progress:list_all_history()[1].updated_at
    fail_page, fail_page_code, fail_cover_decode = mode == "401", 401, mode == "decode"
    fail_display = mode == "display"
    expect(association_reader.showReader(pointer_path), "association opens the existing Reader: " .. mode)
    expect(#global_history == 0, "#5 association handoff before first display creates no global history")
    local page_job = plugin.opds_pages.inner.active.handle
    local catalog_job = jobs[#jobs]
    if mode == "cancel" or mode == "stale" then
        plugin.reader:force_close("plugin_teardown")
        expect(page_job.cancelled, "#5 cancellation owns the real page request")
        expect(catalog_job.cancelled, "#8 Reader close cancels pending chapter catalog work")
        if mode == "stale" then finish(page_job, true) end
    end
    drain()
    if mode == "success" then
        expect(#global_history == 1 and global_history[1] == pointer_path,
            "#5 successful first display records global history exactly once")
        plugin.reader:request_page(26,"whole"); drain()
        expect(#global_history == 1, "#5 later page display never repeats global history")
        plugin.reader:request_page(27,"whole"); drain()
    else
        expect(#global_history == 0 and plugin.progress:list_all_history()[1].updated_at == before_history,
            "#5 failure/cancellation cannot checkpoint or add global history: " .. mode)
    end
    plugin.reader:force_close("plugin_teardown"); drain()
end
fail_page, fail_cover_decode, fail_display = false, false, false
local function accept_shelf(label)
    expect(grid and #grid.items == 1, label .. " contains the unified record")
    local entry = grid.items[1]
    expect(entry.manga.path == manga_path and entry.manga.pointer_path == pointer_path
        and entry.local_cover_path == sidecar, label .. " shares identity, exact pointer and canonical cover")
    entry.on_open()
    expect(plugin.reader.context and plugin.reader.context.chapter.pointer_path == pointer_path
        and plugin.reader.context.chapter.chapter_id == "chapter-1", label .. " opens exact chapter")
    drain(); expect(plugin.reader.position.index == 27, label .. " resumes page 27")
    plugin.reader:force_close("back"); drain()
end
plugin.browser:show_history(); accept_shelf("history")
plugin.library_ui:show_category(category.id); accept_shelf("category")
plugin.library_ui:show_rating_category(5); accept_shelf("rating")
plugin.library_ui:show_offline_shelf()
expect(grid and #grid.items == 1, "cache view must consume the existing OPDS Library record")
expect(grid.items[1].cache_progress == 0 and not grid.items[1].cache_complete,
    "released body memory must never masquerade as an offline download")
expect(grid.allow_multi_select == false, "pointer-only entries cannot invoke whole-body cache deletion")
local stale_cache_open = grid.items[1].on_open
accept_shelf("cache")
expect(stale_cache_open() == false and not plugin.reader.context, "stale cache entry cannot reopen after returning to a new view")
plugin.opds_ui:open_record(plugin.library:list_mangas(connection, category.id)[1])
local pending = jobs[#jobs]
local paints_before, history_before = painted, plugin.progress:list_all_history()[1].updated_at
plugin.reader:force_close("back")
expect(pending.cancelled, "closing Reader cancels actual HTTP work")
finish(pending, true)
expect(painted == paints_before and plugin.progress:list_all_history()[1].updated_at == history_before,
    "late completion cannot repaint or checkpoint")
-- Reconstruct actual startup against the same persisted Library/Pointer files;
-- each new Cover service must validate its sidecar without a warmed lookup map.
-- Observe (and still execute) the real DirectoryStore method to catch fallback
-- before a platform async adapter could hide or defer the wrong request.
local saved_cover = files[sidecar]
for _, mode in ipairs({ "normal", "missing", "decode_failure", "render_failure" }) do
    if not os.getenv("OPDS_VISIBLE_CASE") or os.getenv("OPDS_VISIBLE_CASE") == mode then
        if mode == "missing" then files[sidecar] = nil else files[sidecar] = saved_cover end
        fail_cover_decode = mode == "decode_failure"
        fail_cover_render = mode == "render_failure"
        local session = Plugin:new{ path = TEST_PLUGIN_ROOT, webdavmanga_deps = plugin.webdavmanga_deps }
        local directory_calls = 0
        local real_load = session.directory_store.load
        session.directory_store.load = function(self, ...)
            directory_calls = directory_calls + 1
            return real_load(self, ...)
        end
        local http_before, webdav_before, progress_before = #requests, webdav_requests, progress_requests
        local updates_before, writes_before = cover_updates, #writes
        expect(session.library_ui:show_offline_shelf(), mode .. ": render actual cached-pointer grid")
        drain()
        expect(directory_calls == 0, mode .. ": visible cover must not enumerate a WebDAV directory")
        expect(webdav_requests == webdav_before and #requests == http_before and progress_requests == progress_before,
            mode .. ": visible cover must not send WebDAV, OPDS feed or body requests")
        expect(#writes == writes_before, mode .. ": visible cover must not persist replacement images")
        expect(cover_updates - updates_before == (mode == "normal" and 1 or 0),
            mode .. ": show canonical cover or retain the widget placeholder")
        expect(grid.items[1].manga.pointer_path == pointer_path,
            mode .. ": failed cover never changes exact reopen identity")
        if mode == "normal" then expect(grid.items[1].local_cover_path == sidecar, "normal cover retains canonical path") end
        fail_cover_decode, fail_cover_render = false, false
        grid.items[1].on_open()
        expect(session.reader.context and session.reader.context.chapter.pointer_path == pointer_path
            and session.reader.context.chapter.chapter_id == "chapter-1",
            mode .. ": placeholder entries still reopen the exact pointer through the actual Reader")
        session.reader:force_close("plugin_teardown"); drain()
    end
end
files[sidecar], fail_cover_decode, fail_cover_render = saved_cover, false, false
-- A fresh process has no in-memory sync high-water: only the refreshed pointer
-- can carry the server observation from the real feed into the real Reader.
maximum_pages, minimum_server_progress = 29, 20
series_xml = series_xml:gsub('pse:count="27"', 'pse:count="29"')
    :gsub('pse:lastRead="0"', 'pse:lastRead="20"')
    :gsub('pages/{pageNumber}"', 'pages/{pageNumber}?width=640"')
-- Set up an older on-disk client checkpoint through the storage edge. The
-- newly observed feed is ahead of this independent client's local page six.
plugin.progress.store.values.progress[manga_path].server_last_read = 6
plugin.progress.store.values.progress[manga_path].index = 6
last_patch = nil
local refreshed = Plugin:new{path=TEST_PLUGIN_ROOT,webdavmanga_deps=plugin.webdavmanga_deps}
local refreshed_menu = {}; refreshed:addToMainMenu(refreshed_menu)
refreshed_menu.webdavmanga.sub_item_table_func()[1].callback(); drain()
item("Series").callback(); drain(); item("Volume").callback()
expect(forms.resume and forms.resume.items[1], "#4 feed observation still presents actual resume choice")
expect(forms.resume.items[1].callback(), "#4 start choice reuses the existing pointer")
expect(refreshed.reader.context.chapter.pointer_path == pointer_path
    and refreshed.reader.context.chapter_index:count() == 29, "#4 stable path gets updated page count")
drain()
local updated = assert(refreshed.meguru_pointer:load(pointer_path))
expect(updated.server_last_read == 20 and updated.page_count == 29
    and updated.stream_template:find("width=640",1,true), "#4 verified pointer stores approved refreshed fields")
refreshed.reader:request_page(6,"whole"); drain()
expect(last_patch == nil and refreshed.reader.position.index == 6,
    "#4 newly observed 20 suppresses backwards PATCH 6 after real first display")
refreshed.reader:request_page(21,"whole"); drain()
expect(last_patch == 21, "#4 real Komga PATCH resumes only beyond the observed server high-water")
refreshed.reader:force_close("plugin_teardown"); drain()
plugin.settings_ui:show_connection(); forms.sources.on_delete(source.id); forms.confirm.on_confirm()
expect(plugin.opds_catalog:get(source.id) ~= nil, "existing last-source guard remains effective")
forms.sources.on_add_opds()
expect(forms.connection.on_save{ kind = "opds", name = "Replacement", server_url = root_url, server_kind = "auto" },
    "a replacement source can be created before removing the old one")
plugin.settings_ui:show_connection(); forms.sources.on_delete(source.id); forms.confirm.on_confirm()
expect(plugin.opds_catalog:get(source.id) == nil, "connection deletion reaches unified settings")
before = #requests
expect(plugin.opds_ui:open_record(plugin.library:list_mangas(connection, category.id)[1]) == false,
    "deleted source cannot reopen pointer")
expect(#requests == before and notices[#notices]:find("source_missing", 1, true), "deleted source fails before HTTP")
for path in pairs(files) do expect(path == pointer_path or path == sidecar, "only pointer and canonical cover remain") end
for path in pairs(directories) do expect(not path:match("%.meguru%-publish%.lock$"), "success, errors and canceled choices release owned pointer locks") end
expect(#writes == 3, "one pointer creation, one atomic refresh and one canonical cover; no body or duplicate metadata writes")
expect(#host_errors == 0 and not plugin.stopped, "startup/source changes and real consumers must not hide guarded failures")
io.open, os.rename, os.remove, os.time = original_open, original_rename, original_remove, original_time
print("rebuild_0405_opds_end_to_end_spec: " .. checks .. " checks")
