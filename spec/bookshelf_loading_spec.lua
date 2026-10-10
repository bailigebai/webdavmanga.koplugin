local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local Thumbnail=require("webdavmanga.bookshelf_loader")
local Cache=require("webdavmanga.cache")
local files,records,protected,pending={},{},{},{}
local cache={entries=records,key_for=function(_,id,p,k) return id..p..tostring(k) end,
    lookup=function(_,k) return records[k] and records[k].path end,
    paths_for=function(_,k) return k..".png",k..".part" end,
    protect=function(_,k) protected[k]=(protected[k] or 0)+1 end,
    unprotect=function(_,k) protected[k]=protected[k]-1 end,
    publish=function(_,r,p) r.path=r.key..".png";records[r.key]=r;files[r.path]=files[p];return r.path end,
    remove=function(_,k) if records[k] then files[records[k].path]=nil end;records[k]=nil end,
    discard_part=function() end}
local source={identity="source",request_cover=function(_,g,img,cb) pending[#pending+1]=cb;return true end,
    cancel_cover_generation=function() end,cancel_all=function() end}
local processed=0
local thumb=Thumbnail:new{cache=cache,loader=source,identity="thumb",processor={process=function(src,part,p)
    expect(files[src],"source exists while first thumbnail is generated")
    processed=processed+1;files[part]=p.target_width*p.target_height
    return {format="png",width=p.target_width,height=p.target_height}
end}}
expect(type(thumb.set_target_size)=="function","thumbnail follows visible card dimensions")
thumb:set_target_size(120,160)
local image={name="1.jpg",path="/m/1.jpg",size=100,width=900,height=1200}
local first_key=thumb:cover_key(image)
local a,b
thumb:request_cover("a",image,{on_ready=function(p) a=p end})
thumb:request_cover("b",image,{on_ready=function(p) b=p end})
local source_key=cache:key_for("source",image.path,"cover")
records[source_key]={path="/generated/source.jpg"};files["/generated/source.jpg"]=100
pending[1].on_ready("/generated/source.jpg",false,{width=900,height=1200})
pending[2].on_ready("/generated/source.jpg",false,{width=900,height=1200})
expect(a==b and processed==1,"two cards reuse one compact PNG after source is removed")
expect(records[first_key].width==120 and records[first_key].height==160,"cache stores card-sized image")
expect(files[a]==19200,"thumbnail pixel count is ten times smaller than legacy 384x512")
thumb:set_target_size(240,320)
expect(thumb:cover_key(image)~=first_key,"different layout requests matching-resolution cache")
thumb:set_target_size(10000,10000)
expect(thumb.target_width==384 and thumb.target_height==512,"thumbnail has a hard pixel bound")
thumb:set_target_size(0,0)
expect(thumb.target_width==384 and thumb.target_height==512,"invalid dimensions preserve safe bounds")
thumb:cancel_all()
for _,count in pairs(protected) do expect(count==0,"all independent thumbnail leases released") end

-- Real unified Cache budgets. Six producers reserve actual allowances, not
-- all free capacity. A canceled/unreaped producer still keeps its allowance.
local disk={}
local c=Cache:new{root="/shelf",limit_bytes=6000,unified_quota=true,md5=function(v) return v end,
    store={readSetting=function(_,_,d) return d end,saveSetting=function() end,flush=function() return true end,
        cache_index_size=function() return 0 end,on_disk_size=function() return 0 end},
    fs={make_path=function() end,size=function(p) return disk[p] end,exists=function(p) return disk[p]~=nil end,
        list=function() local out={};for p,n in pairs(disk) do out[#out+1]={path=p,size=n} end;return out end,
        remove=function(p) disk[p]=nil;return true end}}
local parts={}
for i=1,6 do
    local _,part=c:paths_for("k"..i,"manifest","task");parts[i]=part
    expect(c:write_budget(100,800,part,800)==800,"six tasks each admit bounded work")
end
expect(c:write_budget(100,0,nil)==500,"only remaining capacity is available")
disk[parts[1]]=100;disk[parts[1]..".wdm-sort"]=100;disk[parts[1]..".zipwork"]=100
expect(c:write_budget(100,0,nil)==500,"growing files replace held allowance rather than double count")
c:discard_part("k1","manifest","task")
expect(c:write_budget(100,0,nil)==1400 and not disk[parts[1]..".wdm-sort"] and not disk[parts[1]..".zipwork"],"reap releases owned auxiliary files and budget")
print(("bookshelf_loading_spec: %d checks"):format(checks))
