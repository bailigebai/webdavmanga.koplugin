local fixture=dofile('spec/helpers/reader_quadrant_host.lua')
local checks=0
local function expect(value,message)
    checks=checks+1
    assert(value,message)
end
local function host(width,height,mode,options)
    local r,o=fixture(false,options)
    r.shell.screen_w,r.shell.screen_h=width,height
    r.shell.screen.getWidth=function() return width end
    r.shell.screen.getHeight=function() return height end
    r.shell.screen.getSize=function() return {w=width,h=height} end
    local calls={menu=0,panel=0,controls=0,exit=0}
    r.show_koreader_menu=function() calls.menu=calls.menu+1;return true end
    r._move_panel=function() calls.panel=calls.panel+1;return true end
    r.toggle_controls=function() calls.controls=calls.controls+1;return true end
    r.onRightTopDoubleTap=function() calls.exit=calls.exit+1;return true end
    if mode~='page' then
        r.panel_entry={whole_page=mode=='unrecognized'}
        if mode~='unrecognized' then
            r.panel_session={render_options={view=mode=='free' and 'free' or 'cut'},
                current=function() return {buffer=r.page_viewport} end}
        end
        r.reader_settings.dynamic_panel_zoom_enabled=mode=='dynamic'
    end
    return r,o,calls
end
-- Catch actual host rotation/resizing rather than pre-adjusting the shell's
-- cached dimensions. Both the KOReader event and gesture hit ranges matter.
for _,event in ipairs({'onSetRotationMode','onSetDimensions','onScreenResize'}) do
    local r,o,calls=host(600,800,'dynamic')
    r.shell.screen.getWidth=function() return 800 end
    r.shell.screen.getHeight=function() return 600 end
    r.shell.screen.getSize=function() return {w=800,h=600} end
    r.shell.widget[event](r.shell.widget)
    local width,height=r.shell:get_content_size()
    expect(width==800 and height==600 and r.shell.screen_w==800 and r.shell.screen_h==600
        and r.shell.widget.dimen.w==800 and r.shell.widget.dimen.h==600,
        event..' must synchronize dimensions after a host screen change')
    local edge=r.shell.widget.ges_events.EdgeTap[2].range()
    expect(edge.x==720 and edge.w==80 and edge.h==600,
        event..' must extend the actual right-edge gesture range to the rotated screen')
    r.shell.widget:onEdgeTap(nil,{pos={x=795,y=580}})
    expect(calls.menu==1 and calls.panel==0 and calls.controls==0 and #o.requests==1,
        event..' must open the native menu at the new bottom-right')
end
-- Catch a menu band that only spans the center, omits the bottom, or is
-- evaluated after intelligent/dynamic panel navigation or Free View.
for _,screen in ipairs({{600,800,30,770},{800,600,20,580}}) do
    for _,mode in ipairs({'page','intelligent','dynamic','free','unrecognized'}) do
        for _,point in ipairs({{5,screen[3]},{screen[1]/2,screen[3]},{screen[1]-5,screen[3]},
            {5,screen[4]},{screen[1]/2,screen[4]},{screen[1]-5,screen[4]}}) do
            local r,o,calls=host(screen[1],screen[2],mode)
            local dispatch=point[1]==screen[1]/2 and 'onTap' or 'onEdgeTap'
            expect(r.shell.widget[dispatch](r.shell.widget,nil,{ges='tap',pos={x=point[1],y=point[2]}})
                and calls.menu==1 and calls.panel==0 and calls.controls==0 and calls.exit==0
                and #o.requests==1 and r.position.index==1,
                mode..' top/bottom tap must open only the native menu across the full width')
        end
    end
end
-- Hand-calculated integer boundaries; do not derive expectations with the
-- production hit test. Outside the bands still opens the center controls.
for _,case in ipairs({{600,800,0,true},{600,800,66,true},{600,800,67,false},
    {600,800,733,false},{600,800,734,true},{600,800,799,true},
    {800,600,49,true},{800,600,50,false},{800,600,549,false},{800,600,550,true}}) do
    local r,_,calls=host(case[1],case[2],'page')
    r.shell.widget:onTap(nil,{pos={x=case[1]/2,y=case[3]}})
    expect(calls.menu==(case[4] and 1 or 0) and calls.controls==(case[4] and 0 or 1),
        'native menu must occupy exactly each outer twelfth, including after rotation')
end
do
    local r,o,calls=host(600,800,'page')
    r.shell.widget:onTap(nil,{ges='double_tap',pos={x=595,y=30}})
    expect(calls.exit==1 and calls.menu==0 and #o.requests==1,'emergency double tap retains priority')
    r.shell.widget:onTap(nil,{pos={x=595,y=400}})
    expect(calls.menu==0 and #o.requests==2,'a middle-height edge still turns the page')
end
do
    local function speech(x,y)
        if x>=200 and x<=400 and y>=5 and y<=95 then
            if x<206 or x>394 or y<11 or y>89 then return 0 end
            if x>=295 and x<=310 and y>=30 and y<=65 then return 30 end
            return 250
        end
        return 230
    end
    local r,_,calls=host(600,800,'page',{w=600,h=800,pixel=speech})
    r.reader_settings.bubble_zoom_enabled=true
    r.reader_settings.bubble_zoom_trigger='tap'
    r.shell.widget:onTap(nil,{pos={x=280,y=40}})
    expect(r.shell.bubble_zoom and calls.menu==0,'a real dialogue inside the top band retains bubble priority')
    r.shell.widget:onTap(nil,{pos={x=300,y=770}})
    expect(not r.shell.bubble_zoom and calls.menu==0,'dismissing a bubble does not also open a menu')
    r.shell.widget:onTap(nil,{pos={x=300,y=770}})
    expect(calls.menu==1,'a subsequent non-dialogue bottom tap opens the native menu')
end
do
    local r,o,calls=host(600,800,'dynamic')
    r.show_koreader_menu=function() error('native menu unavailable') end
    expect(r.shell.widget:onEdgeTap(nil,{pos={x=5,y=770}}) and #o.requests==1
        and calls.panel==0 and calls.controls==0,'host menu failure is contained without navigation')
end
print(('rebuild_0425_menu_bands_spec: %d checks passed'):format(checks))
