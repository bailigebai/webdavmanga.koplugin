local Profile=require('webdavmanga.panel_detection_profile')
local Analysis=require('webdavmanga.panel_analysis')
local checks=0
local function expect(v,m)checks=checks+1;assert(v,m)end
expect(Profile.threshold({[255]=2000,[217]=2000},255,40)==20,'white page faint lines')
expect(Profile.threshold({[180]=2000,[150]=2000},180,50)==25,'gray page relative contrast')
expect(Profile.threshold({[0]=2000,[255]=2000},0,40)==60,'dark background white frames')
expect(Profile.threshold({[180]=4000},180,50)==50,'uniform page keeps baseline')
expect(Profile.threshold({},255,37)==37,'empty histogram keeps baseline')
for baseline=1,254 do
 local value=Profile.threshold({[255]=1000,[0]=1000},255,baseline)
 expect(value%1==0 and value>=math.max(1,math.ceil(baseline*.5))
  and value<=math.min(254,math.floor(baseline*1.5)),'strict bounds including odd baselines')
end
local function page(background,frame)
 local reads=0;local buffer={}
 function buffer:getWidth()return 200 end
 function buffer:getHeight()return 240 end
 function buffer:getPixel(x,y)
  reads=reads+1
  for _,r in ipairs({{10,20,80,90},{110,20,80,90},{10,140,180,90}})do
   if x>=r[1] and x<r[1]+r[3] and y>=r[2] and y<r[2]+r[4]
    and (x<r[1]+3 or x>=r[1]+r[3]-3 or y<r[2]+3 or y>=r[2]+r[4]-3)then return frame end
  end
  return background
 end
 function buffer:free()error('borrowed page must never be freed by detection')end
 return {buffer=buffer},function()return reads end
end
for _,colors in ipairs({{255,217},{180,150},{0,255}})do
 local raster,reads=page(colors[1],colors[2])
 local manual=Analysis.detect(raster,{detection_threshold=40})
 local options={detection_threshold=40,auto_detection=true}
 local panels,reason,diagnostic=Analysis.detect(raster,options)
 expect(panels and #panels==3,'adaptive detects reliable light, gray and dark frames: '..tostring(reason))
 expect(diagnostic and diagnostic.threshold~=40,'adaptive threshold actually changes this detection')
 expect(options.detection_threshold==40,'manual value remains unchanged')
 expect(reads()==2*200*240,'reuse each scan without extra original pixel reads')
 if colors[1]==255 then expect(not manual,'faint default manual page safely falls back')end
end
local reads=0
local huge={buffer={getWidth=function()return 1000000 end,getHeight=function()return 900000 end,
 getPixel=function()reads=reads+1;return 180 end}}
expect(not Analysis.detect(huge,{auto_detection=true}),'uniform huge page falls back')
expect(reads<=480*480,'adaptive sampling is bounded')
local dialogue=page(255,0);local pixel=dialogue.buffer.getPixel
dialogue.buffer.getPixel=function(self,x,y)
 if x>=96 and x<=100 and y>=60 and y<=64 then return 200 end
 return pixel(self,x,y)
end
local panels,reason,diagnostic=Analysis.detect(dialogue,{auto_detection=true,detection_threshold=40})
expect(panels and #panels==3 and diagnostic.threshold==60,'strong frames keep their ordering candidates')
expect(panels[1].protect.x+panels[1].protect.w>=101/200,'raised adaptive threshold must preserve faint overflow dialogue')
local Settings=require('webdavmanga.settings')
local data={};local settings=Settings:new{store={readSetting=function(_,k,d)return data[k] or d end,
 saveSetting=function(_,k,v)data[k]=v end,flush=function()return true end}}
local defaults=settings:get_reader()
expect(defaults.panel_auto_detection_enabled==false and defaults.dynamic_panel_auto_detection_enabled==false,'adaptive switches default off')
local fixture=dofile('spec/helpers/reader_quadrant_host.lua');local reader=fixture(false)
reader.settings=settings;reader.reader_settings=defaults
reader:toggle_controls('dynamic_advanced')
reader.shell.current_model.actions[1].callback()
expect(reader.reader_settings.dynamic_panel_auto_detection_enabled==true
 and reader.shell.current_model.section=='dynamic_advanced','adaptive toggle retains advanced direct page')
reader.shell.current_model.actions[2].callback()
expect(reader.shell.current_model.section=='dynamic','advanced return goes to dynamic parent')
print('panel_auto_detection_spec: '..checks..' checks')
