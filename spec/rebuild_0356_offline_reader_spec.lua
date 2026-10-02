local Loader = require("webdavmanga.loader")
local UiLibrary = require("webdavmanga.ui_library")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local client_factory_calls, async_calls = 0, 0
local client = {
    download = function(_self, path)
        return { size = 10, format = "jpeg", width = 100, height = 200, remote_path = path }
    end,
}
local loader = Loader:new{
    client_factory = function() client_factory_calls = client_factory_calls + 1; return client end,
    cache = {
        key_for = function(_self, identity, path) return identity .. "\0" .. path end,
        lookup = function() return nil end,
        paths_for = function() return "/cache/final", "/cache/part" end,
        publish = function() return "/cache/final" end,
    },
    async = {
        run = function(work, callback)
            async_calls = async_calls + 1
            local ok, result = pcall(work)
            callback(ok, result, ok and nil or result, {})
            return { cancel = function() end }
        end,
    },
    identity = "source-a",
    offline_path_validator = function(image)
        return image.local_path == "/mnt/us/Offline/Manga/001.jpg"
    end,
}

local ready_path, was_cached
loader:request("offline-generation", {
    path = "/remote/Manga/001.jpg",
    local_path = "/mnt/us/Offline/Manga/001.jpg",
    offline_owned = true,
    format = "jpeg", width = 100, height = 200,
}, {
    on_ready = function(path, cached) ready_path, was_cached = path, cached end,
    on_error = function(err) error(err) end,
})
expect(ready_path == "/mnt/us/Offline/Manga/001.jpg" and was_cached == true)
expect(client_factory_calls == 0 and async_calls == 0)

for _, image in ipairs({
    { path = "/remote/Manga/002.jpg", local_path = "/mnt/us/Offline/Manga/fabricated.jpg", offline_owned = true },
    { path = "/remote/Manga/003.jpg", local_path = "/mnt/us/Offline/Manga/001.jpg" },
    { path = "/remote/Manga/004.jpg", local_path = "/mnt/us/Offline/Manga/rejected.jpg", offline_owned = true },
}) do
    loader:request("network-" .. image.path, image, { on_error = function(err) error(err) end })
end
expect(client_factory_calls == 3 and async_calls == 3,
    "fabricated, unmarked, or rejected local paths must use normal WebDAV loading")

local details_opened, reader_opened = 0, 0
local library_ui = UiLibrary:new{
    settings = { get_connection = function() return {} end },
    library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
    cover_service = {},
    cover_grid = { show = function(_self, model) _self.model = model; return true end,
        cancel = function() return true end },
    browser = {}, ui = { show_info = function() end },
    identity_provider = function() return "source-a" end,
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function() return {{ identity = "source-a",
            manga = { name = "未完成", path = "/Manga" }, progress = 0 }} end,
        reader_model = function() return nil, "incomplete" end,
    },
    show_offline_cache = function() details_opened = details_opened + 1 end,
    open_cached_reader = function() reader_opened = reader_opened + 1 end,
}
library_ui:show_offline_shelf()
library_ui.cover_grid.model.items[1].on_open()
expect(details_opened == 1 and reader_opened == 0,
    "an incomplete cache must open cache details, never a reader")

local opened_context, shelf_shows = nil, 0
local multi_ui = { show_info = function() end }
function multi_ui:show_menu(model) self.last_menu = model end
local complete = {
    manga = { name = "完整漫画", path = "/Complete" },
    chapters = {
        { name = "第1话", path = "/Complete/1", images = {{ name = "001.jpg",
            path = "/remote/Complete/1/001.jpg", local_path = "/offline/001.jpg",
            offline_owned = true }} },
        { name = "第2话", path = "/Complete/2", images = {{ name = "001.jpg",
            path = "/remote/Complete/2/001.jpg", local_path = "/offline/002.jpg",
            offline_owned = true }} },
    },
}
local complete_grid = {
    show = function(_self, model) shelf_shows = shelf_shows + 1; _self.model = model; return true end,
    cancel = function() return true end,
}
local complete_ui = UiLibrary:new{
    settings = { get_connection = function() return {} end },
    library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
    cover_service = {}, cover_grid = complete_grid, browser = {}, ui = multi_ui,
    identity_provider = function() return "source-a" end,
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function() return {{ manga = complete.manga, progress = 1 }} end,
        reader_model = function() return complete end,
    },
    open_cached_reader = function(context) opened_context = context end,
}
complete_ui:show_offline_shelf()
complete_grid.model.items[1].on_open()
expect(multi_ui.last_menu.items[1].text == "继续阅读"
    and multi_ui.last_menu.items[2].text == "选择章节",
    "complete multi-chapter caches must use the existing menu adapter")
multi_ui.last_menu.items[2].callback()
expect(multi_ui.last_menu.items[2].text == "第2话",
    "select chapters must show every cached chapter")
multi_ui.last_menu.items[2].callback()
expect(opened_context and opened_context.chapter_index:get(1).local_path == "/offline/002.jpg",
    "selecting a cached chapter must open that chapter's local image")
opened_context.source_context.on_return()
complete_grid.model.items[1].on_open()
multi_ui.last_menu.items[1].callback()
expect(opened_context and opened_context.chapter_index:get(1).offline_owned == true
    and opened_context.chapter_index:get(1).local_path == "/offline/001.jpg"
    and opened_context.source_context.on_return() == true and shelf_shows == 3,
    "cached reader contexts must use index-owned images and return to the cache shelf")

local direct_context
local direct = {
    manga = { name = "完整直读", path = "/Direct" },
    chapters = {{ name = "完整直读", path = "/Direct", images = {{ name = "001.jpg",
        path = "/remote/Direct/001.jpg", local_path = "/offline/direct.jpg",
        offline_owned = true }} }},
}
local direct_grid = { show = function(_self, model) _self.model = model; return true end,
    cancel = function() return true end }
local direct_ui = UiLibrary:new{
    settings = { get_connection = function() return {} end },
    library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
    cover_service = {}, cover_grid = direct_grid, browser = {}, ui = { show_info = function() end },
    identity_provider = function() return "source-a" end,
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function() return {{ manga = direct.manga, progress = 1 }} end,
        reader_model = function() return direct end,
    },
    open_cached_reader = function(context) direct_context = context end,
}
direct_ui:show_offline_shelf()
direct_grid.model.items[1].on_open()
expect(direct_context and direct_context.layout == "direct"
    and direct_context.chapter_index:get(1).local_path == "/offline/direct.jpg",
    "complete direct-image caches must open their only cached chapter")

local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local scheduled, requested, network_chapters = {}, {}, {}
local confirmation, closed_shells = nil, 0
local reader = Reader:new{
    loader = {
        identity = "source-a",
        request = function(_self, _generation, image)
            requested[#requested + 1] = image
            return {}
        end,
        cancel_generation = function() end,
    },
    progress = {
        chapter_id = function() return "chapter" end,
        resolve = function() return { index = 1, segment = "whole" } end,
    },
    state = State:new(),
    settings = { get_connection = function() return {} end,
        get_reader = function() return {} end },
    cache = { set_protected = function() end },
    ui = {
        create_shell = function() return { show_loading = function() end } end,
        show_shell = function() return true end,
        close_shell = function() closed_shells = closed_shells + 1; return true end,
        schedule = function(_self, callback) scheduled[#scheduled + 1] = callback end,
        confirm = function(_self, model) confirmation = model end,
    },
    open_chapter = function(manga, chapter)
        network_chapters[#network_chapters + 1] = { manga = manga, chapter = chapter }
    end,
}
complete_ui.open_cached_reader = function(context) assert(reader:open(context)) end
local CoverGrid = require("webdavmanga.ui_cover_grid")
local lifecycle_grid = CoverGrid:new{
    cover_service = {}, loader = {}, cache = {},
    connection_provider = function() return {} end,
    settings = { get_reader = function() return {} end },
    ui = {
        show_grid = function(_self, model) shelf_shows = shelf_shows + 1; _self.model = model end,
        close_grid = function() end, free_visible = function() end,
    },
}
complete_ui.cover_grid = lifecycle_grid
complete_ui:show_offline_shelf()
lifecycle_grid.ui.model.items[1].on_open()
multi_ui.last_menu.items[1].callback()
local first_context = reader.context
reader:_ask_next_chapter()
assert(confirmation.on_confirm())
expect(reader.context == nil and closed_shells == 1 and #requested == 1,
    "next chapter confirmation must close the current reader before reopening")
table.remove(scheduled, 1)()
expect(#network_chapters == 0 and #requested == 2
    and requested[2].local_path == "/offline/002.jpg"
    and reader.context.chapter_position == 2
    and reader.context.chapters_index:get(1).path == "/Complete/1",
    "offline next chapter must reopen the next cached chapter without the WebDAV callback")
local shelves_before_return = shelf_shows
reader:force_close("back")
table.remove(scheduled, 1)()
expect(shelf_shows == shelves_before_return + 1,
    "the next offline chapter must retain its return to the cache shelf")

local network_context = {}
for key, value in pairs(first_context) do network_context[key] = value end
network_context.open_chapter = nil
assert(reader:open(network_context))
reader:_ask_next_chapter()
assert(confirmation.on_confirm())
table.remove(scheduled, 1)()
expect(#network_chapters == 1 and network_chapters[1].manga.path == "/Complete"
    and network_chapters[1].chapter.path == "/Complete/2",
    "ordinary WebDAV readers must retain the global next-chapter callback")

print(("rebuild_0356_offline_reader_spec: %d checks"):format(checks))
