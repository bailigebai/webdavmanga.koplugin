local Detector=require("webdavmanga.panel_detector")
local pixels=dofile("spec/fixtures/webtoon_buffer.lua")
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local panels={
 {id="a",x=.05,y=.05,w=.25,h=.2}, {id="b",x=.35,y=.05,w=.25,h=.2},
 {id="c",x=.7,y=.05,w=.25,h=.7}, {id="d",x=.05,y=.35,w=.25,h=.2},
 {id="e",x=.35,y=.35,w=.25,h=.2},
}
local function ids(p) local s={};for _,v in ipairs(p) do s[#s+1]=v.id end;return table.concat(s,",") end
expect(ids(Detector.sort(panels,"normal"))=="a,b,d,e,c","cross-row trailing frame follows the whole leading stack")
expect(ids(Detector.sort(panels,"manga"))=="c,b,a,e,d","manga rows do not get chained into column order")
local function page(inverted,extra)
 return pixels.new(200,240,function(x,y)
  local ink=false
  for _,r in ipairs({{10,30,75,85},{110,30,75,85},{10,140,175,85}}) do
   if x>=r[1] and x<r[1]+r[3] and y>=r[2] and y<r[2]+r[4] then
    ink=x<r[1]+3 or x>=r[1]+r[3]-3 or y<r[2]+3 or y>=r[2]+r[4]-3
       or x>=r[1]+15 and x<r[1]+r[3]-15 and y>=r[2]+20 and y<r[2]+r[4]-20
   end
  end
  if extra and x>=25 and x<=60 and y>=18 and y<=38 then
   ink=ink or x<28 or x>57 or y<21 or y>35
  end
  local gray=ink and 0 or 255
  return inverted and 255-gray or gray
 end)
end
for _,inverted in ipairs({false,true}) do
 local result,reason=Detector.detect({buffer=page(inverted,true)}, {direction="normal"})
 expect(result and #result==3,"bounded pixel backend detects three panels on white and black backgrounds: "..tostring(reason))
 expect(result[1].protect and result[1].protect.y<=18/240 and result[1].y>=27/240,
  "detached/protruding speech expands display only, preserving the core order frame")
end
local count=0
local blank=pixels.new(30000,40000,function() count=count+1;return 255 end)
local value,reason=Detector.detect({buffer=blank},{direction="normal"})
expect(not value and reason=="no_panels" and count<=480*480+2000,"sampling bounds huge source work without copying it")
local pressure=pixels.new(384,384,function(x,y)
 local lx,ly=x%24,y%24
 return lx<18 and ly<18 and 0 or 255
end)
value,reason=Detector.detect({buffer=pressure},{})
expect(not value and reason=="too_many_panels","candidate pressure falls back before quadratic comparison")
local fine=pixels.new(845,1200,function(x,y)
 local ink=false
 for _,r in ipairs({{80,0,400,176},{500,0,270,176},{0,193,845,443},
  {80,655,221,291},{307,655,465,545},{80,951,221,249}}) do
  if x>=r[1] and x<r[1]+r[3] and y>=r[2] and y<r[2]+r[4] then
   ink=ink or x<r[1]+3 or x>=r[1]+r[3]-3 or y<r[2]+3 or y>=r[2]+r[4]-3
  end
 end
 if x>=754 and x<760 and y>=639 and y<=651 then ink=true end
 if x>=50 and x<=166 and y>=1020 and y<=1170 then
  ink=ink or x<53 or x>163 or y<1023 or y>1167
 end
 return ink and 0 or 255
end)
local panels,reason=Detector.detect({buffer=fine},{direction="manga"})
expect(panels and #panels==6,"thin white seams beside a page-number bridge preserve six frames: "..tostring(reason))
local protected=false
for _,p in ipairs(panels or {}) do
 local r=p.protect
 if r.x<=50/845 and r.y<=1020/1200 and r.x+r.w>=166/845 and r.y+r.h>=1170/1200 then protected=true end
end
expect(protected,"speech protruding out of the lower frame is fully protected")
print("rebuild_0412_panel_analysis_spec: "..checks.." checks passed")
