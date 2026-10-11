local checks,failures=0,{}
local function expect(value,message) checks=checks+1;assert(value,message) end
local function case(fn) local ok,err=pcall(fn);if not ok then failures[#failures+1]=err end end
local Class={}
function Class:new(o) o=setmetatable(o or {},{__index=self});if o.init then o:init() end;return o end
function Class:extend(o) return setmetatable(o or {},{__index=self}) end
function Class:getSize() return self.dimen or {w=self.width or 40,h=self.height or 40} end
function Class:free() if self.freed then return end;self.freed=true;for _,c in ipairs(self) do if c.free then c:free() end end end
function Class:paintTo() end
function Class:getFontSizeToFitHeight() return 16 end
local tasks,dirty,shown={}, {},{}
local manager={}
function manager:show(w,mode,region) shown[#shown+1]=w;if mode then self:setDirty(w,mode,region) end end
function manager:close() end
function manager:setDirty(w,mode,region) dirty[#dirty+1]={widget=w,mode=mode,region=region} end
function manager:scheduleIn(_,fn) tasks[#tasks+1]=fn;return fn end
function manager:nextTick(fn) return self:scheduleIn(0,fn) end
function manager:tickAfterNext(fn) return self:scheduleIn(.02,fn) end
function manager:unschedule(fn) for i=#tasks,1,-1 do if tasks[i]==fn then table.remove(tasks,i) end end end
local function tick() local fn=table.remove(tasks,1);if fn then fn() end end
local function drain() local n=0;while #tasks>0 do tick();n=n+1;assert(n<1000) end end
for _,name in ipairs({"button","container/centercontainer","container/framecontainer","container/inputcontainer",
    "horizontalgroup","horizontalspan","imagewidget","iconwidget","overlapgroup","progresswidget",
    "rectspan","textboxwidget","textwidget","titlebar","verticalgroup"}) do package.loaded["ui/widget/"..name]=Class end
package.loaded["ui/geometry"]=Class
package.loaded["ui/gesturerange"]=Class
package.loaded["ui/font"]={getFace=function() return {} end}
package.loaded["ui/size"]={border={thin=1},padding={small=3},margin={small=3}}
package.loaded["ffi/blitbuffer"]={COLOR_WHITE=1,COLOR_BLACK=0}
package.loaded["device"]={screen={getWidth=function() return 600 end,getHeight=function() return 800 end,
    getSize=function() return {w=600,h=800} end,scaleBySize=function(_,n) return n end}}
package.loaded["ui/uimanager"]=manager
local Grid=require("webdavmanga.ui_cover_grid")
local function items(n)
    local result={};for i=1,n do result[i]={id=i,name=tostring(i),manga={path="/m/"..i,name=tostring(i),is_folder=true}} end
    return result
end
local visits=0
local grid=Grid:new{cover_service={resolve=function() end},loader={},cache={},
    settings={get_reader=function() return {} end},connection_provider=function() return {root_path="/m"} end,
    error_reporter={guard=function(_,_,fn) return fn() end,wrap=function(_,_,fn) return fn end}}
grid:show{items=items(20)}
drain()
local widget=shown[#shown]
local visible=widget.model.on_visible
widget.model.on_visible=function(ids) visits=visits+1;return visible(ids) end
case(function()
    expect(widget:set_page(2),"next page is accepted")
    expect(visits==0,"page button returns before starting visible cover work")
end)
case(function()
    expect(dirty[#dirty].mode=="full","page changes request one full ink refresh")
end)
widget:set_page(1);widget:set_page(2)
drain()
case(function() expect(visits==1 and #widget.visible_ids==5,"rapid flips publish only the latest page") end)
grid:show{items=items(3)}
local parent=shown[#shown]
case(function()
    expect(parent.page_group.height==800 and parent.page_group.background==1,"sparse parent paints an opaque complete page")
    expect(dirty[#dirty].mode=="full","returning from 20 books to 3 folders clears the old ink page")
end)
grid:cancel();drain()
case(function() expect(parent.closed,"closing cancels a deferred visible publication") end)

-- Exercise the controller's bounded warm-card rendering with real queue logic.
tasks,dirty,shown={}, {},{}
local rendered=0
local ui={show_grid=function(self,m) self.model=m end,close_grid=function() end,free_visible=function() end,
    get_cover_size=function() return 100,140 end,update_cover=function() rendered=rendered+1;return true end}
local cover={get=function(_,_,path) return {path=path.."/001.jpg",name="001.jpg"} end,
    resolve=function() error("warm covers must not access the source") end,fork=function(self) return self end}
local warm=Grid:new{cover_service=cover,cache={key_for=function(_,_,p) return p end,lookup=function() return "/thumb.png" end},
    loader={identity="thumb",cancel_cover_generation=function() end},ui=ui,scheduler=manager,
    render_batch_size=2,cover_concurrency=6,connection_provider=function() return {root_path="/m"} end,
    settings={get_reader=function() return {} end},render_image={renderImageFile=function() return {free=function() end} end}}
warm:show{items=items(15)}
local ids={};for i=1,15 do ids[i]=i end
ui.model.on_visible(ids)
case(function() expect(rendered==0,"warm page does not synchronously decode all 15 PNGs") end)
tick();if rendered==0 then tick() end
case(function() expect(rendered==2,"one frame renders at most two covers") end)
ui.model.on_visible({1,2,3})
drain()
case(function() expect(rendered==5,"new page drops every queued old render") end)
ui.model.on_visible(ids);warm:cancel();drain()
case(function() expect(rendered==5,"exit rejects delayed rendering") end)
for _,err in ipairs(failures) do print("FAIL "..tostring(err)) end
assert(#failures==0,table.concat(failures,"\n"))

-- Read the pinned upstream methods instead of assuming one queued callback
-- corresponds to one input iteration. Paints can be slow on electronic ink.
local frontend=assert(os.getenv("KOREADER_FRONTEND"),"real UI loop needs KOREADER_FRONTEND")
local file=assert(io.open(frontend.."/ui/uimanager.lua","rb"));local source=file:read("*a");file:close()
local methods={}
for _,name in ipairs({"scheduleIn","nextTick","tickAfterNext","_checkTasks","handleInput"}) do
    methods[#methods+1]=assert(source:match("(function UIManager:"..name.."%b().-\nend)"),name)
end
local clock,polls,paint_pending=0,0,false
local time={now=function() clock=clock+.000001;return clock end,s=function(v) return v end}
local real={_task_queue={},_window_stack={{}},_zeromqs={},event_hook={execute=function() end}}
function real:schedule(at,action,...)
    self._task_queue[#self._task_queue+1]={time=at,action=action,args={n=select("#",...),...}}
    table.sort(self._task_queue,function(a,b) return a.time>b.time end);self._task_queue_dirty=true
end
function real:_repaint() if paint_pending then clock=clock+.1;paint_pending=false end end
function real:processZMQs() end
function real:_standbyTransition() end
local Input={waitEvent=function(_,_,deadline) polls=polls+1;if deadline then clock=math.max(clock,deadline) end end}
assert(loadstring("return function(UIManager,time,Input) "..table.concat(methods,"\n").." end"))()(real,time,Input)
rendered=0
ui.update_cover=function() rendered=rendered+1;paint_pending=true;return true end
warm.scheduler=real
warm:show{items=items(15)};ui.model.on_visible(ids)
real:handleInput();real:handleInput()
expect(polls==2 and rendered<=2,"real input loop polls touch between PNG batches, even after a 100ms paint")
real:scheduleIn(0,function() paint_pending=true end)
real:handleInput()
expect(polls==3 and rendered<=4,"another async repaint still yields before decoding the whole page")
warm:cancel()
for _=1,8 do real:handleInput() end
expect(rendered<=4,"input can cancel the remaining warm page before it is decoded")
print(("bookshelf_responsive_grid_spec: %d checks"):format(checks))
