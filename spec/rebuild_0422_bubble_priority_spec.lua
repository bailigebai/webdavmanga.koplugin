local fixture=dofile("spec/helpers/reader_quadrant_host.lua")
local function speech(x,y)
    if x>=20 and x<=60 and y>=25 and y<=60 then
        if x<22 or x>58 or y<27 or y>58 then return 0 end
        if x>=37 and x<=40 and y>=35 and y<=49 then return 30 end
        return 250
    end
    return 230
end
local r,o=fixture(false,{w=100,h=120,pixel=speech})
r.reader_settings.bubble_zoom_enabled=true
r.reader_settings.bubble_zoom_trigger="tap"
local moved,controls=0,0
r.panel_entry={}
r.panel_session={render_options={view="context"},current=function() return {buffer=r.page_viewport} end}
r._move_panel=function() moved=moved+1;return true end
r.toggle_controls=function() controls=controls+1;return true end
r.shell.widget:onTap(nil,{pos={x=280,y=380}})
assert(r.shell.bubble_zoom and moved==0 and controls==0,"panel-center dialogue must enlarge before opening controls")
r.shell.widget:onTap(nil,{pos={x=280,y=380}})
assert(not r.shell.bubble_zoom and moved==0 and controls==0,"overlay dismiss must not navigate")
r.shell.widget:onTap(nil,{pos={x=595,y=400}})
assert(moved==1,"a non-bubble edge tap must still navigate panels")
r.panel_entry,r.panel_session=nil,nil
r.shell.widget:onTap(nil,{pos={x=300,y=700}})
assert(controls==1,"non-bubble tap must reach normal reader controls")
r.reader_settings.bubble_zoom_trigger="both"
local entered=0
r.enter_panel_mode=function() entered=entered+1;return true end
r.shell.widget:onHold(nil,{pos={x=300,y=700}})
assert(entered==1,"a missed bubble hold must fall through to panel entry")
print("rebuild_0422_bubble_priority_spec: priority and fallback passed")
