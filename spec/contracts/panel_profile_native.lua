local ffi=require('ffi')
assert(ffi.arch=='arm' and ffi.abi('32bit'))
package.preload['ffi/util']=function()return {idiv=function(a,b)return math.floor(a/b)end}end
local BB=require('ffi/blitbuffer')
require('ffi/leptonica_h')
local library=ffi.load('/native/libs/libleptonica.so.6')
local resources={PIX=0,BOX=0,BOXA=0}
local fail
local creators={pixCreate='PIX',pixClone='PIX',pixRead='PIX',pixReadMem='PIX',pixScaleToSize='PIX',
 pixClipRectangle='PIX',pixConvertRGBToGrayFast='PIX',pixConvertTo8='PIX',pixThresholdToBinary='PIX',boxCreate='BOX',pixConnCompBB='BOXA'}
local destructors={pixDestroy='PIX',boxDestroy='BOX',boxaDestroy='BOXA'}
local proxy=setmetatable({}, {__index=function(_,name)
 local fn=library[name]
 return function(...)
  if fail==name then
   fail=nil
   if name=='pixSetPixel' then return 1 end
   return ffi.cast('BOXA*',0)
  end
  local kind=destructors[name]
  if kind and select(1,...)[0]~=nil then resources[kind]=resources[kind]-1 end
  local result=fn(...)
  kind=creators[name]
  if name=='pixInvert' and select(1,...)==nil then kind='PIX' end
  if kind and result~=nil then resources[kind]=resources[kind]+1 end
  return result
 end
end})
ffi.loadlib=function(name)assert(name=='leptonica');return proxy end
local Detector=require('webdavmanga.panel_detector')
local cases=0
local function clean()
 for kind,count in pairs(resources)do assert(count==0,kind..' native ownership leak: '..count)end
end
local function page(background,frame)
 local b=BB.new(200,240,BB.TYPE_BB8);b:fill(BB.Color8(background))
 for _,r in ipairs({{10,20,80,90},{110,20,80,90},{10,140,180,90}})do
  local x,y,w,h=unpack(r);local color=BB.Color8(frame)
  b:paintRect(x,y,w,3,color);b:paintRect(x,y+h-3,w,3,color)
  b:paintRect(x,y,3,h,color);b:paintRect(x+w-3,y,3,h,color)
 end
 return b
end
for _,colors in ipairs({{255,217},{180,150},{0,255}})do
 local b=page(colors[1],colors[2]);local original=ffi.string(b.data,200*240)
 local panels,reason,diagnostic=Detector.detect_native({buffer=b,max_width=960,max_height=960},
  {auto_detection=true,detection_threshold=50,min_side_percent=12.5})
 assert(panels and #panels==3,'native adaptive frames: '..tostring(reason))
 assert(diagnostic.threshold~=50 and diagnostic.background==colors[1],'native effective profile')
 assert(ffi.string(b.data,200*240)==original,'display pixels were modified')
 clean();b:free();cases=cases+1
end
for _,stage in ipairs({'pixSetPixel','pixConnCompBB'})do
 local b=page(255,0);fail=stage
 local panels,reason=Detector.detect_native({buffer=b,max_width=960,max_height=960},{auto_detection=true})
 assert(not panels and reason=='panel_detection_failed','injected native failure must fall back')
 assert(b:getWidth()==200,'failure freed borrowed raster');clean();b:free();cases=cases+1
end
local cropped=BB.new(200,240,BB.TYPE_BB8);cropped:fill(BB.Color8(0))
cropped:paintRect(20,20,160,200,BB.Color8(255))
for _,r in ipairs({{30,30,60,80},{110,30,60,80},{30,130,140,80}})do
 local x,y,w,h=unpack(r);local color=BB.Color8(217)
 cropped:paintRect(x,y,w,3,color);cropped:paintRect(x,y+h-3,w,3,color)
 cropped:paintRect(x,y,3,h,color);cropped:paintRect(x+w-3,y,3,h,color)
end
local panels,reason,diagnostic=Detector.detect_native({buffer=cropped,max_width=960,max_height=960,
 crop={x=.1,y=20/240,w=.8,h=200/240}},{auto_detection=true})
assert(panels and #panels==3 and diagnostic.background==255,'profile must use cropped page background: '..tostring(reason))
clean();cropped:free();cases=cases+1
print('native-profile: '..cases..' real ARM/BB8/Leptonica cases; zero PIX/BOX/BOXA leaks; original pixels intact')

local f=assert(io.open('/output/profile-native-result.json','wb'))
f:write(require('json').encode({cases=cases,resources=resources,borrowed_pixels_unchanged=true}));f:close()
