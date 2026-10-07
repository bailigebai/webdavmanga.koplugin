local Cache=require("webdavmanga.cache")
local Loader=require("webdavmanga.bookshelf_loader")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local saved={schema_version=3,entries={}}
local files={};local MB=1024*1024
local cache=Cache:new{root="/shelf",limit_bytes=4*MB,unified_quota=true,
    store={readSetting=function(_,k,d) return saved[k] or d end,saveSetting=function(_,k,v) saved[k]=v end,
        flush=function() return true end,cache_index_size=function() return 100 end},
    fs={make_path=function() end,size=function(p) return files[p] end,exists=function(p) return files[p]~=nil end,
        remove=function(p) files[p]=nil;return true end,list=function() return {} end},
    md5=function(v) return v end}
cache.entries={visible={kind="cover",path="/shelf/visible.png",size=MB,atime=1},
    old={kind="cover",path="/shelf/old.png",size=MB,atime=0}}
files["/shelf/visible.png"]=MB;files["/shelf/old.png"]=MB
cache:protect("visible")
cache.owned_parts["/shelf/pending.part"]=true;files["/shelf/pending.part"]=1000
expect(cache:total_size()==2*MB+1100,"in-progress files count in shelf capacity")
local requested,err=0,nil
local source={identity="source",request_cover=function() requested=requested+1;return true end}
local loader=Loader:new{cache=cache,loader=source,identity="thumb"}
loader:request_cover(1,{path="/m/huge.jpg",size=3*MB},{on_error=function(e) err=e end})
expect(requested==0 and err,"known source that cannot fit beside active files is rejected before download")
loader:request_cover(2,{path="/m/small.jpg",size=MB},{})
expect(requested==1 and not files["/shelf/old.png"] and files["/shelf/visible.png"],"source reservation evicts idle covers, keeps active files")
expect(cache.cover_limit_bytes <= 3*MB-Loader.MAX_PNG_BYTES-1000,"download size limit reserves PNG, index and pending bytes")
-- Local source originals are read directly, regardless of their file size.
source._uses_direct_local=function() return true end
local before=requested
loader:request_cover(3,{path="/m/local.jpg",size=20*MB},{})
expect(requested==before+1,"large local original consumes only generated thumbnail space")
-- Real source Loader must deliver a finite budget to the actual client.
local SourceLoader=require("webdavmanga.loader")
local worker;local captured
local source_cache={unified_quota=true,cover_limit_bytes=MB,limit_bytes=4*MB,
 lookup=function() end,key_for=function() return "source" end,
 paths_for=function() return "/shelf/source.jpg","/shelf/source.part" end,
 discard_part=function() end}
local real_source=SourceLoader:new{identity="source",cache=source_cache,
 download_limit_provider=function() return 12345 end,
 client_factory=function() return {direct=false,download=function(_,p,part,progress,options)
 captured=options;return nil,{code="transport"} end} end,
 async={run=function(work) worker=work;return {cancel=function() end} end}}
real_source:request_cover(1,{path="/m/unknown.jpg",name="unknown.jpg"},{})
worker();expect(captured and captured.max_bytes==12345,"source budget reaches client even when size is unknown")


local tiny_files={}
local tiny_cache=Cache:new{root="/tiny",limit_bytes=MB,unified_quota=true,md5=function() return string.rep("a",32) end,
 store={readSetting=function(_,k,d) return d end,saveSetting=function() end,flush=function() return true end,
 cache_index_size=function() return 100 end},
 fs={make_path=function() end,size=function(p) return tiny_files[p] end,exists=function() return false end,
 list=function() return {} end,remove=function() return true end}}
local tiny_requests=0
Loader:new{cache=tiny_cache,identity="thumb",loader={identity="source",
 _uses_direct_local=function() return true end,request_cover=function() tiny_requests=tiny_requests+1;return true end}}
 :request_cover(1,{path="/local/large.jpg",size=20*MB},{})
expect(tiny_requests==1,"minimum 1 MB policy can admit a bounded local thumbnail")

print(("bookshelf_budget_spec: %d checks"):format(checks))
