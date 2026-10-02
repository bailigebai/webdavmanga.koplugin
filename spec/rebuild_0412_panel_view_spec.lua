local View=require("webdavmanga.panel_view")
local Source=require("webdavmanga.panel_source")
local Session=require("webdavmanga.panel_session")
local pixels=dofile("spec/fixtures/webtoon_buffer.lua")
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local panel={id="a",x=.1,y=.2,w=.3,h=.2,protect={x=.08,y=.12,w=.35,h=.3}}
local crop={x=.05,y=.1,w=.9,h=.8}
for _,rotation in ipairs({0,90,180,270}) do
 local camera=assert(View.compute(panel,crop,1000,1200,{view="context",rotation=rotation,screen_width=600,screen_height=800}))
 local r=camera.box
 expect(r.x<=crop.x+panel.protect.x*crop.w and r.y<=crop.y+panel.protect.y*crop.h,"context retains the speech top/left after rotation")
 expect(r.x+r.w>=crop.x+(panel.protect.x+panel.protect.w)*crop.w-1e-9 and
  r.y+r.h>=crop.y+(panel.protect.y+panel.protect.h)*crop.h-1e-9,"context retains all protected content")
end
local free=assert(View.compute(panel,crop,1000,1200,{view="free",screen_width=600,screen_height=800}))
expect(free.box.x==crop.x and free.box.y==crop.y and free.box.w==crop.w and free.box.h==crop.h,"free view starts with the whole cropped page")
local edge_options={view="free",zoom=2,pan_x=10,screen_width=600,screen_height=800}
local edge=assert(View.compute(panel,crop,1000,1200,edge_options))
local back=assert(View.pan(edge,crop,edge_options,30,0))
local returned=assert(View.compute(panel,crop,1000,1200,{view="free",zoom=2,pan_x=back.pan_x,
 screen_width=600,screen_height=800}))
expect(returned.box.x<edge.box.x,"one reverse drag moves away from a clamped edge")
local handle
local page=pixels.new(200,240,function(x,y) return (x+y)%256 end)
Source:new{mupdf={}}:open(1,{page_buffer=page,screen_width=60,screen_height=80},{on_ready=function(h) handle=h end})
for _,angle in ipairs({0,90,180,270}) do
 local frame=assert(handle:render(panel,{view="cut",rotation=angle}))
 expect(frame:getWidth()<=60 and frame:getHeight()<=80,"rotated owned frame fits the screen")
 frame:free()
end
handle:close();expect(page.frees==0,"view rotation never mutates or frees the original page")
local fail,publish=false,true
local config,freed
local function buffer() return {frees=0,free=function(self) self.frees=self.frees+1;freed=(freed or 0)+1 end} end
local source={open=function(_,_,_,callbacks)
 local h={detection_raster=function() return {} end,close=function(self) self.closed=true end,
 render=function(_,_,options) config=options;if fail then return nil end;return buffer() end}
 callbacks.on_ready(h);return {cancel=function() h:close() end}
end}
local session=Session:new{source=source,detector={detect=function() return {panel,{id="b",x=.6,y=.2,w=.3,h=.2}} end},screen_width=60,screen_height=80}
session:start({view="context",rotation=0},{on_panel=function() return publish end})
local original=session:current()
fail=true
expect(not session:configure({rotation=90}) and session:current().buffer==original.buffer and session.render_options.rotation==0,"failed rotation keeps original view and options")
fail=false;publish=false
expect(not session:configure({rotation=180}) and session.render_options.rotation==0,"rejected publish does not commit view configuration")
publish=true
expect(session:configure({rotation=270,view="free"}) and session:current().panel.id=="a","view/rotation preserves the physical panel")
expect(not session:move(1) and session:current().panel.id=="a","free view consumes navigation without leaving the page")
expect(session:zoom(2),"explicit zoom applies")
local before=session:current().buffer
expect(not session:configure({rotation=90},function() return false end)
 and session:current().buffer==before and before.frees==0 and session.render_options.zoom==2,
 "persistence failure retains the exact allocation and zoom, without rollback rendering")
expect(session:configure({view="context"}),"return to panel navigation")
local reentered
expect(session:configure({rotation=90},function() reentered=session:move(1);return true end)
 and reentered==false and session:current().panel.id=="a","commit callbacks cannot move and publish a candidate under another panel ID")
session:close()
print("rebuild_0412_panel_view_spec: "..checks.." checks passed")
