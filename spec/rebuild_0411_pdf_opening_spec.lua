local helpers = dofile("spec/rebuild_0411_pdf_dominant_image_spec.lua")
local Pdf = require("webdavmanga.pdf_image_stream")
local Bridge = require("webdavmanga.document_bridge")
local Loader = require("webdavmanga.loader")
local Reader = require("webdavmanga.ui_reader")
local checks = 0
local function expect(value,message) checks=checks+1; assert(value,message) end

local function run(count,bad_page,cancel,recovery)
    local bytes=helpers.fixture{count=count,bad_page=bad_page}
    local tasks,records,parts,extracted,removed={},{},{},{},{}
    local entry={name="book.pdf",path="/book.pdf",size=#bytes,connection={},etag="etag-one",modified="mtime-one"}
    local context, publishes, prompts, downloads, indexed, walked=nil,0,0,0,0,0
    local cache={
        key_for=function(_,_,path) return path end,
        paths_for=function(_,key,extension,token)
            local path=os.tmpname(); parts[#parts+1]=path
            return path..".final",path
        end,
        discard_part=function() return true end,
        lookup=function(_,key) return records[key] and records[key].path end,
        lookup_record=function(_,key) return records[key] and records[key].path,records[key] end,
        publish=function(_,record,path)
            publishes=publishes+1
            expect(#extracted>=math.min(3,count) and #extracted%math.min(3,count)==0,
                "all three extractions finish before any publication")
            record.path=path..".final"; assert(os.rename(path,record.path))
            -- The real cache persists etag/modified, not adapter-specific PDF fields.
            record.pdf_source_size,record.pdf_remote_path,record.pdf_image=nil,nil,nil
            records[record.key]=record; return record.path
        end,
        remove=function(_,key)
            removed[#removed+1]=key
            if recovery=="delete-fails" then return false end
            if records[key] then os.remove(records[key].path); records[key]=nil end
            return true
        end,
        limit_bytes=1000000,
    }
    local parser=Pdf:new()
    local open_index,collect,extract=parser._open_index,parser._collect_page_objects,parser.extract_remote
    parser._open_index=function(self,...)
        indexed=indexed+1; return open_index(self,...)
    end
    parser._collect_page_objects=function(self,...)
        walked=walked+1; return collect(self,...)
    end
    parser.extract_remote=function(self,image,...)
        extracted[#extracted+1]=image.page
        return extract(self,image,...)
    end
    local client={ read_range=function(_,_,first,last)
        expect(last-first+1<#bytes,"no complete PDF request")
        return bytes:sub(first+1,last+1),{["Content-Range"]=("bytes %d-%d/%d"):format(first,last,#bytes)}
    end, download_document=function() downloads=downloads+1 end }
    local handle, failure
    local bridge=Bridge:new{
        cache=cache,pdf_image_stream=parser,client_factory=function() return client end,
        file_size=function(path)
            local file=io.open(path,"rb"); if not file then return 0 end
            local size=file:seek("end");file:close();return size
        end,
        mupdf_pages={remote_capability=function() return false end},
        async={run=function(work,done,options)
            tasks[#tasks+1]={work=work,done=done,options=options};return {cancel=function() end}
        end},
        open_reader=function(value) context=value;return true end,
    }
    bridge:open(entry, {
        on_open_handle=function(value) handle=value end,
        on_error=function(value) failure=value end,
        on_document_fallback_prompt=function() prompts=prompts+1 end,
    })
    local result=tasks[1].work()
    if cancel then bridge:cancel_all() end
    tasks[1].done(true,result)
    if tasks[1].options.on_reaped then tasks[1].options.on_reaped() end
    if cancel or bad_page then
        expect(not context and publishes==0,"failed/canceled opening never publishes page one alone")
        expect(downloads==0,"failure never silently downloads the PDF")
        if bad_page then expect(prompts==1,"all unsupported streams use the existing explicit download prompt") end
    else
        expect(context and publishes==math.min(3,count),"PDF Reader opens after three verified published pages: "
            .. tostring(result.error) .. " / " .. tostring(failure and (failure.detail or failure.message or failure.code)))
        expect(indexed==1 and walked==1,"opening reuses the xref/page tree across all three pages")
        expect(#extracted==math.min(3,count),"only opening pages are extracted before Reader")
        expect(context.chapter_index:count()==count and context.stream_state.total_pages==count,
            "PDF page tree supplies trustworthy Reader total")
        expect(context.stream_state.phase=="complete" and context.stream_state.complete
            and context.stream_state.available_pages==math.min(3,count)
            and context.stream_state.warm_target==20,
            "PDF completed catalog reports only its verified opening pages as readable")
        if count>=20 then
            expect(not context.chapter_index:get(4).pdf_image_offset,"page four remains a lazy descriptor")
            local loader=Loader:new{cache=cache,identity="pdf",client_factory=function() return client end,
                source_kind_provider=function() return "remote" end,
                async={run=function() return {cancel=function() end} end},prefetch_concurrency=2}
            local reader=setmetatable({context=context,loader=loader,generation=1,
                reader_settings={image_prefetch_enabled=true},state={is_current=function() return true end}}, {__index=Reader})
            reader:_prefetch(1)
            expect(#loader.prefetch_queue+loader.prefetch_active_count==17,"existing Loader queues pages four through twenty")
            expect(loader.jobs_by_key["/book.pdf#pdf/4"] and loader.jobs_by_key["/book.pdf#pdf/20"]
                and not loader.jobs_by_key["/book.pdf#pdf/21"],"warmup boundaries are shared")
            loader:cancel_generation(1)
        end
        context=nil
        local second=records["/book.pdf#pdf/2"]
        local first_path=records["/book.pdf#pdf/1"].path
        local third_path=records["/book.pdf#pdf/3"] and records["/book.pdf#pdf/3"].path
        local old_second=second.path
        if recovery=="legacy-unmarked" then
            for _,record in pairs(records) do record.identity=nil;record.modified=nil;record.etag=nil end
        elseif recovery=="legacy-same" or recovery=="legacy-etag" then
            for _,record in pairs(records) do record.modified="mtime-one" end
            if recovery=="legacy-etag" then entry.etag="etag-two" end
        elseif recovery=="etag" or recovery=="new-part-corrupt" then entry.etag="etag-two"
        elseif recovery=="mtime" then entry.modified="mtime-two"
        elseif recovery=="size" then bytes=bytes.."\n";entry.size=#bytes
        elseif recovery then
            local file=assert(io.open(second.path,"wb"));file:write("corrupt image");file:close()
            if recovery=="unknown-version" then second.modified=nil;second.etag=nil end
            if recovery=="unknown-owner" then second.identity="different-source" end
        end
        bridge:open(entry, {
            on_error=function(value) failure=value end,
        })
        local reopened=tasks[2].work()
        if recovery=="new-part-corrupt" then
            local file=assert(io.open(parts[#parts-1],"wb"));file:write("damaged staged bytes");file:close()
        end
        tasks[2].done(true,reopened)
        if recovery=="etag" or recovery=="mtime" or recovery=="size" or recovery=="legacy-etag" then
            expect(context and publishes==6 and #removed==3,
                recovery.." update replaces stale opening pages and reopens PDF")
            if recovery=="legacy-etag" then
                expect(records["/book.pdf#pdf/2"].modified:match("^pdf:"),"legacy stale records migrate to persisted PDF versions")
            end
        elseif recovery=="legacy-unmarked" then
            expect(context and publishes==6 and #removed==3,
                'legacy pages with matching derived cache keys migrate without global cache deletion')
        elseif recovery=="legacy-same" then
            expect(context and publishes==3 and #removed==0,"known same-version legacy cache is reused without deletion")
        elseif recovery=="corrupt" or recovery=="unknown-version" then
            expect(context and publishes==4 and #removed==1 and removed[1]=="/book.pdf#pdf/2",
                "same-version corrupt page is evicted and replaced without blocking PDF reopen")
            expect(records["/book.pdf#pdf/2"].path~=old_second
                and records["/book.pdf#pdf/1"].path==first_path
                and records["/book.pdf#pdf/3"].path==third_path,
                "corrupt page recovery preserves both valid opening neighbors")
        elseif recovery then
            expect(not context and failure and publishes==3 and records["/book.pdf#pdf/2"]
                and records["/book.pdf#pdf/2"].path==old_second,
                recovery.." fails safely without replacing the unowned/undeletable record")
            expect(#removed==(recovery=="delete-fails" and 1 or 0),
                recovery.." never removes any other page")
        else
            expect(context~=nil and publishes==math.min(3,count),
                "reopening the same PDF reuses verified opening cache records")
        end
    end
    for _,path in ipairs(parts) do
        local file=io.open(path,"rb")
        expect(not file,"owned opening parts are removed after publish/failure/cancel")
        if file then file:close() end
        os.remove(path);os.remove(path..".final")
    end
end
run(25)
run(2)
run(25,2)
run(25,nil,true)
for _,recovery in ipairs({"etag","mtime","size","corrupt","delete-fails","unknown-version","unknown-owner",
    "legacy-same","legacy-etag","legacy-unmarked","new-part-corrupt"}) do
    run(3,nil,nil,recovery)
end
print(("rebuild_0411_pdf_opening_spec: %d checks"):format(checks))
