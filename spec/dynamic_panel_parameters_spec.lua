local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local Settings=require('webdavmanga.settings')
local checks=0
local function expect(v,m)checks=checks+1;assert(v,m)end
local data={}
local s=Settings:new{store={readSetting=function(_,k,d)return data[k] or d end,saveSetting=function(_,k,v)data[k]=v end}}
local defaults=s:get_reader()
expect(defaults.dynamic_panel_detection_threshold==50 and defaults.dynamic_panel_min_side_percent==12.5,'preserve native defaults')
for _,v in ipairs({1,37,50,254})do expect(s:set_reader{dynamic_panel_detection_threshold=v},'accept exact threshold')end
for _,v in ipairs({0,255,37.5,math.huge,0/0})do
 local before=s:get_reader().dynamic_panel_detection_threshold
 expect(not s:set_reader{dynamic_panel_detection_threshold=v},'reject invalid threshold')
 expect(s:get_reader().dynamic_panel_detection_threshold==before,'invalid save retains threshold')
end
for _,v in ipairs({2,12.5,50})do expect(s:set_reader{dynamic_panel_min_side_percent=v},'accept fractional percentage')end
for _,v in ipairs({1.99,50.01,math.huge,0/0})do expect(not s:set_reader{dynamic_panel_min_side_percent=v},'reject invalid percentage')end
local normalized={};Dynamic.normalize(normalized)
expect(normalized.dynamic_panel_detection_threshold==50 and normalized.dynamic_panel_min_side_percent==12.5,'normalization adds defaults')
local request=Dynamic.request(normalized,{})
expect(request.detection_threshold==50 and request.min_side_percent==12.5,'request passes exact native parameters')
local numbers=0
for _,item in ipairs(Dynamic.items())do if item.key=='dynamic_panel_detection_threshold' or item.key=='dynamic_panel_min_side_percent' then
 expect(item.choices==nil and item.description,'numeric global editor, not cycling presets');numbers=numbers+1
end end
expect(numbers==2,'both numeric fields appear')
local fixture=dofile('spec/helpers/reader_quadrant_host.lua')
local reader=fixture(false);reader.settings=s;reader.reader_settings=s:get_reader()
local dialog
package.loaded['ui/widget/multiinputdialog']={new=function(_,model)
 model.getFields=function()return {model.typed or '37'}end;return model
end}
reader.shell.ui_manager.show=function(_,widget)dialog=widget end
local function select(prefix)
 reader:toggle_controls('dynamic')
 for _,item in ipairs(reader.shell.current_model.actions)do if item.text:find(prefix,1,true)==1 then return item.callback()end end
 error('missing dynamic number action')
end
expect(select('动态识别阈值'),'open exact threshold editor')
expect(reader.shell.current_model.kind~='controls','numeric editor hides parent')
dialog.typed='0';dialog.buttons[1][2].callback()
expect(reader.shell.input_dialog==dialog,'invalid value keeps editor')
dialog.typed='37';dialog.buttons[1][2].callback()
expect(reader.reader_settings.dynamic_panel_detection_threshold==37 and reader.shell.current_model.section=='dynamic','save exact threshold and return directly')
expect(select('动态最小宽高比例'),'open fractional percentage editor')
dialog.typed='12.5';dialog.buttons[1][2].callback()
expect(reader.reader_settings.dynamic_panel_min_side_percent==12.5,'save fractional value through actual editor')
print('dynamic_panel_parameters_spec: '..checks..' checks')
