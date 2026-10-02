local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local captured_menu
local opened
local settings = {
    get_connection = function()
        return { kind = "webdav", root_path = "/Books" }
    end,
}
local ui = {
    show_menu = function(_self, model) captured_menu = model end,
    show_info = function() end,
}
local Browser = require("webdavmanga.ui_browser")
local browser = Browser:new{
    settings = settings,
    settings_ui = {},
    directory_store = {},
    ui = ui,
    open_reader = function() error("documents must not enter image reader") end,
    open_document = function(entry)
        opened = entry
        return true
    end,
}
local documents = {
    count = function() return 1 end,
    get = function() return {
        path = "/Books/A/book.pdf", name = "book.pdf", is_file = true,
        file_kind = "document",
    } end,
}
local empty = { count = function() return 0 end }
local result, err = browser:_recognize_directory(
    { name = "A", path = "/Books/A" },
    { folders = empty, images = empty, documents = documents })
expect(result and not err and result.layout == "documents",
    "a document-only directory should be recognized as a document shelf")
browser:present_manga(result)
expect(captured_menu and #captured_menu.items == 1
    and captured_menu.items[1].text == "book.pdf",
    "document shelves should show document entries instead of image chapters")
captured_menu.items[1].callback()
expect(opened and opened.path == "/Books/A/book.pdf"
    and opened.file_kind == "document",
    "selecting a document should call the native document handoff")

-- A manga directory may contain image pages and an electronic-book file side
-- by side.  It must expose both entries instead of silently choosing images
-- and hiding documents.
local mixed_images = {
    count = function() return 1 end,
    get = function() return {
        path = "/Books/Mixed/page.jpg", name = "page.jpg", is_file = true,
        file_kind = "image",
    } end,
}
local mixed_folders = { count = function() return 0 end }
local mixed_documents = {
    count = function() return 1 end,
    get = function() return {
        path = "/Books/Mixed/book.pdf", name = "book.pdf", is_file = true,
        file_kind = "document",
    } end,
}
local mixed_result = assert(browser:_recognize_directory(
    { name = "Mixed", path = "/Books/Mixed" },
    { folders = mixed_folders, images = mixed_images, documents = mixed_documents }))
expect(mixed_result.layout == "mixed" and mixed_result.image_index == mixed_images
    and mixed_result.documents_index == mixed_documents,
    "mixed directories should retain both image and document indexes")
captured_menu = nil
browser:present_manga(mixed_result)
expect(captured_menu and #captured_menu.items == 2
    and captured_menu.items[1].text:find("图片", 1, true) ~= nil
    and captured_menu.items[2].text == "book.pdf",
    "mixed directories should show an image entry and document entries")
captured_menu.items[2].callback()
expect(opened and opened.path == "/Books/Mixed/book.pdf",
    "mixed directory documents should still use native document handoff")

local library_items = browser:_directory_items(
    "/Books/Mixed", mixed_folders, 1, empty, mixed_documents)
expect(library_items[4] and library_items[4].text == "当前文件夹（文件）"
    and type(library_items[4].secondary_callback) == "function"
    and library_items[5] and library_items[5].text == "← 返回上一级",
    "a document-only directory must place its current-folder action before back")

print(("document_browser_spec: %d checks"):format(checks))
