-- Independent review counterexamples retained as regression cases.

-- existing three panel controls accepted by book whitelist
do
local Settings=require('webdavmanga.settings')
local data={}
local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,saveSetting=function(_,k,v) data[k]=v end,flush=function() return true end}}
for k,v in pairs({panel_hold_margin_percent=10,panel_initial_zoom=1.5,panel_experimental_sort=true}) do
 local accepted,reason=s:set_panel_reader(string.rep('a',32),{[k]=v})
 assert(accepted==true,'book whitelist rejected '..k)
 print(k,tostring(accepted),tostring(reason))
end
end

-- native gesture payloads are converted to nonzero pan
do
local Reader=require('webdavmanga.ui_reader')
local last_x,last_y
local shell={current_model={kind='page'}}
local reader=setmetatable({panel_entry={},shell=shell,reader_settings={},panel_session={render_options={view='free'},current=function() return {buffer='current'} end,pan=function(_,x,y) last_x,last_y=x,y;return true end}},Reader)
reader:onSwipe(nil,{ges='swipe',pos={x=300,y=400},end_pos={x=300,y=250},direction='north',distance=150})
assert(last_x==0 and last_y==-150,'swipe displacement lost')
print('native swipe pan',last_x,last_y)
reader:onPanelPan(shell,{ges='pan',start_pos={x=300,y=400},pos={x=300,y=280},relative={x=0,y=-120}})
reader:onTwoFingerHoldRelease(shell,{ges='pan_release',pos={x=300,y=250}})
assert(last_x==0 and last_y==-150,'slow pan displacement lost')
print('native slow pan release',last_x,last_y)
end

-- explicit outer-settings reload keeps saved current-book camera
do
local Settings=require('webdavmanga.settings')
local Reader=require('webdavmanga.ui_reader')
local data={}
local key=string.rep('b',32)
local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,saveSetting=function(_,k,v) data[k]=v end,flush=function() return true end}}
assert(s:set_panel_reader(key,{panel_rotation=90,panel_view='cut',panel_navigation='vertical'}))
local reader=setmetatable({settings=s,panel_book_key=key,reader_settings=s:get_panel_reader(key),_prepare_fit_mode=function() return true end,_restart_processed_page=function() return true end},Reader)
assert(s:set_reader({direction='manga'}))
print('before reload',reader.reader_settings.panel_rotation,reader.reader_settings.panel_view,reader.reader_settings.panel_navigation)
reader:reload_settings(s:get_reader())
assert(reader.reader_settings.panel_rotation==90 and reader.reader_settings.panel_view=='cut' and reader.reader_settings.panel_navigation=='vertical','book preferences lost on explicit reload')
print('after explicit reload',reader.reader_settings.panel_rotation,reader.reader_settings.panel_view,reader.reader_settings.panel_navigation)
end

-- configuration commit cannot reenter and relabel rendered content
do
local Session=require('webdavmanga.panel_session')
local Detector=require('webdavmanga.panel_detector')
local allocated={}
local function buffer(id,options)
 local v={id=id,zoom=options.zoom,frees=0,free=function(self) self.frees=self.frees+1 end}
 allocated[#allocated+1]=v;return v
end
local source={open=function(_,_,_,cb)
 local h={detection_raster=function() return {} end,closed=false,close=function(self) self.closed=true end,
 render=function(_,panel,options) return buffer(panel.id,options) end}
 cb.on_ready(h);return {cancel=function() h:close() end}
end}
local s=Session:new{source=source,detector={sort=Detector.sort,detect=function() return {{id='a',x=0,y=0,w=.45,h=1},{id='b',x=.55,y=0,w=.45,h=1}} end},screen_width=600,screen_height=800}
assert(s:start({view='context'},{on_panel=function() return true end}))
local moved
local configured=s:configure({rotation=90},function() moved=s:move(1);return true end)
local c=s:current()
assert(moved==false and c.panel.id==c.buffer.id,'commit relabeled buffer')
print('reentrant move accepted',tostring(moved),'configured',tostring(configured),'current panel',c.panel.id,'rendered buffer',c.buffer.id)
s:close()
end

-- status rebuild failure after showing must not free displayed panel
do
local Reader=require('webdavmanga.ui_reader')
local Session=require('webdavmanga.panel_session')
local buffers={}
local displayed,fail_status
local function buffer(id)
 local b={id=id,frees=0,free=function(self) self.frees=self.frees+1 end}
 buffers[#buffers+1]=b;return b
end
local shell={show_page=function(_,b) displayed=b;return true end,show_status=function() if fail_status then error('second UI rebuild failed') end;return true end}
local reader=setmetatable({shell=shell,reader_settings={},position={index=1},context={chapter_index={count=function() return 1 end}}},Reader)
local source={open=function(_,_,_,cb)
 local h={detection_raster=function() return {} end,close=function(self) self.closed=true end,render=function(_,panel) return buffer(panel.id) end}
 cb.on_ready(h);return {cancel=function() h:close() end}
end}
local s=Session:new{source=source,detector={detect=function() return {{id='a',x=0,y=0,w=1,h=1}} end},screen_width=600,screen_height=800}
assert(s:start({view='context'},{on_panel=function(b,p,i,n) return reader:_show_panel(b,p,i,n) end}))
local original=s:current().buffer
fail_status=true
local accepted=s:configure({rotation=90})
assert(accepted==true and displayed.frees==0,'freed displayed frame after status failure')
print('configure accepted',tostring(accepted),'session retains original',tostring(s:current().buffer==original),'displayed freed count',displayed.frees,'display still original',tostring(displayed==original))
s:close()
end

-- legacy panel controls obey independent order and long-press scope
do
local Reader=require('webdavmanga.ui_reader')
local Settings=require('webdavmanga.settings')
local data={}
local settings=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,saveSetting=function(_,k,v) data[k]=v end,flush=function() return true end}}
local key=string.rep('c',32)
assert(settings:set_panel_reader(key,{panel_order='normal'}))
local model
local reader=setmetatable({settings=settings,panel_book_key=key,reader_settings=settings:get_panel_reader(key),direction='normal',ui={show_controls=function(_,m) model=m;return true end},context={chapter_index={count=function() return 1 end}}},Reader)
reader:toggle_controls('panel')
local choice_count,hold_count,order_button=0,0
for _,a in ipairs(model.actions) do
 if a.text:find('开启') or a.text:find('关闭') or a.text:find('边距') or a.text:find('倍率') or a.text:find('顺序') then
  choice_count=choice_count+1;if a.hold_callback then hold_count=hold_count+1 end
 end
 if a.text:find('分格顺序') then order_button=a end
end
assert(choice_count==hold_count and hold_count>=6,'panel defaults missing hold callbacks')
print('panel setting buttons',choice_count,'hold callbacks',hold_count)
order_button.callback()
assert(reader:_panel_direction()=='manga' and settings:get_reader().direction=='normal','panel order changed physical direction')
print('book panel order after order click',reader:_panel_direction(),'global physical direction',settings:get_reader().direction)
end

-- foreground configure and late prefetch own buffers exactly once
do
local Session=require('webdavmanga.panel_session')
local Detector=require('webdavmanga.panel_detector')
local allocated,scheduled={},{}
local function newbuffer(id,options)
 local b={id=id,rotation=options.rotation,zoom=options.zoom,pan_x=options.pan_x,frees=0,free=function(self) self.frees=self.frees+1 end}
 allocated[#allocated+1]=b;return b
end
local source={open=function(_,_,_,cb)
 local h={detection_raster=function() return {} end,close=function(self) self.closed=true end,render=function(_,p,o) return newbuffer(p.id,o) end}
 cb.on_ready(h);return {cancel=function() h:close() end}
end}
local s=Session:new{source=source,detector={sort=Detector.sort,detect=function() return {{id='a',x=0,y=0,w=.45,h=1},{id='b',x=.55,y=0,w=.45,h=1}} end},screen_width=600,screen_height=800,schedule=function(fn) scheduled[#scheduled+1]=fn end}
assert(s:start({view='context',rotation=0},{on_panel=function() return true end}))
assert(s:configure({zoom=2,pan_x=.15}))
local before=s:current().buffer
assert(not s:configure({rotation=90},function() return false end))
assert(s:current().buffer==before and before.frees==0 and s.render_options.zoom==2 and s.render_options.pan_x==.15)
assert(s:configure({rotation=90}))
for _,fn in ipairs(scheduled) do fn() end
assert(s.next_buffer and s.next_buffer.rotation==90 and s.next_buffer.zoom==1)
local calls=#allocated
assert(s:move(1) and #allocated==calls)
assert(s:current().buffer.rotation==90 and s:current().buffer.zoom==1)
s:close()
for _,fn in ipairs(scheduled) do fn() end
for _,b in ipairs(allocated) do assert(b.frees==1,'ownership mismatch for '..b.id..'/'..tostring(b.rotation)) end
print('all '..#allocated..' owned frames freed once; stale prefetch never published')
end

-- candidate cap fails before returning any partial content
do
local Detector=require('webdavmanga.panel_detector')
local pixels=dofile('spec/fixtures/webtoon_buffer.lua')
local calls=0
local b=pixels.new(384,384,function(x,y) calls=calls+1;return x%24==y%24 and x%24<18 and 0 or 255 end)
local value,reason=Detector.detect({buffer=b},{direction='normal'})
assert(value==nil and reason=='too_many_panels' and calls<=384*384)
print('candidate cap reason',reason,'samples',calls)
end

print("rebuild_0412_panel_lifecycle_spec: 8 scenarios passed")
