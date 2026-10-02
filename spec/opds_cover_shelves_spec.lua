local Browser = require("webdavmanga.ui_browser")
local Library = require("webdavmanga.library")
local UiLibrary = require("webdavmanga.ui_library")

local connection = {
    kind = "opds", source_id = "komga", server_url = "opds://source/komga", root_path = "/",
}
local active_connection = connection
local manga = {
    name = "OPDS 漫画", path = "opds:komga:series:volume", is_folder = true,
    source_id = "komga", series_id = "series", chapter_id = "volume", pointer_path = "/p/Series/Volume.meguru",
    opds_catalog_id = "komga", opds_feed_url = "https://komga/volume",
}
local chapter = {
    name = "OPDS 漫画", path = manga.path,
    source_id = "komga", series_id = "series", chapter_id = "volume", pointer_path = manga.pointer_path,
    opds_catalog_id = "komga", opds_feed_url = "https://komga/volume",
}
local cover_hint = {
    image = { name = "001.jpg", path = manga.path .. "/page-1.jpg" },
    chapter = chapter,
}
local cover_path = "/p/Series/.cover.jpg"
local lookup_count = 0
local opds_cover = {
    lookup = function(_self, received, hint)
        assert(received.kind == "opds" and hint.image.path == cover_hint.image.path,
            "every OPDS shelf must resolve the cover from its own record")
        lookup_count = lookup_count + 1
        return cover_path
    end,
}

local history_grid
local browser = Browser:new{
    settings = {
        get_connection = function() return connection end,
        get_browser_path = function() return "/" end,
    },
    settings_ui = {},
    directory_store = { cancel_all = function() end },
    ui = { close_menu = function() end, show_info = function() end },
    open_reader = function() end,
    progress = {
        list_history = function()
            return {{
                connection = connection, manga = manga, chapter = chapter,
                image_path = cover_hint.image.path, index = 1, total = 10,
                layout = "opds", cover_hint = cover_hint, updated_at = 1,
            }}
        end,
    },
    library = { get_manga = function() return nil end },
    cover_grid = { show = function(_self, model) history_grid = model; return true end },
    opds_cover = opds_cover,
}
browser:show_history{ connection = connection }
assert(history_grid.items[1].local_cover_path == cover_path,
    "OPDS reading history must display the persistent first-page cover")

local values = {}
local library = Library:new{ md5 = function(value) return value end, store = {
    readSetting = function(_, key, fallback) if values[key] == nil then return fallback end; return values[key] end,
    saveSetting = function(_, key, value) values[key] = value end, flush = function() end,
} }
local category = assert(library:create_category(connection, "收藏"))
local record = assert(library:add_manga(connection, manga, {
    layout = "opds", chapter = chapter, cover_hint = cover_hint, category_ids = { category.id },
}))
assert(library:set_rating(connection, manga.path, 5, 5))
local shown_grid, shown_menu
local physical_list_count = 0
local grid = {
    view_sequence = 1,
    cancel = function() end,
    show = function(_self, model) shown_grid = model; return true end,
    leave_for = function(_, callback) return callback() end,
}
local reopened
local library_ui = UiLibrary:new{
    settings = {
        get_connection = function() return active_connection end,
        get_rating_max = function() return 5 end,
    },
    library = library,
    cover_service = {},
    cover_grid = grid,
    browser = { close_menu = function() end, show_library = function() end },
    ui = {
        close_menu = function() end,
        show_info = function() end,
        show_menu = function(_self, model) shown_menu = model end,
    },
    offline_cache = {
        root = function() return "/offline" end,
        list_mangas = function()
            physical_list_count = physical_list_count + 1
            return {{
                identity = "webdav-identity",
                manga = { name = "WebDAV 实体缓存", path = "/漫画/实体缓存" },
                progress = 1, status = "complete",
            }}
        end,
    },
    identity_provider = function() return "opds-identity" end,
    open_opds_record = function(current)
        reopened = current
        assert(current.manga.path == manga.path and current.manga.pointer_path == manga.pointer_path
            and current.chapter.chapter_id == "volume", "cache reopens exact unified chapter and pointer")
        return true
    end,
    opds_cover = opds_cover,
}

library_ui:show_category(category.id)
assert(shown_grid.items[1].local_cover_path == cover_path,
    "OPDS category shelves must display the shared cover")
library_ui:show_rating_category(5)
assert(shown_grid.items[1].local_cover_path == cover_path,
    "OPDS rating shelves must display the shared cover")
local original_file_open = io.open
io.open = function() error("pointer cache view must not touch body files") end
library_ui:show_offline_shelf{ connection = connection, return_path = "/" }
assert(#shown_grid.items == 1 and shown_grid.items[1].cache_progress == 0
    and shown_grid.items[1].cache_complete == false
    and shown_grid.items[1].local_cover_path == cover_path,
    "OPDS cache view must consume unified Library pointers with shared cover and no offline body")
assert(shown_grid.items[1].on_open() and reopened.manga.path == record.manga.path,
    "cache record must reopen from the same Library identity")
io.open = original_file_open
assert(physical_list_count == 0,
    "the OPDS cache-record shelf must not enumerate WebDAV disk caches")
assert(lookup_count == 4,
    "all four OPDS shelves must resolve one shared cover without duplicate files")

print("opds_cover_shelves_spec: passed")
