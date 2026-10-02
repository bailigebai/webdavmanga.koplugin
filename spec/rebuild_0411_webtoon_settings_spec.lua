local Settings = require("webdavmanga.settings")
local Processor = require("webdavmanga.page_processor")
local saved = {}
local settings = Settings:new{store={readSetting=function(_,key,default) return saved[key] or default end,
    saveSetting=function(_,key,value) saved[key]=value end,flush=function() end}}
local values = settings:get_reader()
values.fit_mode="webtoon"
assert(settings:set_reader(values),"long-strip mode must be a persisted display mode")
assert(values.webtoon_overlap_percent==5 and values.webtoon_fit_percent==5
    and values.webtoon_smart_enabled==true and values.webtoon_margin_percent==0,
    "strip options must have conservative defaults")
for _, pair in ipairs({{"webtoon_overlap_percent",21},{"webtoon_overlap_percent",-1},
    {"webtoon_fit_percent",16},{"webtoon_margin_percent",21},{"webtoon_smart_enabled",1},
    {"display_background","unexpected"}}) do
    local copy={}; for key,value in pairs(values) do copy[key]=value end
    copy[pair[1]]=pair[2]
    assert(not settings:set_reader(copy),"invalid strip setting must be rejected: "..pair[1])
end
local w,h=Processor.target_size(1000,20000,values,600,800)
assert(w*h<=math.min(4*600*800,2*1024*1024),"strip decode targets need one shared bounded pixel budget")
assert(h>800 and math.abs(w/h-1000/20000)<0.001,"long strips stay proportional rather than being cropped")
values.split_enabled=true
local w2,h2=Processor.target_size(2000,1000,values,600,800)
assert(w2==600 and h2==300,"strip mode overrides spread splitting")
print("rebuild_0411_webtoon_settings_spec: passed")
