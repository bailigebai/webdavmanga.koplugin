local fixture=dofile('spec/helpers/reader_quadrant_host.lua')
local Source=require('webdavmanga.panel_source')
local Session=require('webdavmanga.panel_session')
local Detector=require('webdavmanga.panel_detector')
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local r,o=fixture(false)
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local viewport=r.page_buffer.viewport
r.page_buffer.viewport=function(self,...)
 local v=viewport(self,...)
 function v:scale(w,h)
  local b={parent=self,frees=0,getWidth=function() return w end,getHeight=function() return h end}
  function b:free() self.frees=self.frees+1;assert(self.frees==1,'owned image double free') end
  return b
 end
 return v
end
r.reader_settings.dynamic_panel_zoom_enabled=true
r.reader_settings.panel_zoom_enabled=false
r.reader_settings.dynamic_panel_order='manga'
r.reader_settings.panel_view='free'
r.reader_settings.panel_entry_gesture='two_finger_tap'
r.panel_source=Source:new{mupdf=false,draw_context=false}
local queue={}
r.ui.schedule=function(_,f) queue[#queue+1]=f end
local native_calls=0
Detector.detect_native=function(raster,options)
 native_calls=native_calls+1
 expect(raster.buffer==r.page_buffer,'native detection borrows current page')
 return Detector.sort({{id='left',x=.05,y=.1,w=.4,h=.4},{id='right',x=.55,y=.1,w=.4,h=.4}},options.direction)
end
r.panel_session_factory=function(options)
 expect(options.detector==Dynamic,'dynamic chooses its separate native detector')
 return Session:new(options)
end
expect(r:onHold(nil,{pos={x=300,y=400}}),'hold enters dynamic even when intelligent gesture is two-finger only')
expect(native_calls==1 and r.panel_entry.mode=='dynamic','dynamic session must be distinct')
local session=r.panel_session
expect(session.render_options.view=='cut' and session.render_options.show_adjacent==false
 and session.render_options.protect_text==false,'normal dynamic view masks adjacent content')
expect(session.panels[1].id=='right','dynamic uses its independent RTL order')
queue[1]();expect(session.next_index==2,'one next panel pre-renders')
local next_buffer=session.next_buffer
expect(r:_move_panel(1) and session.current_buffer==next_buffer,'navigation reuses prefetched panel')
local zoom,fail=false,false
package.loaded['ui/widget/imageviewer']={new=function(_,v)
 if fail then error('viewer construction failed') end
 zoom=v;v.onCloseWidget=function() end;return v
end}
r.shell.ui_manager.show=function() end
r.shell.ui_manager.close=function(_,v) if v and v.onCloseWidget then v:onCloseWidget() end end
local panel_buffer=session.current_buffer
expect(r:onHold(nil,{pos={x=300,y=400}}) and zoom,'hold opens independent free zoom')
expect(zoom.image~=panel_buffer and zoom.image_disposable==false,'zoom owns an expanded source render, not the already cropped panel')
local expanded=zoom.image
expect(expanded.parent and expanded.parent.x<30,'extended image includes actual pixels outside panel')
r.shell:close_panel_zoom()
expect(expanded.frees==1 and panel_buffer.frees==0,'closing free zoom releases only its owned image')
fail=true
expect(not r:onHold(nil,{pos={x=300,y=400}}),'failed free zoom retains current panel')
expect(session:is_active() and session.current_buffer==panel_buffer,'viewer failure preserves reading')
fail=false
local toggled
local controls=r.toggle_controls
r.toggle_controls=function(_,section) toggled=section;return true end
expect(r:onTwoFingerTap(r.shell,{pos={x=300,y=400}}) and toggled=='dynamic','active dynamic gesture opens only dynamic controls')
r.toggle_controls=controls
local saved,flush_failed={},false
local Settings=require('webdavmanga.settings')
r.settings=Settings:new{store={readSetting=function(_,k,d) return saved[k] or d end,
 saveSetting=function(_,k,v) saved[k]=v end,flush=function() return not flush_failed end}}
r.panel_book_key=string.rep('c',32)
expect(r.settings:set_panel_reader(r.panel_book_key,{dynamic_panel_zoom_enabled=true}),'store current dynamic profile')
flush_failed=true
expect(not r:set_panel_option('panel_zoom_enabled',true) and r.panel_session==session
 and session.current_buffer==panel_buffer and panel_buffer.frees==0,'failed mode switch preserves actual panel and position')
flush_failed=false
expect(r:exit_panel_mode() and panel_buffer.frees==1,'exit releases panel once')
for _,f in ipairs(queue) do f() end
expect(not r.panel_session,'late prefetch cannot resurrect an exited session')
expect(r:set_panel_option('panel_zoom_enabled',true) and r.reader_settings.panel_zoom_enabled
 and not r.reader_settings.dynamic_panel_zoom_enabled,'reader switching intelligent on disables dynamic')
expect(r:set_panel_option('dynamic_panel_zoom_enabled',true) and not r.reader_settings.panel_zoom_enabled,'reader switching dynamic on disables intelligent')
local owned={frees=0,free=function(self) self.frees=self.frees+1;assert(self.frees==1) end}
r.shell.ui_manager._window_stack={}
r.shell.ui_manager.show=function(_,v)
 r.shell.ui_manager._window_stack={{widget=v}};error('show failed after mounting')
end
r.shell.ui_manager.close=function() error('close failed before unmounting') end
expect(not r.shell:show_panel_zoom{buffer=owned,owned_buffer=true},'show exception is reported')
expect(r.shell.panel_zoom and owned.frees==0,'double failure must retain ownership of the live viewer image')
r.shell.ui_manager.close=function(_,v)
 v:onCloseWidget()
 r.shell.ui_manager._window_stack={}
end
expect(r.shell:close_panel_zoom() and not r.shell.panel_zoom and owned.frees==1,'retry releases owned pixels only after native window unmounts')
local never_shown={frees=0,free=function(self) self.frees=self.frees+1;assert(self.frees==1) end}
r.shell.ui_manager.show=function() error('show failed before mounting') end
r.shell.ui_manager.close=function() error('close failed before mounting') end
expect(not r.shell:show_panel_zoom{buffer=never_shown,owned_buffer=true},'pre-mount failure reported')
expect(not r.shell.panel_zoom and never_shown.frees==1,'confirmed absent window does not retain an owned image')
print('rebuild_0424_dynamic_reader_spec: '..checks..' checks passed')
