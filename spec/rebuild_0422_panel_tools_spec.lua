local fixture=dofile("spec/helpers/reader_quadrant_host.lua")
local r,o=fixture(false)
assert(r.save_panel_screenshot==nil and r.shell.save_panel_screenshot==nil,
    "the removed plugin screenshot feature must have no callable implementation")
r:toggle_controls('panel_view')
for _,action in ipairs(r.shell.current_model.actions) do
    assert(action.text~='当前视图截图','removed screenshot action must not be offered to readers')
end
r:close_controls()
local mode=0
r.shell.screen.getRotationMode=function() return mode end
r.shell.ui_manager.broadcastEvent=function(_,event) mode=event.mode end
r.shell.ui_manager.onRotation=function() end
package.loaded["ui/event"]={new=function(_,name,value) assert(name=="SetRotationMode");return {mode=value} end}
assert(r.shell:rotate_device(90) and mode==1,"device rotation must use KOReader's public rotation event")
r.reader_settings.panel_entry_gesture="two_finger_tap"
local entered=0;r.enter_panel_mode=function() entered=entered+1;return true end
assert(r:onTwoFingerTap(r.shell,{pos={x=300,y=400}}) and entered==1 and not r.quadrant_zoom,
    "configured two-finger tap must enter panels instead of locking a quadrant")
assert(r:onHold(nil,{pos={x=300,y=400}})==false,"two-finger-only mode must not intercept hold")
print("rebuild_0422_panel_tools_spec: removed screenshot, rotation and entry passed")
