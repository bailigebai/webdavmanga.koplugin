-- Pure source-coordinate camera geometry. Image rotation is independent of
-- page order, navigation direction and the device's orientation.
local View={}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function valid(r)
    return type(r)=="table" and finite(r.x) and finite(r.y) and finite(r.w) and finite(r.h)
        and r.w>0 and r.h>0 and r.x>=0 and r.y>=0 and r.x+r.w<=1.000001 and r.y+r.h<=1.000001
end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
function View.compute(panel,crop,width,height,options)
    options=options or {}
    if not valid(panel) or not valid(crop) or not finite(width) or not finite(height)
        or width<=0 or height<=0 then return nil,"invalid_panel" end
    local rotation=options.rotation or 0
    if rotation~=0 and rotation~=90 and rotation~=180 and rotation~=270 then return nil,"invalid_panel_rotation" end
    local view=options.view or "cut"
    if view~="cut" and view~="context" and view~="free" then return nil,"invalid_panel_view" end
    local tw,th=options.screen_width,options.screen_height
    if not finite(tw) or not finite(th) or tw<=0 or th<=0 then return nil,"invalid_panel_screen" end
    if rotation==90 or rotation==270 then tw,th=th,tw end
    local region=options.protect_text==false and panel or panel.protect or panel
    if not valid(region) then return nil,"invalid_panel" end
    local margin=options.margin_percent or 0
    if not finite(margin) then return nil,"invalid_panel_margin" end
    margin=clamp(margin,0,49)/100
    if options.show_adjacent~=false then
        local x,y=math.max(0,region.x-region.w*margin),math.max(0,region.y-region.h*margin)
        local right,bottom=math.min(1,region.x+region.w*(1+margin)),math.min(1,region.y+region.h*(1+margin))
        region={x=x,y=y,w=right-x,h=bottom-y}
    else tw,th=tw*(1-2*margin),th*(1-2*margin) end
    if view=="free" then region={x=0,y=0,w=1,h=1} end
    local bounds={x=crop.x*width,y=crop.y*height,w=crop.w*width,h=crop.h*height}
    local r={x=bounds.x+region.x*bounds.w,y=bounds.y+region.y*bounds.h,w=region.w*bounds.w,h=region.h*bounds.h}
    local zoom=options.zoom or 1
    local px,py=options.pan_x or 0,options.pan_y or 0
    if not finite(zoom) or zoom<1 or zoom>4 or not finite(px) or not finite(py) then return nil,"invalid_panel_camera" end
    local box=r
    if view~="cut" or zoom>1 then
        local limit=view=="cut" and r or bounds
        local fit=math.min(tw/r.w,th/r.h)*zoom
        local w,h=math.min(limit.w,tw/fit),math.min(limit.h,th/fit)
        local cx,cy=r.x+r.w/2+px*bounds.w,r.y+r.h/2+py*bounds.h
        box={x=clamp(cx-w/2,limit.x,limit.x+limit.w-w),
            y=clamp(cy-h/2,limit.y,limit.y+limit.h-h),w=w,h=h}
    end
    return {box={x=box.x/width,y=box.y/height,w=box.w/width,h=box.h/height},
        target_width=tw,target_height=th,rotation=rotation,
        -- Remember the displayed offset, so overshooting an edge does not
        -- require several opposite drags before the image moves again.
        pan_x=(box.x+box.w/2-r.x-r.w/2)/bounds.w,
        pan_y=(box.y+box.h/2-r.y-r.h/2)/bounds.h}
end
function View.source_delta(dx,dy,rotation)
    if rotation==90 then return dy,-dx end
    if rotation==180 then return -dx,-dy end
    if rotation==270 then return -dy,dx end
    return dx,dy
end
function View.pan(camera,crop,options,dx,dy)
    if not finite(dx) or not finite(dy) then return nil end
    dx,dy=View.source_delta(dx,dy,camera.rotation)
    return {
        pan_x=(camera.pan_x or options.pan_x or 0)-dx/camera.target_width*camera.box.w/crop.w,
        pan_y=(camera.pan_y or options.pan_y or 0)-dy/camera.target_height*camera.box.h/crop.h,
    }
end
return View
