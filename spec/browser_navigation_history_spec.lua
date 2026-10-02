local Browser = require("webdavmanga.ui_browser")
local checks = 0
local function expect(value, message) checks = checks + 1; if not value then error(message) end end
local function index_of(entries)
    return { count = function() return #entries end, get = function(_, i) return entries[i] end,
        find = function(_, path) for i, e in ipairs(entries) do if e.path == path then return i end end end,
        iterator = function(_, first, limit) local out={}; first=first or 1; limit=limit or #entries; for i=first,math.min(#entries,first+limit-1) do out[#out+1]=entries[i] end; return out,first+#out end,
        window = function(_, center, radius) local out={}; for i=math.max(1,center-radius),math.min(#entries,center+radius) do out[#out+1]=entries[i] end; return out end }
end
local direct_images = index_of({ { name = "001.jpg", path = "/漫画/直/001.jpg", is_file = true } })
local chapter_folder = { name = "第1话", path = "/漫画/章/第1话", is_folder = true }
local chapter_folders = index_of({ chapter_folder })
local chapter_images = index_of({ { name = "001.jpg", path = chapter_folder.path .. "/001.jpg", is_file = true } })
local dirs = {
    ["/漫画/直"] = { folders = index_of({}), images = function() return direct_images end, close = function() end },
    ["/漫画/章"] = { folders = function() return chapter_folders end, images = index_of({}), close = function() end },
    [chapter_folder.path] = { folders = index_of({}), images = function() return chapter_images end, close = function() end },
}
for _, d in pairs(dirs) do if type(d.folders) ~= "function" then local f=d.folders; d.folders=function() return f end end; if type(d.images) ~= "function" then local i=d.images; d.images=function() return i end end end
local ds = { load = function(_, path, cb) local d=dirs[path]; if d then cb.on_ready(d) else cb.on_error({code="transport"}) end; return {cancel=function() end} end, invalidate=function() end, cancel_all=function() end }
local connection={server_url="https://nas",username="u",root_path="/漫画"}
local settings={get_connection=function() return connection end,is_configured=function() return true end,get_browser_path=function() return "/漫画" end,set_browser_path=function() return true end,flush=function() end}
local ui={show_menu=function(self,m) self.menu=m end,show_info=function(self,message) self.message=message end,show_busy=function() return {close=function() end} end,close_menu=function() end}
local progress={list_history=function() return {} end,remove_history=function() return true end}
local opened; local browser=Browser:new{settings=settings,settings_ui={show_connection=function() end},directory_store=ds,ui=ui,progress=progress,open_reader=function(c) opened=c end}
local direct_result; browser:identify_manga({name="直",path="/漫画/直",is_folder=true},{on_success=function(r) direct_result=r end})
expect(direct_result and direct_result.layout=="direct" and direct_result.chapter_index==direct_images, "direct recognition uses the image index")
local chapter_result; browser:identify_manga({name="章",path="/漫画/章",is_folder=true},{on_success=function(r) chapter_result=r end})
expect(chapter_result and chapter_result.layout=="chapters" and chapter_result.chapters_index==chapter_folders, "chapter recognition uses the folder index")
local manga={name="章",path="/漫画/章",is_folder=true}; local record={manga=manga,chapter=chapter_folder,index=1,total=1,layout="chapters"}
browser:prepare_resume(record,{on_ready=function(c) opened=c end})
expect(opened and opened.chapter_index==chapter_images and opened.chapters_index==chapter_folders and opened.images==nil and opened.chapters==nil, "resume opens with lightweight index context")
expect(browser:open_prepared_reader(opened)==true, "resume context can be handed to reader")
local persisted={catalog={images={bad=true}},images={{name="bad.jpg",path="/private/bad.jpg"}},chapters={{name="bad",path="/private/bad",is_folder=true}}}
local context=browser:cover_context(manga,chapter_folder)
expect(context.images==nil and context.chapters==nil and persisted.catalog.images.bad==true, "browser never reads or writes persisted catalog arrays")
local history_events = {}
local history_grid = {
    show = function(self, model) self.model = model end,
    leave_for = function(_self, callback)
        history_events[#history_events + 1] = "leave"
        callback()
        return true
    end,
}
browser.cover_grid = history_grid
browser.progress.list_history = function() return { record } end
browser.open_reader = function()
    history_events[#history_events + 1] = "open"
end
browser:show_history()
expect(history_grid.model and history_grid.model.items[1].on_open,
    "history should render through the fullscreen cover grid")
history_grid.model.items[1].on_open()
expect(table.concat(history_events, ",") == "leave,open",
    "history must close its fullscreen grid before opening the reader")
local managed_history
local managed_batch
browser.library = { get_manga = function() return {
    is_read = true, local_deleted = true,
    archived_cover_path = "/archive/cover.jpg",
} end }
browser.manage_history = function(value) managed_history = value end
browser.manage_history_batch = function(values) managed_batch = values end
history_events = {}
browser:show_history()
local deleted_item = history_grid.model.items[1]
expect(deleted_item.is_read == true and deleted_item.local_deleted == true
    and deleted_item.local_cover_path == "/archive/cover.jpg",
    "history forwards retained cover and read metadata to the cover grid")
expect(history_grid.model.allow_multi_select == true
    and type(history_grid.model.on_batch_action) == "function",
    "history exposes a guarded multi-select batch action")
deleted_item.on_open()
expect(#history_events == 0 and ui.message:find("文件已删除", 1, true),
    "opening a deleted local history record never touches its former directory")
deleted_item.on_action()
expect(managed_history == record,
    "history long press routes to the shared rating and read management menu")
history_grid.model.on_batch_action({ deleted_item })
expect(managed_batch and managed_batch[1] == record,
    "history batch action forwards the selected history records")
print(("browser_navigation_history_spec: %d checks"):format(checks))
