local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local UiLibrary = require("webdavmanga.ui_library")
local Browser = require("webdavmanga.ui_browser")

local ALL = "__all__"
local UNCATEGORIZED = "__uncategorized__"
local connection = {
    server_url = "https://nas.example/dav",
    username = "reader",
    password = "never-forward-this",
    root_path = "/Books",
}
local settings = { get_connection = function() return connection end }

local favorites = { id = "favorites", name = "收藏" }
local later = { id = "later", name = "稍后阅读" }
local manga_a = { name = "漫画 A", path = "/Books/A", is_folder = true }
local manga_b = { name = "漫画 B", path = "/Books/B", is_folder = true }
local manga_c = { name = "漫画 C", path = "/Books/C", is_folder = true }
local manga_d = { name = "漫画 D", path = "/Books/D", is_folder = true }
local chapter_a = { name = "第1话", path = "/Books/A/第1话", is_folder = true }

local function clone_set(values)
    local result = {}
    for id, selected in pairs(values or {}) do
        if selected then result[id] = true end
    end
    return result
end

local function clone_record(record)
    return {
        key = record.key,
        manga = record.manga,
        category_ids = clone_set(record.category_ids),
        layout = record.layout,
        cover_hint = record.cover_hint,
    }
end

local library = {
    ALL = ALL,
    UNCATEGORIZED = UNCATEGORIZED,
    categories = { favorites, later },
    mangas = {
        [manga_a.path] = {
            key = "key-a", manga = manga_a, category_ids = { favorites = true },
            layout = "chapters", cover_hint = { chapter = chapter_a },
        },
        [manga_b.path] = {
            key = "key-b", manga = manga_b, category_ids = {}, layout = "direct",
        },
    },
    calls = {},
}

function library:list_categories(received)
    expect(received == connection, "category reads use the current connection")
    local result = {}
    for _, category in ipairs(self.categories) do result[#result + 1] = category end
    return result
end

function library:list_mangas(received, view_id)
    expect(received == connection, "manga reads use the current connection")
    local result = {}
    for _, record in pairs(self.mangas) do
        local include = view_id == ALL
            or (view_id == UNCATEGORIZED and next(record.category_ids) == nil)
            or record.category_ids[view_id] == true
        if include then result[#result + 1] = clone_record(record) end
    end
    table.sort(result, function(left, right) return left.manga.name < right.manga.name end)
    return result
end

local function find_category(categories, category_id)
    for index, category in ipairs(categories) do
        if category.id == category_id then return index, category end
    end
end

function library:create_category(received, name)
    self.calls[#self.calls + 1] = { method = "create_category", connection = received, name = name }
    if name == "" then return nil, "invalid_category_name" end
    for _, category in ipairs(self.categories) do
        if category.name:lower() == name:lower() then return nil, "duplicate_category" end
    end
    local category = { id = "category-" .. tostring(#self.categories + 1), name = name }
    self.categories[#self.categories + 1] = category
    return category
end

function library:rename_category(received, category_id, name)
    self.calls[#self.calls + 1] = {
        method = "rename_category", connection = received, category_id = category_id, name = name,
    }
    local _, category = find_category(self.categories, category_id)
    if not category then return nil, "missing_category" end
    for _, other in ipairs(self.categories) do
        if other.id ~= category_id and other.name:lower() == name:lower() then
            return nil, "duplicate_category"
        end
    end
    category.name = name
    return category
end

function library:remove_category(received, category_id)
    self.calls[#self.calls + 1] = {
        method = "remove_category", connection = received, category_id = category_id,
    }
    local index = find_category(self.categories, category_id)
    if not index then return false end
    table.remove(self.categories, index)
    for _, record in pairs(self.mangas) do record.category_ids[category_id] = nil end
    return true
end

function library:add_manga(received, manga, options)
    self.calls[#self.calls + 1] = {
        method = "add_manga", connection = received, manga = manga, options = options,
    }
    local record = self.mangas[manga.path]
    if not record then
        record = { key = "key:" .. manga.path, manga = manga, category_ids = {} }
        self.mangas[manga.path] = record
    end
    record.manga = manga
    for _, category_id in ipairs(options.category_ids or {}) do
        record.category_ids[category_id] = true
    end
    record.layout = options.layout
    record.cover_hint = options.cover_hint
    return clone_record(record)
end

function library:set_categories(received, path, category_ids)
    self.calls[#self.calls + 1] = {
        method = "set_categories", connection = received, path = path,
        category_ids = category_ids,
    }
    local record = self.mangas[path]
    if not record then return nil, "missing_manga" end
    record.category_ids = {}
    for _, category_id in ipairs(category_ids or {}) do record.category_ids[category_id] = true end
    return clone_record(record)
end

function library:remove_from_category(received, path, category_id)
    self.calls[#self.calls + 1] = {
        method = "remove_from_category", connection = received,
        path = path, category_id = category_id,
    }
    local record = self.mangas[path]
    if not record or not record.category_ids[category_id] then return false end
    record.category_ids[category_id] = nil
    return true
end

function library:remove_manga(received, path)
    self.calls[#self.calls + 1] = {
        method = "remove_manga", connection = received, path = path,
    }
    if not self.mangas[path] then return false end
    self.mangas[path] = nil
    return true
end

function library:relink_manga(received, old_path, recognition)
    local manga = recognition.manga or recognition
    self.calls[#self.calls + 1] = {
        method = "relink_manga", connection = received, old_path = old_path,
        manga = manga, recognition = recognition,
    }
    local source = self.mangas[old_path]
    if not source then return nil, "missing_manga" end
    local target = self.mangas[manga.path]
    if target and target ~= source then
        for category_id in pairs(source.category_ids) do target.category_ids[category_id] = true end
        if recognition.manga then
            target.layout = recognition.layout
            target.cover_hint = recognition.cover_hint
        end
        self.mangas[old_path] = nil
        return clone_record(target)
    end
    self.mangas[old_path] = nil
    source.manga = manga
    source.key = "key:" .. manga.path
    if recognition.manga then
        source.layout = recognition.layout
        source.cover_hint = recognition.cover_hint
    end
    self.mangas[manga.path] = source
    return clone_record(source)
end

local remote_mutations = { delete = 0, MOVE = 0, PUT = 0 }
local browser = {
    current_path = "/Books",
    picker_models = {},
    recognition_requests = {},
    presentations = {},
    library_returns = 0,
    client = {
        delete = function() remote_mutations.delete = remote_mutations.delete + 1 end,
        MOVE = function() remote_mutations.MOVE = remote_mutations.MOVE + 1 end,
        PUT = function() remote_mutations.PUT = remote_mutations.PUT + 1 end,
    },
}
function browser:show_folder_picker(model, start_path)
    self.last_picker = model
    self.last_picker_start = start_path
    self.picker_models[#self.picker_models + 1] = model
end
function browser:identify_manga(manga, options)
    self.last_recognition = { manga = manga, options = options }
    self.recognition_requests[#self.recognition_requests + 1] = self.last_recognition
end
function browser:present_manga(result, source_context)
    self.presentations[#self.presentations + 1] = {
        result = result,
        source_context = source_context,
    }
end
function browser:cover_context(manga)
    return {
        identity = "https://nas.example/dav\0reader\0/Books",
        chapters = manga.path == manga_a.path and { chapter_a } or {},
        images = {},
    }
end
function browser:show_library()
    self.library_returns = self.library_returns + 1
end

local cover_list = { models = {} }
function cover_list:show(model)
    self.last_model = model
    self.models[#self.models + 1] = model
end
function cover_list:cancel() self.cancels = (self.cancels or 0) + 1; return true end

local cover_service = { requests = {} }
function cover_service:refresh(received, record, callbacks)
    local request = { connection = received, record = record, callbacks = callbacks }
    self.requests[#self.requests + 1] = request
    self.last_request = request
    return { cancel = function() request.canceled = true end }
end

local ui = { menus = {}, messages = {}, inputs = {}, confirms = {} }
function ui:show_menu(model)
    self.last_menu = model
    self.menus[#self.menus + 1] = model
end
function ui:show_info(message)
    self.last_message = message
    self.messages[#self.messages + 1] = message
end
function ui:show_input(model)
    self.last_input = model
    self.inputs[#self.inputs + 1] = model
end
function ui:confirm(model)
    self.last_confirm = model
    self.confirms[#self.confirms + 1] = model
end
function ui:close_menu() self.closed = (self.closed or 0) + 1 end

local function last_library_call(method)
    for index = #library.calls, 1, -1 do
        if library.calls[index].method == method then return library.calls[index] end
    end
end

local function find_item(items, text)
    for _, item in ipairs(items or {}) do
        if item.text == text then return item end
    end
end

local function find_item_containing(items, text)
    for _, item in ipairs(items or {}) do
        if item.text and item.text:find(text, 1, true) then return item end
    end
end

local ui_library = UiLibrary:new{
    settings = settings,
    library = library,
    cover_service = cover_service,
    cover_grid = cover_list,
    browser = browser,
    ui = ui,
}

ui_library:show_home()
expect(ui.last_menu.title == "漫画分类架", "home title")
expect(ui.last_menu.items[1].text == "添加漫画", "first action")
expect(ui.last_menu.items[2].text == "管理分类", "second action")
expect(ui.last_menu.items[3].text == "全部漫画（2）", "all count")
expect(ui.last_menu.items[4].text == "未分类（1）", "uncategorized count")
expect(ui.last_menu.items[5].text == "收藏（1）"
    and ui.last_menu.items[6].text == "稍后阅读（0）",
    "custom category counts follow the fixed rows")
ui.last_menu.on_back()
expect(browser.library_returns == 1, "home has an explicit return to the WebDAV shelf")

ui_library:show_home()
ui.last_menu.items[1].callback()
local picker = browser.last_picker
expect(picker.title == "添加漫画" and picker.action_text == "添加",
    "add mode uses explicit right action")
picker.on_back()
expect(ui.last_menu.title == "漫画分类架", "add picker can return to category home")

local adds_before_cancel = #library.calls
ui_library:show_add_picker()
browser.last_picker.on_pick(manga_c)
expect(browser.last_recognition.manga == manga_c
    and browser.last_recognition.options.allow_cached == false,
    "adding validates the selected directory online")
browser.last_recognition.options.on_success{
    manga = manga_c, layout = "chapters", chapters = { chapter_a },
    cover_hint = { chapter = chapter_a },
}
expect(ui.last_menu.title == "选择分类", "successful recognition opens multi-select")
ui.last_menu.on_back()
expect(#library.calls == adds_before_cancel,
    "canceling category selection must create no manga record")

ui_library:show_add_picker()
browser.last_picker.on_pick(manga_c)
    browser.last_recognition.options.on_success{
    manga = manga_c, layout = "direct", images = {},
    cover_hint = { image = { name = "1.jpg", path = "/Books/C/1.jpg" } },
}
ui.last_menu.on_save()
local added = last_library_call("add_manga")
expect(added and added.manga == manga_c and #added.options.category_ids == 0,
    "saving zero categories creates an uncategorized record")
expect(added.options.cover_hint.image.path == "/Books/C/1.jpg"
    and added.options.direct_cover_image.path == "/Books/C/1.jpg",
    "direct recognition is passed to the atomic manga-and-cover library mutation")
expect(#library:list_mangas(connection, UNCATEGORIZED) == 2,
    "zero selected categories remain visible under uncategorized")

local all_before_repeat = #library:list_mangas(connection, ALL)
ui_library:show_add_picker()
browser.last_picker.on_pick(manga_c)
browser.last_recognition.options.on_success{
    manga = manga_c, layout = "chapters", chapters = { chapter_a },
    cover_hint = { chapter = chapter_a },
}
find_item_containing(ui.last_menu.items, "收藏").callback()
ui.last_menu.on_save()
expect(#library:list_mangas(connection, ALL) == all_before_repeat
    and library.mangas[manga_c.path].category_ids.favorites,
    "adding the same path updates one record and merges chosen categories")

ui_library:show_categories()
expect(ui.last_menu.title == "管理分类"
    and ui.last_menu.items[1].text == "新建分类",
    "category management starts with create")
expect(ui.last_menu.items[2].text == "全部漫画（不可修改）"
    and ui.last_menu.items[2].callback == nil
    and ui.last_menu.items[3].text == "未分类（不可修改）"
    and ui.last_menu.items[3].callback == nil,
    "virtual categories are visible and immutable")
ui.last_menu.on_back()
expect(ui.last_menu.title == "漫画分类架", "category management returns home")

ui_library:show_categories()
ui.last_menu.items[1].callback()
expect(ui.last_input.title == "新建分类", "create category opens an input")
local menus_before_input_back = #ui.menus
ui.last_input.on_back()
expect(#ui.menus == menus_before_input_back + 1 and ui.last_menu.title == "管理分类",
    "category input has a back route")

ui_library:show_categories()
ui.last_menu.items[1].callback()
ui.last_input.on_save("  新分类  ")
expect(last_library_call("create_category").name == "新分类",
    "category names are trimmed before persistence")
ui_library:show_categories()
ui.last_menu.items[1].callback()
local category_count_before_duplicate = #library.categories
ui.last_input.on_save("  收藏  ")
expect(#library.categories == category_count_before_duplicate
    and ui.last_message == "分类名称已存在。",
    "duplicate category names show an error without partial changes")

ui_library:show_categories()
local favorites_item = find_item_containing(ui.last_menu.items, "收藏")
favorites_item.callback()
expect(ui.last_input.title == "重命名分类" and ui.last_input.value == "收藏",
    "custom categories can be renamed")
ui.last_input.on_save("  我的收藏  ")
expect(favorites.name == "我的收藏" and last_library_call("rename_category").name == "我的收藏",
    "renaming trims and preserves the category record")

ui_library:show_categories()
local later_item = find_item_containing(ui.last_menu.items, "稍后阅读")
local mangas_before_category_delete = #library:list_mangas(connection, ALL)
later_item.secondary_callback()
expect(last_library_call("remove_category") == nil,
    "category deletion waits for confirmation")
ui.last_confirm.on_confirm()
expect(last_library_call("remove_category").category_id == later.id
    and #library:list_mangas(connection, ALL) == mangas_before_category_delete,
    "confirmed category deletion retains manga records")

local record_a = library:list_mangas(connection, ALL)[1]
if record_a.manga.path ~= manga_a.path then
    for _, record in ipairs(library:list_mangas(connection, ALL)) do
        if record.manga.path == manga_a.path then record_a = record; break end
    end
end
ui_library:show_manage_manga(record_a, ALL)
expect(ui.last_menu.title == "管理漫画 A", "manga management identifies its record")
local manage_back_before = #cover_list.models
ui.last_menu.on_back()
expect(#cover_list.models == manage_back_before + 1
    and cover_list.last_model.title == "全部漫画",
    "manga management returns to the originating list")
local context_item
for _, item in ipairs(cover_list.last_model.items) do
    if item.manga.path == manga_a.path then context_item = item end
end
expect(context_item.layout == "chapters"
    and context_item.cover_hint.chapter.path == chapter_a.path
    and context_item.catalog == nil and context_item.chapters == nil and context_item.images == nil,
    "category rows forward lightweight layout and cover hint without catalog arrays")

ui_library:show_manage_manga(record_a, ALL)
find_item(ui.last_menu.items, "编辑分类").callback()
expect(ui.last_menu.title == "选择分类", "manga management opens category picker")
local set_before_toggle = last_library_call("set_categories")
find_item_containing(ui.last_menu.items, "我的收藏").callback()
expect(last_library_call("set_categories") == set_before_toggle,
    "multi-select edits remain pending until save")
ui.last_menu.on_back()
expect(library.mangas[manga_a.path].category_ids.favorites,
    "canceling multi-select preserves all existing memberships")

ui_library:show_manage_manga(record_a, ALL)
find_item(ui.last_menu.items, "编辑分类").callback()
find_item_containing(ui.last_menu.items, "我的收藏").callback()
find_item_containing(ui.last_menu.items, "新分类").callback()
ui.last_menu.on_save()
local replaced = last_library_call("set_categories")
expect(#replaced.category_ids == 1 and replaced.category_ids[1] == "category-3"
    and library.mangas[manga_a.path].category_ids.favorites == nil
    and library.mangas[manga_a.path].category_ids["category-3"],
    "saving multi-select atomically replaces memberships")

local updated_a = library:list_mangas(connection, ALL)[1]
for _, record in ipairs(library:list_mangas(connection, ALL)) do
    if record.manga.path == manga_a.path then updated_a = record; break end
end
ui_library:show_manage_manga(updated_a, "category-3")
find_item(ui.last_menu.items, "从当前分类移除").callback()
expect(last_library_call("remove_from_category") == nil or
    last_library_call("remove_from_category").path ~= manga_a.path,
    "removing from a category waits for confirmation")
ui.last_confirm.on_confirm()
expect(last_library_call("remove_from_category").category_id == "category-3"
    and cover_list.last_model.title == "新分类",
    "removing only the current relationship returns to that category")
expect(library.mangas[manga_a.path] ~= nil,
    "removing a category relationship keeps the manga on the shelf")

local record_c
for _, record in ipairs(library:list_mangas(connection, ALL)) do
    if record.manga.path == manga_c.path then record_c = record end
end
ui_library:show_manage_manga(record_c, ALL)
find_item(ui.last_menu.items, "刷新封面").callback()
expect(cover_service.last_request.connection == connection
    and cover_service.last_request.record.manga.path == manga_c.path,
    "cover refresh uses the shared cover service")
cover_service.last_request.callbacks.on_ready{ path = "/Books/C/new.jpg" }
expect(cover_list.last_model.title == "全部漫画",
    "cover refresh returns to the originating list")

ui_library:show_manage_manga(record_c, ALL)
find_item(ui.last_menu.items, "重新关联目录").callback()
expect(browser.last_picker.title == "重新关联漫画 C"
    and browser.last_picker.action_text == "重连"
    and browser.last_picker_start == connection.root_path,
    "relink uses an explicit folder-picker action")
browser.last_picker.on_back()
expect(ui.last_menu.title == "管理漫画 C", "relink picker returns to manga management")

ui_library:show_manage_manga(record_c, ALL)
find_item(ui.last_menu.items, "重新关联目录").callback()
browser.last_picker.on_pick(manga_d)
expect(browser.last_recognition.manga == manga_d
    and browser.last_recognition.options.allow_cached == false,
    "relink validates the new directory without cached recognition")
local relink_before_failure = last_library_call("relink_manga")
browser.last_recognition.options.on_failure{ code = "transport" }
expect(last_library_call("relink_manga") == relink_before_failure
    and library.mangas[manga_c.path] ~= nil and library.mangas[manga_d.path] == nil,
    "failed relink recognition makes no partial library change")

ui_library:show_relink_picker(record_c)
browser.last_picker.on_pick(manga_d)
browser.last_recognition.options.on_success{
    manga = manga_d, layout = "direct", images = {},
    cover_hint = { image = { name = "cover.jpg", path = "/Books/D/cover.jpg" } },
}
expect(last_library_call("relink_manga").old_path == manga_c.path
    and last_library_call("relink_manga").recognition.layout == "direct"
    and last_library_call("relink_manga").recognition.cover_hint.image.path == "/Books/D/cover.jpg"
    and last_library_call("relink_manga").recognition.direct_cover_image.path == "/Books/D/cover.jpg"
    and library.mangas[manga_c.path] == nil and library.mangas[manga_d.path] ~= nil,
    "successful recognition commits fresh relink metadata and direct cover exactly once")

local record_d = library.mangas[manga_d.path]
record_d.category_ids.favorites = true
local mangas_before_merge = #library:list_mangas(connection, ALL)
ui_library:show_relink_picker(clone_record(record_d))
browser.last_picker.on_pick(manga_b)
browser.last_recognition.options.on_success{ manga = manga_b, layout = "direct", images = {} }
expect(#library:list_mangas(connection, ALL) == mangas_before_merge - 1
    and library.mangas[manga_b.path].category_ids.favorites,
    "relinking to an existing record merges memberships instead of duplicating manga")

local failed_record = clone_record(library.mangas[manga_b.path])
ui_library:show_category(ALL)
local failed_item
for _, item in ipairs(cover_list.last_model.items) do
    if item.manga.path == manga_b.path then failed_item = item end
end
failed_item.on_open()
browser.last_recognition.options.on_failure{ code = "http", http_status = 404 }
expect(find_item_containing(cover_list.last_model.items, "路径不可用") ~= nil,
    "a failed open marks the row unavailable without removing it")
expect(library.mangas[manga_b.path] ~= nil,
    "an inaccessible path remains available for recovery actions")
local unavailable_item = find_item_containing(cover_list.last_model.items, "路径不可用")
unavailable_item.on_action()
expect(find_item(ui.last_menu.items, "重新关联目录")
    and find_item(ui.last_menu.items, "从漫画书架移除"),
    "an inaccessible record still exposes relink and local delete")

ui.last_menu.on_back()
unavailable_item = find_item_containing(cover_list.last_model.items, "路径不可用")
unavailable_item.on_open()
local successful_open = { manga = manga_b, layout = "direct", images = {} }
browser.last_recognition.options.on_success(successful_open)

failed_record = clone_record(library.mangas[manga_b.path])
ui_library:show_manage_manga(failed_record, ALL)
find_item(ui.last_menu.items, "从漫画书架移除").callback()
local deletes_before_confirm = last_library_call("remove_manga")
expect(not deletes_before_confirm or deletes_before_confirm.path ~= manga_b.path,
    "whole-shelf removal waits for confirmation")
ui.last_confirm.on_confirm()
expect(last_library_call("remove_manga").path == manga_b.path
    and library.mangas[manga_b.path] == nil
    and cover_list.last_model.title == "全部漫画",
    "whole-shelf removal deletes only the local record and returns to all manga")

expect(remote_mutations.delete == 0 and remote_mutations.MOVE == 0 and remote_mutations.PUT == 0,
    "category, manga, cover, delete, and relink UI flows must never mutate WebDAV")

local integration_connection = {
    server_url = "https://nas.example/dav",
    username = "reader",
    password = "not-persisted",
    root_path = "/Books",
}
local integration_browser_path = "/Books/RemoteShelf"
local integration_settings = {
    get_connection = function() return integration_connection end,
    is_configured = function() return true end,
    get_browser_path = function() return integration_browser_path end,
    set_browser_path = function(_self, path)
        integration_browser_path = path
        return true
    end,
    flush = function() end,
}
local integration_manga = {
    name = "分类连载", path = "/Books/分类连载", is_folder = true,
}
local integration_chapter = {
    name = "第1话", path = "/Books/分类连载/第1话", is_folder = true,
}
local integration_direct = {
    name = "分类单行本", path = "/Books/分类单行本", is_folder = true,
}
local integration_direct_image = {
    name = "001.jpg", path = "/Books/分类单行本/001.jpg", is_file = true,
}
local integration_record = {
    key = "integration-manga",
    manga = integration_manga,
    category_ids = { integration = true },
    layout = "chapters",
    cover_hint = { chapter = integration_chapter },
}
local integration_direct_record = {
    key = "integration-direct",
    manga = integration_direct,
    category_ids = { integration = true },
    layout = "direct",
}
local integration_library = {
    ALL = ALL,
    UNCATEGORIZED = UNCATEGORIZED,
    list_categories = function()
        return {{ id = "integration", name = "连载分类" }}
    end,
    list_mangas = function(_self, _connection, view_id)
        if view_id == "integration" or view_id == ALL then
            return { integration_record, integration_direct_record }
        end
        return {}
    end,
}
local integration_cover_list = { models = {} }
function integration_cover_list:show(model)
    self.last_model = model
    self.models[#self.models + 1] = model
end
local integration_browser_ui = { menus = {}, messages = {} }
function integration_browser_ui:show_menu(model)
    self.last_menu = model
    self.menus[#self.menus + 1] = model
end
function integration_browser_ui:show_busy()
    return { close = function() end }
end
function integration_browser_ui:show_info(message)
    self.messages[#self.messages + 1] = message
end
local integration_list_folders = 0
local function test_directory(folders, images, documents)
    local function index(entries)
        return {
            count = function() return #entries end,
            get = function(_, position) return entries[position] end,
        }
    end
    folders, images, documents = folders or {}, images or {}, documents or {}
    local directory = {
        folder_index = index(folders), image_index = index(images),
        document_index = index(documents),
    }
    function directory:folders() return self.folder_index end
    function directory:images() return self.image_index end
    function directory:documents() return self.document_index end
    function directory:file_count() return #images + #documents end
    function directory:close() self.closed = true end
    return directory
end
local integration_directory_store = {}
function integration_directory_store:load(path, callbacks)
    local directory
    if path == integration_manga.path then
        directory = test_directory({ integration_chapter })
    elseif path == integration_direct.path then
        directory = test_directory({}, { integration_direct_image })
    elseif path == "/Books/BookshelfReturn" then
        integration_list_folders = integration_list_folders + 1
        directory = test_directory()
    else
        error("category integration recognizes only its manga paths")
    end
    callbacks.on_ready(directory)
    return { cancel = function() end }
end
local integration_browser
integration_browser = Browser:new{
    settings = integration_settings,
    settings_ui = { show_connection = function() end },
    directory_store = integration_directory_store,
    ui = integration_browser_ui,
    network_manager = { willRerunWhenConnected = function() return false end },
    open_reader = function(context) integration_browser.opened = context end,
}
local integration_library_ui = UiLibrary:new{
    settings = integration_settings,
    library = integration_library,
    cover_service = { refresh = function() end },
    cover_grid = integration_cover_list,
    browser = integration_browser,
    ui = integration_browser_ui,
}

integration_library_ui:show_category("integration")
local category_models_before_open = #integration_cover_list.models
local original_browser_path = integration_browser_path
integration_cover_list.last_model.items[1].on_open()
expect(integration_browser_ui.last_menu.title == integration_manga.name
    and type(integration_browser_ui.last_menu.on_back) == "function",
    "real Browser recognition presents a chapter menu for categorized manga")
integration_browser_ui.last_menu.on_refresh()
expect(integration_browser_ui.last_menu.title == integration_manga.name
    and next(integration_browser.manga_return_paths) == nil,
    "refreshing a categorized chapter menu retains source context without path state")
integration_browser_ui.last_menu.on_back()
expect(#integration_cover_list.models == category_models_before_open + 1
    and integration_cover_list.last_model.title == "连载分类",
    "chapter-menu back returns to the original custom category cover list")
expect(integration_browser_path == original_browser_path
    and next(integration_browser.manga_return_paths) == nil
    and integration_list_folders == 0,
    "category presentation does not pollute or browse the WebDAV return path")

local direct_category_models_before_open = #integration_cover_list.models
local integration_direct_item
for _, item in ipairs(integration_cover_list.last_model.items) do
    if item.manga.path == integration_direct.path then integration_direct_item = item end
end
integration_direct_item.on_open()
expect(integration_browser.opened and integration_browser.opened.layout == "direct"
    and integration_browser.opened.source_context
    and integration_browser.opened.source_context.source == "category"
    and type(integration_browser.opened.source_context.on_return) == "function",
    "direct reader context retains its explicit category source")
expect(#integration_cover_list.models == direct_category_models_before_open
    and integration_cover_list.last_model.title == "连载分类"
    and integration_browser_path == original_browser_path
    and next(integration_browser.manga_return_paths) == nil,
    "direct reader opens over the original category without WebDAV return-path changes")

integration_browser.manga_return_paths[integration_manga.path] = "/Books/BookshelfReturn"
integration_browser:present_manga{
    manga = integration_manga,
    layout = "chapters",
    chapters = { integration_chapter },
    cover_hint = { chapter = integration_chapter },
}
integration_browser_ui.last_menu.on_back()
expect(integration_browser_path == "/Books/BookshelfReturn"
    and integration_list_folders == 1,
    "presentation without a source context preserves the bookshelf return-path behavior")

local presented = browser.presentations[#browser.presentations]
expect(presented and presented.result == successful_open
    and presented.source_context.source == "category"
    and type(presented.source_context.on_return) == "function",
    "a successful library-row recognition uses the public browser presentation behavior")

local epoch_connection = {
    server_url = "https://epoch.example/dav", username = "reader", root_path = "/Books",
}
local switched_connection = {
    server_url = "https://switched.example/dav", username = "reader", root_path = "/Books",
}
local active_epoch_connection = epoch_connection
local epoch_record = {
    key = "epoch", manga = { name = "Epoch", path = "/Books/Epoch", is_folder = true },
    category_ids = {}, layout = "direct",
}
local epoch_library = {
    ALL = ALL, UNCATEGORIZED = UNCATEGORIZED, add_calls = 0, relink_calls = 0,
    list_categories = function() return {} end,
    list_mangas = function() return { epoch_record } end,
    add_manga = function(self) self.add_calls = self.add_calls + 1; return epoch_record end,
    relink_manga = function(self) self.relink_calls = self.relink_calls + 1; return epoch_record end,
}
local epoch_ui = { menus = {}, messages = {} }
function epoch_ui:show_menu(model) self.last_menu = model; self.menus[#self.menus + 1] = model end
function epoch_ui:show_info(message) self.messages[#self.messages + 1] = message end
local epoch_cover_list = { shows = 0, cancels = 0 }
function epoch_cover_list:show(model) self.shows = self.shows + 1; self.last_model = model end
function epoch_cover_list:cancel() self.cancels = self.cancels + 1; return true end
local refresh_requests = {}
local epoch_cover_service = {}
function epoch_cover_service:refresh(_connection, _record, callbacks)
    local request = { callbacks = callbacks, canceled = false }
    refresh_requests[#refresh_requests + 1] = request
    return { cancel = function()
        request.canceled = true
        callbacks.on_ready{ name = "reentrant.jpg", path = "/Books/Epoch/reentrant.jpg" }
    end }
end
local epoch_browser = { recognition_requests = {}, picker_requests = {}, current_path = "/Books" }
function epoch_browser:cover_context()
    return { identity = "https://epoch.example/dav\0reader\0/Books", chapters = {}, images = {} }
end
function epoch_browser:show_library() self.library_returns = (self.library_returns or 0) + 1 end
function epoch_browser:show_folder_picker(model)
    local request = { model = model, canceled = false }
    self.picker_requests[#self.picker_requests + 1] = request
    self.last_picker = model
    return { cancel = function() request.canceled = true end }
end
function epoch_browser:identify_manga(manga, options)
    local request = { manga = manga, options = options, canceled = false }
    self.recognition_requests[#self.recognition_requests + 1] = request
    return { cancel = function() request.canceled = true end }
end
function epoch_browser:present_manga() self.presentations = (self.presentations or 0) + 1 end

local epoch_ui_library = UiLibrary:new{
    settings = { get_connection = function() return active_epoch_connection end },
    library = epoch_library,
    cover_service = epoch_cover_service,
    cover_grid = epoch_cover_list,
    browser = epoch_browser,
    ui = epoch_ui,
}

epoch_ui_library:show_manage_manga(epoch_record, ALL)
find_item(epoch_ui.last_menu.items, "刷新封面").callback()
local refresh_request = refresh_requests[#refresh_requests]
epoch_ui_library:show_home()
expect(refresh_request.canceled and epoch_ui.last_menu.title == "漫画分类架"
    and epoch_cover_list.shows == 0,
    "leaving during refresh invalidates the epoch before reentrant external cancellation")
refresh_request.callbacks.on_ready{ name = "late.jpg", path = "/Books/Epoch/late.jpg" }
expect(epoch_ui.last_menu.title == "漫画分类架" and epoch_cover_list.shows == 0,
    "a refresh completion after leaving cannot reopen the old category")

epoch_ui_library:show_add_picker()
epoch_browser.last_picker.on_pick({ name = "Added", path = "/Books/Added", is_folder = true })
local late_add = epoch_browser.recognition_requests[#epoch_browser.recognition_requests]
active_epoch_connection = switched_connection
late_add.options.on_success{
    manga = late_add.manga, layout = "direct",
    cover_hint = { image = { name = "1.jpg", path = "/Books/Added/1.jpg" } },
}
expect(epoch_ui.last_menu.title ~= "选择分类" and epoch_library.add_calls == 0,
    "an add completion from a different connection identity cannot navigate or mutate")
epoch_ui_library:cancel()

active_epoch_connection = epoch_connection
epoch_ui_library:show_relink_picker(epoch_record)
epoch_browser.last_picker.on_pick({ name = "Moved", path = "/Books/Moved", is_folder = true })
local late_relink = epoch_browser.recognition_requests[#epoch_browser.recognition_requests]
epoch_ui_library:show_home()
late_relink.options.on_success{ manga = late_relink.manga, layout = "chapters",
    cover_hint = { chapter = { name = "第1话", path = "/Books/Moved/第1话" } } }
expect(late_relink.canceled and epoch_library.relink_calls == 0
    and epoch_ui.last_menu.title == "漫画分类架",
    "leaving during relink cancels the handle and suppresses late mutation/navigation")

epoch_ui_library:show_add_picker()
epoch_browser.last_picker.on_pick({ name = "Canceled", path = "/Books/Canceled", is_folder = true })
local canceled_add = epoch_browser.recognition_requests[#epoch_browser.recognition_requests]
epoch_ui_library:cancel()
canceled_add.options.on_success{ manga = canceled_add.manga, layout = "direct",
    cover_hint = { image = { name = "1.jpg", path = "/Books/Canceled/1.jpg" } } }
expect(canceled_add.canceled and epoch_library.add_calls == 0,
    "teardown cancellation suppresses a late add completion")

local owned_picker_connection = {
    server_url = "https://picker.example/dav", username = "reader", root_path = "/Books",
}
local owned_picker_settings = {
    get_connection = function() return owned_picker_connection end,
    is_configured = function() return true end,
    get_browser_path = function() return "/Books" end,
    set_browser_path = function() return true end,
    flush = function() end,
}
local owned_picker_record = {
    key = "owned-picker",
    manga = { name = "原漫画", path = "/Books/原漫画", is_folder = true },
    category_ids = {}, layout = "direct",
}
local owned_picker_library = {
    ALL = ALL,
    UNCATEGORIZED = UNCATEGORIZED,
    list_categories = function() return {} end,
    list_mangas = function() return { owned_picker_record } end,
}
local owned_picker_ui = { menus = {}, messages = {} }
function owned_picker_ui:show_menu(model)
    self.last_menu = model
    self.menus[#self.menus + 1] = model
end
function owned_picker_ui:show_busy()
    return { close = function() end }
end
function owned_picker_ui:show_info(message)
    self.messages[#self.messages + 1] = message
end
local owned_picker_tasks = {}
local owned_picker_directory_store = {}
function owned_picker_directory_store:load(path, callbacks)
    local task = { canceled = false }
    task.work = function()
        if path == "/Books" then
            return test_directory({
                { name = "子目录", path = "/Books/子目录", is_folder = true },
            })
        elseif path == "/Books/子目录" then
            return test_directory({
                { name = "孙目录", path = "/Books/子目录/孙目录", is_folder = true },
            })
        end
        error("unexpected picker path")
    end
    task.done = function(ok, result, err)
        if task.canceled then return end
        if ok then callbacks.on_ready(result) else callbacks.on_error(err) end
    end
    owned_picker_tasks[#owned_picker_tasks + 1] = task
    return { cancel = function() task.canceled = true end }
end
local owned_picker_browser = Browser:new{
    settings = owned_picker_settings,
    settings_ui = { show_connection = function() end },
    directory_store = owned_picker_directory_store,
    ui = owned_picker_ui,
    network_manager = { willRerunWhenConnected = function() return false end },
    open_reader = function() end,
}
local owned_picker_cover_list = { cancels = 0 }
function owned_picker_cover_list:cancel()
    self.cancels = self.cancels + 1
    return true
end
local owned_picker_ui_library = UiLibrary:new{
    settings = owned_picker_settings,
    library = owned_picker_library,
    cover_service = { refresh = function() end },
    cover_grid = owned_picker_cover_list,
    browser = owned_picker_browser,
    ui = owned_picker_ui,
}
local function complete_owned_picker(task)
    local ok, result = pcall(task.work)
    task.done(ok, ok and result or nil, ok and nil or result)
end

owned_picker_ui_library:show_add_picker()
complete_owned_picker(owned_picker_tasks[1])
owned_picker_ui.last_menu.items[1].callback()
local add_descendant_task = owned_picker_tasks[2]
owned_picker_ui_library:show_home()
local add_home_before_late = owned_picker_ui.last_menu
complete_owned_picker(add_descendant_task)
local add_descendant_owned = add_descendant_task.canceled
    and owned_picker_ui.last_menu == add_home_before_late
    and owned_picker_ui.last_menu.title == "漫画分类架"

owned_picker_ui_library:show_relink_picker(owned_picker_record)
complete_owned_picker(owned_picker_tasks[3])
owned_picker_ui.last_menu.items[1].callback()
complete_owned_picker(owned_picker_tasks[4])
owned_picker_ui.last_menu.on_back()
local relink_parent_task = owned_picker_tasks[5]
owned_picker_ui_library:show_home()
local relink_home_before_late = owned_picker_ui.last_menu
complete_owned_picker(relink_parent_task)
local relink_parent_owned = relink_parent_task.canceled
    and owned_picker_ui.last_menu == relink_home_before_late
    and owned_picker_ui.last_menu.title == "漫画分类架"
expect(add_descendant_owned and relink_parent_owned,
    "real recursive add/relink picker requests transfer latest handle ownership before leave")

print(("library_ui_spec: %d checks"):format(checks))
