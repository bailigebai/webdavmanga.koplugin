-- Detection works on a bounded map of the borrowed displayed page. Ordering
-- frames never include display padding. Every remaining substantial ink region
-- must be protected or detection fails rather than silently cutting it away.
local Arrays = require("webdavmanga.panel_arrays")
local Components = require("webdavmanga.panel_components")
local Geometry = require("webdavmanga.panel_geometry")
local Analysis = {}
local MAX_SIDE = 480
local function finite(v)
    return type(v)=="number" and v==v and math.abs(v)<math.huge
end
local function gray(buffer,x,y)
    local pixel=buffer:getPixel(x,y)
    local value=tonumber(type(pixel)=="number" and pixel or pixel:getColor8().a)
    assert(finite(value),"invalid_pixel")
    return math.max(0,math.min(255,math.floor(value)))
end
local function sample(raster)
    local b=assert(raster.buffer)
    local bw,bh=b:getWidth(),b:getHeight()
    assert(finite(bw) and finite(bh) and bw>=8 and bh>=8,"invalid_page")
    local crop=raster.crop or {x=0,y=0,w=1,h=1}
    for _,key in ipairs({"x","y","w","h"}) do assert(finite(crop[key]),"invalid_crop") end
    local left,top=math.max(0,crop.x)*bw,math.max(0,crop.y)*bh
    local width,height=math.min(bw,left+crop.w*bw)-left,math.min(bh,top+crop.h*bh)-top
    assert(width>=8 and height>=8,"invalid_crop")
    local scale=math.min(1,MAX_SIDE/math.max(width,height))
    local w,h=math.max(1,math.floor(width*scale)),math.max(1,math.floor(height*scale))
    local data=Arrays.new("uint8_t[?]",w*h)
    local histogram,total={},0
    local band=math.max(1,math.floor(math.min(w,h)*.01))
    for y=0,h-1 do for x=0,w-1 do
        local value=gray(b,math.min(bw-1,math.floor(left+(x+.5)*width/w)),
            math.min(bh-1,math.floor(top+(y+.5)*height/h)))
        data[y*w+x]=value
        if x<band or x>=w-band or y<band or y>=h-band then
            histogram[value]=(histogram[value] or 0)+1;total=total+1
        end
    end end
    local background,count=255,0
    for value=0,255 do
        count=count+(histogram[value] or 0)
        if count>=total/2 then background=value;break end
    end
    if background>31 and background<224 then
        -- A white gutter spanning the page is stronger evidence than artwork
        -- touching the border. Preserve genuinely black page backgrounds.
        local white=false
        for y=0,h-1 do
            local n=0;for x=0,w-1 do if data[y*w+x]>=224 then n=n+1 end end
            if n>=w*.8 then white=true;break end
        end
        if not white then for x=0,w-1 do
            local n=0;for y=0,h-1 do if data[y*w+x]>=224 then n=n+1 end end
            if n>=h*.8 then white=true;break end
        end end
        if white then background=255 end
    end
    local ink=0
    for i=0,w*h-1 do
        data[i]=math.abs(data[i]-background)>40 and 1 or 0
        ink=ink+data[i]
    end
    return {w=w,h=h,data=data,ink=ink}
end
local function padded(r,map,amount)
    local x,y=math.max(0,math.floor(r.x-amount)),math.max(0,math.floor(r.y-amount))
    local right,bottom=math.min(map.w,math.ceil(r.x+r.w+amount)),math.min(map.h,math.ceil(r.y+r.h+amount))
    return {x=x,y=y,w=right-x,h=bottom-y}
end
local function distance(a,b)
    local dx=math.max(0,a.x-b.x-b.w,b.x-a.x-a.w)
    local dy=math.max(0,a.y-b.y-b.h,b.y-a.y-a.h)
    return math.sqrt(dx*dx+dy*dy)
end
local function protect(panels,map)
    local seen=Arrays.new("uint8_t[?]",map.w*map.h)
    for _,p in ipairs(panels) do
        p.protect=padded(p.protect or p,map,2)
        local r=p.protect
        for y=r.y,r.y+r.h-1 do for x=r.x,r.x+r.w-1 do seen[y*map.w+x]=1 end end
    end
    local queue=Arrays.new("int32_t[?]",map.w*map.h)
    for seed=0,map.w*map.h-1 do
        if map.data[seed]==1 and seen[seed]==0 then
            local head,tail=0,1;queue[0]=seed;seen[seed]=1
            local x1,y1,x2,y2=map.w,map.h,0,0
            while head<tail do
                local i=queue[head];head=head+1
                local x,y=i%map.w,math.floor(i/map.w)
                x1,y1,x2,y2=math.min(x1,x),math.min(y1,y),math.max(x2,x),math.max(y2,y)
                for ny=math.max(0,y-1),math.min(map.h-1,y+1) do
                    for nx=math.max(0,x-1),math.min(map.w-1,x+1) do
                        local n=ny*map.w+nx
                        if map.data[n]==1 and seen[n]==0 then seen[n]=1;queue[tail]=n;tail=tail+1 end
                    end
                end
            end
            if tail>3 then
                local orphan={x=x1,y=y1,w=x2-x1+1,h=y2-y1+1}
                local nearest=math.huge
                for _,p in ipairs(panels) do nearest=math.min(nearest,distance(orphan,p)) end
                if nearest>math.min(map.w,map.h)*.12 then return nil,"panel_content_uncovered" end
                -- At an ambiguous boundary include the content in both views.
                -- It is never used to change the frame ID or reading order.
                local attached=false
                for _,p in ipairs(panels) do
                    if distance(orphan,p)<=nearest+1 then
                        local union=Geometry.rectUnion(p.protect,padded(orphan,map,2))
                        if union.w*union.h>math.max(p.w*p.h*2.5,map.w*map.h*.12) then
                            return nil,"panel_content_uncovered"
                        end
                        p.protect=union;attached=true
                    end
                end
                if not attached then return nil,"panel_content_uncovered" end
            end
        end
    end
    return panels
end
local function detect(raster)
    local map=sample(raster)
    if map.ink==0 then return nil,"no_panels" end
    local panels,reason=Components.segment(map,{component_frame_min=1,segment_max_panels=64})
    if #panels==0 then return nil,reason or "no_panels" end
    if #panels==1 and panels[1].w*panels[1].h<map.w*map.h*.6 then
        return nil,"panel_layout_uncertain"
    end
    local value,reason=protect(panels,map)
    if not value then return nil,reason end
    for _,p in ipairs(panels) do
        p.x,p.y,p.w,p.h=p.x/map.w,p.y/map.h,p.w/map.w,p.h/map.h
        local r=p.protect;r.x,r.y,r.w,r.h=r.x/map.w,r.y/map.h,r.w/map.w,r.h/map.h
        p.id=("%.9f:%.9f:%.9f:%.9f"):format(p.x,p.y,p.w,p.h)
    end
    return panels
end
function Analysis.detect(raster)
    local ok,value,reason=pcall(detect,raster)
    if not ok then return nil,"panel_detection_failed" end
    return value,reason
end
function Analysis.release() Components.clearScratch() end
return Analysis
