local pixels=dofile(assert(TEST_REPO_ROOT).."/spec/fixtures/webtoon_buffer.lua")
local Zoom=require("webdavmanga.bubble_zoom")
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local function speech(x,y)
    if x>=20 and x<=60 and y>=25 and y<=60 then
        if x<22 or x>58 or y<27 or y>58 then return 0 end
        if x>=37 and x<=40 and y>=35 and y<=49 then return 30 end
        return 250
    end
    return 230
end
local page=pixels.new(100,120,speech)
for _,point in ipairs({{x=30,y=40},{x=39,y=42}}) do
    local box=Zoom.detect(page,point)
    expect(box and box.x<=20 and box.y<=25 and box.x+box.w>=61 and box.y+box.h>=61,
        "white bubble bounds include all dialogue even when held on dark lettering")
    expect(box.w<55 and box.h<50,"detection does not select the rest of the page")
end
expect(Zoom.detect(page,{x=5,y=5})==nil,"unbounded page background is not a bubble")
expect(Zoom.detect(pixels.new(100,120),{x=50,y=50})==nil,"empty page is rejected")
expect(Zoom.detect(page,{x=-1,y=50})==nil,"out-of-image point is rejected")
expect(Zoom.detect({getWidth=function() return 100 end,getHeight=function() return 120 end},
    {x=50,y=50})==nil,"missing pixel API fails safely")
local gray=pixels.new(100,120,function(x,y) local p=speech(x,y);return p==250 and 170 or p==230 and 120 or p end)
expect(Zoom.detect(gray,{x=30,y=40})~=nil,"adaptive detection supports gray dialogue paper")
local broken=pixels.new(100,120,function(x,y)
    if x>=35 and x<=45 and y<=28 then return 250 end
    return speech(x,y)
end)
expect(Zoom.detect(broken,{x=30,y=40})==nil,"an open bubble cannot flood into page background")
local function nested(letter)
    return pixels.new(100,120,function(x,y)
        if x>=20 and x<=80 and y>=25 and y<=90 then
            if x<22 or x>78 or y<27 or y>88 then return 0 end
            return letter(x,y) and 0 or 250
        end
        return 230
    end)
end
local hollow=nested(function(x,y)
    return x>=40 and x<=60 and y>=45 and y<=65
        and (x<42 or x>58 or y<47 or y>63)
end)
local hollow_box=Zoom.detect(hollow,{x=50,y=55})
expect(hollow_box and hollow_box.w>=61 and hollow_box.h>=66,
    "holding inside a hollow character selects dialogue instead of its white counter")
local recursive=nested(function(x,y)
    return (x>=40 and x<=70 and y>=45 and y<=75 and (x<42 or x>68 or y<47 or y>73))
        or (x>=50 and x<=60 and y>=55 and y<=65 and (x<52 or x>58 or y<57 or y>63))
end)
expect(Zoom.detect(recursive,{x=55,y=60})==nil,
    "nested glyphs with multiple plausible closed regions fail conservatively")
expect(Zoom.detect(recursive,{x=30,y=40})~=nil,
    "pressing dialogue paper outside the ambiguous glyph still opens the bubble")
local reads=0
local huge=pixels.new(30000,40000,function() reads=reads+1;return 255 end)
expect(Zoom.detect(huge,{x=15000,y=20000})==nil and reads<=65536,
    "huge image analysis reads at most 256x256 samples")
local image={x=150,y=0,w=300,h=800}
expect(Zoom.map_point({x=149,y=20},image,600,1600)==nil,"letterboxing is not treated as image pixels")
local p=Zoom.map_point({x=300,y=400},image,600,1600)
expect(p and p.x==300 and p.y==800,"screen point maps through actual displayed dimensions")
expect(Zoom.map_point({x=450,y=400},image,600,1600)==nil,"right edge is exclusive")
local destination=Zoom.overlay_rect({x=0,y=0,w=150,h=100},2,{x=10,y=10},600,800)
expect(destination and destination.w==300 and destination.h==200 and destination.x>=0 and destination.y>=0,
    "edge bubble enlarges without leaving the screen")
local big=Zoom.overlay_rect({w=500,h=700},3,{x=599,y=799},600,800)
expect(big.w<=600 and big.h<=800 and math.abs(big.w/big.h-500/700)<0.01,
    "large bubble fits without stretching or clipping")
print("rebuild_0411_bubble_zoom_spec: "..checks.." checks passed")
