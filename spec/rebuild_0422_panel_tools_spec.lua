local fixture=dofile("spec/helpers/reader_quadrant_host.lua")
local r,o=fixture(false)
local captured,restored
package.loaded["ui/widget/screenshoter"]={getScreenshotDir=function() return "/screenshots" end}
r.shell.ui_manager.forceRePaint=function() end
r.shell.screen.shot=function(_,name)
    assert(r.shell.current_model.kind=="page" and not r.shell.current_model.show_progress
        and not r.shell.current_model.status_text,"screenshot must contain current view without controls or status")
    captured=name;return true
end
r.shell:show_status("status")
local model=r.shell.current_model
local file=r.shell:save_panel_screenshot()
assert(file==captured and file:find("/screenshots/WebDAVManga_panel_",1,true),"use the configured local screenshot folder")
assert(r.shell.current_model==model and r.shell.current_model.show_progress,"restore the original view after screenshot")
r.shell.screen.shot=function() error("shot failed") end
assert(not r.shell:save_panel_screenshot() and r.shell.current_model==model,"failed screenshot must restore display")
local mode=0
r.shell.screen.getRotationMode=function() return mode end
r.shell.ui_manager.broadcastEvent=function(_,event) mode=event.mode end
r.shell.ui_manager.onRotation=function() end
package.loaded["ui/event"]={new=function(_,name,value) assert(name=="SetRotationMode");return {mode=value} end}
assert(r.shell:rotate_device() and mode==1,"device rotation must use KOReader's public rotation event")
r.reader_settings.panel_entry_gesture="two_finger_tap"
local entered=0;r.enter_panel_mode=function() entered=entered+1;return true end
assert(r:onTwoFingerTap(r.shell,{pos={x=300,y=400}}) and entered==1 and not r.quadrant_zoom,
    "configured two-finger tap must enter panels instead of locking a quadrant")
assert(r:onHold(nil,{pos={x=300,y=400}})==false,"two-finger-only mode must not intercept hold")
print("rebuild_0422_panel_tools_spec: screenshots, rotation and entry passed")
