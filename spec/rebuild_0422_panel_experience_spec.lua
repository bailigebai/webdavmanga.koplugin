local Session=require("webdavmanga.panel_session")
local Source=require("webdavmanga.panel_source")
local all,queue,visible={},{},nil
local function buffer(w,h)
    local b={w=w,h=h,frees=0}
    all[#all+1]=b
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:free() assert(visible~=self,"freed displayed pixels");self.frees=self.frees+1;assert(self.frees==1,"double free") end
    function b:viewport(x,y,vw,vh) local v=buffer(vw,vh);v.x,v.y=x,y;return v end
    function b:scale(sw,sh) local v=buffer(sw,sh);v.x,v.y=self.x,self.y;return v end
    function b:copy() local v=buffer(self.w,self.h);v.x,v.y=self.x,self.y;return v end
    function b:lightenRect(_,_,_,_,factor) self.white=factor end
    return b
end
local page=buffer(1000,1000)
local source=Source:new{mupdf=false,draw_context=false}
local detected=0
local detector={detect=function()
    detected=detected+1
    return {{id="left",x=0,y=0,w=.4,h=1},{id="right",x=.6,y=0,w=.4,h=1}}
end}
local function new_session(view,mode,cross_page)
    local s=Session:new{source=source,detector=detector,screen_width=600,screen_height=800,
        schedule_frame=function(delay,fn) assert(delay>0);queue[#queue+1]=fn end}
    assert(s:start({page_buffer=page,view=view or "context",transition_mode=mode or "native",
        cross_page=cross_page},{on_panel=function(b) visible=b;return true end}))
    return s
end
local s=new_session()
local before=visible
assert(s:move(1) and not s.transition and #queue==0,"host animations must not allocate or schedule Lua camera/fade frames")
assert(visible~=before and visible==s:current().buffer and s:current().panel.id=="right")
assert(before.frees==1,"old display is released after final publication")
local original=s.current_buffer
s.callbacks.on_panel=function() return false end
assert(not s:move(-1) and visible==original and original.frees==0,"failed final publication preserves the preceding view")
s.callbacks.on_panel=function(b) visible=b;return true end
assert(s:move(-1) and s:current().panel.id=="left","failed navigation can be retried")
local borrowed
local Reader=require("webdavmanga.ui_reader")
local reader=setmetatable({panel_session=s,reader_settings={panel_zoom_enabled=true},
 shell={current_model={kind="page"},get_content_size=function() return 600,800 end,
 show_panel_zoom=function(_,model) borrowed=model.buffer;return true end}},Reader)
assert(reader:onHold(nil,{pos={x=300,y=400}}) and borrowed==visible and borrowed.frees==0,"native zoom borrows the settled panel")
visible=nil;s:close()
local previous=detected
s=new_session("free","classic")
assert(detected==previous and s:current().buffer.x==0,"free view opens the whole page without detection")
assert(not s:move(1),"free view does not turn pages")
assert(s:configure({view="context"}) and detected==previous+1,"leaving free view detects panels")
visible=nil;s:close()
for _,b in ipairs(all) do assert(b==page and b.frees==0 or b~=page and b.frees==1,"all allocations release once") end
print("rebuild_0422_panel_experience_spec: final-only host transitions, free view and lifecycle passed")
