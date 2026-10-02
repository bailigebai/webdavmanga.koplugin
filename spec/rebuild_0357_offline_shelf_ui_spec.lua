local Browser = require("webdavmanga.ui_browser")
local UiLibrary = require("webdavmanga.ui_library")
local CoverGrid = require("webdavmanga.ui_cover_grid")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local function index(entries)
    return {
        count = function() return #entries end,
        get = function(_, position) return entries[position] end,
    }
end

local connection = { root_path = "/Books" }
local settings = {
    get_connection = function() return connection end,
    get_browser_path = function() return "/Books" end,
    set_browser_path = function() return true end,
    flush = function() end,
}
local events, received = {}, nil
local browser = Browser:new{
    settings = settings,
    settings_ui = {}, directory_store = {},
    ui = {
        close_menu = function() events[#events + 1] = "closed" end,
        show_menu = function() end,
    },
    open_reader = function() end,
    open_offline_shelf = function(options)
        events[#events + 1] = "opened"
        received = options
    end,
}
browser.current_path = "/Books/当前目录"
local items = browser:_directory_items(browser.current_path, index({}), 1,
    index({}), index({}), 0)
items[2].secondary_callback()
expect(table.concat(events, ",") == "closed,opened",
    "opening the offline shelf must close the browser menu first")
expect(received and received.return_path == "/Books/当前目录",
    "opening the offline shelf must retain the current browser path")

local last_grid, returned, settings_opens = nil, {}, 0
local cached_context
local library_ui = UiLibrary:new{
    settings = settings,
    library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
    cover_service = {},
    cover_grid = {
        view_sequence = 0,
        cancel = function() end,
        show = function(self, model)
            self.view_sequence = self.view_sequence + 1
            last_grid = model
            return true
        end,
    },
    browser = {
        show_library = function(_, refresh, path)
            returned[#returned + 1] = { refresh = refresh, path = path }
        end,
    },
    ui = {},
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function()
            return {{
                manga = { name = "离线漫画", path = "/Manga" },
                cover_path = "/mnt/us/Offline/Manga/001.jpg",
                cached_pages = 1, progress = 1,
            }}
        end,
        reader_model = function()
            return {
                manga = { name = "离线漫画", path = "/Manga" },
                chapters = {{ path = "/Manga", images = {} }},
            }
        end,
    },
    identity_provider = function() return "source-a" end,
    show_offline_cache = function()
        settings_opens = settings_opens + 1
        return true
    end,
    open_cached_reader = function(context) cached_context = context end,
}

expect(library_ui:show_offline_shelf{ return_path = "/Books/当前目录" },
    "offline shelf should open")
expect(type(last_grid.on_settings) == "function",
    "offline shelf must provide its settings action to the cover grid")
last_grid.on_settings()
expect(settings_opens == 1, "offline shelf settings action must open cache settings")
last_grid.on_back()
expect(returned[1] and returned[1].refresh == false
    and returned[1].path == "/Books/当前目录",
    "offline shelf must return to its originating browser path")
expect(library_ui.offline_shelf_identity == nil,
    "offline shelf state must be cleared before returning")
expect(library_ui.offline_shelf_return_path == nil,
    "offline shelf return path must be cleared before returning")

expect(library_ui:show_offline_shelf{ return_path = "/Books/当前目录" },
    "offline shelf should reopen for cached-reader return coverage")
last_grid.items[1].on_open()
expect(cached_context and cached_context.source_context
    and type(cached_context.source_context.on_return) == "function",
    "cached reader context must expose a return callback")
cached_context.source_context.on_return()
last_grid.on_back()
expect(#returned == 2 and returned[2].path == "/Books/当前目录",
    "returning from a cached reader must preserve the originating browser path")

expect(library_ui:show_offline_shelf(), "offline shelf should open from the main menu")
last_grid.on_back()
expect(#returned == 3 and returned[3].path == "/Books",
    "a main-menu offline shelf return must reopen the WebDAV root")

local shown_model
local grid = CoverGrid:new{
    cover_service = {}, loader = {}, cache = {},
    connection_provider = function() return connection end,
    settings = { get_reader = function() return { grid_columns = 5 } end },
    ui = { show_grid = function(_, model) shown_model = model end },
}
expect(grid:show{ title = "缓存漫画", items = {}, on_settings = function() return true end },
    "cover grid should accept an offline shelf settings callback")
expect(type(shown_model.on_settings) == "function",
    "cover grid model must expose a guarded settings callback")

print(("rebuild_0357_offline_shelf_ui_spec: %d checks"):format(checks))
