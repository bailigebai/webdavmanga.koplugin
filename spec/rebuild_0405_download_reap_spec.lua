-- Keep Async.run real. The process boundary deliberately permits work after SIGTERM.
local Async=require("webdavmanga.async")
local Bridge=require("webdavmanga.document_bridge")
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function exists(path) local f=io.open(path,"rb");if f then f:close();return true end;return false end
local function scenario(mode)
    local part=os.tmpname();os.remove(part)
    local final=part..".pdf"
    local queue,child,payload,done={},nil,nil,false
    local downloads,opens,removed,terminated,errors=0,0,0,0,0
    local scheduler={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}
    local ffiutil={runInSubProcess=function(fn) child=fn;return 7,8 end,
        writeToFD=function(_,bytes) payload=bytes end,
        readAllFromFD=function() return payload end,getNonBlockingReadSize=function() return 0 end,
        isSubProcessDone=function() return done end,
        terminateSubProcess=function() terminated=terminated+1 end}
    local handle,confirm
    local bridge=Bridge:new{identity="fixture",cache={key_for=function() return "owned-key" end,
        lookup_record=function() end,paths_for=function() return final,part end,
        discard_part=function(_,key,ext,token)
            expect(key=="owned-key" and ext=="pdf" and token=="doc1","cleanup targets only the owned part")
            removed=removed+1;os.remove(part)
        end,
        publish=function(_,record,path) expect(path==part and record.path==final,"publish owned destination")
            assert(os.rename(part,final));return final end},
        client_factory=function() return {download_document=function(_,_,path)
            downloads=downloads+1;local f=assert(io.open(path,"wb"));f:write("owned download");f:close()
            if mode=="failure" then return nil,"network failure" end
            return {size=14,format="pdf"}
        end} end,
        async={run=function(work,callback,options)
            options.ffiutil,options.scheduler=ffiutil,scheduler
            if mode=="timeout" then options.timeout=-1 end
            return Async.run(work,callback,options)
        end},mupdf_pages={},archive_pages={},mobi_pages={},
        ui_manager={showReader=function(_,path) expect(path==final,"Reader opens final file only");opens=opens+1;return true end}}
    expect(bridge:open({name="book.pdf",path="/book.pdf",size=14,file_kind="document"},{
        on_open_handle=function(value) handle=value end,
        on_document_fallback_prompt=function(_,_,retry) confirm=retry;return true end,
        on_error=function() errors=errors+1 end}),"request accepted")
    expect(confirm and not child and downloads==0,"complete download requires explicit confirmation")
    confirm();confirm()
    expect(child and downloads==0,"one confirmed worker is scheduled")
    if mode=="cancel" then handle:cancel()
    elseif mode=="close" then bridge:cancel_all()
    elseif mode=="timeout" then table.remove(queue,1)() end
    child(7,9)
    expect(exists(part) and downloads==1,"late worker writes the owned part")
    done=true
    local limit=20
    while #queue>0 and limit>0 do limit=limit-1;table.remove(queue,1)() end
    expect(#queue==0,"real Async reaps without endless polling")
    if mode=="success" then
        expect(opens==1 and exists(final) and not exists(part),"success moves one final file and opens once")
        bridge:cancel_all()
        expect(exists(final),"later close never deletes a published file")
    else
        expect(not exists(part) and not exists(final) and opens==0,
            mode..": reap must remove late part without opening Reader")
        if mode=="cancel" or mode=="close" or mode=="timeout" then
            expect(terminated==1 and removed>=2,"cancel and reap safely repeat owned cleanup")
        end
    end
    expect(errors==((mode=="failure" or mode=="timeout") and 1 or 0),"only failures notify")
    os.remove(part);os.remove(final)
end
for _,mode in ipairs({"cancel","close","timeout","failure","success"}) do scenario(mode) end
print(("rebuild_0405_download_reap_spec: %d checks"):format(checks))
