local host=dofile('spec/helpers/reader_quadrant_host.lua')
local Session=require('webdavmanga.panel_session')
local Settings=require('webdavmanga.settings')
local Modes=require('webdavmanga.panel_modes')
local Web=require('webdavmanga.web_panel_zoom')
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local n=0
local function check(v,m)n=n+1;assert(v,m)end
local r,o=host(false);local open_count,detected,owned=0,{},{}
local stored={};r.settings=Settings:new{store={readSetting=function(_,k,d)return stored[k] or d end,
    saveSetting=function(_,k,v)if o.fail_save then return false end;stored[k]=v end,flush=function()return not o.fail_save end}}
r.reader_settings=r.settings:get_reader();r.reader_settings.panel_zoom_enabled=true
local function detector(mode)
    return {detect=function(_,req)
        detected[#detected+1]={mode=mode,request=req};if o.empty then return nil,'no_panels' end
        return {{id=mode..'1',x=0,y=0,w=.5,h=1},{id=mode..'2',x=.5,y=0,w=.5,h=1}}
    end,sort=require('webdavmanga.panel_detector').sort}
end
r.panel_detector=detector('intelligent');Web.detect=detector('web').detect;Dynamic.detect=detector('dynamic').detect
r.panel_session_factory=function(opts)return Session:new(opts)end
r.panel_source={open=function(_,_,_,cb)
    open_count=open_count+1;local handle={}
    function handle:detection_raster()return {buffer=r.page_buffer}end
    function handle:render()
        if o.fail_render then return nil,'panel_render_failed' end
        local b={frees=0,getWidth=function()return 600 end,getHeight=function()return 800 end}
        function b:free()self.frees=self.frees+1;check(self.frees==1,'double free');check(r.shell.current_model.buffer~=self,'visible free')end
        owned[#owned+1]=b;return b
    end
    function handle:close()self.closed=true end
    cb.on_ready(handle);return {}
end}
check(r:enter_panel_mode(),'enter intelligent');local session=r.panel_session
for _,mode in ipairs({'web','dynamic','intelligent','web'})do
    check(r:set_panel_option(Modes.keys[mode],true),'enable '..mode)
    check(Modes.active(r.reader_settings)==mode and r.panel_entry.mode==mode,'mode mutual exclusion')
    check(detected[#detected].mode==mode and r.panel_session==session,'new detector / one owner')
    check(open_count==1 and #o.requests==1,'local original no redownload')
end
check(r:set_panel_option('web_panel_strength_percent',175),'strength tuning')
check(detected[#detected].request.strength_percent==175 and r.panel_session.index==1,'actual recognition parameter')
for _,view in ipairs({'cut','free','context'})do
    check(r:set_panel_option('panel_view',view),'web view '..view)
    check(r.panel_session.render_options.view==view,'shared camera '..view)
end
local old=r.reader_settings.web_panel_strength_percent;local shown=r.panel_session.current_buffer
o.fail_save=true;check(not r:set_panel_option('web_panel_strength_percent',150),'save rejected');o.fail_save=nil
check(r.reader_settings.web_panel_strength_percent==old and r.panel_session.current_buffer==shown,'save rollback')
o.fail_render=true;check(not r:set_panel_option('dynamic_panel_zoom_enabled',true),'switch render rejected');o.fail_render=nil
check(Modes.active(r.reader_settings)=='web' and r.panel_session.current_buffer==shown,'mode rollback')
check(r:toggle_controls('web'),'web menu')
local restore
for _,item in ipairs(r.shell.current_model.actions)do if item.text=='恢复 Web 识别四项默认值'then restore=item end end
check(restore and restore.callback(),'restore recognition settings')
check(r.reader_settings.web_panel_strength_percent==100 and Modes.active(r.reader_settings)=='web','restore keeps enabled / camera')
check(open_count==1,'restores same original')
o.empty=true;check(not r:set_panel_option('web_panel_frame_min',2),'empty redetection')
check(r.panel_entry and r.panel_entry.whole_page and not r.panel_session,'whole page preserves panel route')
check(r.reader_settings.web_panel_frame_min==1,'failed detection does not save')
o.empty=nil;r:next_page();check(#o.requests==2,'whole fallback next physical page')
o.requests[2].callbacks.on_ready('/cache/2.jpg',false,{width=600,height=800})
check(r.panel_session and r.panel_session:is_active() and r.panel_entry.mode=='web','next page continues web')
r:force_close('test');for _,b in ipairs(owned)do check(b.frees==1,'all owners released')end
print('panel_mode_reader_spec: '..n..' checks')
