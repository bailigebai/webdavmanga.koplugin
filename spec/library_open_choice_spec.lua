local UiLibrary = require("webdavmanga.ui_library")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local connection = { server_url = "https://nas", username = "reader", root_path = "/漫画" }
local manga = { name = "漫画 A", path = "/漫画/A", is_folder = true }
local chapter_a = { name = "第1话", path = "/漫画/A/1", is_folder = true }
local chapter_b = { name = "第2话", path = "/漫画/A/2", is_folder = true }
local record = { key = "a", manga = manga, category_ids = { shelf = true }, layout = "chapters" }

local library = {
    ALL = "all", UNCATEGORIZED = "uncategorized",
    list_categories = function() return { { id = "shelf", name = "分类" } } end,
    list_mangas = function() return { record } end,
}
local history = {
    manga = manga, chapter = chapter_b, index = 7, total = 20,
    image_path = chapter_b.path .. "/007.jpg", layout = "chapters",
}
local progress = { list_history = function() return { history } end }
local grid = { shows = 0, leaves = 0 }
function grid:show(model) self.model = model; self.shows = self.shows + 1 end
function grid:leave_for(callback) self.leaves = self.leaves + 1; callback(); return true end
function grid:cancel() self.canceled = (self.canceled or 0) + 1; return true end

local browser = { resume_calls = 0, identify_calls = 0, chapter_calls = 0, opened = {} }
function browser:prepare_resume(received, callbacks)
    self.resume_calls = self.resume_calls + 1
    self.resume_record = received
    self.resume_callbacks = callbacks
    return { cancel = function() end }
end
function browser:identify_manga(received, options)
    self.identify_calls = self.identify_calls + 1
    self.identify_manga_value = received
    self.identify_options = options
    return { cancel = function() end }
end
function browser:prepare_chapter(received_manga, received_chapter, _recognition, callbacks)
    self.chapter_calls = self.chapter_calls + 1
    self.chapter_manga = received_manga
    self.chapter_value = received_chapter
    self.chapter_callbacks = callbacks
    return { cancel = function() end }
end
function browser:open_prepared_reader(context) self.opened[#self.opened + 1] = context end

local ui = { choices = {}, menus = {}, messages = {} }
function ui:show_choice(model) self.choice = model; self.choices[#self.choices + 1] = model end
function ui:close_choice() self.choice_closed = (self.choice_closed or 0) + 1 end
function ui:show_menu(model) self.menu = model; self.menus[#self.menus + 1] = model end
function ui:show_info(message) self.messages[#self.messages + 1] = message end

local settings = { get_connection = function() return connection end }
local shelf = UiLibrary:new{
    settings = settings,
    library = library,
    progress = progress,
    cover_service = { refresh = function() end },
    cover_grid = grid,
    browser = browser,
    ui = ui,
}

shelf:show_category("shelf")
expect(grid.model and grid.model.items[1].on_open, "category opens through the cover grid")
grid.model.items[1].on_open()
expect(browser.resume_calls == 0 and browser.identify_calls == 0,
    "category tap waits for an explicit open choice")
ui.choice.buttons.continue()
expect(browser.resume_calls == 1 and browser.resume_record == history,
    "continue uses the saved history record")
local resume_context = { chapter = chapter_b, chapter_index = 7 }
browser.resume_callbacks.on_ready(resume_context)
expect(#browser.opened == 1 and browser.opened[1] == resume_context and grid.leaves == 1,
    "successful resume closes the grid before opening the reader")

shelf:show_category("shelf")
shelf.cover_grid.model.items[1].on_open()
ui.choice.buttons.chapters()
expect(browser.identify_calls == 1 and browser.chapter_calls == 0,
    "chapter selection identifies the manga before loading a chapter")
local function chapter_index(entries)
    return {
        count = function() return #entries end,
        get = function(_, index) return entries[index] end,
    }
end
browser.identify_options.on_success{
    manga = manga, layout = "chapters", chapters_index = chapter_index({ chapter_a, chapter_b }),
}
expect(ui.menu and ui.menu.items[1].text == chapter_a.name,
    "chapter choice displays the indexed chapter entries")
ui.menu.items[2].callback()
expect(browser.chapter_calls == 1 and browser.chapter_value == chapter_b,
    "selecting a chapter prepares that chapter")
local chapter_context = { chapter = chapter_b, chapter_index = 1 }
browser.chapter_callbacks.on_ready(chapter_context)
expect(#browser.opened == 2 and browser.opened[2] == chapter_context and grid.leaves == 2,
    "selected chapter closes the grid before opening the reader")

print(("library_open_choice_spec: %d checks"):format(checks))
