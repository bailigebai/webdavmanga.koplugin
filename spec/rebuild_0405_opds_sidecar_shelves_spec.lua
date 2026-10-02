local Ui = require("webdavmanga.ui_opds")
local Browser = require("webdavmanga.ui_browser")
local LibraryUi = require("webdavmanga.ui_library")
local Cover = require("webdavmanga.opds_cover")
local source = { id = "s", kind = "opds", url = "https://server/opds" }
local desc = { source_id = "s", series_id = "series:/一", chapter_id = "chapter:/一",
    chapter_name = "同名", page_count = 27, server_kind = "suwayomi",
    stream_template = "https://server/page/{pageNumber}" }
local pointer_path = "/p/Series/chapter.meguru"
local sidecar = "/p/Series/.cover.jpg"
local opens, reads, decodes, writes = 0, 0, 0, 0
local opds = Ui:new{ catalog = { get = function() return source end }, ui = {},
    pointer = { load = function(_, path) assert(path == pointer_path); return desc end },
    reader = { open = function(_, context)
        opens = opens + 1
        assert(context.chapter.chapter_id == desc.chapter_id and context.chapter.pointer_path == pointer_path)
        return true
    end } }
local record = opds:descriptor_record(desc, source, pointer_path)
record.index, record.total, record.updated_at = 3, 27, 1
local cover = Cover:new{ cache = { key_for = function() error("no hashed duplicate") end },
    fs = { open = function(path, mode)
        assert(path == sidecar)
        if mode ~= "rb" then writes = writes + 1; error("existing cover must be reused") end
        reads = reads + 1
        return { read = function() return "valid-cover" end, close = function() return true end }
    end }, image_probe = { inspect_bytes = function() return { width = 600, height = 800 } end },
    renderer = { renderImageData = function() decodes = decodes + 1; return { free = function() end } end } }
local settings = { get_connection = function() return record.connection end,
    get_browser_path = function() return "/" end, get_rating_max = function() return 5 end }
local grid_model, left = nil, 0
local grid = { cancel = function() end, show = function(_, model) grid_model = model; return true end,
    leave_for = function(_, callback) left = left + 1; return callback() end }
local library = { ALL = "all", UNCATEGORIZED = "uncategorized",
    list_categories = function() return { { id = "favorite", name = "收藏" } } end,
    list_mangas = function() return { record } end,
    list_mangas_by_rating = function() return { record } end,
    get_manga = function() return record end }
local function reopen(value) assert(value.manga.path == record.manga.path); return opds:open_record(value) end
local browser = Browser:new{ settings = settings, settings_ui = {}, library = library,
    directory_store = { cancel_all = function() end }, open_reader = function() error("no WebDAV reader") end,
    ui = { close_menu = function() end, show_info = function(_, msg) error(msg) end },
    progress = { list_history = function() return { record } end },
    cover_grid = grid, opds_cover = cover, open_opds_record = reopen }
local function accept_entry()
    assert(#grid_model.items == 1 and grid_model.items[1].local_cover_path == sidecar,
        "all four entry points must use the canonical series sidecar")
    local before = opens
    grid_model.items[1].on_open()
    assert(opens == before + 1, "entry must reopen the exact saved pointer through OPDS")
end
browser:show_history()
accept_entry()
local shelves = LibraryUi:new{ settings = settings, library = library, cover_service = {}, cover_grid = grid,
    browser = { close_menu = function() end, prepare_resume = function() error("no WebDAV resume") end,
        prepare_chapter = function() error("no WebDAV chapter") end },
    ui = { close_menu = function() end, show_info = function(_, msg) error(msg) end },
    opds_cover = cover, open_opds_record = reopen }
shelves:show_category("all"); accept_entry()
shelves:show_category("favorite"); accept_entry()
shelves:show_rating_category(5); accept_entry()
assert(opens == 4 and left == 3, "real grid-capable shelf must leave before OPDS handoff")
assert(reads == 1 and decodes == 1 and writes == 0, "every entry reuses one validated sidecar")
source = nil
opds.progress = { records = { [record.chapter.path] = { index = 7 } } }
local missing_message
opds.ui.show_info = function(_, message) missing_message = message end
browser:show_history()
assert(grid_model.items[1].local_cover_path == sidecar, "deleted source must not remove the saved cover")
grid_model.items[1].on_open()
assert(opens == 4 and missing_message:find("同名", 1, true)
    and missing_message:find("7", 1, true) and missing_message:find("source_missing", 1, true),
    "deleted source keeps saved metadata and local progress before its classified error")
print("rebuild_0405_opds_sidecar_shelves_spec: passed")
