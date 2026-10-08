-- Real Gray Session, source Reader/Shell/Bridge/Settings, pinned ImageWidget and BB.
-- Only the device, scheduler, container chrome, decoder and download boundary are fake.
local Host=require("refresh_test_support")
local UI=require("ui/uimanager")
local Device=require("device")
local _,screen=Host.reset()
function screen:getSize() return {w=self.width,h=self.height} end
function screen:scaleByDPI(n) return n end
Device.input={group={}}
function Device:canDoSwipeAnimation() return true end
function screen:setSwipeAnimations() return true end
function screen:setSwipeDirection() return true end
package.loaded.logger={dbg=function() end,warn=function() end}
local Images=require("imagewidget_test_support")
local BB,ImageWidget=Images.BB,Images.ImageWidget
local Widget=Host.Widget
function Widget:getSize()
    if self.dimen then return self.dimen end
    if self.text then return {w=1,h=1} end
    if self[1] and self[1].getSize then return self[1]:getSize() end
    return {w=self.width or 0,h=self.height or 0}
end
function Widget:free() for _,child in ipairs(self) do if child.free then child:free() end end end
function Widget:paintTo(bb,x,y)
    for _,child in ipairs(self) do if child.paintTo then child:paintTo(bb,x,y) end end
end
for _,name in ipairs({"button","container/centercontainer","container/framecontainer",
    "container/inputcontainer","horizontalgroup","horizontalspan","linewidget",
    "overlapgroup","textwidget","titlebar","verticalgroup","buttondialog"}) do
    package.loaded["ui/widget/"..name]=Widget
end
package.loaded["ui/font"]={getFace=function() return {} end}
package.loaded["ui/gesturerange"]={new=function(_,o) return o end}
package.loaded["ui/size"]={padding={default=1}}
local Session=require("graydither.imagesession")
local service={createImageSession=function(_,options) return Session.new(options) end}
package.loaded.pluginloader={getPluginInstance=function(_,name)
    assert(name=="graydither");return service
end}
local Settings=require("webdavmanga.settings")
local Reader=require("webdavmanga.ui_reader")
local Shell=require("webdavmanga.ui_reader_shell")
local State=require("webdavmanga.state")
local checks=0
local function expect(ok,message) checks=checks+1;assert(ok,message) end
local saved={}
local backing={readSetting=function(_,k,d) if saved[k]==nil then return d end;return saved[k] end,
    saveSetting=function(_,k,v) saved[k]=v end,delSetting=function(_,k) saved[k]=nil end,
    flush=function() return true end}
local settings=Settings:new{store=backing}
local original=settings:get_reader()
original.full_refresh_each_page=true;original.animation_enabled=true;original.prefetch_count=0
original.panel_zoom_enabled=true
assert(settings:set_reader(original))
local requests={}
local entries={}
for i=1,8 do entries[i]={name=i..".jpg",path="/synthetic/"..i..".jpg"} end
local reader=Reader:new{
    open_chapter=function() error("unexpected chapter transition") end,
    state=State:new(),settings=settings,
    loader={identity="gray-contract",request=function(_,_,image,callbacks)
        requests[#requests+1]={image=image,callbacks=callbacks};return {}
    end},
    progress={chapter_id=function() return "synthetic" end,
        resolve=function() return {index=1,segment="whole"} end,save=function() end},
    cache={key_for=function(_,_,path) return path end,set_protected=function() end},
    render_image={renderImageFile=function()
        local buffer=BB.new(screen.width,screen.height,BB.TYPE_BB8)
        buffer:fill(BB.Color8(52));return buffer
    end},
    ui={create_shell=function(_,owner) return Shell:new{owner=owner,screen=screen} end,
        show_shell=function(_,shell) return shell:show() end},
    panel_source={},panel_detector={},
    panel_session_factory=function() return {start=function() return true end,
        close=function() end,is_active=function() return true end} end,
}
local context={manga={name="Synthetic",path="/synthetic"},chapter={name="Fixture",path="/synthetic"},
    chapter_index={count=function() return #entries end,get=function(_,i) return entries[i] end,
        window=function() return entries end}}
local function deliver()
    requests[#requests].callbacks.on_ready("/synthetic-cache/image.jpg",false,
        {width=screen.width,height=screen.height})
end
local function paint()
    local bb=BB.new(screen.width,screen.height,BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE);reader.shell.page_image:paintTo(bb,0,0);return bb
end
local function assert_gray(bb)
    for y=0,bb:getHeight()-1 do for x=0,bb:getWidth()-1 do
        expect(bb:getPixel(x,y):getColor8().a%17==0,"real visible body uses 16 gray values")
    end end
end
assert(reader:open(context));deliver()
local shell,session=reader.shell,reader.shell.graydither_session
expect(getmetatable(session)==Session,"source capability lookup constructs the real shared Session")
expect(getmetatable(shell.page_image).__index==ImageWidget or shell.page_image.paintTo~=nil,
    "source shell builds the pinned actual ImageWidget")
expect(not session.preferences:isEnabled() and not session.refresh_preferences:getEnabled(),
    "both independently stored switches default off")
local plain=paint()
expect(plain:getPixel(0,0):getColor8().a==52,"default-off preserves original pixel")
plain:free()
session.preferences:setGlobal(true);session.refresh_preferences:setEnabled(true)
session.refresh_preferences:setInterval(2);session:settingsChanged()
local source_before=BB.tostring(reader.page_buffer)
local gray=paint();assert_gray(gray);gray:free()
expect(BB.tostring(reader.page_buffer)==source_before,"final paint never mutates the borrowed source buffer")
expect(session.ordinal==1 and session.refresher.count==0,"first real successful paint establishes the baseline")
local duplicate=paint();duplicate:free()
expect(session.ordinal==1 and session.refresher.count==0,"same-token redraw never increments")
reader:next_page()
expect(reader.pending_request and session.paused and session.preserve_progress,
    "source loading cancels pending work and preserves the successful token")
deliver()
expect(shell.current_model.refresh_type=="partial" and not shell.current_model.native_animation,
    "resumed shared automatic refresh temporarily replaces native full and animation")
expect(session.ordinal==1,"download completion and publication alone never count")
local second=paint();assert_gray(second);second:free()
expect(session.ordinal==2 and session.refresher.count==1,"new real body paint advances once across loading")
reader:next_page();deliver()
local third=paint();third:free()
expect(session.refresher.count==2 and session.refresher.busy,"the second visible change queues actual automatic refresh")
reader:toggle_controls()
expect(session.paused and not session.refresher.busy and not session.refresher.task,
    "embedded source settings cancel queued refresh")
UI:advance(1)
expect(session.refresher.completed==0,"cancelled settings transition cannot flash or complete later")
reader:close_controls()
local resumed=paint();resumed:free()
expect(session.ordinal==1 and session.refresher.count==0,"return from settings rebuilds the first-screen baseline")

-- Actual successful panel rendering communicates its camera before committing
-- render_options, so the first pan/zoom cannot lag behind by one screen.
local PanelSession=require("webdavmanga.panel_session")
local fail_render=false
local handle={detection_raster=function() return {} end,close=function() end,
    pan_options=function(_,_,options,dx,dy)
        return {pan_x=(options.pan_x or 0)+dx,pan_y=(options.pan_y or 0)+dy}
    end,
    render=function(_,_,options)
        if fail_render then return nil,"synthetic render failure" end
        local buffer=BB.new(screen.width,screen.height,BB.TYPE_BB8)
        buffer:fill(BB.Color8(52+(options.pan_x or 0)+(options.zoom or 1)));return buffer
    end}
reader.panel_source={open=function(_,_,_,callbacks) callbacks.on_ready(handle);return {} end}
reader.panel_detector={detect=function() return {{id=1,x=0,y=0,w=9,h=7}} end}
reader.panel_session_factory=function(options) return PanelSession:new(options) end
reader.reader_settings.panel_view="free"
session.refresh_preferences:setInterval(50);session:settingsChanged()
expect(reader:enter_panel_mode(),"real source opens its actual dynamic panel session")
local camera=reader.panel_session
local panel_first=paint();assert_gray(panel_first);panel_first:free()
local panel_token=session.last_token
expect(camera:pan(5,2),"real panel camera pan renders successfully")
expect(session.last_token==panel_token,"render/publish alone do not advance the visible counter")
local pan=paint();assert_gray(pan);pan:free()
expect(session.ordinal==2 and session.refresher.count==1,"first painted same-panel camera pan counts immediately")
local pan_token=session.last_token
expect(camera:zoom(1.5),"real panel camera zoom renders successfully")
local zoom=paint();assert_gray(zoom);zoom:free()
expect(session.last_token~=pan_token and session.ordinal==3 and session.refresher.count==2,
    "painted same-panel zoom uses its successful new camera token")
local zoom_token=session.last_token
fail_render=true
expect(not camera:pan(3,0),"failed real source camera render is rejected")
local failed=paint();failed:free()
expect(session.last_token==zoom_token and session.ordinal==3,"failed camera render preserves visible token and count")

-- Real shared menu handles a failed source write without activating the value.
local items=session:getMenuItems()
backing.flush=function() return false end
expect(items[1].callback()==false,"a source storage failure is caught by the real shared menu")
expect(session.preferences:isEnabled() and reader.reader_settings.graydither_enabled,
    "failed save leaves the active source preference unchanged")
backing.flush=function() return true end
reader:toggle_controls()
local shared_action
for _,action in ipairs(shell.current_model.actions) do
    if action.text=="灰度抖动与墨水屏刷新" then shared_action=action end
end
expect(shared_action and shared_action.callback(),"actual embedded source controls open the real shared menu")
expect(session.menu and UI:getTopmostVisibleWidget()==session.menu,"the shared modal owns the menu above the source body")
session.menu.buttons[2][1].callback()
local refresh_button=session.menu.buttons[1][1]
expect(refresh_button.enabled,"immediate refresh is available from the shared source menu")
refresh_button.callback()
expect(not session.menu and UI:getTopmostVisibleWidget()==shell.widget and session.refresher.busy,
    "manual menu refresh returns to the real source body before its queued repaint")
UI:advance(0)
expect(session.refresher.completed==1,"the returned source body completes actual native refresh")
session.refresh_preferences:setEnabled(false);session:settingsChanged()
expect(reader:_page_change(1,2,"whole","whole",{"whole"},{"whole"}).refresh_type=="full",
    "turning off shared refresh restores the saved source full-refresh preference")
reader.full_refresh_each_page=false
expect(reader:_page_change(1,2,"whole","whole",{"whole"},{"whole"}).animate,
    "the saved native animation returns when source full-refresh is off")
expect(settings:get_reader().full_refresh_each_page and settings:get_reader().animation_enabled,
    "effective overrides never overwrite either original saved preference")
session.refresh_preferences:setEnabled(true);session:settingsChanged()
local frame=shell.current_model
session.attachImage=function() error("synthetic optional service failure") end
expect(shell:show_page(frame.buffer,frame.viewport,nil,{refresh_type="full",reading_token=frame.reading_token}),
    "an attach failure still publishes the actual source body")
expect(session.closed and shell.current_model.refresh_type=="full" and UI.dirty[#UI.dirty].mode=="full",
    "an actual Session attach failure restores native full in the same queued repaint")
shell:open_graydither_session();session=shell.graydither_session
expect(session and not session.closed,"a fresh reading session can obtain the enabled shared capability again")
shell:show_page(frame.buffer,frame.viewport,nil,{refresh_type="full",reading_token=frame.reading_token})
session.refresh_preferences:setEnabled(true);session.refresh_preferences:setMode("flash")
session.refresh_preferences:setHold(.1);session:settingsChanged()
local baseline=paint();baseline:free()
expect(session:requestRefresh(),"real ready session can queue manual flash")
UI:advance(0)
expect(session.refresher.layer and UI:getTopmostVisibleWidget()==session.refresher.layer,
    "black phase is owned by the actual Session refresh controller")
shell.widget:onCloseWidget()
expect(session.closed and not session.refresher.layer and not session.refresher.task,
    "direct host CloseWidget retires the owner and cancels an active black phase")
expect(not session.options.is_ready() and not shell:open_graydither_session(),
    "an externally closed owner cannot create or refresh a new shared session")
reader:force_close("contract")
expect(session.closed and not session.refresher.layer and not session.refresher.task,
    "source close removes the shared modal and all scheduled phase work")
local frames=#UI.frames;UI:advance(1)
expect(#UI.frames==frames,"retired session cannot paint a delayed white phase")
expect(not shell.graydither_session and not session:isRefreshManaged(),"close releases source refresh ownership")
print(("graydither_reader_contract: %d checks passed"):format(checks))
