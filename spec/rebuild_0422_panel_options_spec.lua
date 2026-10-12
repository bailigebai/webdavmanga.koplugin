local Settings=require("webdavmanga.settings")
local UISettings=require("webdavmanga.ui_settings")
local values={}
local s=Settings:new{store={readSetting=function(_,k,d) return values[k] or d end,
saveSetting=function(_,k,v) values[k]=v end,flush=function() return true end}}
local key=string.rep("f",32)
assert(s:set_panel_reader(key,{panel_transition_mode="native",panel_protect_text=false}),
    "advanced settings must persist in the current-book profile")
assert(s:get_panel_reader(key).panel_transition_mode=="native" and s:get_reader().panel_transition_mode=="classic",
    "book transitions must not silently change other books")
assert(not s:set_panel_reader(key,{panel_transition_frames=1000}),"reject unbounded animation work")
assert(not s:set_panel_reader(key,{panel_transition_duration=0/0}),"reject invalid animation time")
local form
local ui=UISettings:new{settings=s,client_factory=function() return {} end,async={},cache={},
    ui={show_reader=function(_,v) form=v end,show_info=function() end}}
ui:show_reader("panel")
form.values.panel_transition_mode="native"
form.values.panel_detection_threshold="37"
assert(form.on_save(form.values) and s:get_reader().panel_transition_mode=="native"
    and s:get_reader().panel_detection_threshold==37,"global numeric form must retain exact advanced options on save")
form.values.panel_detection_threshold="37.5"
assert(not form.on_save(form.values) and s:get_reader().panel_detection_threshold==37,
    "invalid numeric global input must retain the previous threshold")
print("rebuild_0422_panel_options_spec: profile and controls passed")
