-- KOReader primitives are the boundary; exercise the production surface's
-- painting and input routes with a recording framebuffer.
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local width,height=1000,1400
package.preload["ffi/blitbuffer"]=function() return {COLOR_WHITE=13} end
package.preload.device=function() return {screen={getWidth=function() return width end,
    getHeight=function() return height end}} end
local Geometry={new=function(_,o) return o end}
package.preload["ui/geometry"]=function() return Geometry end
package.preload["ui/gesturerange"]=function() return {new=function(_,o)
    function o:match(ev) return self.ges==ev.ges end;return o
end} end
local Input={}
function Input:extend(o) return setmetatable(o or {},{__index=self}) end
function Input:new(o) return self:extend(o) end
function Input:paintTo(bb,x,y) if self[1] then self[1]:paintTo(bb,x,y) end end
function Input:onGesture(ev)
    for name,sequence in pairs(self.ges_events) do
        if sequence[1]:match(ev) then
            local callback=self["on"..(sequence.event or name)]
            if callback and callback(self,ev) then return true end
        end
    end
    return self.stop_events_propagation
end
function Input:onKeyPress(key) if key=="Back" then return self:onBack() end end
Input.onKeyRepeat=Input.onKeyPress
function Input:free() self.freed=true end
package.preload["ui/widget/container/inputcontainer"]=function() return Input end
package.preload["ui/widget/titlebar"]=function() return {new=function(_,o)
    function o:paintTo() end;return o
end} end
local backs,closes=0,0
local surface=require("webdavmanga.ui_background").new{on_back=function() backs=backs+1 end,
    on_close=function() closes=closes+1 end}
local painted
local buffer={paintRect=function(_,x,y,w,h,color) painted={x,y,w,h,color} end}
surface:paintTo(buffer,0,0)
expect(painted[1]==0 and painted[2]==0 and painted[3]==1000 and painted[4]==1400 and painted[5]==13,
    "surface paints an opaque entire-screen background")
width,height=1400,1000;surface:paintTo(buffer,0,0)
expect(painted[3]==1400 and painted[4]==1000,"rotating does not expose an unpainted part of KOReader")
expect(surface:onGesture{ges="tap"} and surface:onGesture{ges="swipe"} and surface:onGesture{ges="unknown"},
    "waiting surface consumes touch events instead of passing them to native reader")
expect(surface:onKeyPress("PageForward") and surface:onKeyRepeat("PageForward"),"hardware turns cannot operate the hidden reader")
surface:onKeyPress("Back");surface[1].close_callback()
expect(backs==1 and closes==1,"back and title close remain reachable during loading")
surface:onCloseWidget();expect(surface.freed,"closing the surface releases its child widgets")
print(("ui_background_spec: %d checks"):format(checks))
