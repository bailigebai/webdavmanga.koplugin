local Thumbnail=require("webdavmanga.bookshelf_loader")
local Cache=require("webdavmanga.cache")
local checks,failures=0,{}
local function expect(v,m) checks=checks+1;if not v then failures[#failures+1]=m end end
local function fixture()
    local files,workers,requests,hashes={},{},{},{}
    local cache=Cache:new{root="/shelf",limit_bytes=20*1024*1024,unified_quota=true,
        md5=function(v) if not hashes[v] then hashes[v]="k"..tostring(#hashes+1);hashes[#hashes+1]=v end;return hashes[v] end,
        store={readSetting=function(_,_,d) return d end,saveSetting=function() end,flush=function() return true end,
            cache_index_size=function() return 0 end,on_disk_size=function() return 0 end},
        fs={make_path=function() end,size=function(p) return files[p] end,exists=function(p) return files[p]~=nil end,
            list=function() local out={};for p,n in pairs(files) do out[#out+1]={path=p,size=n} end;return out end,
            remove=function(p) files[p]=nil;return true end,rename=function(a,b) files[b]=files[a];files[a]=nil;return true end}}
    local source={identity="source",request_cover=function(_,g,image,cb) requests[#requests+1]=cb;return true end,
        cancel_cover_generation=function() end,cancel_all=function() end}
    local processor={}
    local calls=0
    processor.process=function(src,part,settings)
        expect(files[src]~=nil,"worker reads a still-owned source")
        calls=calls+1;files[part]=1000
        return {format="png",width=settings.target_width,height=settings.target_height,validated=true}
    end
    local async={run=function(work,done,options)
        local w={work=work,done=done,options=options};workers[#workers+1]=w
        return {cancel=function() w.canceled=true end}
    end}
    local thumb=Thumbnail:new{cache=cache,loader=source,identity="thumb",processor=processor,async=async}
    thumb:set_target_size(120,160)
    local image={name="1.jpg",path="/m/1.jpg",size=100,width=900,height=1200}
    local source_key=cache:key_for(source.identity,image.path,"cover")
    local path="/shelf/"..source_key..".jpg"
    cache.entries[source_key]={key=source_key,path=path,kind="cover",size=100,extension="jpg",
        format="jpeg",width=900,height=1200,validated=true};files[path]=100
    local function ready(i) requests[i].on_ready(path,false,{width=900,height=1200}) end
    local function finish(i) local w=workers[i];local ok,result=pcall(w.work);w.done(ok,result) end
    return thumb,cache,files,workers,ready,finish,image,path,function() return calls end,processor,async
end
do
    local t,c,files,w,ready,finish,img,src,calls=fixture();local a,b
    t:request_cover("a",img,{on_ready=function(p) a=p end})
    t:request_cover("b",img,{on_ready=function(p) b=p end})
    ready(1);ready(2)
    expect(calls()==0 and not a,"source completion never decodes/encodes on the UI thread")
    expect(#w==1,"duplicate cards share a single background PNG producer")
    if w[1] then finish(1) end
    expect(a and a==b and calls()==1,"both waiters receive the compact thumbnail")
    expect(not files[src],"original cache entry is released after producer finishes")
    local count=#w;t:request_cover("warm",img,{on_ready=function(p) expect(p==a,"warm cover is reused") end})
    expect(#w==count,"warm cache does not launch a PNG producer")
    t:cancel_all();expect(not next(c.protection_leases) and c:pending_size()==0,"successful work leaves no leases or parts")
end
do
    local t,c,files,w,ready,_,img,src=fixture();local delivered=0
    t:request_cover("old",img,{on_ready=function() delivered=delivered+1 end});ready(1)
    t:cancel_cover_generation("old")
    expect(w[1] and w[1].canceled and files[src],"cancel holds the source until the child is reaped")
    expect(next(c.owned_parts)~=nil,"cancel holds temporary ownership until the child is reaped")
    if w[1] then
        local ok,result=pcall(w[1].work);w[1].done(ok,result)
        w[1].options.on_reaped();w[1].options.on_cancelled()
    end
    expect(delivered==0 and not files[src] and not next(c.owned_parts) and not next(c.protection_leases),
        "late completion never publishes and reap cleans exactly once")
end
do
    local t,c,files,w,ready,finish,img,src=fixture()
    t:request_cover("small",img,{});ready(1);t:set_target_size(240,320)
    t:request_cover("large",img,{});ready(2)
    expect(#w==2 and files[src],"layout sizes have separate jobs sharing a protected original")
    if w[1] and w[2] then
        finish(1);expect(files[src]~=nil,"one job cannot delete another job's source")
        finish(2);expect(not files[src],"last producer releases the shared original")
    end
    t:cancel_all();expect(not next(c.protection_leases),"layout changes release all source and thumbnail leases")
end
do
    local t,c,files,w,ready,_,img,src=fixture();local errors=0
    t:request_cover("failed",img,{on_error=function() errors=errors+1 end});ready(1)
    if w[1] then
        w[1].done(false,nil,"timeout",{reap_pending=true})
        expect(files[src] and next(c.owned_parts),"timeout reserves resources until child exits")
        w[1].options.on_reaped()
    end
    expect(errors==1 and not files[src] and not next(c.owned_parts),"failed worker reports once and releases after reap")
    t:cancel_all();expect(not next(c.protection_leases),"error cleanup releases leases")
end
do
    local t,c,files,w,ready,finish,img,src=fixture();local result
    t:request_cover("old",img,{});ready(1);t:cancel_cover_generation("old")
    t:request_cover("new",img,{on_ready=function(p) result=p end});ready(2)
    expect(#w==2,"a new page never joins a producer already being terminated")
    if w[1] and w[2] then
        w[1].options.on_reaped();expect(files[src]~=nil,"old reap preserves a fresh producer's original")
        finish(2);expect(result and not files[src],"fresh producer publishes after old cancellation")
    end
    t:cancel_all();expect(not next(c.protection_leases) and c:pending_size()==0,"successor cleans all ownership")
end
do
    local t,c,files,_,ready,_,img,src,_,_,async=fixture();local errors=0
    async.run=function() error("spawn failed") end
    t:request_cover("spawn",img,{on_error=function() errors=errors+1 end});ready(1)
    expect(errors==1 and not files[src] and not next(c.owned_parts),"spawn exception cleans source and reserved output")
    t:cancel_all();expect(not next(c.protection_leases),"spawn failure releases leases")
end
do
    local t,c,files,w,ready,finish,img,src,_,processor=fixture();local errors=0
    processor.process=function() error("decoder failed") end
    t:request_cover("decode",img,{on_error=function() errors=errors+1 end});ready(1)
    if w[1] then finish(1) end
    expect(errors==1 and not files[src] and c:pending_size()==0,"decoder exception cleans output and source")
    t:cancel_all();expect(not next(c.protection_leases),"decoder failure releases leases")
end
do
    local t,c,files,w,ready,finish,img,src=fixture();local delivered=0
    t:request_cover("broken",img,{on_ready=function() error("card failed") end})
    t:request_cover("healthy",img,{on_ready=function() delivered=delivered+1 end});ready(1);ready(2)
    if w[1] then finish(1) end
    expect(delivered==1 and not files[src],"one card callback cannot starve a merged waiter")
    t:cancel_all();expect(not next(c.protection_leases),"callback exceptions do not leak leases")
end
do
    local t,c,files,w,ready,finish,img,src=fixture()
    c.entries[c:key_for("source",img.path,"cover")]=nil
    t:request_cover("local",img,{});ready(1);if w[1] then finish(1) end
    expect(files[src]~=nil,"thumbnailing never deletes an unowned local original")
    t:cancel_all()
end
do
    local t,c,files,w,ready,_,img,src=fixture();local errors=0
    t:request_cover("budget",img,{on_error=function() errors=errors+1 end});c.limit_bytes=200;ready(1)
    expect(errors==1 and #w==0 and not files[src] and c:pending_size()==0,
        "lost PNG capacity rejects before fork and cleans exact reservations")
    t:cancel_all();expect(not next(c.protection_leases),"zero budget releases leases")
end
do
    -- Real SourceLoader returns nil after a synchronous source-cache hit.
    -- This must not release the grid lane while asynchronous PNG work runs.
    local t,c,_,w,_,finish,_,src=fixture()
    t.loader.request_cover=function(_,_,_,cb) cb.on_ready(src,true,{width=900,height=1200});return nil end
    local Grid=require("webdavmanga.ui_cover_grid")
    local cover={fork=function(self) return self end,resolve=function(_,_,options,cb)
        cb.on_ready({path=options.manga.path.."/1.jpg",name="1.jpg",size=100});return true end}
    local queue={};local scheduler={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}
    local ui={show_grid=function(self,m) self.model=m end,close_grid=function() end,free_visible=function() end,
        get_cover_size=function() return 100,140 end,update_cover=function() return true end}
    local grid=Grid:new{cover_service=cover,cache=c,loader=t,ui=ui,scheduler=scheduler,
        render_batch_size=2,cover_concurrency=6,connection_provider=function() return {} end,
        settings={get_reader=function() return {} end},render_image={renderImageFile=function() return {free=function() end} end}}
    local items,ids={},{};for i=1,15 do items[i]={id=i,manga={path="/m/"..i}};ids[i]=i end
    grid:show{items=items};ui.model.on_visible(ids)
    expect(#w==6,"cached source completion keeps all six whole-chain slots occupied")
    if #w==6 then
        finish(1);local fn=table.remove(queue,1);if fn then fn() end
        expect(#w==7,"one rendered PNG releases exactly one complete slot")
    end
    grid:cancel()
    for _,worker in ipairs(w) do worker.options.on_reaped() end
    expect(not next(c.owned_parts) and not next(c.protection_leases),"bounded asynchronous lanes clean on exit")
end
do
    local t,c,files,w,ready,finish,img,src=fixture();local errors=0
    c.publish=function() error("index serialization error") end
    t:request_cover("publish",img,{on_error=function() errors=errors+1 end});ready(1)
    local ok=true;if w[1] then ok=pcall(finish,1) end
    expect(ok and errors==1 and not files[src] and not next(c.owned_parts) and not next(t.all_jobs),
        "publish exceptions clean producers and report an error instead of blocking a lane")
    t:cancel_all();expect(not next(c.protection_leases),"publish exception leaves no leases")
end
assert(#failures==0,table.concat(failures,"\n"))
print(("bookshelf_responsive_thumbnail_spec: %d checks"):format(checks))
