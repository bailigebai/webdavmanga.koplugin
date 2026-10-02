local Settings=require("webdavmanga.settings")
local Reader=require("webdavmanga.ui_reader")
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local saved,failed={},false
local store={readSetting=function(_,k,d) return saved[k] or d end,saveSetting=function(_,k,v) saved[k]=v end,
 flush=function() return not failed end}
local s=Settings:new{store=store}
local a,b=string.rep("a",32),string.rep("b",32)
expect(s:get_reader().panel_view=="context" and s:get_reader().panel_rotation==0,"safe context view is the default")
expect(s:set_panel_reader(a,{panel_rotation=90,panel_navigation="vertical"}),"save current-book settings")
expect(s:get_panel_reader(a).panel_rotation==90 and s:get_panel_reader(b).panel_rotation==0,"book choices do not change other books")
expect(s:set_panel_reader(a,{panel_rotation=180},true) and s:get_panel_reader(b).panel_rotation==180,"hold applies to this book and defaults")
failed=true
expect(not s:set_panel_reader(a,{panel_rotation=270},true) and s:get_panel_reader(a).panel_rotation==180 and s:get_reader().panel_rotation==180,"flush failure restores both book and defaults")
failed=false
for _,v in ipairs({{panel_rotation=45},{panel_navigation="diagonal"},{panel_view="unknown"},{password="example"}}) do
 expect(not s:set_panel_reader(a,v),"reject malformed or unrelated profile values")
end
for i=1,70 do expect(s:set_panel_reader(("%032x"):format(i),{panel_rotation=90}),"profile capacity write") end
local n=0;for k in pairs(saved.panel_books) do n=n+1;expect(k:match("^%x+$") and #k==32,"profile keys contain no raw paths") end
expect(n<=64,"book profile storage is bounded")
local moved,controls,pan=0,0,0
local reader=setmetatable({panel_entry={},direction="manga",reader_settings={panel_navigation="vertical",panel_reverse_navigation=false},
 shell={get_content_size=function() return 600,800 end},panel_session={render_options={view="context"}},
 _move_panel=function(_,delta) moved=moved+delta;return true end,
 toggle_controls=function(_,section) controls=controls+1;expect(section=="panel_view","center opens panel controls");return true end},Reader)
reader:onTap(nil,{pos={x=300,y=400}})
expect(controls==1 and moved==0,"center never exits or changes panels")
reader:onSwipe(nil,{direction="north"});expect(moved==1,"vertical up advances independent of manga order")
reader:onSwipe(nil,{direction="west"});expect(moved==1,"other axis does not advance")
reader.reader_settings.panel_reverse_navigation=true
reader:onSwipe(nil,{direction="south"});expect(moved==2,"custom navigation reversal")
reader.panel_session.render_options.view="free"
reader.panel_session.pan=function() pan=pan+1;return true end
reader.panel_session.pan=function(_,dx,dy) pan=pan+1;expect(dx==0 and dy==-50,"swipe uses actual KOReader start/end positions");return true end
reader:onSwipe(nil,{direction="north",pos={x=100,y=100},end_pos={x=100,y=50}})
expect(moved==2 and pan==1,"free view pans rather than navigating")
reader.shell.current_model={kind="page"}
reader.panel_session.current=function() return {buffer="current"} end
reader:onPanelPan(reader.shell,{ges="pan",start_pos={x=100,y=100},pos={x=100,y=80},relative={x=0,y=-20}})
reader:onTwoFingerHoldRelease(reader.shell,{ges="pan_release",pos={x=100,y=50}})
expect(pan==2,"slow drag commits once on native release without relative")
local book_key=string.rep("c",32)
local model,info
local actual=setmetatable({settings=s,panel_book_key=book_key,reader_settings=s:get_panel_reader(book_key),
 direction="normal",context={chapter_index={count=function() return 1 end}},
 ui={show_controls=function(_,v) model=v;return true end,show_info=function(_,v) info=v end}},Reader)
actual:toggle_controls("panel_view")
expect(#model.actions==10,"panel controls expose three views, rotation, zoom and independent navigation")
local rotate=model.actions[2]
local default_angle=s:get_reader().panel_rotation
expect(rotate.callback() and actual.reader_settings.panel_rotation==(default_angle+90)%360,
 "actual rotation button saves current book")
expect(s:get_reader().panel_rotation==default_angle,"tap leaves new-book default unchanged")
expect(model.actions[2].hold_callback() and s:get_reader().panel_rotation==actual.reader_settings.panel_rotation,
 "hold updates current book and new-book default")
local previous=actual.reader_settings.panel_rotation
failed=true
expect(not model.actions[2].callback() and actual.reader_settings.panel_rotation==previous and info,
 "failed storage keeps current settings and shows feedback over controls")
failed=false
actual:reload_settings(s:get_reader())
expect(actual.reader_settings.panel_rotation==previous,"explicit global reload preserves current-book rotation")
print("rebuild_0412_panel_controls_spec: "..checks.." checks passed")
