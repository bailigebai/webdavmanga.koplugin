local cases = {}
local function fs_fixture()
    local files, encoded, mode, locks = {}, {}, {}, {}
    local json = { encode = function(value)
        local parts, copy = {}, {}
        for k,v in pairs(value) do parts[#parts+1] = k.."="..tostring(v); copy[k]=v end
        table.sort(parts); local bytes=table.concat(parts,"\n"); encoded[bytes]=copy; return bytes
    end, decode = function(bytes) return encoded[bytes] end }
    local fs = { make_path=function() return true end, exists=function(p) return files[p]~=nil end,
        mkdir=function(p) if locks[p] then return nil end; locks[p]=true;return true end,
        rmdir=function(p) locks[p]=nil;return true end,
        remove=function(p) files[p]=nil; return true end,
        rename=function(a,b) files[b]=mode.corrupt or files[a]; files[a]=nil; return true end,
        open=function(path,access)
            if access=="rb" then
                if not files[path] then return nil end
                return { read=function() return files[path] end, close=function() return true end }
            end
            return { write=function(_,bytes) files[path]=bytes; return true end,
                flush=function() return true end,
                close=function()
                    if mode.close_fail=="nil" then return nil,"disk full" end
                    if mode.close_fail=="false" then return false,"disk full" end
                    return true
                end }
        end }
    return fs,json,files,mode
end

cases.cover_close = function()
    local Cover=require("webdavmanga.opds_cover")
    for _,failure in ipairs({"nil","false"}) do
        local fs,_,files,mode=fs_fixture(); mode.close_fail=failure
        local cover=Cover:new{cache={},fs=fs,
            image_probe={inspect_bytes=function() return {} end},
            renderer={renderImageData=function() return {free=function() end} end}}
        local path=cover:store({}, {pointer_path="/p/S/a.meguru"}, "jpeg", {decoded=true})
        assert(path==nil and files["/p/S/.cover.jpg"]==nil and files["/p/S/.cover.jpg.tmp"]==nil,
            "nil/false close must never publish a canonical cover")
    end
end

cases.cover_verify = function()
    local Cover=require("webdavmanga.opds_cover")
    local fs,_,files,mode=fs_fixture(); mode.corrupt="broken"
    local decode_count=0
    local cover=Cover:new{cache={},fs=fs,
        image_probe={inspect_bytes=function(bytes) if bytes~="broken" then return {} end end},
        renderer={renderImageData=function(_,bytes)
            if bytes=="decoder-broken" then return nil end
            decode_count=decode_count+1; return {free=function() end}
        end}}
    assert(cover:store({}, {pointer_path="/p/S/a.meguru"}, "jpeg", {decoded=true})==nil,
        "write-after-rename corruption must fail validation")
    assert(files["/p/S/.cover.jpg"]==nil and not cover.validated_sidecars["/p/S/.cover.jpg"])
    mode.corrupt="decoder-broken"
    assert(cover:store({}, {pointer_path="/p/S/a.meguru"}, "jpeg", {decoded=true})==nil,
        "valid signature but broken published image must not be cached as validated")
    assert(files["/p/S/.cover.jpg"]==nil and not cover.validated_sidecars["/p/S/.cover.jpg"])
    mode.corrupt=nil
    assert(cover:store({}, {pointer_path="/p/S/a.meguru"}, "jpeg", {decoded=true})=="/p/S/.cover.jpg")
    assert(decode_count==1, "a successful store must decode the actual published file")
end

cases.prepared_crop = function()
    local Reader=require("webdavmanga.ui_reader")
    local inspected=0
    local buffer={getWidth=function() return 100 end,getHeight=function() return 160 end,
        getPixel=function(_,x,y) inspected=inspected+1
            return x>=12 and x<88 and y>=16 and y<144 and 24 or 250 end}
    local reader=setmetatable({reader_settings={auto_crop_enabled=true,auto_crop_max_percent=20},
        _silent=function(_,_,callback) return callback() end},Reader)
    local crop=reader:_detect_crop(buffer,{prepared=true})
    assert(crop and crop.x>=10 and crop.y>=14,
        "disk gray/tone prepared page must still detect its white margins")
    local before=inspected
    assert(reader:_detect_crop(buffer,{memory_processed=true,crop=crop})==crop)
    assert(inspected==before, "already memory-processed crop must not be rescanned")
    assert(reader:_detect_crop(buffer,{memory_processed=true})~=nil,
        "gray-only memory processing is not evidence that crop detection ran")
    local black={getWidth=buffer.getWidth,getHeight=buffer.getHeight,
        getPixel=function() inspected=inspected+1;return 24 end}
    local _,metadata=require("webdavmanga.page_processor").process_buffer(black,{crop={max_percent=20}})
    before=inspected
    assert(reader:_detect_crop(black,metadata)==nil and inspected==before,
        "an explicit no-crop result must be reusable without a second scan")
    local callback
    buffer.viewport=function(self) return self end
    local live=Reader:new{loader={identity="disk"},state=require("webdavmanga.state"):new{},
        prepared_pages={request=function(_,_,_,_,callbacks) callback=callbacks;return {} end},
        progress={chapter_id=function() return "chapter" end,resolve=function() return 1 end,save=function() end},
        settings={get_connection=function() return {} end,get_reader=function()
            return {auto_crop_enabled=true,auto_crop_max_percent=20,gray_enhance_enabled=true,prefetch_count=0}
        end},open_chapter=function() end,
        cache={key_for=function() return "key" end,set_protected=function() end},
        render_image={renderImageFile=function() return buffer end},
        ui={create_shell=function() return {get_content_size=function() return 100,160 end,
            show=function() return true end,show_loading=function() end,show_page=function() return true end} end}}
    local image={name="page.jpg",path="/disk/page.jpg"}
    assert(live:open{manga={path="/disk"},chapter={path="/disk/ch"},source_context={},
        chapter_index={count=function() return 1 end,get=function() return image end}})
    callback.on_ready("/prepared/page.jpg",false,{prepared=true,width=100,height=160})
    assert(live.page_crop and live.page_crop.x>=10,"real prepared Reader publication must retain crop")
    before=inspected
    live:_display_segment("whole",false);live:_display_segment("whole",false)
    assert(inspected==before,"repainting/flipping segments must reuse crop instead of rescanning pixels")
end

cases.series_cover = function()
    local Driver=require("webdavmanga.opds_driver")
    local Pointer=require("webdavmanga.meguru_pointer")
    local Cover=require("webdavmanga.opds_cover")
    local source={id="s",server_kind="komga",url="https://host/opds?token=current"}
    local Ui=require("webdavmanga.ui_opds")
    local series_context
    local ui=Ui:new{catalog={},reader={},ui={}}
    ui.current={feed_url="https://host/opds"}
    ui.open_url=function(_,_,_,_,_,_,context) series_context=context;return true end
    ui:_open_entry(source,{kind="series",id="S",name="Series",href="https://host/opds/v1.2/series/S",
        image_url="https://user:secret@host/series.jpg?token=old-secret"})
    local desc=assert(Driver.resolve(source,ui:_driver_context{series_context=series_context},
        {name="Book",image_url="https://host/book.jpg",stream={count=27,
            template="https://host/api/v1/books/B/pages/{pageNumber}"}}))
    local fs,json,files=fs_fixture()
    local pointer=Pointer:new{root="/p",fs=fs,json=json,md5=function() return "aabbcc0011223344" end}
    local path=assert(pointer:save(desc)); local loaded=assert(pointer:load(path))
    local candidates=Cover.candidates(loaded,{image={path="opds:s:S:B/page-1.jpg"},chapter={pointer_path=path}})
    assert(#candidates==3 and candidates[2].image_url(600,800,source)=="https://host/series.jpg?token=current",
        "real driver-pointer roundtrip must preserve a safely restored series cover candidate")
    for _,bytes in pairs(files) do assert(not bytes:find("secret",1,true) and not bytes:find("user:",1,true)) end
end

cases.progress_restart = function()
    local LocalProgress=require("webdavmanga.progress")
    local Pages=require("webdavmanga.opds_pages")
    local persisted={}
    local function copy(value)
        if type(value)~="table" then return value end
        local result={};for k,v in pairs(value) do result[k]=copy(v) end;return result
    end
    local store={readSetting=function(_,k,d) return copy(persisted[k] or d) end,
        saveSetting=function(_,k,v) persisted[k]=copy(v) end,flush=function() return true end}
    local desc={source_id="s",series_id="S",chapter_id="B",server_kind="komga",page_count=27,
        server_last_read=0,stream_template="https://host/api/v1/books/B/pages/{pageNumber}"}
    local sent={}
    local function new_pages(progress)
        return Pages:new{progress_store=progress,source_provider=function() return {id="s",url="https://host/opds"} end,
            transfer={run=function(work,done) local body,err=work(); done(body~=nil,body,err);return {cancel=function() end} end},
            transport={request_json=function(_,_,_,body) sent[#sent+1]=body.page;return true end}}
    end
    local local_progress=LocalProgress:new{store=store,md5=function(v) return v end}
    new_pages(local_progress):sync_progress(desc,10)
    local_progress:save("opds:s:S:B","opds:s:S:B#opds/3",3,"whole")
    local restarted=LocalProgress:new{store=store,md5=function(v) return v end}
    new_pages(restarted):sync_progress(desc,5)
    assert(#sent==1 and sent[1]==10, "Komga must not PATCH 5 after restart following PATCH 10")
    new_pages(restarted):sync_progress(desc,11)
    assert(#sent==2 and sent[2]==11)
    desc.server_last_read=20
    new_pages(restarted):sync_progress(desc,6)
    desc.server_last_read=0
    new_pages(LocalProgress:new{store=store,md5=function(v) return v end}):sync_progress(desc,12)
    assert(#sent==2, "newly observed server baseline must survive restart even on a lower local page")
    store.flush=function() return false end
    new_pages(restarted):sync_progress(desc,21)
    assert(#sent==2, "failed durable reservation must not dispatch a potentially backwards PATCH")
    store.flush=function() return nil,"disk full" end
    new_pages(restarted):sync_progress(desc,22)
    assert(#sent==2, "nil/error flush also must not dispatch PATCH")
end

for _,name in ipairs({"cover_close","cover_verify","prepared_crop","series_cover","progress_restart"}) do
    if not REVIEW_CASE or REVIEW_CASE==name then cases[name](); print("integrity: "..name.." passed") end
end
