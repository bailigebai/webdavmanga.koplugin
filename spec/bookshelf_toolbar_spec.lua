local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local loaded,Toolbar=pcall(require,"webdavmanga.bookshelf_toolbar")
expect(loaded,"bookshelf needs adjacent connection and view buttons")
package.preload["device"]=function() return {screen={getWidth=function() return 1000 end,scaleBySize=function(_,x) return x end}} end
package.preload["ui/size"]=function() return {padding={large=12}} end
package.preload["ui/widget/titlebar"]=function() return {new=function(_,o) o.right_button={};return o end} end
package.preload["ui/widget/horizontalgroup"]=function() return {new=function(_,o) return o end} end
package.preload["ui/widget/iconbutton"]=function() return {new=function(_,o) return o end} end
local switches,toggles,closes=0,0,0
local bar=Toolbar.new{title="漫画书架",view_mode="list",on_switch_connection=function() switches=switches+1 end,
    on_toggle_view=function() toggles=toggles+1 end,on_close=function() closes=closes+1 end}
local buttons=bar.bookshelf_buttons
expect(#buttons==2 and bar[1].overlap_align=="left","two buttons share left header")
expect(buttons[1].padding_right==nil and buttons[2].padding_left==nil,"no enlarged overlapping tap zones")
buttons[1].callback();buttons[2].callback();bar.close_callback()
expect(switches==1 and toggles==1 and closes==1,"all header actions stay independent")
expect(#bar:generateHorizontalLayout()[1]==3,"keyboard focus includes both left buttons and exit")
print(("bookshelf_toolbar_spec: %d checks"):format(checks))
