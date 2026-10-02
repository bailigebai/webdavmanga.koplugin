local ArchivePages = require("webdavmanga.archive_pages")
local Bridge = require("webdavmanga.document_bridge")
local Loader = require("webdavmanga.loader")
local Reader = require("webdavmanga.ui_reader")
local Errors = require("webdavmanga.errors")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, field in pairs(value) do result[key] = copy(field) end; return result
end
local encoded, serial = {}, 0
package.preload.json = function() return {
    encode = function(value) serial=serial+1; local key='{"id":'..serial..'}'; encoded[key]=copy(value); return key end,
    decode = function(value) return copy(encoded[value]) end,
} end
local JPEG = string.char(255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,217)
local function write(path, bytes)
    local file=assert(io.open(path,"wb")); assert(file:write(bytes)); assert(file:close())
end
do
    local paths={os.tmpname(),os.tmpname(),os.tmpname()}
    local names={"notes.txt","010.jpg","folder","001.jpg","009.jpg"}
    local stream={open=function() return {cursor=0} end,
        next=function(_,reader)
            reader.cursor=reader.cursor+1
            expect(reader.cursor<=5,"opening must stop at third image despite skipped entries")
            return {name=names[reader.cursor],index=reader.cursor,size=#JPEG,mode="file"}
        end,
        extract_current=function(_,_,target) write(target,JPEG);return {size=#JPEG} end,
        close=function() end}
    local book=assert(ArchivePages:new{archive_stream=stream}:inspect_remote({size=1000000,
        read_at=function() return "x" end},"cb7","/book.cb7",{page_limit=3,opening_targets=paths}))
    expect(book.index:get(1).archive_entry_ordinal==2 and book.index:get(2).archive_entry_ordinal==4
        and book.index:get(3).archive_entry_ordinal==5,"non-image entries preserve actual native ordinals")
    expect(book.index:get(1).name=="010.jpg" and book.index:get(2).name=="001.jpg",
        "opening index preserves the extracted archive sequence without later sorting")
    for _,path in ipairs(paths) do os.remove(path) end
end
local function run(count, solid, failure, cancel, tamper, format)
    format = format or "7z"
    local book_path = "/book." .. format
    local tasks, files, records, sessions, extracts, growth = {}, {}, {}, {}, {}, {}
    local context, error_value, prompt, handle, scheduled
    local publishes, downloads, range_reads = 0, 0, 0
    local registered, foreign_discard = {}, false
    local stream = {
        available = function() return true end,
        open = function(_, options)
            expect(options.format == format, "archive adapter forwards actual format")
            if (format=="rar" or format=="cbr") and #sessions==0 then
                expect(options.block_size==512*1024,"RAR opening uses bounded larger Range blocks")
            end
            local reader = { cursor=0, read_at=options.read_at, calls=0, id=#sessions+1 }
            sessions[#sessions+1]=reader
            return reader
        end,
        next = function(_, reader)
            reader.calls=reader.calls+1; reader.cursor=reader.cursor+1
            if failure then return nil, failure end
            if reader.cursor>count then reader.eof=true;return nil end
            assert(reader.read_at(solid and (reader.cursor-1)*32 or 1000+reader.cursor*32, 16))
            return {name=("%03d.jpg"):format(reader.cursor),mode="file",size=#JPEG,index=reader.cursor}
        end,
        extract_current = function(_, reader, target)
            extracts[#extracts+1]={session=reader.id,page=reader.cursor}
            write(target,JPEG); return {size=#JPEG}
        end,
        close = function(_, reader) reader.closed=true end,
    }
    local pages=ArchivePages:new{archive_stream=stream}
    local cache = {
        limit_bytes=1000000,
        key_for=function(_,_,path) return path end,
        paths_for=function(_,key,extension,token)
            registered[key.."|"..extension.."|"..token]=true
            local path=os.tmpname().."."..extension.."."..token;files[#files+1]=path;return path..".final",path
        end,
        lookup=function(_,key) return records[key] and records[key].path end,
        lookup_record=function(_,key) return records[key] and records[key].path,records[key] end,
        discard_part=function(_,key,extension,token)
            if not registered[key.."|"..extension.."|"..token] then foreign_discard=true end
            return true
        end,
        clear_matching_cache=function() return true end,
        publish=function(_,record,part)
            if record.kind=="page" then
                expect(#extracts>=math.min(count,3),"all opening extractions precede first publication")
                publishes=publishes+1
            end
            record.path=part..".final";assert(os.rename(part,record.path));records[record.key]=record
            files[#files+1]=record.path;return record.path
        end,
        remove=function(_,key) if records[key] then os.remove(records[key].path);records[key]=nil end;return true end,
    }
    local client={read_range=function(_,_,first,last)
        range_reads=range_reads+1
        expect(last-first+1<1000000,"no whole archive request")
        return string.rep("x",last-first+1),{["Content-Range"]=("bytes %d-%d/1000000"):format(first,last)}
    end, download_document=function() downloads=downloads+1 end}
    local bridge=Bridge:new{cache=cache,archive_pages=pages,
        client_factory=function() return client end,
        async={run=function(work,done,options) tasks[#tasks+1]={work=work,done=done,options=options};return {cancel=function() end} end},
        scheduler={scheduleIn=function(_,_,callback) scheduled=callback;return true end,
            unschedule=function() scheduled=nil end},
        file_size=function(path) local f=io.open(path,"rb");if not f then return 0 end;local size=f:seek("end");f:close();return size end,
        open_reader=function(value)
            context=value
            expect(publishes==math.min(3,count),"Reader opens only after opening transaction publishes")
            value.stream_state.on_index_growth=function(generation)
                expect(generation==value.stream_state.generation,"growth belongs to current generation")
                growth[#growth+1]=value.chapter_index:count()
            end
            return true
        end,
    }
    local original_inspect=pages.inspect_remote
    pages.inspect_remote=function(self,descriptor,format,path,options)
        if options and options.on_progress then
            local progress=options.on_progress
            options.on_progress=function(index,total)
                local ok=progress(index,total)
                if scheduled then local callback=scheduled;scheduled=nil;callback() end
                return ok
            end
        end
        return original_inspect(self,descriptor,format,path,options)
    end
    bridge:_open_archive({name="book."..format,path=book_path,size=1000000,connection={}},client,book_path,{
        on_error=function(value) error_value=value end,
        on_open_handle=function(value) handle=value end,
        on_document_fallback_prompt=function(_,_,_,value) prompt=value end,
    })
    local first=tasks[1].work()
    if tamper=="one_page_lower_bound" then
        first.index.items={first.index.items[1]};first.index.count=1
        first.opening_metadata={first.opening_metadata[1]};first.opening_lower_bound=3
    elseif tamper=="corrupt_third" then
        for _,path in ipairs(files) do if path:find("_opening_3",1,true) then write(path,"bad bytes") end end
    end
    if cancel then handle.cancel() end
    tasks[1].done(true,first)
    if tasks[1].options.on_reaped then tasks[1].options.on_reaped() end
    if failure or cancel or tamper=="one_page_lower_bound" or tamper=="corrupt_third" then
        expect(not context and publishes==0 and downloads==0,"failed/canceled opening never publishes or downloads whole archive")
        if failure then
            expect(prompt and Errors.message(prompt):find(failure=="archive_encrypted" and "加密"
                or failure=="archive_codec_unsupported" and "不支持" or "损坏",1,true),
                "native failure shows specific prompt")
        end
    else
        expect(context~=nil,"7Z Reader opens: "..tostring(first.error).." / "..tostring(error_value and error_value.detail))
        expect(#sessions==1 and #extracts==math.min(count,3),"single session enumerates and extracts opening pages")
        for _, extracted in ipairs(extracts) do expect(extracted.session==1,"opening never re-extracts in another reader") end
        expect(sessions[1].closed,"opening native reader is released")
        if count<=3 then
            -- At three the adapter deliberately stops without probing a fourth header.
            if count<3 then expect(sessions[1].eof and context.stream_state.complete
                and context.stream_state.total_pages==count,"two-page archive opens complete at real EOF") end
        else
            expect(sessions[1].calls==3 and not sessions[1].eof,
                "long opening never enumerates the fourth header or scans to EOF")
            expect(context.chapter_index:count()==3 and not context.stream_state.complete
                and context.stream_state.total_pages==nil
                and context.stream_state.available_pages==3,
                "lower bound never masquerades as total or readable page count")
            expect(context.stream_state.warm_target==20 and #tasks==2,"background starts after Reader with warm target twenty")
            if tamper=="late_background" then
                local before=range_reads;handle.cancel()
                local background=tasks[2].work();tasks[2].done(true,background)
                expect(range_reads==before and context.chapter_index:count()==3
                    and not context.stream_state.complete,"canceled background cannot read or mutate old generation")
                for _,path in ipairs(files) do os.remove(path) end
                return
            end
            local background=tasks[2].work();tasks[2].done(true,background)
            expect(context.chapter_index:count()==count and context.stream_state.complete
                and context.stream_state.total_pages==count
                and context.stream_state.available_pages==3,
                "background supplies the exact catalog without claiming lazy pages readable")
            expect(type(context.stream_state.mark_ready)=="function",
                "progressive bridge exposes validated-page readiness")
            context.stream_state.mark_ready(5,context.stream_state.generation)
            expect(context.stream_state.available_pages==3,
                "out-of-order page five cannot cross the unread page-four gap")
            context.stream_state.mark_ready(4,context.stream_state.generation)
            expect(context.stream_state.available_pages==5,
                "page four completion advances the contiguous readable prefix through page five")
            context.stream_state.mark_ready(6,"stale-generation")
            expect(context.stream_state.available_pages==5,
                "stale generations cannot advance readable-page state")
            expect(growth[1]==4 and growth[17]==20 and growth[#growth]==count,
                "background publishes every page four through twenty before remaining catalog")
            local loader=Loader:new{cache=cache,identity="7z",client_factory=function() return client end,
                source_kind_provider=function() return "remote" end,
                async={run=function() return {cancel=function() end} end},prefetch_concurrency=2}
            local reader=setmetatable({context=context,loader=loader,generation=1,
                reader_settings={image_prefetch_enabled=true},state={is_current=function() return true end}}, {__index=Reader})
            reader:_prefetch(1)
            expect(loader.jobs_by_key[book_path.."#archive/4"] and loader.jobs_by_key[book_path.."#archive/20"]
                and not loader.jobs_by_key[book_path.."#archive/21"],"shared Loader warms only pages four through twenty first")
            loader:cancel_generation(1)
        end
    end
    if handle then handle.cancel() end
    expect(not foreign_discard,"cleanup discards only originally registered cache paths after ordinal binding")
    for _,path in ipairs(files) do os.remove(path) end
end
run(25,false)
run(25,true)
run(2,false)
run(25,false,nil,true)
run(25,false,nil,nil,"one_page_lower_bound")
run(25,false,nil,nil,"corrupt_third")
run(25,false,nil,nil,"late_background")
for _,reason in ipairs({"archive_encrypted","archive_codec_unsupported","archive_truncated"}) do run(25,false,reason) end

-- Use the production Cache, including lookup copies, matching predicates and
-- remove failure semantics. Only its filesystem/store/hash boundaries are local.
local Cache = require("webdavmanga.cache")
local function cached_open(mode, damaged_page, format)
    format=format or "7z"
    local book_path="/book."..format
    local unique=os.tmpname():gsub("\\","/")
    local root,prefix=unique:match("^(.*)/([^/]+)$")
    assert(root and prefix);os.remove(unique)
    local files,hashes,removed,published,tasks={},{},{},{},{}
    local hashes_count,sessions,extractions=0,0,0
    local denied_path,context,failure,handle
    local function size(path)
        local file=io.open(path,"rb");if not file then return 0 end
        local value=file:seek("end");file:close();return value
    end
    local cache=Cache:new{root=root,limit_bytes=1000000,clock=function() return 100 end,
        md5=function(value)
            if not hashes[value] then hashes_count=hashes_count+1;hashes[value]=prefix.."_"..hashes_count end
            return hashes[value]
        end,
        store={readSetting=function(_,_,default) return default end,saveSetting=function() end,flush=function() end},
        fs={make_path=function(path) assert(path==root);return true end,
            exists=function(path) return size(path)>0 end,size=size,open=io.open,
            rename=os.rename,remove=function(path)
                if path==denied_path then return nil,"injected remove failure" end
                return os.remove(path)
            end,list=function() return {} end}}
    local real_paths,real_publish,real_remove=cache.paths_for,cache.publish,cache.remove
    function cache:paths_for(...)
        local final,part=real_paths(self,...);files[final],files[part]=true,true;return final,part
    end
    function cache:publish(record,path)
        local result,err=real_publish(self,record,path)
        if result then files[result]=true;published[#published+1]=record.key end
        return result,err
    end
    function cache:remove(key) removed[#removed+1]=key;return real_remove(self,key) end
    local keys,paths={},{}
    for position=1,4 do
        local remote=book_path.."#archive/"..position
        keys[position]=cache:key_for("cache-identity",remote)
        local _,part=cache:paths_for(keys[position],"jpg","seed")
        write(part,JPEG)
        paths[position]=assert(cache:publish({key=keys[position],kind="page",identity="cache-identity",
            remote_path=remote,size=#JPEG,extension="jpg",format="jpeg",width=1,height=1,
            etag="v1",modified="1000000:2:v1:m1"},part))
    end
    local document_key=cache:key_for("cache-identity",book_path)
    local _,source_part=cache:paths_for(document_key,format,"source")
    write(source_part,"complete source")
    local source=assert(cache:publish({key=document_key,kind="document",identity="cache-identity",
        remote_path=book_path,size=15,extension=format,validated=true},source_part))
    local _,foreign_part=cache:paths_for(keys[2],"jpg","another_task")
    write(foreign_part,"other task bytes")
    published={}
    if damaged_page then
        write(paths[damaged_page],string.rep("x",#JPEG))
        local _,record=cache:lookup_record(keys[damaged_page])
        expect(record and record.validated and record.size==#JPEG,
            "real validated Cache lookup retains a same-length corrupt image")
    end
    if mode=="delete-fails" then denied_path=paths[damaged_page]
    elseif mode=="foreign-owner" then cache.entries[keys[damaged_page]].identity="another-source"
    elseif mode=="changed-etag" then cache.entries[keys[damaged_page]].etag="v2"
    elseif mode=="legacy" then cache.entries[keys[damaged_page]].identity=nil
    elseif mode=="unversioned" then cache.entries[keys[damaged_page]].modified=nil
    elseif mode=="stale" then cache.entries[keys[damaged_page]].modified="1000000:2:v0:m0"
    elseif mode=="legacy-foreign" then
        cache.entries[keys[1]].identity=nil
        cache.entries[keys[2]].identity="another-source"
    elseif mode=="mixed" then
        cache.entries[keys[2]].identity=nil
        cache.entries[keys[3]].modified="1000000:2:v0:m0"
    elseif mode=="legacy-tail" then
        for position=2,3 do
            cache.entries[keys[position]].identity=nil
            cache.entries[keys[position]].etag=nil
        end
    end
    if mode=="record-race" then
        local lookup,count=cache.lookup_record,0
        function cache:lookup_record(key)
            if key==keys[damaged_page] then
                count=count+1
                if count==2 then self.entries[key].identity="another-source" end
            end
            return lookup(self,key)
        end
    end
    local archive=ArchivePages:new{archive_stream={
        open=function() sessions=sessions+1;return {cursor=0} end,
        next=function(_,reader)
            reader.cursor=reader.cursor+1
            return {name=("%03d.jpg"):format(reader.cursor),index=reader.cursor,mode="file",size=#JPEG}
        end,
        extract_current=function(_,_,target) extractions=extractions+1;write(target,JPEG);return {size=#JPEG} end,
        close=function() end}}
    local bridge=Bridge:new{cache=cache,identity="cache-identity",archive_pages=archive,file_size=size,
        client_factory=function() return {read_range=function() error("fake codec reads no source") end} end,
        async={run=function(work,done) tasks[#tasks+1]={work=work,done=done};return {cancel=function() end} end},
        open_reader=function(value) context=value;return true end}
    bridge:_open_archive({name="book."..format,path=book_path,size=1000000,etag="v1",modified="m1",connection={}},
        nil,book_path,{on_open_handle=function(value) handle=value end,on_error=function(value) failure=value end})
    local result=tasks[1].work()
    if mode=="new-part-corrupt" then
        for path in pairs(files) do if path:find("_opening_3.part",1,true) then write(path,string.rep("x",#JPEG)) end end
    end
    tasks[1].done(true,result)
    local refreshed=mode=="legacy" or mode=="unversioned" or mode=="stale"
        or mode=="mixed" or mode=="legacy-tail"
    local expected_success=mode=="valid" or mode=="repair" or refreshed
    local repaired=not damaged_page or require("webdavmanga.image_probe").inspect(paths[damaged_page],"jpg")~=nil
    local damaged_survives=not damaged_page or (cache.entries[keys[damaged_page]]~=nil
        and size(paths[damaged_page])==#JPEG)
    local untouched=size(source)==15 and size(foreign_part)==16
    for position=1,4 do
        if position~=damaged_page then
            untouched=untouched and cache.entries[keys[position]]~=nil
                and require("webdavmanga.image_probe").inspect(paths[position],"jpg")~=nil
        end
    end
    if handle then handle.cancel() end
    for path in pairs(files) do os.remove(path) end
    expect((context~=nil)==expected_success,mode.." page "..tostring(damaged_page)
        .." opening outcome: "..tostring(failure and failure.detail))
    expect(sessions==1 and extractions==3,"cache recovery reuses the one-pass opening artifacts without reopening")
    expect(untouched,"repair never removes neighboring images, complete source or another task's part")
    if mode=="repair" then
        expect(repaired and #removed==1 and removed[1]==keys[damaged_page]
            and #published==1 and published[1]==keys[damaged_page],"only the corrupt page is removed and republished")
    elseif mode=="valid" then
        expect(#removed==0 and #published==0,"all valid opening cache records are reused")
    elseif refreshed then
        local wanted=(mode=="mixed" or mode=="legacy-tail") and 2 or 1
        expect(repaired and #removed==wanted and #published==wanted,
            "only owned legacy/stale derived pages are refreshed")
        for _,key in ipairs(removed) do
            expect(key==keys[damaged_page or 2]
                or ((mode=="mixed" or mode=="legacy-tail") and key==keys[3]),
                "refresh touches only the selected opening pages")
        end
    else
        expect(damaged_survives and #published==0 and #removed==(mode=="delete-fails" and 1 or 0),
            mode.." safely refuses replacement before deleting unrelated or unverified records")
    end
end
cached_open("valid")
for position=1,3 do cached_open("repair",position) end
for _,mode in ipairs({"delete-fails","foreign-owner","changed-etag","record-race","new-part-corrupt"}) do
    cached_open(mode,2)
end
print(("rebuild_0411_7z_opening_spec: %d checks"):format(checks))
return { run = run, cached_open = cached_open }
