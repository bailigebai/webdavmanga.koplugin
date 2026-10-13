-- Real KindleHF LuaJIT arrays and KOReader BlitBuffer over user sample pixels.
local ffi=require('ffi')
assert(ffi.arch=='arm' and ffi.abi('32bit'))
package.preload['ffi/util']=function() return {idiv=function(a,b) return math.floor(a/b) end} end
local BB=require('ffi/blitbuffer')
local json=require('json')
local Detector=require('webdavmanga.panel_detector')
ffi.loadlib=function(name)assert(name=='leptonica');return ffi.load('/native/libs/libleptonica.so.6')end
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local Web=require('webdavmanga.web_panel_zoom')
local variants={
    {name='intelligent',detect=Detector.detect},
    {name='intelligent-auto',detect=Detector.detect,auto=true},
    {name='dynamic',detect=Dynamic.detect,threshold=50},
    {name='dynamic-auto',detect=Dynamic.detect,threshold=50,auto=true},
    {name='web',detect=Web.detect,strength=100},
    {name='web-strong',detect=Web.detect,strength=175},
}
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local manifest=json.decode(read('/samples/samples.json'))
local results={}
for _,sample in ipairs(manifest) do
    local data=read('/samples/'..sample.file)
    assert(#data==sample.width*sample.height)
    local b=BB.new(sample.width,sample.height,BB.TYPE_BB8)
    ffi.copy(b.data,data,#data)
    for _,variant in ipairs(variants)do
    local options={direction='manga',detection_threshold=type(sample.threshold)=="number" and sample.threshold or variant.threshold or 40,
        auto_detection=variant.auto==true,min_side_percent=12.5,strength_percent=variant.strength or 100,
        min_area_permille=2,frame_min=1,dialogue_distance_percent=12}
    local started=os.clock()
    local panels,reason,diagnostic=variant.detect({buffer=b,max_width=960,max_height=960},options)
    local elapsed=os.clock()-started
    assert(b:getWidth()==sample.width,'detector must leave the borrowed buffer alive')
    local expected=type(sample.expected)=='table' and sample.expected[variant.name]
        or type(sample.expected)=='number' and variant.name=='intelligent' and sample.expected or nil
    if sample.label=='blank' then expected=0 end
    if expected~=nil then assert((panels and #panels or 0)==expected,sample.label..'/'..variant.name..': '..tostring(reason)) end
    assert(ffi.string(b.data,#data)==data,'borrowed original pixels changed')
    if diagnostic and diagnostic.threshold then
        local baseline=options.detection_threshold
        if variant.auto then assert(diagnostic.threshold>=math.max(1,math.ceil(baseline*.5))
            and diagnostic.threshold<=math.min(254,math.floor(baseline*1.5)),'adaptive range')end
    end
    for _,p in ipairs(panels or {}) do
        for _,r in ipairs({p,p.protect}) do
            assert(r.x>=0 and r.y>=0 and r.w>0 and r.h>0 and r.x+r.w<=1.000001 and r.y+r.h<=1.000001,'invalid protected rectangle')
        end
    end
    results[#results+1]={label=sample.label,mode=variant.name,options=options,effective_profile=diagnostic,count=panels and #panels or 0,reason=reason,
        panels=panels or {},seconds=elapsed,expected=expected,borrowed_pixels_unchanged=true}
    require('webdavmanga.panel_analysis').release()
    require('webdavmanga.web_panel_analysis').release()
    end
    b:free()
    collectgarbage('collect')
end
local f=assert(io.open('/output/panel-native-result.json','wb'))
f:write(json.encode({arch=ffi.arch,cases=results}));f:close()
print('panel_analysis_native: '..#results..' samples, borrowed buffers intact')
