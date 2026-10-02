local Browser = require("webdavmanga.ui_browser")
local checks = 0
local function expect(value, message) checks = checks + 1; if not value then error(message) end end
local function index_of(entries)
    return {
        count = function() return #entries end,
        get = function(_self, i) return entries[i] end,
        find = function(_self, path) for i, entry in ipairs(entries) do if entry.path == path then return i end end end,
        iterator = function(_self, first, limit)
            local out = {}; first = first or 1; limit = limit or #entries
            for i = first, math.min(#entries, first + limit - 1) do out[#out + 1] = entries[i] end
            return out, first + #out
        end,
        window = function(_self, center, radius)
            local out = {}; for i = math.max(1, center-radius), math.min(#entries, center+radius) do out[#out+1] = entries[i] end; return out
        end,
    }
end
local function directory(folders, images)
    local f, i = index_of(folders or {}), index_of(images or {})
    return { folders = function() return f end, images = function() return i end, close = function() end, folder_index = f, image_index = i }
end
local root_folders = {}; for i = 1, 85 do root_folders[i] = { name = "漫画 " .. i, path = "/漫画/" .. i, is_folder = true } end
local nested_folders = {}; for i = 1, 85 do nested_folders[i] = { name = "子目录 " .. i, path = "/漫画/2/" .. i, is_folder = true } end
local chapter = { name = "第1话", path = "/漫画/1/第1话", is_folder = true }
local chapter_images = { { name = "001.jpg", path = chapter.path .. "/001.jpg", is_file = true } }
local dirs = { ["/漫画"] = directory(root_folders), ["/漫画/1"] = directory({ chapter }),
    ["/漫画/2"] = directory(nested_folders), [chapter.path] = directory({}, chapter_images) }
local loads, invalidations, cancellations = {}, {}, {}
local directory_store = {
    load = function(_self, path, callbacks)
        loads[#loads + 1] = path
        local d = dirs[path]
        if d then callbacks.on_ready(d) else callbacks.on_error({ code = "transport" }) end
        return { cancel = function() cancellations[path] = (cancellations[path] or 0) + 1 end }
    end,
    invalidate = function(_self, path) invalidations[#invalidations + 1] = path end, cancel_all = function() end,
}
local connection = { server_url = "https://nas", username = "reader", root_path = "/漫画" }
local settings = { get_connection = function() return connection end, is_configured = function() return true end, get_browser_path = function() return "/漫画" end, set_browser_path = function() return true end, flush = function() end }
local ui = { menus = {}, show_menu = function(self, model) self.last_menu = model; self.menus[#self.menus+1] = model end, show_info = function() end, show_busy = function() return { close = function() end } end, close_menu = function() end }
local opened
local rating_shelf_opens, offline_shelf_opens = 0, 0
local browser = Browser:new{ settings = settings, settings_ui = { show_connection = function() end }, directory_store = directory_store, ui = ui, open_reader = function(context) opened = context end,
    open_rating_shelf = function() rating_shelf_opens = rating_shelf_opens + 1 end,
    open_offline_shelf = function() offline_shelf_opens = offline_shelf_opens + 1 end }
browser:show_library()
expect(#ui.last_menu.items == 89, "85 folders should be shown in one scrollable bookshelf list")
expect(ui.last_menu.items[1].text == "↻ 刷新"
    and ui.last_menu.items[1].mandatory == "开启缓存"
    and ui.last_menu.items[2].text == "阅读历史"
    and ui.last_menu.items[2].mandatory == "缓存漫画"
    and ui.last_menu.items[3].text == "漫画分类架"
    and ui.last_menu.items[3].mandatory == "漫画评分架"
    and ui.last_menu.items[4].text == "← 退出漫画书架",
    "root actions must remain in the accepted two-column layout")
ui.last_menu.items[2].secondary_callback()
expect(offline_shelf_opens == 1, "the bookshelf offline entry must open the cache shelf")
browser:show_library()
ui.last_menu.items[3].secondary_callback()
expect(rating_shelf_opens == 1, "the bookshelf rating entry must open the automatic rating shelf")
browser:show_library()
expect(ui.last_menu.items[89].text == "漫画 85", "the bookshelf should include the final folder without pagination")
for item_index = 5, 89 do
    local item = ui.last_menu.items[item_index]
    expect(item.mandatory == "进入漫画"
        and type(item.mandatory_func) == "function"
        and item.mandatory_func() == "进入漫画"
        and item.cache_callback == nil
        and type(item.secondary_callback) == "function",
        "every bookshelf folder row must expose only the enter-manga action")
end
ui.last_menu.items[1].callback()
expect(ui.last_menu.items[5].text == "漫画 1",
    "refresh from a later page must return the current directory to its first page")
browser:show_library(false, "/漫画/2", 2)
expect(ui.last_menu.items[5].text == "子目录 1",
    "nested directory navigation should ignore obsolete page offsets")
ui.last_menu.items[4].callback()
expect(ui.last_menu.items[5].text == "漫画 1",
    "returning to the parent directory must always start at its first page")
local stale_items = browser:_directory_items("/漫画", dirs["/漫画"].folder_index, 1)
local loads_before_stale_tap = #loads
browser.request_generation = browser.request_generation + 1
expect(stale_items[5].callback() == true and #loads == loads_before_stale_tap,
    "directory rows from an older request must consume taps without starting another load")
ui.last_menu.items[1].callback(); expect(invalidations[#invalidations] == "/漫画", "refresh invalidates only current path")
browser:show_library(false, "/漫画/1")
expect((cancellations["/漫画"] or 0) >= 1, "navigating to another path cancels the previous directory request (count=" .. tostring(cancellations["/漫画"] or 0) .. ")")
expect(ui.last_menu.items[1].text == "↻ 刷新"
    and ui.last_menu.items[2].text == "阅读历史"
    and ui.last_menu.items[3].text == "漫画分类架"
    and ui.last_menu.items[4].text == "← 返回上一级"
    and ui.last_menu.items[5].text == "第1话",
    "non-root two-column actions must precede directory rows")
local folders_index, images_index = dirs["/漫画/1"].folder_index, dirs[chapter.path].image_index
local recognized
browser:identify_manga({ name = "漫画 1", path = "/漫画/1", is_folder = true }, { on_success = function(result) recognized = result end })
expect(recognized and recognized.chapters_index == folders_index and folders_index:count() == 1, "chapter recognition must retain the folder index rather than a chapters array")
local mixed_images = index_of({
    { name = "001.png", path = "/漫画/混合目录/001.png", is_file = true },
    { name = "002.webp", path = "/漫画/混合目录/002.webp", is_file = true },
})
local mixed_result = browser:_recognize_directory(
    { name = "混合目录", path = "/漫画/混合目录", is_folder = true },
    directory({ { name = "不会作为章节", path = "/漫画/混合目录/子目录", is_folder = true } },
        { mixed_images:get(1), mixed_images:get(2) }))
expect(mixed_result and mixed_result.layout == "direct"
    and mixed_result.chapter_index:count() == 2
    and mixed_result.chapter_index:get(1).path == mixed_images:get(1).path,
    "direct images must win over child folders and every supported image must become a page")
local direct_folder_items = browser:_directory_items(
    "/漫画/直读", index_of({}), 1, mixed_images)
expect(direct_folder_items[5].text == "当前文件夹（图片）"
    and direct_folder_items[5].mandatory == "进入漫画"
    and direct_folder_items[5].mandatory_func() == "进入漫画"
    and type(direct_folder_items[5].callback) == "function"
    and direct_folder_items[5].cache_callback == nil
    and type(direct_folder_items[5].secondary_callback) == "function",
    "a folder containing direct images must expose only the enter-manga action")
browser:prepare_chapter({ name = "漫画 1", path = "/漫画/1", is_folder = true }, chapter, {}, { on_ready = function(context) opened = context end })
expect(opened and opened.chapter_index == images_index and opened.images == nil and opened.chapters == nil, "prepared reader context must carry the same image index without arrays")
expect(browser:open_prepared_reader(opened) == true, "prepared reader can be opened exactly once")

browser:show_folder_picker({ title = "添加漫画", action_text = "添加" })
local picker_page_one = ui.last_menu
expect(#picker_page_one.items == 41
    and picker_page_one.items[40].text == "漫画 40"
    and picker_page_one.items[41].text == "下一页 →",
    "folder picker must instantiate at most 40 directory rows per page")
picker_page_one.items[41].callback()
local picker_page_two = ui.last_menu
expect(#picker_page_two.items == 42
    and picker_page_two.items[1].text == "漫画 41"
    and picker_page_two.items[40].text == "漫画 80"
    and picker_page_two.items[41].text == "← 上一页"
    and picker_page_two.items[42].text == "下一页 →",
    "folder picker second page must remain bounded and expose page controls")
local loads_before_stale_picker_tap = #loads
picker_page_one.items[1].callback()
expect(#loads == loads_before_stale_picker_tap,
    "folder picker rows from an older page must not start a stale request")
picker_page_two.on_back()
expect(ui.last_menu.items[1].text == "漫画 1",
    "back from a later folder picker page must return to the previous page")
expect(Browser.folder_sort_key("漫画") < Browser.folder_sort_key("章节")
    and Browser.folder_sort_key("漫画 2") < Browser.folder_sort_key("漫画 10"),
    "folder sorting should use stable Chinese initials and natural numeric order")
print(("browser_ui_spec: %d checks"):format(checks))
