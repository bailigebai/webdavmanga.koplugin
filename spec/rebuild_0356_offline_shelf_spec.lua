local UiLibrary = require("webdavmanga.ui_library")
local CoverGrid = require("webdavmanga.ui_cover_grid")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local connection = { server_url = "https://source-a", username = "reader", root_path = "/" }
local models = {{
    manga = { name = "离线漫画", path = "/Manga" },
    cover_path = "/mnt/us/Offline/Manga/001.jpg", progress = 0.4,
}}
local last_grid, progress_updates = nil, {}
local active_identity = "source-a"
local library_ui = UiLibrary:new{
    settings = { get_connection = function() return connection end },
    library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
    cover_service = {},
    cover_grid = {
        show = function(_self, model) last_grid = model; return true end,
        cancel = function() return true end,
        update_progress = function(_self, id, progress)
            progress_updates[#progress_updates + 1] = { id = id, progress = progress }
            return true
        end,
    },
    browser = {},
    ui = { show_info = function() end },
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function(_self, identity)
            expect(identity == "source-a", "shelf must use current source identity")
            return models
        end,
        reader_model = function() return nil, "incomplete" end,
    },
    offline_manager = {},
    identity_provider = function() return active_identity end,
    show_offline_cache = function() end,
    open_cached_reader = function() end,
}

library_ui:show_offline_shelf()
expect(last_grid.title == "缓存漫画")
expect(last_grid.items[1].cache_progress == 0.4)
expect(last_grid.items[1].local_cover_path == "/mnt/us/Offline/Manga/001.jpg")

library_ui:update_offline_progress{
    root = "/mnt/us/Offline",
    identity = "source-a", manga_path = "/Manga", total = 10,
    downloaded = 5, cached = 1, running = true,
}
expect(progress_updates[1].id == "source-a\0/Manga")
expect(progress_updates[1].progress == 0.6)

library_ui:cancel()
local ignored_after_leave = library_ui:update_offline_progress{
    root = "/mnt/us/Offline",
    identity = "source-a", manga_path = "/Manga", total = 10,
    downloaded = 6, cached = 1, running = true,
}
library_ui:show_offline_shelf()
active_identity = "source-b"
local ignored_after_identity_switch = library_ui:update_offline_progress{
    root = "/mnt/us/Offline",
    identity = "source-a", manga_path = "/Manga", total = 10,
    downloaded = 7, cached = 1, running = true,
}
expect(not ignored_after_leave and not ignored_after_identity_switch
    and #progress_updates == 1,
    "offline progress must stop when the cache shelf closes or its identity changes")

local OfflineCache = require("webdavmanga.offline_cache")
local saved, zero_files = {}, {}
local zero_cache = OfflineCache:new{
    store = {
        readSetting = function(_self, key, fallback) return saved[key] or fallback end,
        saveSetting = function(_self, key, value) saved[key] = value end,
    },
    root_provider = function() return "/mnt/us/Offline" end,
    fs = { exists = function(path) return zero_files[path] == true end },
    md5 = function(value)
        local sum = #value
        for position = 1, #value do sum = (sum * 33 + value:byte(position)) % 0xffffffff end
        return ("%032x"):format(sum)
    end,
}
assert(zero_cache:save_job("source-a", { name = "Scanning", path = "/Scanning" }, {
    status = "scanning", total_pages = 0, cached_pages = 0,
}))
local scanning = zero_cache:list_mangas("source-a")
expect(#scanning == 1 and scanning[1].status == "scanning"
    and scanning[1].cached_pages == 0 and scanning[1].cover_path == nil
    and scanning[1].progress == 0,
    "a scanning job must appear on the cache shelf before its first cached page")
for _, status in ipairs({ "limit", "canceled", "empty", "error", "space" }) do
    assert(zero_cache:save_job("source-a", { name = status, path = "/" .. status }, {
        status = status, total_pages = 10, cached_pages = 999,
    }))
end
assert(zero_cache:save_job("source-b", { name = "Hidden", path = "/Hidden" }, {
    status = "limit", total_pages = 1,
}))
saved.jobs.invalid = { schema_version = 2, key = "invalid", identity = "source-a",
    manga_name = "Invalid", manga_path = "/Invalid", status = "scanning" }
local zero_models = zero_cache:list_mangas("source-a")
expect(#zero_models == 6,
    "zero-page terminal jobs must stay visible while other identities and invalid keys stay hidden")
for _, model in ipairs(zero_models) do
    expect(model.cached_pages == 0 and model.cover_path == nil and model.progress == 0
        and model.total_pages == (model.status == "scanning" and 0 or 10),
        "zero-page shelf items must retain totals without trusting stale cached counts")
end
local zero_details, zero_readers, zero_reader_models = 0, 0, 0
function zero_cache:reader_model(identity, path)
    zero_reader_models = zero_reader_models + 1
    return OfflineCache.reader_model(self, identity, path)
end
active_identity = "source-a"
library_ui.offline_cache = zero_cache
library_ui.show_offline_cache = function() zero_details = zero_details + 1 end
library_ui.open_cached_reader = function() zero_readers = zero_readers + 1 end
library_ui:show_offline_shelf()
for _, item in ipairs(last_grid.items) do item.on_open() end
expect(zero_details == 6 and zero_readers == 0 and zero_reader_models == 0,
    "zero-page jobs must open existing details without constructing a reader model")
local cover_connections, cover_resolutions, cover_downloads, cover_updates = 0, 0, 0, 0
local rendered_paths = {}
local visibility_grid = CoverGrid:new{
    connection_provider = function() cover_connections = cover_connections + 1; return connection end,
    cover_service = { resolve = function(_self, _connection, record, callbacks)
        cover_resolutions = cover_resolutions + 1
        callbacks.on_ready({ path = record.manga.path .. "/cover.jpg" })
    end },
    loader = { request_cover = function(_self, _generation, _image, callbacks)
        cover_downloads = cover_downloads + 1
        callbacks.on_error("offline")
    end },
    cache = {}, settings = { get_reader = function() return {} end },
    render_image = { renderImageFile = function(_self, path)
        rendered_paths[#rendered_paths + 1] = path
        return {}
    end },
    ui = {
        show_grid = function(_self, model) _self.model = model end,
        close_grid = function() end, free_visible = function() end,
        update_cover = function() cover_updates = cover_updates + 1; return true end,
    },
}
local visibility_library = UiLibrary:new{
    settings = library_ui.settings, library = library_ui.library,
    cover_service = {}, cover_grid = visibility_grid, browser = {}, ui = library_ui.ui,
    offline_cache = zero_cache, identity_provider = function() return "source-a" end,
}
local function show_visible_covers()
    assert(visibility_library:show_offline_shelf())
    local ids = {}
    for _, item in ipairs(visibility_grid.ui.model.items) do ids[#ids + 1] = item.id end
    assert(visibility_grid.ui.model.on_visible(ids))
end
show_visible_covers()
expect(cover_connections == 0 and cover_resolutions == 0 and cover_downloads == 0
    and cover_updates == 0 and #rendered_paths == 0,
    "visible zero-page cache shelf items must stay placeholders without any WebDAV cover work")
local scanned_page = "/Scanning/001.jpg"
local scanned_key = zero_cache:key_for("source-a", scanned_page)
local scanned_local = "/mnt/us/Offline/Scanning/001-" .. scanned_key:sub(1, 8) .. ".jpg"
zero_files[scanned_local] = true
zero_cache.entries[scanned_key] = {
    namespace = "webdavmanga-offline-v1", owned = true, key = scanned_key,
    identity = "source-a", remote_path = scanned_page,
    manga_path = "/Scanning", manga_name = "Scanning",
    chapter_path = "/Scanning", chapter_name = "Scanning", chapter_position = 1,
    page_position = 1, image_name = "001.jpg", root = "/mnt/us/Offline",
    local_path = scanned_local, size = 80, extension = "jpg",
    format = "jpeg", width = 100, height = 200,
}
assert(zero_cache:save_job("source-a", { name = "Scanning", path = "/Scanning" }, {
    status = "complete", total_pages = 1, cached_pages = 1, failed = 0,
}))
for _, item in ipairs(last_grid.items) do
    if item.manga.path == "/Scanning" then item.on_open() end
end
expect(zero_readers == 1 and zero_reader_models == 1 and zero_details == 6
    and #zero_cache:list_mangas("source-a") == 6,
    "a displayed zero-page job that completes must become readable without duplicate shelf items")
show_visible_covers()
expect(cover_connections == 0 and cover_resolutions == 0 and cover_downloads == 0
    and cover_updates == 1 and rendered_paths[1] == scanned_local,
    "refreshing a cache job with its first page must render the local cover without networking")
visibility_grid.render_image.renderImageFile = function() return nil end
show_visible_covers()
expect(cover_connections == 0 and cover_resolutions == 0 and cover_downloads == 0,
    "an unavailable offline cover must remain a placeholder instead of falling back to WebDAV")
assert(visibility_grid:show{ items = {{ id = "ordinary", name = "Ordinary",
    manga = { name = "Ordinary", path = "/Ordinary" } }} })
assert(visibility_grid.ui.model.on_visible({ "ordinary" }))
expect(cover_connections == 1 and cover_resolutions == 1 and cover_downloads == 1,
    "ordinary history/category/rating items must retain remote cover resolution and loading")

local grid = CoverGrid:new{
    cover_service = {}, loader = {}, cache = {},
    connection_provider = function() return connection end,
    settings = { get_reader = function() return { grid_columns = 5 } end },
    ui = {
        show_grid = function(_self, model) _self.model = model end,
        close_grid = function() end,
        free_visible = function() end,
        set_progress = function(_self, id, progress)
            _self.updated = { id = id, progress = progress }
            return true
        end,
    },
}
grid:show{ title = "缓存漫画", items = {{ id = "source-a\0/Manga", name = "离线漫画",
    cache_progress = 0.4, manga = models[1].manga }} }
expect(grid:update_progress("source-a\0/Manga", 0.6)
    and grid.ui.updated.id == "source-a\0/Manga" and grid.ui.updated.progress == 0.6,
    "live progress must update only the visible cover cell")

local function widget_class()
    local class = {}
    class.__index = class
    function class:new(values)
        local object = values or {}
        setmetatable(object, self)
        if object.init then object:init() end
        return object
    end
    function class:extend(definition)
        definition = definition or {}
        definition.__index = definition
        setmetatable(definition, { __index = self })
        return definition
    end
    function class:getSize()
        return { w = self.width or self.dimen and self.dimen.w or 600,
            h = self.height or self.dimen and self.dimen.h or 50 }
    end
    function class:free() self.freed = true end
    return class
end

local dirty_cells, dirty_grids = 0, 0
local input = widget_class()
function input.paintTo() return true end
local textbox = widget_class()
function textbox:getFontSizeToFitHeight() return 20 end
local screen = {
    getWidth = function() return 600 end, getHeight = function() return 800 end,
    getSize = function() return { w = 600, h = 800 } end,
    scaleBySize = function(_self, value) return value end,
}
local ui_manager = {
    show = function() end, close = function() end,
    setDirty = function(_self, _widget, region)
        if type(region) == "function" then dirty_cells = dirty_cells + 1
        else dirty_grids = dirty_grids + 1 end
    end,
    nextTick = function() return false end,
}
local modules = {
    ["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 2 },
    ["device"] = { screen = screen },
    ["ui/font"] = { getFace = function() return {} end },
    ["ui/geometry"] = { new = function(_self, value) return value end },
    ["ui/gesturerange"] = { new = function(_self, value) return value end },
    ["ui/size"] = { border = { thin = 1 }, padding = { small = 2 } },
    ["ui/uimanager"] = ui_manager,
    ["ui/widget/container/inputcontainer"] = input,
    ["ui/widget/textboxwidget"] = textbox,
}
for _, name in ipairs({ "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/iconwidget", "ui/widget/imagewidget", "ui/widget/overlapgroup",
    "ui/widget/progresswidget", "ui/widget/rectspan",
    "ui/widget/textwidget", "ui/widget/titlebar", "ui/widget/verticalgroup" }) do
    modules[name] = widget_class()
end
for name, module in pairs(modules) do
    package.loaded[name] = nil
    package.preload[name] = function() return module end
end
local widget_grid = CoverGrid:new{
    cover_service = { resolve = function() return nil end },
    loader = { identity = "source-a", cancel_cover_generation = function() end },
    cache = { key_for = function() return "key" end, lookup = function() end },
    connection_provider = function() return connection end,
    settings = { get_reader = function() return { grid_columns = 5 } end },
}
widget_grid:show{ title = "缓存漫画", items = {{ id = "cell", name = "离线漫画",
    cache_progress = 0.6, manga = models[1].manga },
    { id = "other", name = "Other", cache_progress = 0.5,
        manga = { name = "Other", path = "/Other" } }} }
local progress_layer = widget_grid.ui.widget.cells.cell.cover_slot[1][2]
expect(progress_layer and progress_layer.height >= screen:scaleBySize(8)
    and progress_layer.overlap_offset[2] >= 0,
    "cache progress must render as a bottom overlay at least eight pixels high")
local progress_widget = widget_grid.ui.widget
local other_cover = progress_widget.cells.other.cover_slot[1]
local initial_dirty_grids = dirty_grids
expect(progress_layer.percentage == 0.6,
    "cache progress overlay must receive the current progress value")
expect(widget_grid.ui:set_progress("cell", 0.2) and dirty_cells == 1,
    "set_progress must repaint only the changed cell")
expect(progress_widget.cells.cell.cover_slot[1][2].percentage == 0.2,
    "cell-local progress updates must refresh the visible progress bar")
for _, case in ipairs({ { -0.2, 0 }, { 0.237, 0.237 }, { 1.7, 1 } }) do
    assert(widget_grid:update_progress("cell", case[1]))
    expect(progress_widget.cells.cell.cover_slot[1][2].percentage == case[2],
        "visible progress values must be clamped to the supported range")
end
expect(widget_grid.ui.widget == progress_widget
    and progress_widget.cells.other.cover_slot[1] == other_cover
    and dirty_grids == initial_dirty_grids and dirty_cells == 4,
    "percentage changes must not rebuild or repaint the full grid or another cell")

print(("rebuild_0356_offline_shelf_spec: %d checks"):format(checks))
