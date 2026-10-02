local Progress = require("webdavmanga.progress")
local Cover = require("webdavmanga.cover")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local stored = {}
local progress = Progress:new{
    store = {
        readSetting = function(_, key, default) return stored[key] or default end,
        saveSetting = function(_, key, value) stored[key] = value end,
    },
    md5 = function(value) return value end,
    clock = function() return 1 end,
}
local connection = { server_url = "http://nas", username = "reader", root_path = "/Books" }
local page = {
    name = "00001.png", path = "/Books/comic.pdf#mupdf/1", is_file = true,
    size = 3, format = "png", mupdf_page = 1, mupdf_source_size = 100,
    mupdf_remote_path = "/Books/comic.pdf",
}
local manga = { name = "comic.pdf", path = "/Books/comic.pdf", is_file = true }
progress:save("chapter", page.path, 1, "whole", {
    connection = connection, manga = manga, chapter = manga, total = 3,
    layout = "mupdf_pages", cover_hint = { image = page },
})
local history = progress:list_history(connection)[1]
expect(history.layout == "mupdf_pages", "history must retain MuPDF layout")
expect(history.cover_hint.image.mupdf_page == 1
    and history.cover_hint.image.mupdf_remote_path == "/Books/comic.pdf",
    "history cover must retain MuPDF source fields")

local resolved
local cover = Cover:new{
    library = { get_cover = function() end, set_cover = function() return true end },
    directory_store = {},
}
cover:resolve(connection, history, { on_ready = function(image) resolved = image end })
expect(resolved and resolved.mupdf_page == 1
    and resolved.mupdf_source_size == 100,
    "cover resolver must accept and return MuPDF page covers")
print(("rebuild_0375_mupdf_history_cover_spec: %d checks"):format(checks))
