local Modes=require('webdavmanga.panel_modes')
local Settings=require('webdavmanga.settings')
local checks=0
local function expect(v,m)checks=checks+1;assert(v,m)end
local keys={intelligent='panel_zoom_enabled',dynamic='dynamic_panel_zoom_enabled',web='web_panel_zoom_enabled'}
for from,fkey in pairs(keys)do for to,tkey in pairs(keys)do if from~=to then
 local values={[fkey]=true};Modes.resolve(values)
 local previous={};for k,v in pairs(values)do previous[k]=v end
 values[tkey]=true;Modes.resolve(values,previous,tkey)
 expect(Modes.active(values)==to,'explicit enable wins from '..from..' to '..to)
 for mode,key in pairs(keys)do expect(values[key]==(mode==to),'exactly one enabled mode')end
 values[tkey]=false;Modes.resolve(values)
 expect(not Modes.enabled(values),'disabling current mode does not activate another')
end end end
local broken={panel_zoom_enabled=true,dynamic_panel_zoom_enabled=true,web_panel_zoom_enabled=true}
Modes.resolve(broken);expect(Modes.active(broken)=='web','deterministic corrupt profile recovery')
for mode,key in pairs(keys)do
 local patch=Modes.override({[key]=true})
 for other,field in pairs(keys)do expect(patch[field]==(other==mode),'book enable overrides every competing global default')end
end
local data,fail={},false
local s=Settings:new{store={readSetting=function(_,k,d)return data[k] or d end,
 saveSetting=function(_,k,v)data[k]=v end,flush=function()return not fail end}}
local book=string.rep('a',32)
expect(s:set_reader{panel_zoom_enabled=true},'global intelligent')
expect(s:set_panel_reader(book,{web_panel_zoom_enabled=true}), 'per-book web selection')
expect(Modes.active(s:get_panel_reader(book))=='web' and Modes.active(s:get_reader())=='intelligent','book wins without replacing defaults')
fail=true
expect(not s:set_panel_reader(book,{dynamic_panel_zoom_enabled=true},true),'failed default save')
expect(Modes.active(s:get_panel_reader(book))=='web' and Modes.active(s:get_reader())=='intelligent','failed storage preserves both modes')
fail=false
expect(s:set_reader{web_panel_zoom_enabled=true},'switch global web')
expect(s:set_reader{dynamic_panel_zoom_enabled=true} and Modes.active(s:get_reader())=='dynamic','new explicit global enable wins')
print('panel_modes_spec: '..checks..' checks')
