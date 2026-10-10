local fixture=dofile("spec/helpers/reader_quadrant_host.lua")
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
local function reader(real)
    local r,o=fixture(real,{w=100,h=120,pixel=speech})
    r.reader_settings.bubble_zoom_enabled=true
    r.reader_settings.bubble_zoom_trigger="hold"
    r.reader_settings.bubble_zoom_scale=2
    return r,o
end
for _,real in ipairs({false,true}) do
    local r,o=reader(real)
    local source,view,position=r.page_buffer,r.page_viewport,r.position
    local requests,decodes,saves=#o.requests,o.decodes,o.saves
    expect(r.shell.widget:onHold(nil,{pos={x=280,y=380}}),"single hold consumes a dialogue gesture")
    local overlay=r.shell.bubble_zoom
    expect(overlay and overlay.buffer and overlay.buffer.parent==view,"bubble crop borrows the displayed view")
    expect(overlay.rect.x>=0 and overlay.rect.y>=0 and overlay.rect.x+overlay.rect.w<=600
        and overlay.rect.y+overlay.rect.h<=800,"floating bubble remains on screen")
    if real then
        o.image:getSize()
        expect(o.image.image==overlay.buffer and o.image.image_disposable==false,
            "real ImageWidget borrows bubble pixels")
        expect(o.image:getCurrentWidth()<=overlay.rect.w and o.image:getCurrentHeight()<=overlay.rect.h,
            "real ImageWidget fits the entire bubble")
    end
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{ges="hold_release"})==true and r.shell.bubble_zoom==overlay,
        "lifting the held finger is consumed and leaves the bubble open")
    expect(r.shell.widget:onTap(nil,{pos={x=599,y=700}}) and not r.shell.bubble_zoom,
        "next tap dismisses bubble without turning a page")
    expect(r.page_buffer==source and r.page_viewport==view and r.position==position
        and source.frees==0 and overlay.buffer.frees==1,"dismiss releases only the borrowed bubble view")
    expect(#o.requests==requests and o.decodes==decodes and o.saves==saves,
        "bubble inspection does not download, decode or write reading progress")
    r.shell.widget:onHold(nil,{pos={x=280,y=380}})
    overlay=r.shell.bubble_zoom
    r:force_close("plugin_teardown")
    expect(overlay.buffer.frees==1 and source.frees==1,"teardown releases bubble and page once each")
end
do
    local r,o=reader(false)
    r.reader_settings.bubble_zoom_trigger="tap"
    r.panel_entry={}
    r.panel_session={render_options={view="context"}}
    local previous,next_page=0,0
    r._move_panel=function(_,delta)
        if delta<0 then previous=previous+1 else next_page=next_page+1 end
        return true
    end
    r.shell.widget:onTap(nil,{pos={x=5,y=400}})
    r.shell.widget:onTap(nil,{pos={x=595,y=400}})
    expect(previous==1 and next_page==1,"tap bubble mode preserves panel navigation")
end
do
    local r,o=reader(false)
    local image=r.shell.page_image
    local frame=package.loaded["ui/widget/container/framecontainer"]
    local original=frame.new
    frame.new=function() error("injected frame failure") end
    expect(not pcall(r.shell.show_page,r.shell,r.shell.current_model),"failed widget construction is reported")
    frame.new=original
    expect(r.shell.page_image==image,"failed rebuild preserves the image used for screen mapping")
end
do
    local r,o=reader(false)
    r.reader_settings.bubble_zoom_enabled=false
    local saved
    r.settings.set_reader=function(_,values) saved=values;return true end
    r.settings.flush=function() return true end
    local requests,decodes,saves=#o.requests,o.decodes,o.saves
    r:toggle_controls("display")
    local toggle=r.shell.current_model.actions[1]
    expect(toggle.callback() and saved.bubble_zoom_enabled and r.reader_settings.bubble_zoom_enabled,
        "local display action persists and applies bubble preference")
    expect(#o.requests==requests and o.decodes==decodes and o.saves==saves,
        "local bubble preferences do not reload the page or save reading progress")
    local before=r.reader_settings.bubble_zoom_enabled
    r.settings.set_reader=function() return false,"injected_save_failure" end
    expect(r.shell.current_model.actions[1].callback()==false
        and r.reader_settings.bubble_zoom_enabled==before,"failed preference write preserves current settings")
end
do
    local r,o=reader(false)
    r.reader_settings.panel_zoom_enabled=false
    expect(r.shell.widget:onHold(nil,{pos={x=5,y=5}})==false,
        "a missed bubble hold is not consumed when panels are disabled")
    expect(r.shell.widget:onBubbleHoldPan()==false and r.shell.widget:onTwoFingerHoldRelease(nil,{ges="hold_release"})==false,
        "missed bubble detection must leave no stale hold state")
    expect(r.shell.widget:onTwoFingerHold(nil,{pos={x=280,y=380}}),"quadrant hold remains reachable after a bubble miss")
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{ges="hold_release"}) and not r.quadrant_hold,
        "quadrant release remains reachable")
end
do
    local r,o=reader(false)
    r.reader_settings.panel_zoom_enabled=false
    r.shell.widget:onHold(nil,{pos={x=5,y=5}})
    expect(not r.shell.bubble_zoom and r.shell.current_model.kind=="page" and not r.panel_session,
        "pressing outside the image never enters panel mode")
    r.shell:show_controls{actions={}}
    expect(r.shell.widget:onHold(nil,{pos={x=280,y=380}})==false and not r.shell.bubble_zoom,
        "settings cannot start a bubble")
    r:close_controls()
    r.quadrant_hold={}
    expect(r.shell.widget:onHold(nil,{pos={x=280,y=380}})==false and not r.shell.bubble_zoom,
        "a two-finger hold cannot start bubble detection")
end
print("rebuild_0411_bubble_reader_spec: "..checks.." checks passed")
