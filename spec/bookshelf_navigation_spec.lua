-- Real Browser navigation; only the external window manager/directory IO are delayed.
local Browser=require("webdavmanga.ui_browser")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local connection={kind="webdav",server_url="http://nas",root_path="/m"}
local settings={get_connection=function() return connection end,is_configured=function() return true end,
    get_browser_path=function() return "/m" end,set_browser_path=function() return true end,
    get_bookshelf_view=function() return "covers" end,flush=function() end}
local pending,grid_model,background,menu,shown={},nil,nil,nil,0
local ui={show_background=function(_,model) background=model;shown=shown+1 end,
    close_background=function() background=nil end,close_menu=function() menu=nil end,
    show_menu=function(_,model) menu=model end,show_info=function() end}
local grid={cancel=function() grid_model=nil end,show=function(_,model) grid_model=model end,
    leave_for=function(_,cb) grid_model=nil;pending.navigation=cb;return true end}
local directory_store={load=function(_,path,cb) pending[path]=cb;return {cancel=function() end} end}
local empty={count=function() return 0 end,get=function() end}
local function directory(path)
    local folders={count=function() return 1 end,get=function() return {name="A",path=path.."/A",is_folder=true} end,
        iterator=function() return {{name="A",path=path.."/A",is_folder=true}} end}
    return {folders=function() return folders end,images=function() return empty end,close=function() end}
end
local browser=Browser:new{settings=settings,settings_ui={},directory_store=directory_store,
    bookshelf_grid=grid,ui=ui,open_reader=function() end}
browser:show_library(false,"/m")
expect(background and not grid_model,"opaque plugin surface remains while initial directory loads")
pending["/m"].on_ready(directory("/m"));grid_model.items[1].on_open()
expect(background and not grid_model,"deferred grid navigation never exposes KOReader")
pending.navigation();expect(background and not grid_model,"directory IO stays over plugin surface")
pending["/m/A"].on_ready(directory("/m/A"));grid_model.on_back()
expect(background,"returning to parent keeps the surface")
pending["/m"].on_error({code="transport"});expect(background,"load failure keeps plugin background and back action")
expect(shown==1,"navigation does not stack duplicate full-screen surfaces")
local stale=pending["/m"]
browser:end_session()
expect(not background and not grid_model,"explicit exit closes owned surface and foreground")
stale.on_ready(directory("/m"));expect(not background and not grid_model,"late directory reply cannot reopen exited plugin")
browser:show_library(false,"/m");expect(background and shown==2,"fresh opening recreates one surface")
background.on_back();expect(not background,"back during root load exits instead of trapping a blank page")
-- The real grid defers actions after closing its window. Exit through the
-- background must invalidate these actions, not merely the directory request.
local Grid=require("webdavmanga.ui_cover_grid")
local queued={}
browser.bookshelf_grid=Grid:new{cover_service={cancel_all=function() end},
    loader={cancel_cover_generation=function() end},cache={},
    settings={get_reader=function() return {grid_columns=3} end},
    connection_provider=function() return connection end,
    ui={show_grid=function(_,model) grid_model=model end,close_grid=function() grid_model=nil end},
    scheduler={scheduleIn=function(_,_,cb) queued[#queued+1]=cb end}}
browser:show_library(false,"/m");pending["/m"].on_ready(directory("/m"))
grid_model.on_actions();background.on_back()
while #queued>0 do table.remove(queued,1)() end
expect(not background and not grid_model and not menu,"queued action cannot reopen any plugin window after exit")
print(("bookshelf_navigation_spec: %d checks"):format(checks))
