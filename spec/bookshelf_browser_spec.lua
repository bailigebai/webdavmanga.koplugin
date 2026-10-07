local Browser=require("webdavmanga.ui_browser")
local Settings=require("webdavmanga.settings")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local saved={};local settings=Settings:new{store={readSetting=function(_,k,d) return saved[k] or d end,
    saveSetting=function(_,k,v) saved[k]=v end,flush=function() end}}
settings:set_connection{server_url="http://nas",username="u",password="p",root_path="/m"}
local function index(items) return {count=function() return #items end,get=function(_,i) return items[i] end,
    iterator=function(_,first,limit) local out={};for i=first,math.min(#items,first+limit-1) do out[#out+1]=items[i] end;return out end} end
local function dir(folders,images) return {folders=function() return index(folders) end,
    images=function() return index(images or {}) end,close=function() end} end
local folders={{name="A",path="/m/A",is_folder=true},{name="B",path="/m/B",is_folder=true}}
local dirs={["/m"]=dir(folders),["/m/A"]=dir({},{{name="001.jpg",path="/m/A/001.jpg"}}),["/m/B"]=dir({})}
local shelf_loads,reader_loads,refreshes,network_prompts=0,0,0,0
local ds={load=function(_,p,cb) reader_loads=reader_loads+1;cb.on_ready(dirs[p]);return {cancel=function() end} end}
local bs={load=function(_,p,cb) shelf_loads=shelf_loads+1;cb.on_ready(dirs[p]);return {cancel=function() end} end,
    invalidate=function() end,lookup=function() return nil end}
local ui={show_menu=function(self,m) self.menu=m end,close_menu=function() end,
    show_info=function() end,get_anchor=function() return "/m/B" end}
local grid={is_open=false,show=function(self,m) self.model=m;self.is_open=true;return true end,
    cancel=function(self) self.is_open=false end,
    leave_for=function(self,cb) self.is_open=false;cb();return true end}
local reader,cache_action,connected
local browser=Browser:new{settings=settings,settings_ui={show_connection=function() connected=true end,
    show_bookshelf_cache=function() end},directory_store=ds,bookshelf_directory_store=bs,bookshelf_grid=grid,
    on_bookshelf_refresh=function() refreshes=refreshes+1 end,ui=ui,
    network_manager={willRerunWhenConnected=function() network_prompts=network_prompts+1;return false end},
    open_reader=function(context) reader=context end,cache_manga=function() cache_action=true end}
browser:show_library(false,"/m")
expect(shelf_loads==1 and reader_loads==0,"bookshelf directory manifests use isolated cache")
expect(type(ui.menu.on_toggle_view)=="function","list toolbar has cover toggle beside connection")
ui.menu.on_toggle_view()
expect(settings:get_bookshelf_view()=="covers" and grid.is_open,"switch and persist cover mode")
expect(#grid.model.items==2 and grid.model.items[2].manga.path=="/m/B","grid contains only folder cards")
expect(grid.model.initial_item_id=="/m/B","list to grid preserves visible folder anchor")
expect(grid.model.on_switch_connection and grid.model.on_actions and grid.model.on_close,"existing shelf controls remain reachable")
grid.model.on_anchor("/m/B");grid.model.on_toggle_view()
expect(ui.menu.initial_item_id=="/m/B" and settings:get_bookshelf_view()=="list","grid to list preserves position")
ui.menu.on_toggle_view();grid.model.items[1].on_hold()
expect(ui.menu.title=="A" and ui.menu.items[1].text=="进入漫画" and ui.menu.items[2].text=="缓存漫画","long press retains read and cache actions")
ui.menu.items[2].callback();expect(cache_action,"long-press cache works")
browser:show_library(false,"/m");grid.model.items[1].on_open()
expect(browser.current_path=="/m/A" and grid.model.items[1].manga.path=="/m/A","tap cover enters folder")
grid.model.items[1].on_open()
expect(reader and reader_loads>0,"current-image card opens reader with original directory store")
browser:show_library(false,"/m");grid.model.on_actions()
expect(ui.menu.items[1].text=="↻ 刷新" and ui.menu.items[2].text=="阅读历史","refresh/history/category actions retained")
ui.menu.items[1].callback();expect(refreshes>0,"refresh invalidates shelf selections")
grid.model.on_switch_connection();expect(connected,"top-left connection action works")
-- A cached directory must bypass Wi-Fi prompting when the device is offline.
local before=network_prompts
local cached=dir(folders);cached.acquire=function(self) return self end
bs.lookup=function() return cached end
browser:show_library(false,"/m")
expect(network_prompts==before,"saved directory opens offline before network prompt")
browser:cancel();expect(not grid.is_open,"cancel closes bookshelf grid and pending covers")
print(("bookshelf_browser_spec: %d checks"):format(checks))
