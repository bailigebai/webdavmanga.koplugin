-- Actual ARM LuaJIT, KOReader Blitbuffer and packaged Leptonica. No network.
local ffi=require('ffi')
assert(ffi.arch=='arm' and ffi.abi('32bit'))
local created,destroyed=0,0
ffi.loadlib=function(name)
    assert(name=='leptonica','unexpected optional library')
    local lib=ffi.load('/native/libs/libleptonica.so.6')
    return setmetatable({}, {__index=function(_,key)
        local fn=lib[key]
        if key=='pixDestroy' or key=='boxDestroy' or key=='boxaDestroy' then
            return function(p) if p[0]~=nil then destroyed=destroyed+1 end;return fn(p) end
        elseif key=='pixCreate' or key=='pixClone' or key=='pixConvertRGBToGrayFast'
            or key=='pixConvertTo8' or key=='pixScaleToSize' or key=='pixConnCompBB'
            or key=='pixClipRectangle' or key=='boxCreate' then
            return function(...) local p=fn(...);if p~=nil then created=created+1 end;return p end
        elseif key=='pixInvert' or key=='pixThresholdToBinary' then
            return function(a,b)
                local p=fn(a,b)
                if p~=nil and (key=='pixThresholdToBinary' or a==nil) then created=created+1 end
                return p
            end
        end
        return fn
    end})
end
package.preload['ffi/util']=function() return {idiv=function(a,b) return math.floor(a/b) end} end
local BB=require('ffi/blitbuffer')
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local json=require('json')
local results={}
local function run(label,buffer,count,direction)
    local started=os.clock()
    local panels,reason=Dynamic.detect({buffer=buffer,max_width=600,max_height=800},{direction=direction or 'normal'})
    assert((panels and #panels or 0)==count,label..': '..tostring(reason))
    assert(created==destroyed,label..': native allocation leak')
    results[#results+1]={label=label,panels=panels or {},reason=reason,seconds=os.clock()-started,
        created=created,destroyed=destroyed}
    return panels
end
local function page(dark)
    local b=BB.new(400,600,BB.TYPE_BB8)
    b:fill(BB.Color8(dark and 0 or 255))
    local ink=BB.Color8(dark and 255 or 0)
    for _,r in ipairs({{20,20,160,240},{220,20,160,240},{20,320,160,240},{220,320,160,240}}) do
        local x,y,w,h=unpack(r)
        b:paintRect(x,y,w,4,ink);b:paintRect(x,y+h-4,w,4,ink)
        b:paintRect(x,y,4,h,ink);b:paintRect(x+w-4,y,4,h,ink)
    end
    return b
end
local light=page(false)
local ltr=run('white-LTR',light,4)
assert(ltr[1].x==.05 and ltr[2].x==.55 and ltr[3].y>ltr[1].y)
local rtl=run('white-RTL',light,4,'manga')
assert(rtl[1].x==.55 and rtl[2].x==.05)
local dark=page(true);run('dark-LTR',dark,4)
local blank=BB.new(400,600,BB.TYPE_BB8);blank:fill(BB.Color8(255));run('blank',blank,0)
local reads=0
run('large-bounded',{getWidth=function() return 100000 end,getHeight=function() return 100000 end,
    getPixel=function() reads=reads+1;return 255 end},0)
assert(reads<=600*600,'sampling exceeds physical screen or longest-side cap')
local bad={getWidth=function() return 400 end,getHeight=function() return 600 end,
    getPixel=function() error('injected pixel failure') end}
run('pixel-failure-cleanup',bad,0)
for i=1,8 do run('repeat-'..i,light,4) end
light:free();dark:free();blank:free()
local f=assert(io.open('/output/dynamic-native-result.json','wb'))
f:write(json.encode({arch=ffi.arch,created=created,destroyed=destroyed,cases=results}));f:close()
print('dynamic_panel_native: '..#results..' cases, all native allocations released')
