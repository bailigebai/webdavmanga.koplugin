local Browser = require("webdavmanga.ui_browser")
local Cover = require("webdavmanga.cover")
local checks = 0
local function expect(value, message) checks = checks + 1; if not value then error(message) end end
local function index(entries)
    return { count=function() return #entries end, get=function(_,i) return entries[i] end,
        find=function(_,p) for i,e in ipairs(entries) do if e.path==p then return i end end end }
end
local connection = { server_url="https://nas", username="reader", root_path="/漫画" }
local settings = { get_connection=function() return connection end, is_configured=function() return true end,
    get_browser_path=function() return "/漫画" end, set_browser_path=function() return true end, flush=function() end }
local folders = index({ { name="书", path="/漫画/书", is_folder=true } })
local images = index({ { name="001.jpg", path="/漫画/书/001.jpg", is_file=true } })
local directory = { folders=function() return folders end, images=function() return images end, close=function() end }
local loads, invalidations = 0, 0
local directory_store = {
    load=function(_, path, callbacks) loads=loads+1; callbacks.on_ready(directory); return { cancel=function() end } end,
    invalidate=function() invalidations=invalidations+1 end, cancel_all=function() end,
}
local ui = { show_menu=function(self, model) self.menu=model end, show_info=function() end,
    show_busy=function() return { close=function() end } end, close_menu=function() end }
local browser = Browser:new{ settings=settings, settings_ui={ show_connection=function() end },
    directory_store=directory_store, ui=ui, open_reader=function() end }
local recognized
browser:identify_manga({ name="书", path="/漫画/书", is_folder=true }, { on_success=function(r) recognized=r end })
expect(loads == 1 and recognized and recognized.chapter_index == images, "browser uses the injected DirectoryStore index")
browser:show_library(false, "/漫画")
local refresh
for _, item in ipairs(ui.menu.items) do if item.text == "↻ 刷新" then refresh = item end end
expect(refresh and refresh.callback, "refresh is a real visible action")
refresh.callback(); expect(invalidations == 1, "refresh invalidates the active directory only")
local library = { get_cover=function() end, set_cover=function() return true end, set_no_cover=function() return true end }
local cover = Cover:new{ library=library, directory_store=directory_store }
expect(cover.directory_store == directory_store, "cover service receives the same DirectoryStore instance")
print(("plugin_integration_spec: %d checks"):format(checks))
