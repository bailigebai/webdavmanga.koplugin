local checks=0; local function expect(v,m) checks=checks+1;assert(v,m) end
local loaded, Loader = pcall(require,"webdavmanga.bookshelf_loader")
expect(loaded, "bookshelf must generate and cache bounded thumbnails")
local records,files,protected,removed={}, {}, {}, {}
local cache={root="/shelf",entries=records,fs={size=function(p) return files[p] end},
    key_for=function(_,identity,path) return identity.."/"..path end,
    lookup=function(_,key) return records[key] and records[key].path end,
    paths_for=function(_,key) return key..".png",key..".part" end,
    protect=function(_,key) protected[key]=true end,
    unprotect=function(_,key) protected[key]=nil end,
    remove=function(_,key) local r=records[key]; if r then removed[r.path]=true; files[r.path]=nil end; records[key]=nil end,
    discard_part=function(_,key) files[key..".part"]=nil end,
    publish=function(_,record,part) records[record.key]=record;record.path=record.key..".png";
        files[record.path]=files[part];files[part]=nil;return record.path end,
}
local pending,rendered={},0
local source={identity="source",request_cover=function(_,g,image,cb) pending[g]=cb;return true end,
    cancel_cover_generation=function(_,g) pending[g].canceled=true end,cancel_all=function() end}
local processor={process=function(sourcepath,part,profile)
    rendered=rendered+1
    expect(profile.target_width==384 and profile.target_height==512
        and not profile.lut and not profile.crop,"thumbnail fits whole image without enhancement")
    files[part]=50;return {format="png",width=200,height=300,validated=true}
end}
local service=Loader:new{cache=cache,loader=source,identity="thumb",processor=processor,image_probe={inspect=function() return {width=300,height=400} end}}
local image={path="/m/001.jpg",name="001.jpg",etag="v1"}
local src_key=cache:key_for(source.identity,image.path,"cover")
records[src_key]={path="/shelf/original.jpg"};files["/shelf/original.jpg"]=500
local ready
service:request_cover(1,image,{on_ready=function(p) ready=p end})
pending[1].on_ready("/shelf/original.jpg")
expect(ready and files[ready]==50 and removed["/shelf/original.jpg"],"persist small PNG, discard owned original")
expect(protected[service:cover_key(image)],"visible thumbnail remains protected")
service:request_cover(2,image,{on_ready=function(p) ready=p end})
expect(rendered==1,"cached thumbnail bypasses download and decode")
service:cancel_cover_generation(1);service:cancel_cover_generation(2)
expect(not protected[service:cover_key(image)],"shared visible cover releases only when all leases end")
expect(service:cover_key{path=image.path,etag="v2"}~=service:cover_key(image),"source changes invalidate thumbnail key")
local localimage={path="/local/001.jpg",name="001.jpg"}
files[localimage.path]=800
service:request_cover(3,localimage,{})
pending[3].on_ready(localimage.path)
expect(files[localimage.path]==800 and not removed[localimage.path],"local original never removed")
local late={path="/m/late.jpg",name="late.jpg"}
service:request_cover(4,late,{on_ready=function() error("late view callback") end})
service:cancel_cover_generation(4)
records[cache:key_for(source.identity,late.path,"cover")]={path="/shelf/late.jpg"};files["/shelf/late.jpg"]=300
pending[4].on_ready("/shelf/late.jpg")
expect(not files["/shelf/late.jpg"] and rendered==2,"canceled late source freed without decoding")
service.processor={process=function() return nil,"write_failed" end}
local error_seen
service:request_cover(5,late,{on_error=function() error_seen=true end})
records[cache:key_for(source.identity,late.path,"cover")]={path="/shelf/fail.jpg"};files["/shelf/fail.jpg"]=300
pending[5].on_ready("/shelf/fail.jpg")
expect(error_seen and not files["/shelf/fail.jpg"],"failed PNG frees original and reports placeholder")
service:cancel_all()
expect(next(protected)==nil,"teardown releases every thumbnail lease")
-- Real processing dimensions must fit every ratio before native scaling.
service.processor={process=function(_,part,profile)
 files[part]=50;return {format="png",width=profile.target_width,height=profile.target_height,validated=true} end}
local cases={{1000,1000,384,384},{2000,1000,384,192},{1000,4000,128,512}}
for i,c in ipairs(cases) do
 local item={path="/local/ratio"..i..".jpg",name="ratio.jpg"}
 service:request_cover(10+i,item,{})
 pending[10+i].on_ready(item.path,false,{width=c[1],height=c[2]})
 local result=records[service:cover_key(item)]
 expect(result.width==c[3] and result.height==c[4],"square, landscape and tall covers keep their aspect ratios")
end


print(("bookshelf_thumbnail_spec: %d checks"):format(checks))
