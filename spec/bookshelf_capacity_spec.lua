local Shelf=require("webdavmanga.bookshelf")
local Cache=require("webdavmanga.cache")
local MB=1024*1024
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local function fixture(limit)
    local files,workers={},{}
    local cache=Cache:new{root="/shelf",limit_bytes=limit,unified_quota=true,md5=function(v) return v end,
        store={readSetting=function(_,_,d) return d end,saveSetting=function() end,flush=function() return true end,
            cache_index_size=function() return 0 end,on_disk_size=function() return 0 end},
        fs={make_path=function() end,size=function(p) return files[p] end,exists=function(p) return files[p]~=nil end,
            list=function() local r={};for p,s in pairs(files) do r[#r+1]={path=p,size=s} end;return r end,
            remove=function(p) files[p]=nil;return true end,
            rename=function(a,b) files[b]=files[a];files[a]=nil;return true end}}
    local async={run=function(work,done,options)
        local w={work=work,done=done,options=options};workers[#workers+1]=w
        return {cancel=function() w.canceled=true end}
    end}
    local budgets={}
    local client={connection={root_path="/m"},read_range=function() return "a" end,
        write_directory_manifest=function(_,p,part,o)
            budgets[p]=o.max_temp_bytes;return nil,{code="storage",detail="fixture"}
        end}
    local shelf=Shelf:new{cache=cache,settings={get_bookshelf_cache=function()
            return {total_mb=limit/MB,trigger_mb=limit/MB,retain_mb=0,interval_minutes=10} end,
            get_connection=function() return {root_path="/m",kind="webdav"} end},
        identity_provider=function() return "fixture" end,async=async,client_factory=function() return client end,
        catalog={},grid={},settings_ui={},document_cover={}}
    return shelf,cache,files,workers,budgets
end
do
    local shelf,cache,_,workers,budgets=fixture(200*MB)
    shelf.loader:set_target_size(120,160)
    local old={}
    for i=1,6 do old[i]=shelf.directory_store:load("/m/old"..i,{}) end
    for _,h in ipairs(old) do h:cancel() end
    local handles={}
    for i=1,6 do handles[i]=shelf.directory_store:load("/m/new"..i,{}) end
    expect(#workers<12,"new requests wait instead of starting workers with zero allowances")
    local canceled=shelf.directory_store:load("/m/cancel",{});canceled:cancel()
    for i=1,6 do workers[i].options.on_reaped() end
    expect(#workers==12,"all six new requests resume after old workers are reaped")
    for i=7,12 do local w=workers[i];w.done(true,w.work()) end
    for i=1,6 do expect(budgets["/m/new"..i]>=MB,"resumed manifest gets fresh capacity, including partial-positive pressure") end
    expect(not budgets["/m/cancel"] and not next(cache.space_waiters),"canceled waiting request never restarts")
end
do
    local shelf,cache,files,workers=fixture(6*MB)
    local source=shelf.source_loader
    local limits={}
    source.archive_pages=require("webdavmanga.archive_pages"):new{
        image_probe={inspect=function() return {format="jpeg",width=100,height=140} end},
        remove_file=function(p) files[p]=nil end,
        archive_stream={open=function() return {} end,
            next=function() return {index=1,name="001.jpg",mode="file",size=4*MB} end,
            extract_current=function(_,reader,part,max_bytes)
                limits[#limits+1]=max_bytes
                if 4*MB>max_bytes then return nil,"cache_limit" end
                files[part]=4*MB;return {size=4*MB}
            end,close=function() end}}
    for i=1,6 do source:request_cover("g",{name="001.jpg",path="/m/"..i..".rar#zip/1",
        archive_entry_name="001.jpg",archive_remote_path="/m/"..i..".rar",archive_kind="libarchive",
        archive_format="rar",archive_entry_ordinal=1,archive_source_size=10*MB,archive_size=2*MB},{}) end
    expect(#workers==2,"known archive images exceeding a lane's share wait for real space")
    local i=1
    while workers[i] do local w=workers[i];w.done(true,w.work());i=i+1 end
    expect(#workers==6 and #limits==6,"waiting archive jobs all retry after completed jobs release space")
    for _,maximum in ipairs(limits) do expect(maximum<4*MB,"native writer receives strict budget for stale descriptors") end
    expect(cache:pending_size()==0 and not next(cache.space_waiters),"all failed or waiting source parts are released")
end
do
    local shelf,cache,files,workers=fixture(MB)
    shelf.loader:set_target_size(120,160)
    cache.entries.visible={kind="cover",key="visible",path="/shelf/visible.png",size=80*1024,
        extension="png",format="png",width=120,height=160,validated=true}
    files["/shelf/visible.png"]=80*1024;cache:protect("visible")
    local maximum
    shelf.source_loader.client_factory=function() return {direct=false,download=function(_,p,part,progress,o)
        maximum=o.max_bytes;return nil,{code="transport",detail="fixture"}
    end} end
    shelf.source_loader:request_cover("g",{name="unknown.jpg",path="/m/unknown.jpg"},{})
    expect(#workers==1,"unknown size starts with available positive space when no producer can release more")
    local w=workers[1];w.done(true,w.work())
    expect(maximum and maximum>50*1024 and maximum<MB,"small-cache source keeps a finite usable limit beside a visible cover")
    expect(cache:pending_size()==0 and not next(cache.space_waiters),"small cache leaves no idle waiters or reservations")
end
do
    local shelf,cache=fixture(200*MB)
    shelf.loader:set_target_size(120,160)
    cache.limit_bytes=MB;shelf:reschedule()
    expect(shelf.directory_store.temporary_limit_provider()>500*1024,
        "lowering capacity uses the current lane count without needing a restart")
    expect(shelf.source_loader.cover_concurrency==1,"source slots adapt immediately to a small cache")
    cache.limit_bytes=200*MB;shelf:reschedule()
    expect(shelf.source_loader.cover_concurrency==6,"raising capacity restores parallel source slots")
end
do
    local Mupdf=require("webdavmanga.mupdf_pages")
    local writes,closed=0,0
    local engine={openRemoteDocument=function() return {getPages=function() return 1 end,
        openPage=function() return {getSize=function() return 1000,1000 end,
            draw_new=function() return {writePNG=function() writes=writes+1;return true end,free=function() end} end,
            close=function() closed=closed+1 end} end,close=function() closed=closed+1 end} end}
    local p=Mupdf:new{mupdf=engine,draw_context={},image_probe={inspect=function() return {width=1000,height=1000,format="png"} end},
        temp_name=function() error("probe must not allocate a temporary image") end}
    local descriptor={name="a.pdf",format="pdf",size=100,read_at=function() return "a" end}
    local book=p:inspect_remote(descriptor,"/m/a.pdf",{page=1,probe_only=true})
    expect(book and book.index:get(1).mupdf_page==1 and writes==0,"cover inspection reads page information without rendering a large PNG")
    local result,err=p:render_remote({name="1.png",format="pdf",size=100,mupdf_page=1},descriptor.read_at,"/part",100)
    expect(not result and err=="cache_limit" and writes==0,"MuPDF rendering rejects over-budget output before writing")
    expect(closed==4,"native page/document handles close in probe and budget rejection paths")
end
do
    local _,cache,files,workers=fixture(MB)
    local descriptor
    local service=require("webdavmanga.document_cover"):new{cache=cache,metadata_limit_provider=function() return 128*1024 end,
        client_factory=function() return {} end,async={run=function(work,done,options)
            local w={work=work,done=done,options=options};workers[#workers+1]=w
            return {cancel=function() w.canceled=true end}
        end},archive_pages={inspect_remote=function(_,d)
            descriptor=d;files[d.metadata_work_path]=1000;return nil,"fixture"
        end}}
    local h=service:resolve({root_path="/m"},{name="a.epub",path="/m/a.epub",size=10000},{})
    local w=workers[1];local r=w.work()
    expect(descriptor.metadata_max_bytes==128*1024 and descriptor.metadata_work_path:find(".part.wdm-epub",1,true),
        "EPUB parser receives a bounded parent-owned metadata path")
    h:cancel();w.done(false,r,"canceled",{reap_pending=true})
    expect(cache:pending_size()==1000,"canceled child retains metadata ownership until reap")
    w.options.on_reaped()
    expect(cache:pending_size()==0 and not files[descriptor.metadata_work_path],"reaping removes EPUB work and releases its reservation")
end
do
    local function le(n,count) local s="";for _=1,count do s=s..string.char(n%256);n=math.floor(n/256) end;return s end
    local name="META-INF/container.xml"
    local compressed,raw=864862,MB
    local header="PK\003\004"..le(20,2)..le(0,2)..le(8,2)..le(0,8)..le(compressed,4)..le(raw,4)
        ..le(#name,2)..le(0,2)..name
    local image={archive_entry_name=name,archive_source_size=2*MB,archive_local_offset=0,
        archive_method=8,archive_flags=0,archive_crc32=0,archive_compressed_size=compressed,archive_size=raw}
    local archive=require("webdavmanga.archive_pages"):new{open_file=function() error("must reject before creating work") end}
    local value,err=archive:_read_metadata(image,{metadata_work_path="/part.wdm-epub",metadata_max_bytes=500*1024,
        read_at=function(offset,count) return header:sub(offset+1,offset+count) end})
    expect(not value and err=="cache_limit","large compressed EPUB metadata cannot bypass the shelf disk allowance")
end
do
    -- Keep the complete descriptor-copy path under test: neither end is stubbed.
    local function le(n,count) local s="";for _=1,count do s=s..string.char(n%256);n=math.floor(n/256) end;return s end
    local name="META-INF/container.xml"
    local body=string.rep("x",128)
    local header="PK\003\004"..le(20,2)..le(0,2)..le(8,2)..le(0,8)..le(#body,4)..le(MB,4)
        ..le(#name,2)..le(0,2)..name
    local central="PK\001\002"..le(20,2)..le(20,2)..le(0,2)..le(8,2)..le(0,8)
        ..le(#body,4)..le(MB,4)..le(#name,2)..le(0,12)..le(0,4)..name
    local offset=#header+#body
    local zip=header..body..central.."PK\005\006"..le(0,4)..le(1,2)..le(1,2)
        ..le(#central,4)..le(offset,4)..le(0,2)
    local _,cache,_,workers=fixture(MB)
    local opened=0
    local archive=require("webdavmanga.archive_pages"):new{open_file=function()
        opened=opened+1;return nil,"must reject before disk work"
    end}
    local service=require("webdavmanga.document_cover"):new{cache=cache,archive_pages=archive,
        metadata_limit_provider=function() return 65536 end,
        client_factory=function() return {read_range=function(_,_,a,b)
            return zip:sub(a+1,b+1),{["content-range"]=("bytes %d-%d/%d"):format(a,b,#zip)}
        end} end,async={run=function(work,done,options)
            workers[1]={work=work,done=done,options=options};return {cancel=function() end}
        end}}
    service:resolve({root_path="/m"},{name="a.epub",path="/m/a.epub",size=#zip},{})
    local w=workers[1];local result=w.work();w.done(true,result)
    expect(result.error=="cache_limit" and opened==0,
        "real DocumentCover to ArchivePages preserves metadata budget through descriptor copies")
    expect(cache:pending_size()==0 and not next(cache.space_waiters),"metadata rejection frees the owned reservation")
end
print(("bookshelf_capacity_spec: %d checks"):format(checks))
