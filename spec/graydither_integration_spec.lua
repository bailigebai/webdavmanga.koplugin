local Settings = require("webdavmanga.settings")
local fixture = dofile("spec/helpers/reader_quadrant_host.lua")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function copy(values)
    local result = {}
    for key, value in pairs(values or {}) do result[key] = value end
    return result
end
local function settings_store()
    local saved = {}
    local store = {
        readSetting = function(_, key, default) if saved[key] == nil then return default end; return saved[key] end,
        saveSetting = function(_, key, value) saved[key] = value end,
        delSetting = function(_, key) saved[key] = nil end,
        flush = function() return true end,
    }
    return Settings:new{store=store}, store
end

G_reader_settings = {readSetting=function() return true end}
local settings, store = settings_store()
expect(settings:get_reader().graydither_enabled == false,
    "WebDAV gray dithering starts disabled even when the host global value is true")
expect(settings:get_reader().graydither_refresh_enabled == false,
    "WebDAV automatic refresh starts independently disabled")
local values = settings:get_reader()
values.graydither_enabled = true
expect(settings:set_reader(values), "gray-only settings save through the source store")
local reopened = Settings:new{store=store}:get_reader()
expect(reopened.graydither_enabled and not reopened.graydither_refresh_enabled,
    "the two source switches persist independently")
values.graydither_enabled = "true"
expect(not settings:set_reader(values), "invalid source switch types are rejected")

local sessions, creates = {}, 0
local plugin = {}
function plugin:createImageSession(options)
    creates = creates + 1
    local session = {options=options, images={}, events={}}
    local function event(name) session.events[#session.events+1] = name end
    session.preferences = {
        isEnabled=function() return options.store:readSetting("graydither_enabled") == true end,
        setGlobal=function(_, value) options.store:saveSetting("graydither_enabled", value) end,
    }
    session.refresh_preferences = {
        getEnabled=function() return options.store:readSetting("graydither_refresh_enabled") == true end,
        setEnabled=function(_, value) options.store:saveSetting("graydither_refresh_enabled", value) end,
        setInterval=function(_, value) options.store:saveSetting("graydither_refresh_interval", value) end,
    }
    function session:attachImage(image, token)
        if self.fail_attach then error("unavailable image service") end
        self.images[#self.images+1] = {image=image, token=token}
        return {}
    end
    function session:settingsChanged() event("settings"); self.paused=false; options.redraw() end
    function session:pause(preserve_progress) event("pause"); self.paused=true; self.preserve_progress=preserve_progress==true end
    function session:resume() event("resume"); self.paused=false end
    function session:reset() event("reset") end
    function session:close() event("close"); self.closed=true end
    function session:isRefreshManaged()
        return not self.closed and not self.paused and self.refresh_preferences:getEnabled()
    end
    function session:requestRefresh() event("refresh"); return options.is_ready() end
    function session:getMenuItems() return {} end
    function session:showMenu(return_to_reading) self.return_to_reading=return_to_reading; event("menu"); return true end
    sessions[#sessions+1]=session
    return session
end
local active_plugin = plugin
package.loaded.pluginloader = {getPluginInstance=function(_, name)
    expect(name == "graydither", "lookup requests only the enabled named service")
    return active_plugin
end}

local reader, observed, context = fixture(false)
local shell, session = reader.shell, sessions[#sessions]
expect(session and session.options.owner == shell.widget, "the session owns the real reading window")
expect(session.options.is_ready(), "only the displayed page is ready")
expect(#session.images == 1 and session.images[1].image == shell.page_image,
    "only the final body ImageWidget is attached")
expect(not session.preferences:isEnabled() and not session.refresh_preferences:getEnabled(),
    "an unset source preference never inherits native global true")
local first_token = session.images[1].token
expect(type(first_token) == "string" and #first_token > 0, "the screen identity is a stable opaque token")
reader:_display_segment(reader.position.segment, false)
expect(session.images[#session.images].token == first_token, "repainting a logical screen preserves its token")
shell:show_status("notice", 0)
expect(session.images[#session.images].token == first_token, "status changes cannot create screen identities")
reader:onTwoFingerTap(shell, {pos={x=100,y=100}})
local quadrant_token = session.images[#session.images].token
expect(quadrant_token ~= first_token, "quadrant viewport has its own logical identity")
reader:onTwoFingerTap(shell, {pos={x=100,y=100}})
expect(session.images[#session.images].token == first_token, "collapsing returns to the original identity")

reader:toggle_controls()
expect(not session.options.is_ready() and session.paused, "embedded settings pause the service")
expect(not session.preserve_progress, "settings rebuild the baseline rather than counting their redraw")
local has_menu_entry=false
for _, action in ipairs(shell.current_model.actions or {}) do
    if action.text == "灰度抖动与墨水屏刷新" then has_menu_entry=true end
end
expect(has_menu_entry,"the source reading controls expose the shared feature menu")
local images_before_settings = #session.images
reader:toggle_controls("display")
expect(#session.images == images_before_settings, "settings never attach an ImageWidget")
reader:close_controls()
expect(session.options.is_ready() and not session.paused, "returning to the page resumes the same session")
expect(session.images[#session.images].token == first_token, "returning from settings keeps the same logical identity")
shell:show_loading("loading")
expect(session.paused and session.preserve_progress and not session.options.is_ready(),
    "temporary page loading cancels refresh without losing reading progress")
shell:show_error{message="failed"}
expect(session.paused and session.preserve_progress,"temporary errors retain the last successful screen baseline")
reader:close_controls()

shell.widget:onSuspend()
expect(session.paused, "suspend cancels pending auxiliary refresh")
shell.widget:onResume()
expect(not session.paused, "resume establishes a new visible baseline")
shell.widget:onRequestSuspend()
expect(session.paused, "request suspend cancels before host sleep begins")
shell.widget:onResume()
local before_rotation = #session.events
shell.widget:onSetRotationMode()
shell.widget:onSetDimensions()
shell.widget:onScreenResize()
expect(#session.events == before_rotation+3, "rotation and dimensions cancel obsolete pending refresh")

reader:show_graydither_settings()
expect(session.return_to_reading and session.events[#session.events] == "menu", "the source uses the shared settings menu")
expect(session.return_to_reading() ~= false and session.options.is_ready(), "manual refresh can return to the reading page first")
expect(type(shell.widget.onCloseWidget)=="function", "the host CloseWidget event retires an externally closed owner")
shell.widget:onCloseWidget()
expect(session.closed and not session.options.is_ready(),"direct host widget close cancels shared refresh without replaying reader exit")
shell.widget:onCloseWidget()
reader:force_close("fixture")
expect(session.closed and not session.options.is_ready(), "close retires the session before closing its window")

-- Real source persistence, including a write/flush failure, drives the service.
local r, o, ctx = fixture(false)
local persisted, backing = settings_store()
local source_values = persisted:get_reader()
source_values.full_refresh_each_page=true; source_values.animation_enabled=true
expect(persisted:set_reader(source_values), "old refresh and animation preferences save")
r:force_close("reopen")
r.settings=persisted
expect(r:open(ctx), "reopening with the real source settings succeeds")
o.requests[#o.requests].callbacks.on_ready("/cache/reopen.jpg",false,{width=600,height=800})
local s=r.shell.graydither_session
expect(s and not s.preferences:isEnabled(), "reopened source retains default-off")
s.preferences:setGlobal(true)
s:settingsChanged()
expect(persisted:get_reader().graydither_enabled and not persisted:get_reader().graydither_refresh_enabled,
    "gray-only toggles do not turn on automatic refresh")
local old_settings = r.reader_settings
backing.flush=function() return false end
expect(not pcall(s.refresh_preferences.setEnabled,s.refresh_preferences,true), "failed persistence is visible to the shared menu")
expect(not s.refresh_preferences:getEnabled() and r.reader_settings.graydither_refresh_enabled == old_settings.graydither_refresh_enabled,
    "a failed source write does not activate refresh or replace active preferences")
backing.flush=function() return true end
local saved_writer=backing.saveSetting
backing.saveSetting=function() return false end
expect(not pcall(s.preferences.setGlobal,s.preferences,false), "a rejected source store write is reported")
expect(s.preferences:isEnabled() and r.reader_settings.graydither_enabled,
    "a rejected store write keeps the saved and active gray preference unchanged")
backing.saveSetting=saved_writer
s.refresh_preferences:setEnabled(true); s:settingsChanged()
r:force_close("reopen")
expect(r:open(ctx),"a session can reopen with shared refresh enabled")
s=r.shell.graydither_session
r.shell.supports_animation=true
expect(s.paused and r.shell.current_model.kind=="loading","the first source page pauses while it loads")
o.requests[#o.requests].callbacks.on_ready("/cache/second.jpg",false,{width=600,height=800})
expect(r.shell.current_model.refresh_type=="partial" and not r.shell.current_model.native_animation,
    "loading-to-page publication still suppresses the old full-refresh and animation")
local managed=r:_page_change(1,2,"whole","whole",{"whole"},{"whole"})
expect(managed.refresh_type=="full" and not managed.animate,
    "the reader preserves native intent for the shell's optional refresh override")
expect(r.full_refresh_each_page and r.animation_enabled and persisted:get_reader().full_refresh_each_page,
    "the original full-refresh and animation preferences are retained")
s.refresh_preferences:setEnabled(false); s:settingsChanged()
local native=r:_page_change(1,2,"whole","whole",{"whole"},{"whole"})
expect(native.refresh_type=="full" and not native.animate, "disabling shared refresh immediately restores native full")
r.full_refresh_each_page=false
expect(r:_page_change(1,2,"whole","whole",{"whole"},{"whole"}).animate,
    "the prior native animation returns when native full is off")
s.refresh_preferences:setEnabled(true); s:settingsChanged()
s.fail_attach=true
r.full_refresh_each_page=true
expect(r:_display_segment("whole",false,r:_page_change(1,2,"whole","whole",{"whole"},{"whole"})),
    "a service failure cannot reject source reading")
expect(r.shell.current_model.refresh_type=="full",
    "attach failure restores original full refresh in the same published frame")
expect(s.closed and not r.shell:is_graydither_refresh_managed(), "a failed image service releases ownership")
r.full_refresh_each_page=true
expect(r:_page_change(1,2,"whole","whole",{"whole"},{"whole"}).refresh_type=="full",
    "service failure restores native full-refresh behavior")
r:force_close("fixture")

-- Tokens describe displayed source modes, never the download path or buffers.
local width_reader = fixture(false,{fit_mode="width",w=600,h=2400})
local width_session=sessions[#sessions]
local width_token=width_session.images[#width_session.images].token
width_reader:next_page()
expect(width_session.images[#width_session.images].token ~= width_token, "vertical pan advances a logical reading screen")
width_reader:force_close("fixture")
local split_reader = fixture(false,{split=true,w=1200,h=800})
local split_session=sessions[#sessions]
local split_token=split_session.images[#split_session.images].token
split_reader:next_page()
expect(split_session.images[#split_session.images].token~=split_token, "left and right split screens have distinct identities")
local panel_buffer=split_reader.page_buffer
split_reader:_show_panel(panel_buffer,{},1,2)
local panel_token=split_session.images[#split_session.images].token
split_reader:_show_panel(panel_buffer,{},1,2)
expect(split_session.images[#split_session.images].token==panel_token,"repaint of a panel preserves identity")
split_reader:_show_panel(panel_buffer,{},2,2)
expect(split_session.images[#split_session.images].token~=panel_token,"another panel counts despite the same physical index")
local frame={getWidth=function() return 600 end,getHeight=function() return 800 end,free=function() end}
split_reader.fit_mode="webtoon"
split_reader:_publish_webtoon(frame,{index=1,y=0,fraction=0},{background="white"})
local strip_token=split_session.images[#split_session.images].token
split_reader:_publish_webtoon(frame,{index=1,y=800,fraction=.5},{background="white"})
expect(split_session.images[#split_session.images].token~=strip_token,"strip positions within the same source image have distinct identities")
split_reader:force_close("fixture")

-- The actual PanelSession publishes its successful camera, not the old state
-- that is still installed while its on_panel callback runs.
local PanelSession=require("webdavmanga.panel_session")
local camera_reader=fixture(false)
local camera_service=sessions[#sessions]
local fail_render=false
local handle={detection_raster=function() return {} end,close=function() end,
    pan_options=function(_,_,options,dx,dy)
        return {pan_x=(options.pan_x or 0)+dx,pan_y=(options.pan_y or 0)+dy}
    end,
    render=function()
        if fail_render then return nil,"synthetic render failure" end
        return {getWidth=function() return 600 end,getHeight=function() return 800 end,free=function() end}
    end}
camera_reader.panel_source={open=function(_,_,_,callbacks) callbacks.on_ready(handle);return {} end}
camera_reader.panel_detector={detect=function() return {{id=1,x=0,y=0,w=600,h=800}} end}
camera_reader.panel_session_factory=function(options) return PanelSession:new(options) end
camera_reader.reader_settings.panel_view="free"
expect(camera_reader:enter_panel_mode(),"actual dynamic panel session opens")
local camera=camera_reader.panel_session
local camera_token=camera_service.images[#camera_service.images].token
expect(camera:pan(20,30),"actual free view renders the new camera")
local panned_token=camera_service.images[#camera_service.images].token
expect(panned_token~=camera_token,"first same-panel camera pan publishes a new visible token immediately")
expect(camera:zoom(1.5),"actual free view renders zoom")
local zoomed_token=camera_service.images[#camera_service.images].token
expect(zoomed_token~=panned_token,"same-panel zoom publishes a new token")
fail_render=true
expect(not camera:pan(5,0),"failed pan render is rejected")
expect(camera_service.images[#camera_service.images].token==zoomed_token,"failed render never publishes a requested camera token")
camera_reader:force_close("fixture")

active_plugin=nil
local absent, absent_observed=fixture(false)
expect(absent.page_buffer and absent.shell.page_image and not absent.shell.graydither_session,
    "missing or disabled service preserves the existing reader")
expect(absent:show_graydither_settings()==false and absent.shell.current_model.kind=="page",
    "an unavailable settings entry keeps the page and explains the requirement")
absent:force_close("fixture")
active_plugin={createImageSession=function() error("service unavailable") end}
local failing=fixture(false)
expect(failing.page_buffer and not failing.shell.graydither_session,"session creation failure falls back to source reading")
failing:force_close("fixture")
active_plugin=true
local malformed=fixture(false)
expect(malformed.page_buffer and not malformed.shell.graydither_session,
    "malformed optional plugin capability must never prevent the source reader from opening")
malformed:force_close("fixture")
print(("graydither_integration_spec: %d checks passed"):format(checks))
