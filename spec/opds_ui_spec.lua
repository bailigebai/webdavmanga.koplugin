local Ui = require("webdavmanga.ui_opds")

local shown = {}
local ui = {
    show_menu = function(_self, model) shown[#shown + 1] = model end,
    show_info = function() end,
}
local feed = {
    title = "根目录",
    entries = {
        { id = "series", name = "系列", kind = "series", href = "https://x/series" },
    },
}
local volume_feed = {
    title = "系列",
    entries = {
        { id = "volume", name = "第 1 卷", kind = "volume", href = "https://x/volume" },
    },
}
local pages_feed = {
    title = "第 1 卷",
    entries = {
        { id = "p1", name = "1.jpg", kind = "page", image_url = "https://x/1.jpg" },
        { id = "p2", name = "2.jpg", kind = "page", image_url = "https://x/2.jpg" },
    },
}
local catalog = {
    list = function() return {{ id = "c1", name = "Komga", url = "https://x/root" }} end,
    active = function() return { id = "c1", name = "Komga", url = "https://x/root" } end,
    set_active = function() return true end,
    fetch = function(_self, _id, url)
        if url:match("/series$") then return volume_feed end
        if url:match("/volume$") then return pages_feed end
        return feed
    end,
}
local opened
local reader = { open = function(_self, context) opened = context end }
local adapter = Ui:new{ catalog = catalog, ui = ui, reader = reader,
    async = { run = function(work, done)
        local ok, value = pcall(work); done(ok, value); return {cancel=function() end}
    end } }
adapter:show_home()
assert(#shown == 1 and shown[1].items[1].text == "系列")
shown[1].items[1].callback()
assert(#shown == 2 and shown[2].items[1].text == "第 1 卷")
shown[2].items[1].callback()
assert(#shown == 3 and shown[3].items[1].text == "打开本卷（2 页）")
shown[3].items[1].callback()
assert(opened and opened.chapter_index:count() == 2)
assert(opened.chapter_index:get(1).opds_page == true)
assert(opened.connection.kind == "opds"
    and opened.connection.server_url:match("^opds://source/")
    and opened.manga.opds_catalog_id == "c1"
    and opened.chapter_index:get(1).opds_source_id == "c1",
    "OPDS reading must persist a safe source identity and resolve page auth by source id")

print("opds_ui_spec: passed")
