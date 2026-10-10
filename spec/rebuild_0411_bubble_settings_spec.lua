local Settings=require("webdavmanga.settings")
local UiSettings=require("webdavmanga.ui_settings")
local stored,about,help,form={}
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local settings=Settings:new{store={readSetting=function(_,key,default) return stored[key] or default end,
    saveSetting=function(_,key,value) stored[key]=value end,flush=function() return true end}}
local defaults=settings:get_reader()
expect(defaults.bubble_zoom_enabled==false and defaults.bubble_zoom_trigger=="both"
    and defaults.bubble_zoom_scale==2,"bubble remains opt-in and defaults to dialogue-priority gestures")
local values={};for k,v in pairs(defaults) do values[k]=v end
values.bubble_zoom_enabled=true;values.bubble_zoom_trigger="tap";values.bubble_zoom_scale=3
expect(settings:set_reader(values) and settings:get_reader().bubble_zoom_enabled
    and settings:get_reader().bubble_zoom_trigger=="tap" and settings:get_reader().bubble_zoom_scale==3,
    "bubble preferences persist")
for _,pair in ipairs({{"bubble_zoom_enabled",1},{"bubble_zoom_trigger","swipe"},{"bubble_zoom_scale",2.5}}) do
    local bad={};for k,v in pairs(values) do bad[k]=v end;bad[pair[1]]=pair[2]
    expect(not settings:set_reader(bad),"invalid bubble preference rejected: "..pair[1])
end
local ui=UiSettings:new{settings=settings,client_factory=function() return {} end,async={},cache={},
    ui={show_about=function(_,model) about=model end,
    show_reader_help=function(_,text) help=text;return true end,
    show_reader=function(_,model) form=model end,show_info=function() end}}
ui:show_about("0.4.11",{})
local action
for _,item in ipairs(about.actions) do if item.text=="漫画阅读说明" then action=item end end
expect(action and action.callback(),"about menu opens built-in manga instructions")
expect(help and help:find("气泡放大",1,true) and help:find("双指",1,true)
    and help:find("长按",1,true),"instructions explain bubble and quadrant operations")
ui:show_reader("display")
expect(form.values.bubble_zoom_enabled and form.values.bubble_zoom_trigger=="tap"
    and form.values.bubble_zoom_scale==3,"global editor shows saved bubble preferences")
local draft={};for k,v in pairs(form.values) do draft[k]=v end
draft.bubble_zoom_enabled=false;draft.bubble_zoom_trigger="hold";draft.bubble_zoom_scale=1.5
expect(form.on_save(draft) and settings:get_reader().bubble_zoom_enabled==false
    and settings:get_reader().bubble_zoom_trigger=="hold" and settings:get_reader().bubble_zoom_scale==1.5,
    "global editor normalization preserves all bubble choices including false")
print("rebuild_0411_bubble_settings_spec: "..checks.." checks passed")
