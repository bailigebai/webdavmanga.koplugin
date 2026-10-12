-- Real KindleHF LuaJIT arrays and KOReader BlitBuffer over user sample pixels.
local ffi=require('ffi')
assert(ffi.arch=='arm' and ffi.abi('32bit'))
package.preload['ffi/util']=function() return {idiv=function(a,b) return math.floor(a/b) end} end
local BB=require('ffi/blitbuffer')
local json=require('json')
local Detector=require('webdavmanga.panel_detector')
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local manifest=json.decode(read('/samples/samples.json'))
local results={}
for _,sample in ipairs(manifest) do
    local data=read('/samples/'..sample.file)
    assert(#data==sample.width*sample.height)
    local b=BB.new(sample.width,sample.height,BB.TYPE_BB8)
    ffi.copy(b.data,data,#data)
    local started=os.clock()
    local panels,reason=Detector.detect({buffer=b},{direction='manga',detection_threshold=sample.threshold or 40})
    local elapsed=os.clock()-started
    assert(b:getWidth()==sample.width,'detector must leave the borrowed buffer alive')
    if type(sample.expected)=='number' then assert((panels and #panels or 0)==sample.expected,sample.label..': '..tostring(reason)) end
    for _,p in ipairs(panels or {}) do
        for _,r in ipairs({p,p.protect}) do
            assert(r.x>=0 and r.y>=0 and r.w>0 and r.h>0 and r.x+r.w<=1.000001 and r.y+r.h<=1.000001,'invalid protected rectangle')
        end
    end
    results[#results+1]={label=sample.label,count=panels and #panels or 0,reason=reason,
        panels=panels or {},seconds=elapsed,expected=sample.expected}
    b:free()
    require('webdavmanga.panel_analysis').release()
    collectgarbage('collect')
end
local f=assert(io.open('/output/panel-native-result.json','wb'))
f:write(json.encode({arch=ffi.arch,cases=results}));f:close()
print('panel_analysis_native: '..#results..' samples, borrowed buffers intact')
