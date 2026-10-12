local Detector=require('webdavmanga.panel_detector')
local pixels=dofile('spec/fixtures/webtoon_buffer.lua')
local function artwork(x,y)
    for _,c in ipairs({{55,65},{165,65},{55,185},{165,185}}) do
        if ((x-c[1])/40)^2+((y-c[2])/48)^2<=1 then return 0 end
    end
    return 255
end
for _,dark in ipairs({false,true}) do
    local page=pixels.new(220,250,function(x,y) local v=artwork(x,y);return dark and 255-v or v end)
    local result,reason=Detector.detect({buffer=page},{direction='normal'})
    assert(result and #result==4,'borderless artwork separated by gutters must produce four panels: '..tostring(reason))
    assert(result[1].x<.5 and result[1].y<.5 and result[2].x>.5 and result[3].y>.5,'reading order must remain row based')
end
local faint=pixels.new(200,240,function(x,y)
    for _,r in ipairs({{10,20,80,90},{110,20,80,90},{10,140,180,90}}) do
        if x>=r[1] and x<r[1]+r[3] and y>=r[2] and y<r[2]+r[4]
            and (x<r[1]+3 or x>=r[1]+r[3]-3 or y<r[2]+3 or y>=r[2]+r[4]-3) then return 217 end
    end
    return 255
end)
assert(not Detector.detect({buffer=faint},{detection_threshold=40}),'default must not invent invisible ink')
assert(#assert(Detector.detect({buffer=faint},{detection_threshold=37}))==3,'exact37 threshold must detect faint38delta lines')
local Gutters=require('webdavmanga.panel_gutters')
local map={w=240,h=240,data={},ink=0,bg=255}
for y=0,239 do for x=0,239 do
    local split=120+.12*(y-120)
    local ink=x>=10 and x<230 and y>=10 and y<230 and math.abs(x-split)>3
    map.data[y*240+x]=ink and 1 or 0;map.ink=map.ink+map.data[y*240+x]
end end
local diagonal=Gutters.segment(map)
assert(#diagonal==2,'slanted gutters must divide a page without an axis-aligned white gap')
assert(diagonal[1].w>100 and diagonal[2].w>100,'slanted display bounds must retain widening corners')
-- The inner white stripe of a drawn speech/panel frame must not split it.
local framed={w=200,h=200,data={},ink=0,bg=255}
for y=0,199 do for x=0,199 do
    local ink=x>=10 and x<190 and y>=10 and y<190 and
        (x<13 or x>=187 or y<13 or y>=187 or x>=30 and x<75 or x>=125 and x<170)
    framed.data[y*200+x]=ink and 1 or 0;framed.ink=framed.ink+framed.data[y*200+x]
end end
assert(#Gutters.segment(framed)==1,'Meguru body evidence must block internal whitespace splits')
print('panel_gutters_spec: borderless white/dark pages, order and precise faint thresholds passed')
