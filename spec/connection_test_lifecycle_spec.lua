local UiSettings=require("webdavmanga.ui_settings")
local checks=0;local function expect(v,m)checks=checks+1;assert(v,m)end
local function fixture(kind,deferred,synchronous)
    local f={jobs={},infos={},busy_shown=0,busy_closed=0}
    local values=kind=="local" and {kind="local",local_path="/mnt/us/Comics"}
        or {kind=kind,server_url="http://nas:5005",root_path="/Comics"}
    f.controller=UiSettings:new{settings={},cache={},client_factory=function()
        return {test_connection=function()return true end}
    end,nodeshare={parse_endpoint=function()return {host="nas",port=5005}end,probe=function()return true end},
        ui={show_busy=function()
            f.busy_shown=f.busy_shown+1;local closed=false
            return {close=function()if not closed then closed=true;f.busy_closed=f.busy_closed+1 end end}
        end,show_info=function(_,text)f.infos[#f.infos+1]=text end,close_all=function()return true end},
        async={run=function(work,done)
            local job={work=work,done=done,cancels=0};f.jobs[#f.jobs+1]=job
            if synchronous then done(true,work()) end
            return {cancel=function()job.cancels=job.cancels+1 end}
        end},network_manager={willRerunWhenConnected=function(_,start)
            if deferred then f.start=start;return true end;return false
        end}}
    function f:run()
        if kind=="nodeshare" then return self.controller:_run_nodeshare_connection_test(values) end
        return self.controller:_run_connection_test(values)
    end
    return f
end
for _,kind in ipairs({"local","webdav","nodeshare"}) do
    local f=fixture(kind);expect(f:run() and #f.jobs==1,kind.." test starts")
    f.controller:close_all()
    expect(f.jobs[1].cancels==1 and f.busy_closed==1,kind.." exit cancels its worker and busy window")
    f.jobs[1].done(true,{ok=true,stage="webdav"})
    expect(#f.infos==0,kind.." late callback cannot reopen a popup over KOReader")
    f:run();f.jobs[1].done(true,{ok=true,stage="webdav"})
    expect(#f.infos==0,kind.." old callback cannot interfere with a reopened session")
    f.jobs[2].done(true,f.jobs[2].work())
    expect(#f.infos==1 and f.busy_closed==2,kind.." fresh session still reports successful tests")
    f.controller:close_all()
    expect(f.jobs[2].cancels==0,kind.." settled worker handle is not mistakenly retained")
    local repeated=fixture(kind);repeated:run();repeated:run()
    expect(repeated.jobs[1].cancels==1 and repeated.busy_closed==1,kind.." repeated tests replace old work")
    repeated.jobs[1].done(true,{ok=true});expect(#repeated.infos==0,kind.." replaced result stays silent")
    local inline=fixture(kind,false,true);inline:run();inline.controller:close_all()
    expect(#inline.infos==1 and inline.jobs[1].cancels==0,kind.." synchronous completion owns no stale worker")
end
for _,kind in ipairs({"webdav","nodeshare"}) do
    local f=fixture(kind,true);f:run();expect(f.start and #f.jobs==0,kind.." waits for connectivity")
    f.controller:close_all();f.start()
    expect(#f.jobs==0 and f.busy_shown==0,kind.." delayed connectivity cannot reopen an exited plugin")
end
print(("connection_test_lifecycle_spec: %d checks"):format(checks))
