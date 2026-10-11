local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local files,names,scans,unrelated_stats={},{},0,0
local function add(path,size)
    files[path]={mode="file",size=size,modification=1}
    names[#names+1]=path:match("([^/]+)$")
end
for i=1,3000 do add("/shelf/cached"..i..".png",1000) end
package.loaded["libs/libkoreader-lfs"]={
    attributes=function(path,attribute)
        if not attribute and path:find("/cached",1,true) then unrelated_stats=unrelated_stats+1 end
        local record=files[path]
        if not record then return nil,"missing file" end
        return attribute and record[attribute] or record
    end,
    dir=function()
        scans=scans+1
        local i=0
        return function() i=i+1;return names[i] end
    end}
package.loaded.util={makePath=function() return true end}
local Cache=require("webdavmanga.cache")
local cache=Cache:new{root="/shelf",limit_bytes=100000,unified_quota=true,
    store={readSetting=function(_,key,default) return key=="schema_version" and 3 or default end,
        saveSetting=function() end,flush=function() return true end},
    md5=function() return string.rep("a",32) end}
local parts={}
for i=1,6 do
    local _,part=cache:paths_for(string.rep(tostring(i),32),"manifest","writer")
    parts[i]=part
    add(part,100);add(part..".zipwork",40)
    add(part..".wdm-lock",20);add(part..".wdm-random-spool",30)
end
local total=cache:pending_size()
print(("SHELF budget scans=%d unrelated_stats=%d pending=%d"):format(scans,unrelated_stats,total))
expect(total==1140,"all main/ZIP/nonce auxiliary bytes remain exact")
expect(scans==1,"six writers share one auxiliary scan per pending calculation")
expect(unrelated_stats==0,"budget never stats the 3000 unrelated cached thumbnails")
scans,unrelated_stats=0,0
local allowance=cache:write_budget(100,0,parts[1],500)
expect(allowance==500,"bounded allowance remains available")
expect(unrelated_stats==0,"admission does not stat unrelated cache files")
local other="/shelf/foreign.part.wdm-random-spool"
add(other,77)
local removed={}
cache.fs.remove=function(path) removed[path]=true;files[path]=nil;return true end
cache:discard_part(string.rep("1",32),"manifest","writer")
expect(removed[parts[1]] and removed[parts[1]..".zipwork"] and removed[parts[1]..".wdm-lock"],
    "cancel removes all owned writer files")
expect(not removed[other] and files[other],"cancel cannot remove a foreign writer's auxiliary")
expect(unrelated_stats==0,"cancel does not stat cached thumbnails")
expect(cache:pending_size()==950,"canceled writer no longer occupies quota")
print(("bookshelf_responsive_cache_spec: %d checks"):format(checks))
