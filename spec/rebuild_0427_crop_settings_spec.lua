local Settings=require('webdavmanga.settings')
local UISettings=require('webdavmanga.ui_settings')
local Reader=require('webdavmanga.ui_reader')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local stored,fail={},false
local s=Settings:new{store={readSetting=function(_,k,d) return stored[k] or d end,
    saveSetting=function(_,k,v) stored[k]=v end,flush=function() return not fail end}}
expect(s:get_reader().auto_crop_enhance_enabled==false,'new crop enhancement remains opt-in')
local params={auto_crop_enabled=true,auto_crop_enhance_enabled=true,
    auto_crop_border_width=3,auto_crop_min_area=6,auto_crop_padding_percent=2}
expect(s:set_reader(params),'valid enhancement settings save')
expect(s:get_reader().auto_crop_padding_percent==2,'settings survive reading')
for _,case in ipairs({{'auto_crop_enhance_enabled','yes'},{'auto_crop_border_width',11},
    {'auto_crop_min_area',0},{'auto_crop_padding_percent',6},{'auto_crop_min_area',1.5}}) do
    expect(not s:set_reader({[case[1]]=case[2]}),'reject invalid '..case[1])
end
local model
local ui=UISettings:new{settings=s,client_factory=function() return {} end,async={},cache={},
    ui={show_reader=function(_,m) model=m end,show_info=function() end}}
ui:show_reader('crop')
fail=true
model.values.auto_crop_enhance_enabled=false
expect(not model.on_save(model.values),'failed global form save reports failure')
expect(s:get_reader().auto_crop_enhance_enabled==true,'failed global form flush restores old crop setting')
fail=false
model.values.auto_crop_enhance_enabled=true
model.values.auto_crop_border_width=4
model.values.auto_crop_min_area=9
model.values.auto_crop_padding_percent=3
expect(model.on_save(model.values),'global crop form accepts enhancement controls')
local got=s:get_reader()
expect(got.auto_crop_border_width==4 and got.auto_crop_min_area==9 and got.auto_crop_padding_percent==3,
    'global form retains all enhancement parameters instead of dropping them')
local requested=0
local r=setmetatable({reader_settings=got,settings=s,position={index=7},request_serial=0,
    request_page=function(_,index,segment) expect(index==7 and segment=='whole','crop redraw reuses current page');requested=requested+1;return true end},
    {__index=Reader})
expect(type(r.set_crop_enhance_option)=='function' and r:set_crop_enhance_option('auto_crop_enhance_enabled',false),
    'reader exposes independent enhancement toggle')
expect(not r.reader_settings.auto_crop_enhance_enabled and r.reader_settings.auto_crop_enabled and requested==1,
    'turning off enhancement retains master and updates current page once')
expect(not r:set_crop_enhance_option('auto_crop_padding_percent',99) and requested==1,
    'invalid reader input neither saves nor reloads')
fail=true
expect(not r:set_crop_enhance_option('auto_crop_enhance_enabled',true)
    and not r.reader_settings.auto_crop_enhance_enabled and requested==1,
    'save failure keeps current view and original preference')
stored.reader={auto_crop_enhance_enabled='bad',auto_crop_border_width=math.huge,
    auto_crop_min_area=-1,auto_crop_padding_percent=0/0}
got=s:get_reader()
expect(not got.auto_crop_enhance_enabled and got.auto_crop_border_width==2
    and got.auto_crop_min_area==4 and got.auto_crop_padding_percent==1,'corrupt saved enhancement preferences normalize safely')
print('rebuild_0427_crop_settings_spec: '..checks..' checks passed')
