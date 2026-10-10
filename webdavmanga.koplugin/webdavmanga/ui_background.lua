-- One opaque surface under the plugin's asynchronous windows. Owns no images.
local Background={}
function Background.new(model)
    local BB=require("ffi/blitbuffer")
    local Device=require("device")
    local Geom=require("ui/geometry")
    local GestureRange=require("ui/gesturerange")
    local InputContainer=require("ui/widget/container/inputcontainer")
    local TitleBar=require("ui/widget/titlebar")
    local Surface=InputContainer:extend{covers_fullscreen=true,stop_events_propagation=true}
    function Surface:paintTo(bb,x,y)
        self.dimen=Geom:new{x=x,y=y,w=Device.screen:getWidth(),h=Device.screen:getHeight()}
        bb:paintRect(x,y,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
        InputContainer.paintTo(self,bb,x,y)
    end
    function Surface:onConsume() return true end
    function Surface:onKeyPress(key) InputContainer.onKeyPress(self,key);return true end
    function Surface:onKeyRepeat(key) InputContainer.onKeyRepeat(self,key);return true end
    function Surface:onCloseWidget() self:free() end
    function Surface:onBack() model.on_back();return true end
    local dimen=Geom:new{x=0,y=0,w=Device.screen:getWidth(),h=Device.screen:getHeight()}
    local events={}
    for _,gesture in ipairs({"tap","double_tap","hold","hold_release","swipe","pan","pan_release",
        "two_finger_tap","two_finger_swipe","multiswipe","pinch","spread","rotate"}) do
        events["Consume"..gesture]={GestureRange:new{ges=gesture,range=dimen},event="Consume"}
    end
    return Surface:new{dimen=dimen,ges_events=events,key_events={Back={{"Back"}}},
        TitleBar:new{title="WebDAV 漫画",fullscreen=true,
            close_callback=model.on_close or model.on_back}}
end
return Background
