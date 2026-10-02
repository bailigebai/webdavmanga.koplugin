local Reader = require("webdavmanga.ui_reader")

local opds_pages = {
    eligible = function(_self, image) return image.opds_page == true end,
}
local reader = Reader:new{
    loader = { identity = "test" },
    progress = { save = function() end },
    state = {},
    settings = {
        get_connection = function() return { kind = "webdav" } end,
    },
    cache = { key_for = function() return "key" end },
    ui = {},
    open_chapter = function() end,
    opds_pages = opds_pages,
    memory_pages = { eligible = function() return false end },
}
reader.reader_settings = { image_engine = "default" }
reader.session_image_engine = "default"
assert(reader:_memory_eligible({ opds_page = true, name = "1.jpg" }) == true)
assert(reader:_page_source({ opds_page = true, name = "1.jpg" }) == opds_pages)
assert(reader:_page_source({ name = "1.jpg" }) == nil)

print("opds_reader_integration_spec: passed")
