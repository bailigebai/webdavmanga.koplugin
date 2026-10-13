local host=dofile('spec/helpers/reader_quadrant_host.lua')
local Session=require('webdavmanga.panel_session')
local Settings=require('webdavmanga.settings')
local Modes=require('webdavmanga.panel_modes')
local Web=require('webdavmanga.web_panel_zoom')
local Dynamic=require('webdavmanga.dynamic_panel_zoom')
local n=0
local function check(v,m)n=n+1;assert(v,m)end
local function fixture()
local r,o=host(false);local detected,owned={},{};o.opens=0
local stored={};r.settings=Settings:new{store={readSetting=function(_,k,d)return stored[k] or d end,
    saveSetting=function(_,k,v)if o.fail_save then return false end;stored[k]=v;if o.on_save then o.on_save()end end,flush=function()return not o.fail_save end}}
r.settings:set_reader{panel_zoom_enabled=true};r.reader_settings=r.settings:get_reader()
local function detector(mode)
    return {detect=function(_,req)
        detected[#detected+1]={mode=mode,request=req};if o.empty then return nil,'no_panels' end
        return {{id=mode..'1',x=0,y=0,w=.5,h=1},{id=mode..'2',x=.5,y=0,w=.5,h=1}}
    end,sort=require('webdavmanga.panel_detector').sort}
end
r.panel_detector=detector('intelligent');Web.detect=detector('web').detect;Dynamic.detect=detector('dynamic').detect
r.panel_session_factory=function(opts)if o.fail_factory then error('factory failed')end;return Session:new(opts)end
r.panel_source={open=function(_,_,_,cb)
    o.opens=o.opens+1;local handle={}
    function handle:detection_raster()return {buffer=r.page_buffer}end
    function handle:render()
        if o.on_render then o.on_render(handle) end
        if o.fail_render then return nil,'panel_render_failed' end
        local b={frees=0,getWidth=function()return 600 end,getHeight=function()return 800 end}
        function b:free()self.frees=self.frees+1;check(self.frees==1,'double free');check(r.shell.current_model.buffer~=self,'visible free')end
        owned[#owned+1]=b;return b
    end
    function handle:close()self.closed=true end
    if o.async then o.ready=function()cb.on_ready(handle)end else cb.on_ready(handle)end
    return {cancel=function()handle:close()end}
end}
return r,o,owned,detected
end
local r,o,owned,detected=fixture()
check(r:enter_panel_mode(),'enter intelligent');local session=r.panel_session
for _,mode in ipairs({'web','dynamic','intelligent','web'})do
    check(r:set_panel_option(Modes.keys[mode],true),'enable '..mode)
    check(Modes.active(r.reader_settings)==mode and r.panel_entry.mode==mode,'mode mutual exclusion')
    check(detected[#detected].mode==mode and r.panel_session==session,'new detector / one owner')
    check(o.opens==1 and #o.requests==1,'local original no redownload')
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
check(o.opens==1,'restores same original')
o.empty=true;check(not r:set_panel_option('web_panel_frame_min',2),'empty redetection')
check(r.panel_entry and r.panel_entry.whole_page and not r.panel_session,'whole page preserves panel route')
check(r.reader_settings.web_panel_frame_min==1,'failed detection does not save')
o.empty=nil;r:next_page();check(#o.requests==2,'whole fallback next physical page')
o.requests[2].callbacks.on_ready('/cache/2.jpg',false,{width=600,height=800})
check(r.panel_session and r.panel_session:is_active() and r.panel_entry.mode=='web','next page continues web')
r:force_close('test');for _,b in ipairs(owned)do check(b.frees==1,'all owners released')end
-- Whole-page fallback is still a reading mode; its next-page continuation
-- must survive failure of the replacement's first render, save or publication.
for _,failure in ipairs({'render','save','publish','factory','no-panels','async-render','async-success','late-close','close-save'})do
    local reader,opts,buffers=fixture()
    opts.empty=true;reader:enter_panel_mode();opts.empty=nil
    check(reader.panel_entry and reader.panel_entry.whole_page,'initial whole fallback')
    local previous=reader.reader_settings;local entry=reader.panel_entry
    if failure=='render' or failure=='async-render'then opts.fail_render=true end
    if failure=='save'then opts.fail_save=true end
    if failure=='factory'then opts.fail_factory=true end
    if failure=='no-panels'then opts.empty=true end
    if failure=='publish'then reader._show_panel=function()return false end end
    if failure=='close-save'then opts.on_save=function()opts.on_save=nil;reader:force_close('closed in save')end end
    if failure:find('async',1,true)or failure=='late-close'then opts.async=true end
    local accepted=reader:set_panel_option('web_panel_zoom_enabled',true)
    if opts.async then
        check(accepted and reader.reader_settings==previous,'async switch must not save before ready')
        if failure=='late-close'then reader:force_close('late switch')end
        opts.ready()
    else check(not accepted,'failed first publication must reject switch: '..failure)end
    opts.fail_render,opts.fail_save,opts.fail_factory,opts.empty=nil,nil,nil,nil
    if failure=='late-close' or failure=='close-save'then
        check(Modes.active(reader.settings:get_reader())=='intelligent','closed initial publication cannot commit mode')
        check(not reader.panel_entry and not reader.panel_session,'late ready cannot reopen closed reader')
    elseif failure=='async-success'then
        check(Modes.active(reader.reader_settings)=='web' and reader.panel_session:is_active(),'async successful switch commits')
    else
        check(Modes.active(reader.reader_settings)==Modes.active(previous)
            and Modes.active(reader.settings:get_reader())=='intelligent',
            'failed switch restores runtime and persisted mode: '..failure)
        check(reader.panel_entry and reader.panel_entry.whole_page and reader.panel_entry.mode==entry.mode,
            'failed switch retains whole-page continuation: '..failure)
        reader:next_page();check(#opts.requests==2,'next physical page after rejected switch')
        opts.requests[2].callbacks.on_ready('/cache/2.jpg',false,{width=600,height=800})
        if opts.async then opts.ready()end
        if failure~='publish'then check(reader.panel_session and reader.panel_session:is_active(),'next page re-detects original mode')end
    end
    reader:force_close('test');for _,b in ipairs(buffers)do check(b.frees==1,'fallback owners released')end
end
-- Saving an off switch inside pre-render must not release the source on its
-- native render stack. This also exercises non-camera settings while busy.
do
    local reader,opts=fixture();check(reader:enter_panel_mode(),'busy test start')
    local active=reader.panel_session;local attempts=0
    opts.on_render=function(handle)
        for _,change in ipairs({{'panel_zoom_enabled',false},{'panel_navigation','vertical'}})do
            attempts=attempts+1
            check(not reader:set_panel_option(change[1],change[2]),'busy edit must be rejected')
            check(not handle.closed and reader.panel_session==active,'render source stays owned')
        end
    end
    active.schedule=function(cb)cb()end;active:_schedule_next()
    check(attempts==2 and Modes.active(reader.reader_settings)=='intelligent','busy edit must not save')
    opts.on_render=nil;reader:force_close('busy complete')
end
print('panel_mode_reader_spec: '..n..' checks')
