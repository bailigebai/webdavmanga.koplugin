local Settings=require('webdavmanga.settings')
local Detector=require('webdavmanga.panel_detector')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local data,failed={},false
local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,
 saveSetting=function(_,k,v) data[k]=v end,flush=function() return not failed end}}
expect(s:get_reader().dynamic_panel_zoom_enabled==false,'dynamic mode defaults off')
expect(s:set_reader({panel_zoom_enabled=true}),'enable intelligent panels')
expect(s:set_reader({dynamic_panel_zoom_enabled=true}),'enable independent dynamic mode')
expect(s:get_reader().dynamic_panel_zoom_enabled and not s:get_reader().panel_zoom_enabled,'dynamic disables intelligent')
expect(s:set_reader({panel_zoom_enabled=true}) and not s:get_reader().dynamic_panel_zoom_enabled,'intelligent disables dynamic')
local a,b=string.rep('a',32),string.rep('b',32)
expect(s:set_panel_reader(a,{dynamic_panel_zoom_enabled=true,dynamic_panel_order='manga'}),'independent book preferences')
expect(s:get_panel_reader(a).dynamic_panel_zoom_enabled and not s:get_panel_reader(a).panel_zoom_enabled,'book overrides cannot leave both modes on')
expect(not s:get_panel_reader(b).dynamic_panel_zoom_enabled,'other book uses defaults')
expect(s:set_panel_reader(a,{panel_zoom_enabled=true}) and not s:get_panel_reader(a).dynamic_panel_zoom_enabled,'switch back on current book')
failed=true
expect(not s:set_panel_reader(a,{dynamic_panel_zoom_enabled=true},true),'failed save must roll back')
expect(s:get_panel_reader(a).panel_zoom_enabled and not s:get_reader().dynamic_panel_zoom_enabled,'failed save restores modes')
failed=false
expect(not s:set_reader({dynamic_panel_initial_zoom=99}),'bound native zoom work')
data.reader={panel_zoom_enabled=true,dynamic_panel_zoom_enabled=true}
expect(s:get_reader().dynamic_panel_zoom_enabled and not s:get_reader().panel_zoom_enabled,'corrupt dual setting normalizes deterministically')
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local calls=0
local backend={connected_components=function(_,r,t,c)
 calls=calls+1;expect(r.buffer~=nil and t==50 and c==8,'native detection receives bounded raster')
 return {width=100,height=100,boxes={{x=5,y=5,w=40,h=40},{x=55,y=5,w=40,h=40}}}
end}
local panels=Dynamic.detect({buffer={}}, {backend=backend,direction='manga'})
expect(calls==1 and #panels==2 and panels[1].x==.55,'native path bypasses intelligent analysis and follows RTL')
panels=Detector.detect_native({buffer={}}, {backend=backend,direction='normal'})
expect(panels[1].x==.05,'native LTR order')
local UISettings=require('webdavmanga.ui_settings')
local form
local ui=UISettings:new{settings=s,client_factory=function() return {} end,async={},cache={},
 ui={show_reader=function(_,v) form=v end,show_info=function() end}}
ui:show_reader('panel')
form.values.panel_zoom_enabled=true
form.values.dynamic_panel_zoom_enabled=false
expect(form.on_save(form.values) and s:get_reader().panel_zoom_enabled,'global form supports switching back')
form.values.dynamic_panel_zoom_enabled=true
expect(form.on_save(form.values) and s:get_reader().dynamic_panel_zoom_enabled and not s:get_reader().panel_zoom_enabled,'global form retains mutual exclusion')
print('rebuild_0424_dynamic_panel_spec: '..checks..' checks passed')
