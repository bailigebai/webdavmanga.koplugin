-- Real Browser/OPDS adapters and registry, with the external window stack injected.
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local manager={_window_stack={{widget={host=true}}},closed={}}
function manager:show(widget) self._window_stack[#self._window_stack+1]={widget=widget} end
function manager:close(widget)
    for i=#self._window_stack,1,-1 do
        if self._window_stack[i].widget==widget then table.remove(self._window_stack,i) end
    end
    self.closed[#self.closed+1]=widget
    if widget.close_callback then widget.close_callback() end
end
package.loaded["ui/uimanager"]=manager
for _,name in ipairs({"menu","infomessage","multiinputdialog","buttondialog","confirmbox"}) do
    package.loaded["ui/widget/"..name]={new=function(_,model) model.widget_type=name;return model end}
end
package.loaded["webdavmanga.ui_background"]={new=function(model) model.widget_type="background";return model end}
local Browser=require("webdavmanga.ui_browser")
local browser=Browser:new{settings={get_connection=function()return {root_path="/m"}end},settings_ui={},
    directory_store={},open_reader=function()end}
browser:begin_session()
local background=manager._window_stack[2].widget
local Ui=require("webdavmanga.ui_opds")
local ui=Ui:new{catalog={},reader={}}
local backs=0
ui.ui:show_menu{title="OPDS",on_back=function() backs=backs+1 end}
ui.ui:show_info("temporary status")
ui.ui:show_input{title="Search",fields={{description="Search",text=""}}}
ui.ui:show_resume{title="Continue",items={},on_cancel=function() backs=backs+1 end}
ui:cancel()
expect(#manager._window_stack==2 and manager._window_stack[2].widget==background,
    "OPDS exit closes input/resume/info as well as its current menu, retaining only the common background")
expect(backs==0,"programmatic exit does not navigate back or reopen a replaced menu")
browser.ui:show_info("temporary browser status")
browser.ui:confirm{ text="Close?" }
browser:end_session()
expect(#manager._window_stack==1 and manager._window_stack[1].widget.host,
    "browser session exit closes owned transient dialogs without closing host windows")
expect(manager.closed[#manager.closed]==background,"background is the final owned window removed")
print(("plugin_window_ownership_spec: %d checks"):format(checks))
