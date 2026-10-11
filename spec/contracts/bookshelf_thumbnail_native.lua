-- Actual ARM KOReader decoder, scaling, PageProcessor and PNG encoding.
-- Cache registry/client are IO boundaries; this is not a Kindle speed test.
local ffi=require("ffi")
assert(ffi.arch=="arm" and ffi.abi("32bit"))
local libraries=assert(loadfile("/output/libraries.lua"))()
ffi.loadlib=function(name) return ffi.load(assert(libraries[name],name)) end
local ffiutil=require("ffi/util")
package.preload.logger=function() return {dbg=function() end,warn=function() end,info=function() end} end
package.preload.dbg=function() return {guard=function() end} end
package.preload.device=function() return {hasColorScreen=function() return false end} end
G_reader_settings={isTrue=function() return false end,isFalse=function() return false end,readSetting=function(_,_,d) return d end}
local Renderer=require("ui/renderimage")
local decoded,buffer=pcall(Renderer.renderImageFile,Renderer,"/output/source.jpg",false,120,160)
assert(decoded,tostring(buffer));assert(buffer,"native decode failed");buffer:free()
local Thumbnail=require("webdavmanga.bookshelf_loader")
local json=require("json")
local input=assert(loadfile("/output/input.lua"))()
local records,ids,sequence={},{},0
local function bytes(path) local f=assert(io.open(path,"rb"));local n=f:seek("end");f:close();return n end
local cache={entries=records,
    key_for=function(_,identity,path,kind)
        local id=identity..path..tostring(kind)
        if not ids[id] then sequence=sequence+1;ids[id]="k"..sequence end
        return ids[id]
    end,
    lookup=function(_,key) return records[key] and records[key].path end,
    paths_for=function(_,key) return "/output/"..key..".png","/output/"..key..".part" end,
    protect=function() end,unprotect=function() end,
    publish=function(_,record,part)
        local path="/output/"..record.key..".png";assert(os.rename(part,path))
        record.path=path;record.size=bytes(path);records[record.key]=record;return path
    end,
    remove=function(_,key) assert(not records[key],"must not delete original") end,
    discard_part=function(_,key) os.remove("/output/"..key..".part") end}
local source_requests=0
local source={identity="source",request_cover=function(_,_,image,cb)
    source_requests=source_requests+1
    cb.on_ready("/output/source.jpg",false,{width=input.width,height=input.height})
    return true
end}
local tasks={}
local scheduler={scheduleIn=function(_,delay,callback)
    tasks[#tasks+1]={at=ffiutil.getTimestamp()+(delay or 0),callback=callback}
end}
local Async=require("webdavmanga.async")
local async={run=function(work,done,options)
    options.scheduler=scheduler;options.ffiutil=ffiutil
    return Async.run(work,done,options)
end}
local thumb=Thumbnail:new{cache=cache,loader=source,identity="thumbnail",renderer=Renderer,async=async}
local image={name="source.jpg",path="/comic/001.jpg",size=bytes("/output/source.jpg")}
local original_size=image.size
local cases={}
for _,target in ipairs({{120,160},{240,320},{384,512}}) do
    thumb:set_target_size(unpack(target))
    local result
    thumb:request_cover("g",image,{on_ready=function(path) result=path end,
        on_error=function(err) error(tostring(err.detail)) end})
    assert(not result and #tasks>0,"PNG must be generated in a child, not the source callback")
    local deadline=ffiutil.getTimestamp()+120
    while not result and #tasks>0 and ffiutil.getTimestamp()<deadline do
        table.sort(tasks,function(a,b) return a.at<b.at end)
        local task=table.remove(tasks,1)
        local delay=task.at-ffiutil.getTimestamp()
        if delay>0 then ffiutil.usleep(math.floor(delay*1000000)) end
        task.callback()
    end
    assert(result,"thumbnail must render")
    local record=records[thumb:cover_key(image)]
    assert(record.width<=target[1] and record.height<=target[2])
    local previous=source_requests
    thumb:request_cover("g",image,{on_ready=function(path,cached) assert(path==result and cached) end})
    assert(source_requests==previous,"warm thumbnail performs no source request")
    cases[#cases+1]={target=target,width=record.width,height=record.height,bytes=bytes(result),
        file=result:match("([^/]+)$"),warm_source_requests=0}
end
assert(bytes("/output/source.jpg")==original_size)
local f=assert(io.open("/output/thumbnail-native-result.json","wb"))
f:write(json.encode({arch=ffi.arch,background_subprocess=true,source_bytes=original_size,source_requests=source_requests,
    cases=cases,original_unchanged=true}));f:close()
print("PASS actual KOReader ARM subprocess JPEG decode, bounded thumbnail PNGs and warm cache")
