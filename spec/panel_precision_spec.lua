local Settings=require('webdavmanga.settings')
local Options=require('webdavmanga.panel_options')
local Reader=require('webdavmanga.ui_reader')
local values={}
local settings=Settings:new{store={readSetting=function(_,k,d) return values[k] or d end,
    saveSetting=function(_,k,v) values[k]=v end,flush=function() return true end}}
local key=string.rep('a',32)
for _,n in ipairs({1,37,41,254}) do
    assert(settings:set_panel_reader(key,{panel_detection_threshold=n}), 'exact threshold must persist: '..n)
    assert(settings:get_panel_reader(key).panel_detection_threshold==n,'threshold must survive reload')
end
for _,n in ipairs({0,255,37.5,math.huge,0/0}) do
    assert(not settings:set_panel_reader(key,{panel_detection_threshold=n}),'invalid threshold must not persist')
end
local normalized={};for _,f in ipairs(Options.fields) do normalized[f.key]=f.default end
normalized.panel_detection_threshold=37;Options.normalize(normalized)
assert(normalized.panel_detection_threshold==37 and Options.validate(normalized),'normalization must preserve exact values')
local form
local reader=setmetatable({settings=settings,panel_book_key=key,reader_settings=settings:get_panel_reader(key),
    ui={show_number_input=function(_,model) form=model;return true end}},Reader)
assert(reader:show_panel_threshold_input(false),'current book numeric input must open')
assert(form.on_save('41') and settings:get_panel_reader(key).panel_detection_threshold==41)
assert(not form.on_save('41.1') and not form.on_save('0') and not form.on_save('nan'))
assert(reader:show_panel_threshold_input(true) and form.on_save('39'))
assert(settings:get_reader().panel_detection_threshold==39,'long press numeric input must save default')
print('panel_precision_spec: exact threshold validation, reload and numeric input passed')
