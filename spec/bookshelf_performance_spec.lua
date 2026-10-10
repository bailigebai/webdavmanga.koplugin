-- Production selection, grid, source and thumbnail loaders; only I/O/time/UI
-- are controlled boundaries. Fixed 2s directory + 2s transfer per card.
local Cover=require("webdavmanga.cover")
local Grid=require("webdavmanga.ui_cover_grid")
local Source=require("webdavmanga.loader")
local Thumbnail=require("webdavmanga.bookshelf_loader")
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local function run(count,concurrency,defer)
    local now,events,records,files,selection=0,{},{},{},{}
    local active,peak,downloaded,rendered,canceled=0,0,0,0,0
    local scheduler={scheduleIn=function(_,delay,fn) events[#events+1]={at=now+delay,fn=fn} end}
    local function later(delay,fn)
        local task={canceled=false};active=active+1;peak=math.max(peak,active)
        scheduler:scheduleIn(delay,function()
            active=active-1
            if not task.canceled then fn() end
        end)
        return {cancel=function() if not task.canceled then task.canceled=true;canceled=canceled+1 end end}
    end
    local function drain()
        local steps=0
        while #events>0 do
            steps=steps+1;assert(steps<1000,"load queue failed to settle")
            table.sort(events,function(a,b) return a.at<b.at end)
            local e=table.remove(events,1);now=e.at;e.fn()
        end
    end
    local cache={entries=records,limit_bytes=1000000,cover_limit_bytes=1000000,
        key_for=function(_,id,p,kind) return id..":"..p..":"..tostring(kind) end,
        lookup=function(_,key) return records[key] and records[key].path end,
        paths_for=function(_,key) return key..".png",key..".part" end,
        protect=function() end,unprotect=function() end,
        publish=function(_,record,part) record.path=record.key..".png";records[record.key]=record;files[record.path]=files[part];files[part]=nil;return record.path end,
        remove=function(_,key) if records[key] then files[records[key].path]=nil end;records[key]=nil end,
        discard_part=function(_,key) files[key..".part"]=nil end}
    local dirs={load=function(_,path,cb)
        return later(2,function()
            local image={name="001.jpg",path=path.."/001.jpg",size=100,width=300,height=400}
            cb.on_ready({images=function() return {get=function() return image end} end,close=function() end})
        end)
    end}
    local library={get_cover=function(_,_,p) return selection[p] end,
        set_cover=function(_,_,p,img) selection[p]={manga_path=p,image=img};return true end}
    local cover=Cover:new{library=library,directory_store=dirs,scheduler=scheduler}
    local source=Source:new{identity="source",cache=cache,cover_concurrency=concurrency,
        client_factory=function() return {download=function(_,path,part)
            downloaded=downloaded+1;files[part]=100
            return {size=100,format="jpeg",width=300,height=400}
        end} end,
        async={run=function(work,done) return later(2,function() local ok,result=pcall(work);done(ok,result) end) end}}
    local thumbnail=Thumbnail:new{identity="thumb",cache=cache,loader=source,
        processor={process=function(_,part,profile) files[part]=20;return {format="png",width=profile.target_width,height=profile.target_height} end}}
    local ui={show_grid=function(self,m) self.model=m end,free_visible=function() end,close_grid=function() end,
        update_cover=function() rendered=rendered+1;return true end}
    local grid=Grid:new{cover_service=cover,loader=thumbnail,cache=cache,
        cover_concurrency=concurrency,connection_provider=function() return {root_path="/m"} end,
        settings={get_reader=function() return {} end},ui=ui,scheduler=scheduler,
        render_image={renderImageFile=function() return {free=function() end} end}}
    local items,ids={},{}
    for i=1,count do items[i]={id=i,manga={name=tostring(i),path="/m/"..i,is_folder=true}};ids[i]=i end
    grid:show{items=items};ui.model.on_visible(ids)
    local first_active=active
    if not defer then drain() end
    return {seconds=now,rendered=rendered,peak=peak,initial_active=first_active,downloads=downloaded,
        warm=function() local before=now;ui.model.on_visible(ids);drain();return now-before end,
        grid=grid,ui=ui,drain=drain,ids=ids,canceled=function() return canceled end,
        visible=function(next_ids) ui.model.on_visible(next_ids) end,
        renders=function() return rendered end,cache=cache,thumbnail=thumbnail,selection=selection}
end
local old=run(15,1)
local fast=run(15,6)
print(("BOOKSHELF controlled baseline=%.3fs optimized=%.3fs speedup=%.3fx peak=%d"):format(old.seconds,fast.seconds,old.seconds/fast.seconds,fast.peak))
expect(old.rendered==15 and fast.rendered==15,"every visible card loads")
expect(fast.initial_active==6,"six independent selections start without canceling each other")
expect(fast.peak<=6,"complete chains never exceed six workers")
expect(old.seconds/fast.seconds>=5,"15 cold covers eliminate serial wait by at least fivefold in controlled latency")
expect(fast.warm()==0 and fast.canceled()==0,"warm page requires no network wait")
local cached=fast.renders()
local first_image=fast.selection["/m/1"].image
fast.cache:remove(fast.thumbnail:cover_key(first_image))
fast.visible(fast.ids)
expect(fast.renders()==cached+14,"cached cards behind a cold card display before it finishes")
fast.drain()
expect(fast.renders()==cached+15,"missing thumbnail is rebuilt without hiding cached neighbors")
local leave=run(15,6,true)
leave.visible({7,8,9});leave.grid:cancel();leave.drain()
expect(not leave.grid.is_open and leave.renders()==0,"close rejects late callbacks from both page generations")
expect(leave.canceled()==9,"page switch and exit cancel every independent directory request")
local resized=run(15,6,true)
resized.grid:set_cover_concurrency(1)
expect(resized.canceled()==6,"capacity change cancels old six-lane page")
resized.drain()
expect(resized.renders()==15 and resized.grid.cover_concurrency==1,"smaller lane count restarts the visible page without closing the shelf")
resized.grid:set_cover_concurrency(6)
expect(resized.grid.cover_concurrency==6 and #resized.grid.resolution_slots==6,"capacity increase reuses a bounded pool")
print(("bookshelf_performance_spec: %d checks"):format(checks))
