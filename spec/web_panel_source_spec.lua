local Web=require('webdavmanga.web_panel_zoom')
local Detector=require('webdavmanga.panel_detector')
package.preload['mangaweb.panel_arrays']=function()return require('webdavmanga.panel_arrays')end
package.preload['mangaweb.panel_geometry']=function()return require('webdavmanga.panel_geometry')end
package.preload['mangaweb.panel_components']=function()return dofile('spec/fixtures/mangaweb-v0.8.91/panel_components.lua')end
local Original=dofile('spec/fixtures/mangaweb-v0.8.91/panel_analysis.lua')
local checks=0
local function expect(v,m)checks=checks+1;assert(v,m)end
for _,name in ipairs({'panel_analysis','panel_components'})do
 local input=assert(io.open('spec/fixtures/mangaweb-v0.8.91/'..name..'.lua','rb'));local raw=input:read('*a');input:close()
 local output=assert(io.open('webdavmanga.koplugin/webdavmanga/web_'..name..'.lua','rb'));local actual=output:read('*a');output:close()
 local expected=raw:gsub('mangaweb%.panel_arrays','webdavmanga.panel_arrays')
  :gsub('mangaweb%.panel_geometry','webdavmanga.panel_geometry'):gsub('mangaweb%.panel_components','webdavmanga.web_panel_components')
 expect(actual==expected,'source extraction changes only documented namespaces')
end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for k,v in pairs(a)do if not equal(v,b[k])then return false end end
 for k in pairs(b)do if a[k]==nil then return false end end
 return true
end
local function canvas()
 local data={};local c={}
 function c:fill(x,y,w,h,tone)for yy=y,y+h-1 do for xx=x,x+w-1 do data[yy*200+xx]=tone end end end
 function c:ring(x,y,w,h,tone)self:fill(x,y,w,1,tone);self:fill(x,y+h-1,w,1,tone);self:fill(x,y,1,h,tone);self:fill(x+w-1,y,1,h,tone)end
 c.raster={buffer={getWidth=function()return 200 end,getHeight=function()return 200 end,getPixel=function(_,x,y)return data[y*200+x]or 255 end}}
 return c
end
local defaults={};Web.normalize(defaults)
expect(defaults.web_panel_strength_percent==100 and defaults.web_panel_min_area_permille==2
 and defaults.web_panel_frame_min==1 and defaults.web_panel_dialogue_distance_percent==12,'source defaults')
local cases={}
local pale=canvas();pale:ring(10,10,80,80,220);pale:ring(110,10,80,80,220)
cases[#cases+1]={pale,{}};cases[#cases+1]={pale,{strength_percent=200}}
local small=canvas();small:ring(10,10,80,80,0);small:ring(110,10,80,80,0);small:ring(10,150,10,10,0)
cases[#cases+1]={small,{}};cases[#cases+1]={small,{min_area_permille=20}}
local strict=canvas();strict:fill(10,10,80,1,0);strict:fill(10,10,1,80,0);strict:ring(110,10,80,80,0)
cases[#cases+1]={strict,{frame_min=4}}
local dialogue=canvas();dialogue:ring(10,10,80,120,0);dialogue:ring(145,10,45,120,0);dialogue:fill(115,70,5,5,0)
cases[#cases+1]={dialogue,{}};cases[#cases+1]={dialogue,{dialogue_distance_percent=20}}
local layout=canvas();layout:ring(10,10,80,60,0);layout:ring(110,10,80,100,0);layout:ring(10,90,80,100,0);layout:ring(110,130,80,60,0)
cases[#cases+1]={layout,{direction='manga'}}
for _,case in ipairs(cases)do
 local upstream,reason=Original.detect(case[1].raster,case[2]);if upstream then upstream=Detector.sort(upstream,case[2].direction or 'normal')end
 local actual,err=Web.detect(case[1].raster,case[2])
 expect(equal(actual,upstream) and reason==err,'identical source panels, protection and failure semantics')
end
local values={web_panel_strength_percent=175,web_panel_dialogue_distance_percent=20};Web.normalize(values)
local request=Web.request(values,{view='free',direction='manga'})
expect(request.strength_percent==175 and request.dialogue_distance_percent==20 and request.view=='free','source tuning reaches detector without replacing view')
values.web_panel_zoom_enabled=true;values.panel_view='cut';values.panel_order='manga'
Web.restore_detection(values)
expect(values.web_panel_zoom_enabled and values.panel_view=='cut' and values.panel_order=='manga' and values.web_panel_strength_percent==100,'restore only recognition fields')
print('web_panel_source_spec: '..checks..' checks')
