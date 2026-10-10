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
    assert(s:start({page_buffer=page,view=view or "context",transition_mode=mode or "smooth",
        cross_page=cross_page,
        transition_frames=5,transition_duration=.3},{on_panel=function(b) visible=b;return true end}))
    return s
end
local s=new_session()
local before=visible
assert(s:move(1) and s.transition,"smooth navigation should schedule bounded intermediate cameras")
assert(visible==before,"move should retain old display until the first frame is ready")
local first=table.remove(queue,1);first()
assert(visible.x>0 and visible.x<600,"intermediate frame must move between source panels")
local rendered=#all
assert(not s:configure({rotation=90}),"settings must not mutate an in-flight camera")
local borrowed
local Reader=require("webdavmanga.ui_reader")
local reader=setmetatable({panel_session=s,reader_settings={panel_zoom_enabled=true},
    shell={current_model={kind="page"},get_content_size=function() return 600,800 end,
        show_panel_zoom=function(_,model) borrowed=model.buffer;return true end}},Reader)
assert(reader:onHold(nil,{pos={x=300,y=400}}),"long press can open the native zoom view during a transition")
while #queue>0 do table.remove(queue,1)() end
assert(borrowed==s:current().buffer and borrowed.frees==0,"native zoom must borrow the settled frame, never a transient freed next tick")
assert(s:current().panel.id=="right" and visible==s:current().buffer and not s.transition,"transition finishes on target panel")
visible=nil;s:close()
s=new_session("context","smooth")
local publish=s.callbacks.on_panel
local reentered=false
s.callbacks.on_panel=function(b,...)
    local accepted=publish(b,...)
    if s.transition and s.pending and not reentered then
        reentered=true;assert(s:finish_transition())
    end
    return accepted
end
assert(s:move(1));table.remove(queue,1)()
assert(reentered and not s.transition and visible==s:current().buffer,
    "reentrant completion must not revive the old transition")
visible=nil;s:close()
s=new_session("context","smooth")
assert(s:move(1));table.remove(queue,1)()
local original=s.current_buffer
s.callbacks.on_panel=function(b)
    if b==original then visible=nil;s:close() end
    return false
end
assert(not s:finish_transition() and not s.active and not s.transition,
    "a closing restoration callback must not revive a failed transition")
while #queue>0 do table.remove(queue,1)() end
visible=nil;s:close()
s=new_session("context","smooth")
assert(s:move(1));table.remove(queue,1)()
local original=s.current_buffer
local fail=true
s.callbacks.on_panel=function(b)
    if fail then return false end
    visible=b;return true
end
assert(not s:finish_transition() and s.transition,"temporary publish failures must retain owned visible pixels")
fail=false
assert(s:finish_transition() and not s.transition and visible==original,
    "retry after transient UI failure must restore the original and unblock navigation")
while #queue>0 do table.remove(queue,1)() end
visible=nil;s:close()
s=new_session("context","animated",true)
local final=s.transition.target
table.remove(queue,1)()
local rejected=false
s.callbacks.on_panel=function(b)
    assert(b,"cross-page recovery must never publish nil pixels")
    if b==final and not rejected then rejected=true;return false end
    visible=b;return true
end
assert(not s:finish_transition() and s.transition,"cross-page target rejection must retain a recoverable display")
assert(s:finish_transition() and not s.transition and visible==s:current().buffer,
    "cross-page retry must rerender a valid target after transient widget failure")
while #queue>0 do table.remove(queue,1)() end
visible=nil;s:close()
s=new_session("cut","animated")
assert(s:move(1));table.remove(queue,1)()
assert(visible.white and visible.white>0,"animated navigation must render an actual fade frame")
local stale=table.remove(queue,1)
visible=nil;s:close();rendered=#all
if stale then stale() end
assert(#all==rendered,"closing must cancel every stale render")
local previous=detected
s=new_session("free","classic")
assert(detected==previous and s:current().buffer.x==0,"free view must open the whole page without panel detection")
assert(not s:move(1),"free view must not turn pages")
assert(s:configure({view="context"}) and detected==previous+1,"leaving free view must detect real panels")
visible=nil;s:close()
for _,b in ipairs(all) do assert(b==page and b.frees==0 or b~=page and b.frees==1,"all owned allocations must release once") end
print("rebuild_0422_panel_experience_spec: cameras, fades, free view and lifecycle passed")
