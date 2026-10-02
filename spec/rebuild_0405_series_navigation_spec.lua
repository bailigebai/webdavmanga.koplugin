local Ui = require("webdavmanga.ui_opds")
assert(type(Ui.open_descriptor) == "function", "existing Reader must accept a descriptor")
local Navigation = require("webdavmanga.series_navigation")
local chosen, stopped = {}, 0
local nav = Navigation:new{ cancel = function() stopped = stopped + 1 end,
    open_entry = function(entry) assert(stopped > #chosen); chosen[#chosen + 1] = entry; return true end }
local order = { { chapter_id = "c10", chapter_name = "十" },
    { chapter_id = "c2", chapter_name = "二" }, { chapter_id = "c1", chapter_name = "一" } }
local neighbors = nav:neighbors{ kind = "opds", chapter_id = "c2", entries = order }
assert(neighbors.previous.chapter_id == "c10" and neighbors.next.chapter_id == "c1", "OPDS preserves server order")
assert(#chosen == 0, "menu display must not create pointers")
assert(nav:auto_next(26, 27) == false and #chosen == 0)
assert(nav:open("previous") and chosen[1].chapter_id == "c10")
assert(nav:auto_next(27, 27) and chosen[2].chapter_id == "c1")
neighbors = nav:neighbors{ kind = "local", path = "/m/2.cbz", entries = {
    { name = "10.cbz", path = "/m/10.cbz" }, { name = "1.cbz", path = "/m/1.cbz" },
    { name = "2.cbz", path = "/m/2.cbz" }, { name = "3.cbz", path = "/other/3.cbz" },
    { name = "3.zip", path = "/m/3.zip" } } }
assert(neighbors.previous.name == "1.cbz" and neighbors.next.name == "10.cbz")
neighbors = nav:neighbors{ kind = "local", path = "/alone/1.cbz", entries = {} }
assert(not neighbors.previous and not neighbors.next and nav:open("next") == false)

local source = { id = "s", kind = "opds", url = "https://server/opds" }
local descriptor = { source_id = "s", server_kind = "suwayomi", series_id = "series:/一",
    chapter_id = "chapter:/一", chapter_name = "同名", page_count = 27,
    stream_template = "https://server/page/{pageNumber}" }
local context, info, opens = nil, nil, 0
local ui = Ui:new{ catalog = { get = function() return source end },
    reader = { open = function(_, value) context = value; opens = opens + 1; return true end },
    progress = { records = {} }, ui = { show_info = function(_, value) info = value end } }
assert(ui:open_descriptor(descriptor, source, { page = 27, pointer_path = "/p.meguru" }) == true)
assert(context.chapter_index:count() == 27 and context.initial_page == 27)
assert(context.chapter.source_id == "s" and context.chapter.chapter_id == "chapter:/一")
assert(context.chapter.pointer_path == "/p.meguru" and context.cover_hint.image.path:match("/page%-1.jpg$"))
assert(context.chapter_index:get(1).path == context.chapter.path .. "#opds/1")
assert(context.connection.kind == "opds" and context.connection.source_id == "s")
ui.reader.open = function() return nil end
assert(ui:open_descriptor(descriptor, source, {}) == false, "nil Reader handoff is failure")
source = nil
ui.progress.records[context.chapter.path] = { index = 7 }
assert(ui:open_descriptor(descriptor, nil, { pointer_path = "/p.meguru" }) == false)
assert(info:find("同名", 1, true) and info:find("7", 1, true) and info:find("source_missing", 1, true))
local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local Pages = require("webdavmanga.opds_pages")
local requested, errors, progress_writes = {}, {}, {}
local shown_pages = 0
local shell = { get_content_size = function() return 600, 800 end,
    show_loading = function() end, show = function() return true end,
    show_page = function() shown_pages = shown_pages + 1; return true end,
    show_error = function(_, model) errors[#errors + 1] = model end,
    close_now = function() end }
local reader_pages = Pages:new{ transport = { get_bytes = function() error("not executed") end },
    source_provider = function() return nil end,
    transfer = { run = function(work, done, options)
        local h = { work = work, done = done, cancel = function(self)
            self.cancelled = true; if options.on_cancelled then options.on_cancelled() end
        end }
        requested[#requested + 1] = h; return h
    end } }
local real_reader = Reader:new{ loader = { identity = "active-webdav" }, state = State:new{},
    opds_pages = reader_pages, cache = { set_protected = function() end }, open_chapter = function() end,
    progress = { chapter_id = function(_, connection) assert(connection.source_id == "s"); return "chapter" end,
        resolve = function() return { index = 3 } end,
        save = function(_, _, _, _, _, history) progress_writes[#progress_writes + 1] = history end },
    settings = { get_connection = function() return { kind = "webdav" } end,
        get_reader = function() return { image_engine = "default" } end },
    ui = { create_shell = function() return shell end } }
source = { id = "s", kind = "opds", url = "https://server/opds" }
ui.reader = real_reader
assert(ui:open_descriptor(descriptor, source, { page = 27 }))
assert(real_reader.pending_request.index == 27 and real_reader.context.connection.source_id == "s")
local _, err = requested[1].work()
requested[1].done(false, nil, err)
assert(not real_reader.pending_request and #errors == 1 and #progress_writes == 0)
assert(errors[1].on_retry and errors[1].message:find("source_missing", 1, true))
errors[1].on_retry()
assert(#requested == 2 and real_reader.pending_request.index == 27, "retry must remain on failed page")
real_reader:force_close("back")
assert(requested[2].cancelled, "Reader close must cancel actual page handle")
reader_pages.source_provider = function() return source end
reader_pages.transport.get_bytes = function() return 200, {}, "OK", "jpeg" end
reader_pages.inner.image_probe = { inspect_bytes = function() return { width = 600, height = 800, format = "jpeg" } end }
reader_pages.inner.renderer = { renderImageData = function()
    return { w = 600, h = 800, free = function() end }
end }
assert(ui:open_descriptor(descriptor, source, { page = 27 }))
local actual = requested[#requested]
local body = actual.work()
actual.done(true, body)
assert(shown_pages == 1 and real_reader.position.index == 27 and not real_reader.pending_request,
    "existing Reader must actually paint the decoded page")
assert(#progress_writes == 1 and progress_writes[1].connection.source_id == "s"
    and progress_writes[1].chapter.chapter_id == "chapter:/一", "checkpoint must keep OPDS identity")
real_reader:force_close("back")
assert(type(Navigation.local_context) == "function", "local CBZ open must attach same-directory navigation")
local local_context = { chapter = { path = "/m/2.cbz" }, source_context = {} }
local local_open
Navigation.local_context(local_context, { kind = "local" }, function(directory)
    assert(directory == "/m")
    return { { path = "/m/10.cbz", name = "10.cbz" }, { path = "/m/2.cbz", name = "2.cbz" } }
end, function(entry) local_open = entry; return true end)
assert(local_context.source_context.navigation.current.next.name == "10.cbz")
assert(local_context.source_context.navigation:open("next") and local_open.path == "/m/10.cbz")
local saved_pointers, feed_requests = 0, 0
local komga_source = { id = "k", server_kind = "komga", url = "https://server/opds/v1.2/catalog" }
local current_desc = { source_id = "k", server_kind = "komga", series_id = "series-1", chapter_id = "b2",
    chapter_name = "第二本", page_count = 27, stream_template = "https://server/api/v1/books/b2/pages/{pageNumber}",
    series_feed_url = "https://server/opds/v1.2/series/series-1" }
local saved_desc, neighbor_context
local restored_ui = Ui:new{ reader = { open = function(_, value) neighbor_context = value; return true end },
    async = { run = function(work, done)
        local ok, value = pcall(work); done(ok, value); return {cancel=function() end}
    end },
    ui = {}, pointer = { save = function(_, value) saved_pointers = saved_pointers + 1; saved_desc = value; return "/series/next.meguru" end,
        load = function() return saved_desc end }, catalog = {
        get = function() return komga_source end,
        fetch = function(_, id, url)
            feed_requests = feed_requests + 1
            assert(id == "k")
            if url:find("page=2", 1, true) then return { entries = {
                { name = "最后", kind = "volume", stream = { count = 27,
                    template = "https://server/api/v1/books/b1/pages/{pageNumber}" } } } } end
            return { entries = {
                { name = "第二本", kind = "volume", stream = { count = 27,
                    template = "https://server/api/v1/books/b2/pages/{pageNumber}" } } },
                next_url = "https://server/opds/v1.2/series/series-1?page=2" }
        end } }
assert(restored_ui:open_descriptor(current_desc, komga_source, { pointer_path = "/series/current.meguru" }))
assert(feed_requests == 1 and saved_pointers == 0, "history loads only its current feed page without saving neighbors")
assert(neighbor_context.source_context.navigation.current.next)
assert(neighbor_context.source_context.navigation:open("next"))
assert(feed_requests == 2 and saved_pointers == 1 and neighbor_context.chapter.chapter_id == "b1")
print("rebuild_0405_series_navigation_spec: passed")
