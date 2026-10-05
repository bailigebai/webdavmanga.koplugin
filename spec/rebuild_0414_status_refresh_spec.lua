local Shell=require("webdavmanga.ui_reader_shell")
local checks,failures=0,{}
local function expect(value,message) checks=checks+1;if not value then failures[#failures+1]=message end end
local observed={images=0,image_frees=0,dirty={},scheduled={}}
local function class(kind)
    local c={};c.__index=c
    function c:new(options)
        local v=setmetatable(options or {},self)
        if kind=="imagewidget" then observed.images=observed.images+1 end
        if v.init then v:init() end
        return v
    end
    function c:extend(options) local child=setmetatable(options or {},{__index=self});child.__index=child;return child end
    function c:getSize()
        if self.dimen then return self.dimen end
        if self.text then return {w=math.min(#self.text*10,self.max_width or 600),h=20} end
        local child=self[1] and self[1]:getSize() or {w=0,h=0}
        return {w=child.w+2*(self.padding or 0),h=child.h+2*(self.padding or 0)}
    end
    function c:free()
        if kind=="imagewidget" then observed.image_frees=observed.image_frees+1 end
        for _,child in ipairs(self) do if child.free then child:free() end end
    end
    return c
end
local screen={getWidth=function() return 600 end,getHeight=function() return 800 end,
    getSize=function() return {x=0,y=0,w=600,h=800} end}
local manager={setDirty=function(_,widget,mode,rect)
    if observed.reject then error("refresh unavailable") end
    observed.dirty[#observed.dirty+1]={widget=widget,mode=mode,rect=rect}
end,close=function() end,scheduleIn=function(_,_,callback) observed.scheduled[#observed.scheduled+1]=callback end}
local modules={device={screen=screen,input={group={}}},["ffi/blitbuffer"]={COLOR_WHITE=1,COLOR_BLACK=0},
    ["ui/font"]={getFace=function() return {} end},["ui/geometry"]={new=function(_,v) return v end},
    ["ui/gesturerange"]={new=function(_,v) return v end},["ui/size"]={padding={default=8}},["ui/uimanager"]=manager}
for _,name in ipairs({"button","container/centercontainer","container/framecontainer","container/inputcontainer",
    "horizontalgroup","horizontalspan","imagewidget","linewidget","overlapgroup","textwidget","titlebar","verticalgroup"}) do
    modules["ui/widget/"..name]=class(name)
end
for name,module in pairs(modules) do package.loaded[name]=module end
local shell=Shell:new{owner={},screen=screen}
local original={}
shell:show_page(original,original,nil,{refresh_type="full"},.5,true,1)
local page_image=shell.page_image
local page_children=#shell.widget[1]
local images,frees=observed.images,observed.image_frees
observed.dirty={}
shell:show_status("a",2)
local first=observed.dirty[#observed.dirty]
expect(first and first.mode=="ui" and first.rect and first.rect.x==0 and first.rect.y==0
    and first.rect.w==18 and first.rect.h==28,"status appearance refreshes only its measured top-left text rectangle")
expect(shell.page_image==page_image and observed.images==images and observed.image_frees==frees,
    "status appearance must preserve ImageWidget and borrowed page buffer")
shell:show_status(string.rep("a",300),2)
local second=observed.dirty[#observed.dirty]
expect(second and second.mode=="ui" and second.rect and second.rect.w==260 and second.rect.h==28,
    "replacement text stays width-bounded and refreshes the union of old and new bounds")
local requests=#observed.dirty
observed.scheduled[1]()
expect(#observed.dirty==requests and shell.current_model.status_text~=nil,"an older status timer cannot erase its replacement")
observed.scheduled[2]()
local cleared=observed.dirty[#observed.dirty]
expect(shell.current_model.status_text==nil and cleared and cleared.mode=="ui"
    and cleared.rect and cleared.rect.w==260 and cleared.rect.h==28,
    "status expiry restores the underlying image only within the old text rectangle")
expect(shell.widget.status_widget==nil and #shell.widget[1]==page_children,
    "expired status removes the white text overlay rather than leaving an empty box")
expect(shell.page_image==page_image and observed.images==images and observed.image_frees==frees,
    "status replacement and expiry never rebuild or free page ImageWidget")
shell:show_status("old page",2)
local old_timer=observed.scheduled[#observed.scheduled]
shell:show_page({}, {},nil,{},.75,true,1)
observed.dirty={}
old_timer()
expect(#observed.dirty==0,"a timer belonging to the previous page cannot redraw the new page")

local bubble_frees=0
local source={viewport=function() return {free=function() bubble_frees=bubble_frees+1 end} end}
shell:show_bubble_zoom(source,{x=10,y=10,w=50,h=50},{x=100,y=100},2)
local bubble=shell.bubble_zoom
page_image=shell.page_image;images,frees=observed.images,observed.image_frees
shell:show_status("new status",0)
expect(shell.bubble_zoom==bubble and bubble_frees==0 and shell.page_image==page_image
    and observed.images==images and observed.image_frees==frees,
    "a status notice must preserve an active speech-bubble overlay and its borrowed allocation")
local previous=shell.current_model.status_text
observed.reject=true
local succeeded,result=pcall(shell.show_status,shell,"replacement",0)
expect(succeeded and result==false and shell.current_model.status_text==previous and shell.page_image==page_image,
    "a rejected regional refresh keeps the previous notice and image without throwing")
observed.reject=false
local before=#observed.dirty
shell:show_status(previous,0)
expect(#observed.dirty==before,"unchanged status text needs no repaint")
if #failures>0 then error(table.concat(failures,"\n")) end
print("rebuild_0414_status_refresh_spec: "..checks.." checks")
