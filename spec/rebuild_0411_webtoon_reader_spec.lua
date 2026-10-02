local pixels = dofile(TEST_PLUGIN_ROOT .. "/../spec/fixtures/webtoon_buffer.lua")
package.loaded["ffi/blitbuffer"] = pixels.bb
local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local Settings = require("webdavmanga.settings")
local Progress = require("webdavmanga.progress")
local stored, shown, checkpoints, statuses, jobs = {}, {}, {}, {}, {}
local store={readSetting=function(_,key,default) return stored[key] or default end,
    saveSetting=function(_,key,value) stored[key]=value end,flush=function() end}
local settings=Settings:new{store=store}
local values=settings:get_reader(); values.fit_mode="webtoon"; values.prefetch_near_count=0
values.prefetch_far_count=0; values.webtoon_fit_percent=0; values.webtoon_smart_enabled=false
assert(settings:set_reader(values),"reader integration needs the strip display mode")
local images={{name="1.png",path="/m/1.png",width=100,height=60},
    {name="2.png",path="/m/2.png",width=200,height=400},
    {name="3.png",path="/m/3.png",width=100,height=200}}
local index={count=function() return #images end,get=function(_,i) return images[i] end,
    find=function(_,path) for i,image in ipairs(images) do if image.path==path then return i end end end}
local progress=Progress:new{store=store,md5=function(value) return value end,clock=function() return 123 end}
local original_save=progress.save
function progress:save(...) checkpoints[#checkpoints+1]={...}; return original_save(self,...) end
local shell={get_content_size=function() return 100,100 end,
    show=function() return true end,show_loading=function() return true end,
    show_status=function(_,text) statuses[#statuses+1]=text end,
    show_error=function(_,model) error("unexpected page error: "..tostring(model.message)) end,
    show_page=function(_,buffer,viewport,_,change)
        assert(buffer.frees==0); shown[#shown+1]={buffer=buffer,viewport=viewport,change=change}; return true
    end,close_now=function() shown={} end,
    free_buffer_later=function(_,buffer) assert(not shown[#shown] or shown[#shown].buffer~=buffer); buffer:free(); return true end}
local loader={identity="fixture",request=function(_,_,image,callbacks)
    jobs[#jobs+1]={image=image,callbacks=callbacks}; return {}
end,prefetch=function() end,cancel_generation=function() end}
local reader=Reader:new{loader=loader,progress=progress,state=State:new(),settings=settings,
    cache={key_for=function(_,_,path) return path end,set_protected=function() end},
    open_chapter=function() end,
    render_image={renderImageFile=function(_,path,_,w,h)
        local tone=path==images[1].path and 30 or 80
        return pixels.new(w,h,function() return tone end)
    end},
    ui={create_shell=function() return shell end,show_shell=function() return true end,
        close_shell=function() shell:close_now(); return true end,schedule=function(_,callback) callback() end}}
local context={connection={kind="local",local_path="/"},manga={name="M",path="/m"},
    chapter={name="C",path="/m/c"},chapter_index=index}
local function complete(position)
    local job=jobs[position]; assert(job,"expected a queued loader job")
    job.callbacks.on_ready(job.image.path,false,{width=job.image.width,height=job.image.height})
end
assert(reader:open(context))
assert(#jobs==1 and #shown==0,"Reader starts only the first required strip image")
complete(1)
assert(#jobs==2 and #shown==0,"a partial screen waits for its required neighbor")
complete(2)
assert(#shown==1 and shown[1].viewport:getPixel(50,59)==30 and shown[1].viewport:getPixel(50,60)==80,
    "real Reader loading and decoding must publish joined pixels")
assert(reader.position.index==1 and #checkpoints==1,"neighbor loads cannot checkpoint unread images")
reader:next_page()
assert(reader.position.index==2 and #shown==2,"forward uses the strip anchor rather than one image per page")
local record=progress.records[reader.chapter_id]
assert(record.vertical_fraction and record.vertical_fraction>0,"successful strip scrolling saves an image-local fraction")
reader:previous_page()
assert(reader.position.index==1,"previous returns to the exact prior screen")
reader:next_page()
local saved_fraction=progress.records[reader.chapter_id].vertical_fraction
reader:force_close("fixture")
assert(reader:open(context)); complete(3)
assert(reader.position.index==2 and math.abs(reader.webtoon_session.point.fraction-saved_fraction)<0.011,
    "reopening restores the normalized strip anchor")
assert(reader:set_fit_mode("page"))
assert(not reader.webtoon_session,"changing mode closes the strip source owner")
complete(4)
assert(reader.fit_mode=="page" and reader.position.index==2,"regular page mode uses the same loader after switching")
reader:request_page(3)
local old_job=#jobs
reader.quadrant_zoom={x=0,y=0,w=50,h=50}
local panel_closed=0
reader.panel_session={close=function() panel_closed=panel_closed+1 end}
assert(reader:set_fit_mode("webtoon"))
assert(not reader.quadrant_zoom and not reader.panel_session and panel_closed==1,
    "strip display must exit quadrant and panel sessions")
local strip_job=#jobs
complete(strip_job)
assert(reader.webtoon_session and reader.position.index==2)
complete(old_job)
assert(reader.position.index==reader.webtoon_session.point.index,
    "a stale ordinary request cannot overwrite a strip frame")
reader:next_page()
local resumed=progress.records[reader.chapter_id].vertical_fraction
reader:force_close("fixture")
local opds_context={}
for k,v in pairs(context) do opds_context[k]=v end
opds_context.initial_page=2; opds_context.resume_local=true
assert(reader:open(opds_context)); complete(#jobs)
assert(math.abs(reader.webtoon_fraction-resumed)<0.011,
    "an explicit OPDS local continue keeps the saved within-image position: "..tostring(reader.webtoon_fraction).." / "..tostring(resumed))
reader:force_close("fixture")
local start_context={}
for k,v in pairs(context) do start_context[k]=v end
start_context.initial_page=1
assert(reader:open(start_context))
local initial_strip=#jobs
assert(reader:set_fit_mode("page"))
assert(#jobs==initial_strip+1,"switching a pending initial strip starts the regular page request")
complete(initial_strip); complete(#jobs)
assert(reader.position.index==1 and not reader.webtoon_session)
reader.quadrant_zoom={x=0,y=0,w=50,h=50}
reader.panel_session={close=function() panel_closed=panel_closed+1 end}
local reloaded=settings:get_reader(); reloaded.fit_mode="webtoon"
assert(reader:reload_settings(reloaded))
assert(not reader.quadrant_zoom and not reader.panel_session and panel_closed==2,
    "global settings reload must enforce the same strip mode exclusion")
complete(#jobs); complete(#jobs)
reader:force_close("fixture")
assert(reader:set_fit_mode("page"))
assert(reader:open(start_context))
local initial_ordinary=#jobs
assert(reader:set_fit_mode("webtoon"))
assert(#jobs==initial_ordinary+1,"switching a pending ordinary first page starts the strip request")
complete(initial_ordinary); complete(#jobs); complete(#jobs)
assert(reader.webtoon_session.point and reader.position.index==1)
reader:force_close("fixture")
for _,allocation in ipairs(pixels.allocated) do assert(allocation.frees==1,"every owned source/frame must be released") end
print("rebuild_0411_webtoon_reader_spec: integration, resume, mode switch and ownership passed")
