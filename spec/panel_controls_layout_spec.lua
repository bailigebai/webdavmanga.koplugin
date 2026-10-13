local fixture=dofile('spec/helpers/reader_quadrant_host.lua')
local r,o=fixture(false)
local checks,failures=0,{}
local function expect(v,m)checks=checks+1;assert(v,m)end
local function test(name,f)local ok,e=pcall(f);if not ok then failures[#failures+1]=name..': '..tostring(e)end end
local function find(text)
 for _,a in ipairs(r.shell.current_model.actions or {})do if a.text==text then return a end end
end
test('direct menu parents',function()
 r:toggle_controls('panel');expect(find('更多分格设置'),'advanced is directly under intelligent panels')
 r:toggle_controls('panel_view');expect(not find('更多分格设置') and not find('旋转整个设备 ↻'),'view only controls panel image')
 find('← 返回上一级').callback();expect(r.shell.current_model.section=='panel','view returns to panel root')
 r:toggle_controls('panel_advanced');find('← 返回上一级').callback()
 expect(r.shell.current_model.section=='panel','advanced returns to panel root')
 r:toggle_controls('root');expect(find('设备旋转'),'device rotation has outer entry')
 find('设备旋转').callback()
 for _,angle in ipairs({0,90,180,270})do expect(find(tostring(angle)..'°'),'explicit device angle')end
 find('← 返回上一级').callback();expect(r.shell.current_model.section=='root','device rotation returns to root')
end)
test('exact angles and idle selection',function()
 local mode,events,rebuild=0,0,0
 r.shell.screen.getRotationMode=function()return mode end
 r.shell.ui_manager.broadcastEvent=function(_,event)mode=event.mode;events=events+1 end
 r.shell.ui_manager.onRotation=function()rebuild=rebuild+1 end
 package.loaded['ui/event']={new=function(_,name,value)expect(name=='SetRotationMode','native orientation event');return {mode=value}end}
 for _,angle in ipairs({90,180,270,0})do
  expect(r.shell:rotate_device(angle) and mode==angle/90,'exact host rotation')
 end
 expect(events==4 and rebuild==4,'one host rebuild per changed angle')
 local requests=#o.requests
 expect(r:rotate_panel_device(0) and events==4 and #o.requests==requests,'same orientation is idle')
 expect(not r.shell:rotate_device(45) and not r:rotate_panel_device(45),'reject arbitrary angles')
 r.closing=true;expect(not r:rotate_panel_device(90),'closed reader cannot rotate');r.closing=false
end)
test('dynamic successful display clears old status',function()
 r.reader_settings.dynamic_panel_zoom_enabled=true;r:close_controls()
 r.shell:show_status('正在识别分格')
 expect(r:_show_panel(r.page_buffer,{},1,12,{}),'display dynamic panel')
 expect(r.shell.current_model.status_text==nil,'dynamic view has no persistent label or stale status')
 r.shell:show_status('设备方向调整失败',2)
 expect(r.shell.current_model.status_text=='设备方向调整失败','errors remain visible')
end)
test('rotation layout rejection restores host orientation and page',function()
 local reader,observed=fixture(false);local shell=reader.shell
 local mode=0
 shell.screen.getRotationMode=function()return mode end
 shell.ui_manager.broadcastEvent=function(_,event)mode=event.mode end
 shell.ui_manager.onRotation=function()end
 shell.widget.init=function()error('injected rotation layout failure')end
 local page=reader.page_buffer;local requests=#observed.requests
 expect(not reader:rotate_panel_device(90),'rejected rotation is reported')
 expect(mode==0 and reader.page_buffer==page and #observed.requests==requests,'rollback keeps orientation and current original')
end)
assert(#failures==0,table.concat(failures,'\n'))
print('panel_controls_layout_spec: '..checks..' checks')
