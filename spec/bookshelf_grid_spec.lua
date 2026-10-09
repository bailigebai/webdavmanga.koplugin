local Grid=require("webdavmanga.ui_cover_grid")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local ui={show_grid=function(self,model) self.model=model end,close_grid=function() end,free_visible=function() end}
local grid=Grid:new{cover_service={resolve=function(_,_,_,cb) cb.on_error({code="empty"});return {cancel=function() end} end},
    cache={key_for=function() return "x" end,lookup=function() end},loader={cancel_cover_generation=function() end},
    connection_provider=function() return {root_path="/m"} end,settings={get_reader=function() return {grid_columns=3} end},
    ui=ui,render_image={},scheduler={scheduleIn=function(_,_,fn) fn() end}}
local toggled,switched,actions,closed,anchor=0,0,0,0
grid:show{title="漫画书架",view_mode="covers",initial_item_id="B",items={{id="A",manga={path="/m/A"}},{id="B",manga={path="/m/B"}}},
    on_toggle_view=function() toggled=toggled+1 end,on_switch_connection=function() switched=switched+1 end,
    on_actions=function() actions=actions+1 end,on_close=function() closed=closed+1 end,
    on_anchor=function(id) anchor=id end}
expect(ui.model.on_toggle_view and ui.model.on_switch_connection and ui.model.on_actions and ui.model.on_close,
    "grid receives all bookshelf toolbar/footer actions")
expect(ui.model.initial_item_id=="B" and ui.model.view_mode=="covers","native layout receives anchor and mode")
ui.model.on_visible({"A","B"});expect(anchor=="B","initial visible page keeps requested item anchor")
ui.model.on_visible({"A"});expect(anchor=="A","later page updates first visible anchor")
local old=ui.model
old.on_toggle_view();old.on_switch_connection();old.on_actions();old.on_close()
expect(toggled==1 and switched==1 and actions==1 and closed==1,"live actions dispatched")
grid:cancel();old.on_toggle_view();old.on_actions()
expect(toggled==1 and actions==1,"late toolbar callbacks cannot act after close")
local ok,deferred=pcall(Grid.new,Grid,{cover_service=grid.cover_service,cache=grid.cache,
    loader=grid.loader,connection_provider=grid.connection_provider,settings=grid.settings,defer_ui=true})
expect(ok and deferred.ui==nil,"unused shelf must not allocate native UI at plugin startup")
expect(deferred:cancel()==false,"unused lazy shelf can be torn down")
local rendered_size
local fitted=Grid:new{cover_service=grid.cover_service,cache=grid.cache,loader=grid.loader,
 connection_provider=grid.connection_provider,settings=grid.settings,
 fit_whole_image=true,image_probe={inspect=function() return {width=384,height=192} end},
 ui={get_cover_size=function() return 120,160 end,update_cover=function() return true end},
 render_image={renderImageFile=function(_,p,frames,w,h) rendered_size={w,h};return {} end}}
fitted.is_open=true;fitted.active_generation=1
fitted:_render_cover(1,{id="A"},"/shelf/landscape.png")
expect(rendered_size[1]==120 and rendered_size[2]==60,"grid presentation preserves thumbnail ratio too")
local deferred_action,queued=0,{}
grid.scheduler={scheduleIn=function(_,_,callback) queued[#queued+1]=callback end}
grid:show{items={}}
grid:leave_for(function() deferred_action=deferred_action+1 end)
grid:cancel()
table.remove(queued,1)()
expect(deferred_action==0,"cancel after grid closes also invalidates its queued navigation")
grid:show{items={}}
grid:leave_for(function() deferred_action=deferred_action+1 end)
table.remove(queued,1)()
expect(deferred_action==1,"live deferred navigation still executes once")


print(("bookshelf_grid_spec: %d checks"):format(checks))
