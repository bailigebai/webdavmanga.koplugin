local fixture = dofile("spec/helpers/reader_quadrant_host.lua")
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local points={{x=100,y=100},{x=500,y=100},{x=100,y=700},{x=500,y=700}}
local ids={"top_left","top_right","bottom_left","bottom_right"}
for i,point in ipairs(points) do
    local r,o=fixture(false)
    local source,original,position=r.page_buffer,r.page_viewport,r.position
    local requests,decodes,saves=#o.requests,o.decodes,o.saves
    expect(type(r.shell.widget.onTwoFingerHold)=="function","Shell must receive native two-finger hold")
    expect(r.shell.widget:onTwoFingerHold(nil,{ges="two_finger_hold",pos=point}),"hold starts temporary zoom")
    expect(r.quadrant_zoom==ids[i] and r.quadrant_hold,"hold selects the correct quadrant")
    expect(r.page_viewport.w==300 and r.page_viewport.h==400,"selected quarter uses the existing image")
    expect(r.shell.widget:onTwoFingerHoldPan(nil,{ges="two_finger_hold_pan",pos=points[5-i]}),"hold movement is consumed")
    expect(r.quadrant_zoom==ids[i],"moving held fingers does not switch quadrants")
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{ges="two_finger_hold_release",pos={x=-10,y=900}}),
        "release outside the page restores the view")
    expect(not r.quadrant_zoom and not r.quadrant_hold and r.page_viewport.w==original.w
        and r.page_viewport.h==original.h and r.position==position,"release restores the original view and position")
    expect(r.page_buffer==source and source.frees==0 and #o.requests==requests
        and o.decodes==decodes and o.saves==saves,"hold/release never loads, decodes, saves or frees the source")
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{})==false,"a repeated release does nothing")
end
do
    local r,o=fixture(false,{w=600,h=2400,fit_mode="width"})
    r.pan_y=350;r:_display_segment("whole",false)
    local original=r.page_viewport
    expect(r.shell.widget:onTwoFingerHold(nil,{pos=points[2]}),"hold works on a panned page")
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{}),"release restores panned view")
    expect(r.pan_y==350 and r.page_viewport.y==original.y,"long-page position stays exact")
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    r.shell.widget:onTwoFingerHold(nil,{pos=points[4]})
    expect(r.quadrant_zoom=="bottom_right","hold can temporarily inspect another locked quadrant")
    r.shell.widget:onTwoFingerHoldRelease(nil,{})
    expect(r.quadrant_zoom=="top_left","release restores previous locked zoom")
end
for _,mode in ipairs({"controls","error","loading","pending","panel","closed"}) do
    local r,o=fixture(false)
    if mode=="controls" then r.shell:show_controls{actions={}}
    elseif mode=="error" then r.shell:show_error{message="error"}
    elseif mode=="loading" then r.shell:show_loading("loading")
    elseif mode=="pending" then r.pending_request={}
    elseif mode=="panel" then r.panel_session={}
    elseif mode=="closed" then r.shell.closed=true end
    expect(r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})==false and not r.quadrant_hold,
        mode.." cannot start temporary page zoom")
end
do
    local r,o=fixture(false)
    local point={index=1,fraction=0.25}
    r.webtoon_session={busy=true,point=point}
    expect(r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})==false,
        "an unfinished strip frame cannot start hold zoom")
    r.webtoon_session.busy=false
    expect(r.shell.widget:onTwoFingerHold(nil,{pos=points[2]}),"a stable strip frame can be inspected")
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{}) and r.webtoon_session.point==point,
        "strip anchor stays exact after temporary inspection")
end
do
    local r,o=fixture(false)
    r.settings.set_reader=function() return true end
    r.settings.flush=function() return true end
    r.shell.widget:onTwoFingerHold(nil,{pos=points[1]})
    local requests=#o.requests
    expect(r:set_fit_mode("width") and #o.requests==requests+1,
        "changing fit mode during hold reloads normally")
    expect(not r.quadrant_hold and not r.quadrant_zoom,"mode change clears temporary zoom")
end
do
    local r,o=fixture(false)
    local tasks={}
    r.shell.scheduler={scheduleIn=function(_,_,callback) tasks[callback]=true end,
        unschedule=function(_,callback) tasks[callback]=nil end}
    local contacts={[0]={down=true,current_tev={id=10}},[1]={down=true,current_tev={id=11}}}
    r.shell.device.input={main_finger_slot=0,gesture_detector={getContact=function(_,slot) return contacts[slot] end}}
    r.shell.widget:onTwoFingerHold(nil,{pos=points[1]})
    local tick=next(tasks)
    expect(type(tick)=="function","hold watches its native contact identities")
    contacts[0].current_tev.id=-1 -- The void buddy can keep down=true on lift.
    tick()
    expect(not r.quadrant_hold and not r.quadrant_zoom and next(tasks)==nil,
        "missing native release restores the image and cancels contact checking")
    contacts[0]={down=true,current_tev={id=12}}
    r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})
    expect(next(tasks)~=nil,"subsequent hold gets a fresh watcher")
    r.shell.widget:onTwoFingerHoldRelease(nil,{})
    expect(next(tasks)==nil,"normal release cancels its watcher")
    r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})
    local fresh=next(tasks)
    tick() -- A callback already dequeued before cancellation may arrive late.
    expect(next(tasks)==fresh and r.quadrant_hold,"old contact check cannot cancel a new hold")
    contacts[1]={down=true,current_tev={id=13}}
    tasks[fresh]=nil;fresh()
    expect(not r.quadrant_hold and next(tasks)==nil,"replaced contacts cannot keep old hold active")
end
for _,options in ipairs({{w=600,h=800},{w=1200,h=800,split=true},
    {w=600,h=2400,fit_mode="width"},{w=640,h=880,crop={x=11,y=17,w=601,h=803}}}) do
    local r,o=fixture(true,options)
    r.page_crop=options.crop;r:_display_segment(r.position.segment,false)
    o.image:getSize()
    local original={x=r.page_viewport.x,y=r.page_viewport.y,w=r.page_viewport.w,h=r.page_viewport.h,
        iw=o.image:getCurrentWidth(),ih=o.image:getCurrentHeight(),pan=r.pan_y}
    local source,requests,decodes,saves=r.page_buffer,#o.requests,o.decodes,o.saves
    for _,point in ipairs(points) do
        expect(r.shell.widget:onTwoFingerHold(nil,{pos=point}),"real ImageWidget accepts hold")
        o.image:getSize()
        expect(o.image.image==r.page_viewport and o.image.image_disposable==false
            and o.image:getCurrentWidth()<=600 and o.image:getCurrentHeight()<=800,
            "selected quadrant fits the screen and borrows existing pixels")
        expect(r.shell.widget:onTwoFingerHoldRelease(nil,{}),"real ImageWidget restores on lift")
        o.image:getSize()
        expect(r.page_viewport.x==original.x and r.page_viewport.y==original.y
            and r.page_viewport.w==original.w and r.page_viewport.h==original.h
            and o.image:getCurrentWidth()==original.iw and o.image:getCurrentHeight()==original.ih
            and r.pan_y==original.pan,"release restores exact viewport, fitted size and scroll position")
    end
    expect(r.page_buffer==source and source.frees==0 and #o.requests==requests
        and o.decodes==decodes and o.saves==saves,"real rendering never mutates source or progress")
end
do
    local r,o=fixture(false)
    r.shell.widget:onTwoFingerHold(nil,{pos=points[2],time=10})
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{time=9})==false and r.quadrant_hold,
        "release older than this hold cannot restore it")
    r.shell:show_controls{actions={}}
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{time=11}) and not r.quadrant_zoom
        and r.shell.current_model.kind=="controls","release restores state without replacing controls")
    r:_display_segment(r.position.segment,false)
    expect(r.page_viewport.w==600,"returning from controls uses original view")
    r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})
    expect(r.shell.widget:onSuspend()==false and not r.quadrant_hold and not r.quadrant_zoom,
        "suspend clears temporary zoom and still propagates to KOReader")
    expect(r.shell.widget:onResume()==false,"resume preserves native lifecycle propagation")
end
do
    local r,o=fixture(false)
    local old_shell=r.shell
    r.shell.widget:onTwoFingerHold(nil,{pos=points[2]})
    r:force_close("plugin_teardown")
    expect(not r.quadrant_hold and not r.quadrant_zoom,"closing clears temporary state")
    expect(old_shell.widget:onTwoFingerHoldRelease(nil,{})==false,"late release cannot reopen closed Reader")
end
print("rebuild_0411_quadrant_hold_spec: "..checks.." checks passed")
