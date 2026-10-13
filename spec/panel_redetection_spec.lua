local Session=require('webdavmanga.panel_session')
local n=0
local function check(v,m)n=n+1;assert(v,m)end
local function fixture()
    local f={opens=0,live=0,peak=0,queued={},all={}}
    local function buffer()
        local b={frees=0};f.live=f.live+1;f.peak=math.max(f.peak,f.live);f.all[#f.all+1]=b
        function b:free()self.frees=self.frees+1;check(self.frees==1,'double free');check(f.shown~=self,'free visible');f.live=f.live-1 end
        return b
    end
    local handle={}
    function handle:detection_raster()check(not self.closed,'closed raster');return {borrowed=true}end
    function handle:render(panel,opts)
        check(not self.closed,'closed render');if f.render_fail then return nil,'panel_render_failed' end
        if f.close_render then f.shown=nil;f.session:close()end
        local b=buffer();b.panel=panel;b.options=opts;return b
    end
    function handle:close()self.closed=true end
    local detector={detect=function(_,r)
        f.last_request=r;if f.empty then return nil,'no_panels' end
        return {{id=tostring(r.detection_threshold)..'-1',x=0,y=0,w=.5,h=1},{id='two',x=.5,y=0,w=.5,h=1}}
    end}
    f.session=Session:new{screen_width=600,screen_height=800,detector=detector,
        schedule=function(cb)f.queued[#f.queued+1]=cb end,
        source={open=function(_,_,_,cb)f.opens=f.opens+1;cb.on_ready(handle);return {}end}}
    f.session:start({detection_threshold=40,view='context'}, {
        on_panel=function(b,_,_,_,opts)if f.reject then return false end;f.shown=b;f.revision=opts.layout_revision;return true end,
        on_fallback=function()f.detached=true;f.shown=nil;return true end})
    return f
end
do
    local f=fixture();local s=f.session;local initial=s.current_buffer;local stale=f.queued[1]
    stale();check(f.live==2,'current/next');local revision=f.revision
    for _,threshold in ipairs({1,37,254})do
        check(s:redetect({detection_threshold=threshold},function()return true end),'redetect')
        check(s.index==1 and s.panels[1].id==threshold..'-1','new first panel')
        check(f.opens==1 and f.last_request.detection_threshold==threshold,'reuse original handle')
        check(f.revision~=revision,'layout token changes');revision=f.revision
        stale();check(s.current_buffer==f.shown,'late prefetch cannot publish')
    end
    check(initial.frees==1 and f.peak<=2,'bounded rendered owners')
    f.shown=nil;s:close();check(f.live==0,'all released')
end
for _,failure in ipairs({'save','render','publish'})do
    local f=fixture();local s=f.session;local b,panels,request=s.current_buffer,s.panels,s.source_request;local rolled=0
    f.render_fail=failure=='render';f.reject=failure=='publish'
    check(not s:redetect({detection_threshold=70},function()return failure~='save' end,function()rolled=rolled+1 end),'reject '..failure)
    check(s.current_buffer==b and s.panels==panels and s.source_request==request and f.shown==b,'preserve layout '..failure)
    check(rolled==(failure=='publish' and 1 or 0),'rollback committed save only')
    check(f.opens==1 and f.peak<=2,'no reopen / extra buffer')
    f.shown=nil;s:close();check(f.live==0,'failure cleanup')
end
do
    local f=fixture();f.empty=true;check(not f.session:redetect({detection_threshold=1}),'empty result')
    check(f.detached and not f.session:is_active() and f.live==0,'detach before fallback free')
end
do
    local f=fixture();f.close_render=true;check(not f.session:redetect({detection_threshold=50}),'reentrant close')
    check(f.live==0 and not f.session:is_active(),'candidate released after close')
end
do
    local f=fixture();local detector={detect=function()return {{id='web',x=0,y=0,w=1,h=1}}end}
    check(f.session:redetect({view='cut',direction='manga'},nil,nil,detector),'detector switch')
    check(f.session.detector==detector and f.session.direction=='manga' and f.session.index==1,'atomic mode layout')
    check(f.session.render_options.view=='cut' and f.opens==1,'camera uses same source')
    check(f.session:configure({view='free'}),'free view')
    check(f.session:redetect({detection_threshold=33}),'free local tuning')
    check(f.session.render_options.view=='free' and f.session.source_request.detection_threshold==33,'keep free view')
    f.shown=nil;f.session:close();check(f.live==0,'switch cleanup')
end
print('panel_redetection_spec: '..n..' checks')
