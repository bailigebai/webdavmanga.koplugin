local Identity = require("webdavmanga.manga_identity")
local LibraryUi = require("webdavmanga.ui_library")
local Ui = require("webdavmanga.ui_opds")
local Reader = require("webdavmanga.ui_reader")
local Library = require("webdavmanga.library")

local opds = Identity.normalize_connection{
    kind = "opds", server_url = "https://x/root", root_path = "/",
}
assert(opds.kind == "opds", "OPDS connections must retain their own source kind")

local library_values = {}
local library_store = {
    readSetting = function(_self, key, default)
        return library_values[key] == nil and default or library_values[key]
    end,
    saveSetting = function(_self, key, value) library_values[key] = value end,
    flush = function() end,
}
local real_library = Library:new{ store = library_store, md5 = function(value) return value end }
local opds_category = assert(real_library:create_category(opds, "收藏"))
local opds_record = assert(real_library:add_manga(opds, {
    name = "OPDS 系列", path = "/opds/c1/volume", is_folder = true,
    opds_catalog_id = "c1", opds_feed_url = "https://x/volume",
}, {
    layout = "opds", category_ids = { opds_category.id },
    cover_hint = { image = { name = "1.jpg", path = "/opds/c1/volume/page-1.jpg" } },
}))
assert(opds_record.layout == "opds"
    and opds_record.manga.opds_catalog_id == "c1"
    and #real_library:list_mangas(opds, opds_category.id) == 1,
    "the existing library must persist OPDS records without changing WebDAV records")

-- Cache view consumes the existing Library record. It never needs a second
-- per-OPDS record store, and a closed session cannot imply offline body pages.
local connection = { kind = "opds", source_id = "s", root_path = "/" }
local descriptor = { source_id = "s", series_id = "series", chapter_id = "volume",
    chapter_name = "Volume", server_kind = "komga", page_count = 27,
    stream_template = "https://fixture.invalid/api/v1/books/volume/pages/{pageNumber}" }
local pointer_path, canonical = "/p/Series/Volume.meguru", "/p/Series/.cover.jpg"
local exact_context, cache_grid
local unified_ui = Ui:new{ catalog = { get = function() return { id = "s" } end },
    pointer = { load = function(_, path) assert(path == pointer_path); return descriptor end },
    reader = { open = function(_, context) exact_context = context; return true end }, ui = {} }
local unified = unified_ui:descriptor_record(descriptor, { id = "s" }, pointer_path)
assert(real_library:add_manga(connection, unified.manga, {
    layout = "opds", chapter = unified.chapter, cover_hint = unified.cover_hint,
}))
local unified_shelf = LibraryUi:new{ library = real_library,
    settings = { get_connection = function() return connection end }, browser = {}, ui = {},
    cover_service = {}, cover_grid = { cancel = function() end,
        show = function(_, model) cache_grid = model; return true end,
        leave_for = function(_, callback) return callback() end },
    opds_cover = { lookup = function(_, _, hint)
        assert(hint.chapter.pointer_path == pointer_path); return canonical
    end }, open_opds_record = function(record) return unified_ui:open_record(record) end }
local file_open = io.open
io.open = function() error("pointer cache view must not write or read body files") end
assert(unified_shelf:show_offline_shelf())
assert(#cache_grid.items == 1 and cache_grid.items[1].manga.path == "opds:s:series:volume"
    and cache_grid.items[1].local_cover_path == canonical, "cache view shares stable Library identity and canonical cover")
assert(cache_grid.items[1].cache_progress == 0 and not cache_grid.items[1].cache_complete,
    "released page memory is not an offline download")
assert(cache_grid.items[1].on_open() and exact_context.chapter.pointer_path == pointer_path
    and exact_context.chapter.chapter_id == "volume" and exact_context.chapter_index:count() == 27,
    "cache consumer reopens exact pointer through real OPDS UI and virtual index")
io.open = file_open
assert(#real_library:list_mangas(connection, real_library.ALL) == 1, "reopening never duplicates Library records")

local shown = {}
local ui = {
    show_menu = function(_self, model) shown[#shown + 1] = model end,
    show_info = function() end,
}
local feed = {
    title = "根目录",
    entries = {
        { id = "series", name = "系列", kind = "series", href = "https://x/series" },
    },
}
local volume_feed = {
    title = "系列",
    entries = {
        { id = "volume", name = "第 1 卷", kind = "volume", href = "https://x/volume" },
    },
}
local pages_feed = {
    title = "第 1 卷",
    entries = {
        { id = "p1", name = "1.jpg", kind = "page", image_url = "https://x/1.jpg" },
        { id = "p2", name = "2.jpg", kind = "page", image_url = "https://x/2.jpg" },
    },
}
local catalog = {
    list = function() return {{ id = "c1", name = "Komga", url = "https://x/root" }} end,
    active = function() return { id = "c1", name = "Komga", url = "https://x/root" } end,
    set_active = function() return true end,
    fetch = function(_self, _id, url)
        if url:match("/series$") then return volume_feed end
        if url:match("/volume$") then return pages_feed end
        return feed
    end,
}
local opened
local reader = { open = function(_self, context) opened = context end }
local library_calls = {}
local cover_ensures = 0
local library = {
    list_categories = function() return {{ id = "fav", name = "收藏" }} end,
    add_manga = function(_self, connection, resource, options)
        library_calls[#library_calls + 1] = { method = "add_manga", connection = connection,
            resource = resource, options = options }
        return { manga = resource }
    end,
    set_categories = function(_self, connection, path, ids)
        library_calls[#library_calls + 1] = { method = "set_categories", connection = connection,
            path = path, ids = ids }
        return true
    end,
    set_rating = function(_self, connection, path, rating, scale)
        library_calls[#library_calls + 1] = { method = "set_rating", connection = connection,
            path = path, rating = rating, scale = scale }
        return true
    end,
}
local adapter = Ui:new{
    catalog = catalog, ui = ui, reader = reader,
    async = { run = function(work, done)
        local ok, value = pcall(work); done(ok, value); return {cancel=function() end}
    end },
    library = library,
    ensure_cover = function(connection, cover_image)
        assert(connection.kind == "opds" and cover_image.path:match("/page%-1%.jpg$"),
            "OPDS shelf actions must request the first page as their shared cover")
        cover_ensures = cover_ensures + 1
        return true
    end,
}
adapter:show_home()
shown[1].items[1].callback()
shown[2].items[1].callback()
local page_menu = shown[#shown]
local open_item
for _, item in ipairs(page_menu.items) do
    if item.text == "打开本卷（2 页）" then open_item = item end
end
assert(open_item and open_item.callback, "OPDS volume must keep its open action")
open_item.callback()
assert(opened and opened.connection and opened.connection.kind == "opds",
    "OPDS reader context must carry an OPDS connection")
assert(opened.layout == "opds" and opened.source_context.opds == true,
    "OPDS reader context must be marked for shelf/history routing")
assert(opened.cover_hint and opened.cover_hint.image
    and opened.cover_hint.image.path == opened.chapter_index:get(1).path,
    "OPDS history must retain the same first-page cover hint")
assert(opened.chapter_index:get(1).opds_page == true,
    "OPDS pages must continue using the memory page source")
assert(opened.chapter_index:get(1).opds_cover == true
    and opened.chapter_index:get(1).opds_cover_connection.kind == "opds",
    "the first OPDS reader page must be marked for one-time cover persistence")

local checkpoint_context
local history_reader = Reader:new{
    loader = { identity = "test" },
    progress = { save = function(_self, _id, _path, _index, _segment, context)
        checkpoint_context = context
    end },
    state = {},
    settings = {
        get_connection = function()
            return { kind = "webdav", server_url = "https://nas", root_path = "/Books" }
        end,
    },
    cache = { key_for = function() return "key" end },
    ui = {},
    open_chapter = function() end,
}
history_reader.context = opened
history_reader.chapter_id = "opds-chapter"
history_reader:_checkpoint(1, "whole", opened.chapter_index:get(1))
assert(checkpoint_context and checkpoint_context.connection
    and checkpoint_context.connection.kind == "opds",
    "OPDS history checkpoint must use the context connection")

local manage_item
for _, item in ipairs(page_menu.items) do
    if item.text == "书架记录" then manage_item = item end
end
assert(manage_item == nil,
    "OPDS feed must not expose a second category, rating, or cache menu")

print("opds_shelf_integration_spec: passed")
