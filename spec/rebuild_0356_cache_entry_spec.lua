local Browser = require("webdavmanga.ui_browser")
local UiLibrary = require("webdavmanga.ui_library")

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

local function find_button(menu, text)
    for _, item in ipairs(menu.items) do
        if item.text == text then return item end
    end
    error("missing menu entry: " .. text)
end

local connection = { kind = "local", root_path = "/Books" }
local entered, cached = 0, 0
local browser = Browser:new{
    settings = {
        get_connection = function() return connection end,
        get_browser_path = function() return "/Books" end,
        set_browser_path = function() return true end,
        flush = function() end,
    },
    settings_ui = {}, directory_store = {}, ui = {}, open_reader = function() end,
    cache_manga = function() cached = cached + 1 end,
}
browser.enter_manga = function() entered = entered + 1 end
local rows = select(1, browser:_directory_items("/Books", index({{
    name = "漫画", path = "/Books/漫画", is_folder = true,
}}), 1, index({}), index({}), 0))
local folder_row = rows[5]
expect(folder_row.mandatory == "进入漫画" and folder_row.cache_callback == nil,
    "bookshelf folders must only expose the enter-manga action")
folder_row.secondary_callback()
expect(entered == 1 and cached == 0,
    "the right-side folder action must still enter manga without caching")

local category_record = { manga = { name = "分类", path = "/Books/category" },
    rating = 5, rating_scale = 5, category_ids = { ["category-a"] = true } }
local history_record = { manga = { name = "历史", path = "/Books/history" },
    rating = 5, rating_scale = 5 }
local rating_record = { manga = { name = "评分", path = "/Books/rating" },
    rating = 5, rating_scale = 5 }
local records = {
    [category_record.manga.path] = category_record,
    [history_record.manga.path] = history_record,
    [rating_record.manga.path] = rating_record,
}
local last_menu, last_grid, cached_manga
local ui = {
    show_menu = function(_, menu) last_menu = menu end,
    close_menu = function() end,
    show_info = function() end,
}
local library = {
    ALL = "all", UNCATEGORIZED = "uncategorized",
    get_manga = function(_, _, path) return records[path] end,
    list_categories = function() return {{ id = "category-a", name = "分类 A" }} end,
    list_mangas = function() return { category_record } end,
    list_mangas_by_rating = function() return { rating_record } end,
    rating_for = function(record) return record.rating end,
}
local library_ui = UiLibrary:new{
    settings = { get_connection = function() return connection end,
        get_rating_max = function() return 5 end },
    library = library,
    cover_service = {},
    cover_grid = { cancel = function() end, show = function(_, grid)
        last_grid = grid
        return true
    end },
    browser = {}, ui = ui, local_archive = {},
    cache_manga = function(manga) cached_manga = manga end,
}

library_ui:show_manage_manga(category_record, "category-a")
expect(find_button(last_menu, "评分：5 / 5 星")
    and find_button(last_menu, "标记为已读")
    and find_button(last_menu, "编辑分类")
    and find_button(last_menu, "从当前分类移除")
    and find_button(last_menu, "从漫画书架移除")
    and find_button(last_menu, "永久删除本地漫画文件夹"),
    "category management must retain rating, category, read, removal and local archive actions")
find_button(last_menu, "缓存到 Kindle").callback()
expect(cached_manga.path == category_record.manga.path,
    "category management cache must target its manga")

library_ui:show_history_manage(history_record)
expect(find_button(last_menu, "评分：5 / 5 星")
    and find_button(last_menu, "标记为已读")
    and find_button(last_menu, "编辑分类")
    and find_button(last_menu, "删除阅读历史")
    and find_button(last_menu, "永久删除本地漫画文件夹"),
    "history management must retain its existing actions")
find_button(last_menu, "缓存到 Kindle").callback()
expect(cached_manga.path == history_record.manga.path,
    "history management cache must target its manga")

library_ui:show_rating_category(5)
last_grid.items[1].on_action()
find_button(last_menu, "缓存到 Kindle").callback()
expect(cached_manga.path == rating_record.manga.path,
    "rating management cache must target its manga through the shared menu")

print(("rebuild_0356_cache_entry_spec: %d checks"):format(checks))
