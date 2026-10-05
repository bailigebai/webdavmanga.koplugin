local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local Processor = require("webdavmanga.page_processor")
local checks, failures = 0, {}
local function expect(value, message)
    checks = checks + 1
    if not value then failures[#failures + 1] = message end
end
local images = {{path="/001.jpg",width=600,height=800},
    {path="/002.jpg",width=600,height=800},{path="/003.jpg",width=600,height=800}}
local values = {gray_enhance_enabled=true,gray_enhance_preset="clear",
    tone_adjust_enabled=true,tone_adjust_preset="original",auto_crop_enabled=true,
    image_prefetch_enabled=true,prefetch_count=2,fit_mode="page",show_preprocess_success=true}
local notices, prepared_calls, raw_calls, old_ready = {}, 0, 0
local function buffer()
    return {getWidth=function() return 600 end,getHeight=function() return 800 end,
        viewport=function(self) return self end,free=function() end}
end
local function raw_request(_,_,image,callbacks)
    raw_calls=raw_calls+1
    callbacks.on_ready(image.path,false,{width=600,height=800})
end
local reader = Reader:new{
    loader={identity="notice",request=raw_request,prefetch=function() end},
    prepared_pages={request=function(_,_,image,profile,callbacks)
        if not profile then return raw_request(nil,nil,image,callbacks) end
        prepared_calls=prepared_calls+1
        callbacks.on_ready("/prepared"..image.path,false,
            {width=600,height=800,prepared=true,crop_checked=true})
    end,prefetch=function(_,_,_,_,_,_,ready) old_ready=ready end,
        cache_key=function(_,image) return "prepared"..image.path end,cancel_processing=function() end},
    progress={chapter_id=function() return "fixture" end,
        resolve=function() return {index=1,segment="whole"} end,save=function() end},
    state=State:new(),settings={get_reader=function() return values end,
        get_connection=function() return {} end,set_reader=function(_,next_values) values=next_values;return true end},
    cache={key_for=function(_,identity,path) return identity..path end,set_protected=function() end},
    ui={create_shell=function() return {get_content_size=function() return 600,800 end,
        show_loading=function() end,show_page=function() return true end,
        show_status=function(_,text) notices[#notices+1]=text end,
        free_buffer_later=function(_,b) b:free() end} end,show_shell=function() end},
    render_image={renderImageFile=function() return buffer() end},open_chapter=function() end,
}
reader:open{manga={},chapter={},chapter_index={count=function() return 3 end,
    get=function(_,number) return images[number] end,window=function() return images end}}
local captured_ready=old_ready
expect(type(captured_ready)=="function","enhanced prefetch exposes a completion boundary")
reader:set_gray_enhance_enabled(false)
reader:set_tone_adjust_enabled(false)
captured_ready(images[2],"/prepared/002.jpg",false,{prepared=true})
expect(#notices==0,"disabled enhancement must suppress old completions even with auto-crop enabled")
reader:set_auto_crop_enabled(false)
local before_prepared,before_raw=prepared_calls,raw_calls
reader:next_page()
expect(prepared_calls==before_prepared and raw_calls==before_raw+1,
    "all processing disabled must load the original page instead of a prepared derivative")
captured_ready(images[3],"/prepared/003.jpg",false,{prepared=true})
expect(#notices==0,"late prepared callbacks must remain silent after every processing switch is off")
reader.reader_settings.gray_enhance_enabled=true
notices={}
reader:_arm_preprocess_notice(1)
reader:_note_preprocess_success(images[2],{prepared=true})
expect(#notices==1,"successful enabled enhancement keeps the user-selected success notice")
reader.reader_settings.show_preprocess_success=false
reader:_note_preprocess_success(images[3],{prepared=true})
expect(#notices==1,"turning off the notice also suppresses a previously armed path")
reader.reader_settings.show_preprocess_success=true
local before_failed=#notices
reader:_note_preprocess_success(images[3],{prepared=true,processing_error="failed"})
expect(#notices==before_failed,"failed processing never reports success")
local processor=reader:_memory_processor(images[2])
reader.reader_settings.gray_enhance_enabled=false
local original=buffer()
local displayed,metadata=processor(original,{width=600,height=800},images[2])
expect(displayed==original and metadata.memory_processed~=true,
    "a queued memory processor disabled before execution must preserve and identify the original buffer")
expect(Processor.profile(reader.reader_settings,images[2],600,800)==nil,
    "all switches off produces no LUT or crop processing profile")
if #failures>0 then error(table.concat(failures,"\n")) end
print("rebuild_0414_preprocess_notice_spec: "..checks.." checks")
