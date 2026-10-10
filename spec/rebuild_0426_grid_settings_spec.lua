local Settings=require('webdavmanga.settings')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local data,failed={},false
local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,
    saveSetting=function(_,k,v) data[k]=v end,flush=function() return not failed end}}
local defaults=s:get_reader()
expect(defaults.grid_zoom_enabled==false and defaults.grid_zoom_rtl==false
    and defaults.grid_zoom_guides==true,'independent grid defaults are opt-in with visible guides')
expect(s:set_reader({grid_zoom_enabled=true,grid_zoom_rtl=true}),'global grid preferences persist')
expect(s:get_reader().grid_zoom_enabled and s:get_reader().grid_zoom_rtl,'read grid preferences')
expect(s:set_reader({panel_zoom_enabled=true}) and s:get_reader().grid_zoom_enabled,
    'grid does not turn off an independently configured panel mode')
local a,b=string.rep('a',32),string.rep('b',32)
expect(s:set_panel_reader(a,{grid_zoom_enabled=false,grid_zoom_rtl=false,grid_zoom_guides=false}),
    'reuse current-book preference storage')
expect(not s:get_panel_reader(a).grid_zoom_enabled and not s:get_panel_reader(a).grid_zoom_guides,
    'current book can disable default grid and guides')
expect(s:get_panel_reader(b).grid_zoom_enabled and s:get_panel_reader(b).grid_zoom_guides,
    'another book keeps default settings')
expect(s:set_panel_reader(a,{grid_zoom_enabled=true,grid_zoom_guides=false},true),
    'long-press saves book and future-book defaults')
expect(s:get_reader().grid_zoom_enabled and not s:get_reader().grid_zoom_guides,
    'long-press changes defaults')
failed=true
expect(not s:set_panel_reader(a,{grid_zoom_enabled=false},true),'failed flush rejects update')
expect(s:get_panel_reader(a).grid_zoom_enabled and s:get_reader().grid_zoom_enabled,
    'failed flush restores book and default state')
failed=false
for _,key in ipairs({'grid_zoom_enabled','grid_zoom_rtl','grid_zoom_guides'}) do
    expect(not s:set_reader({[key]='yes'}),'reject invalid '..key)
end
data.reader={grid_zoom_enabled='yes',grid_zoom_rtl=1,grid_zoom_guides='no'}
local restored=s:get_reader()
expect(not restored.grid_zoom_enabled and not restored.grid_zoom_rtl and restored.grid_zoom_guides,
    'invalid saved grid preferences normalize safely')
local UISettings=require('webdavmanga.ui_settings')
local form
local ui=UISettings:new{settings=s,client_factory=function() return {} end,async={},cache={},
    ui={show_reader=function(_,v) form=v end,show_info=function() end}}
ui:show_reader('grid')
form.values.grid_zoom_enabled=true
form.values.grid_zoom_rtl=true
form.values.grid_zoom_guides=false
expect(form.on_save(form.values),'global form saves independent grid section')
local saved=s:get_reader()
expect(saved.grid_zoom_enabled and saved.grid_zoom_rtl and not saved.grid_zoom_guides,
    'form normalization preserves all grid choices')
print('rebuild_0426_grid_settings_spec: '..checks..' checks passed')
