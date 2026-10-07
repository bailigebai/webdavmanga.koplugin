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
expect(cache.cover_limit_bytes < 2*MB,"download size limit reserves PNG, index and pending bytes")
print(("bookshelf_budget_spec: %d checks"):format(checks))
