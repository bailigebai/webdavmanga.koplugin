local Driver = require("webdavmanga.opds_driver")
local Identity = require("webdavmanga.manga_identity")
local Library = require("webdavmanga.library")
local Ui = require("webdavmanga.ui_opds")
local Pointer = require("webdavmanga.meguru_pointer")
local values = {}
local library = Library:new{md5=function(value) return value end, store={
    readSetting=function(_,key,default) if values[key]==nil then return default end return values[key] end,
    saveSetting=function(_,key,value) values[key]=value end, flush=function() end}}
local source = {id="s", server_kind="suwayomi"}
local tuples = {
    {series_id="urn:manga:4",chapter_id="urn:chapter:10:urn:chapter:11"},
    {series_id="urn:manga:4:urn:chapter:10",chapter_id="urn:chapter:11"},
}
local records = {}
local files, encoded, locks = {}, {}, {}
local pointer = Pointer:new{root="/p",md5=function() return "112233aabbcc0000" end,
    json={encode=function(value) local bytes="json-"..tostring(#encoded+1);encoded[#encoded+1]=value;return bytes end,
        decode=function(bytes) return encoded[tonumber(bytes:match("json%-(%d+)"))] end},
    fs={make_path=function() return true end,exists=function(path) return files[path]~=nil end,
        mkdir=function(path) if locks[path] then return nil end;locks[path]=true;return true end,
        rmdir=function(path) locks[path]=nil;return true end,
        rename=function(from,to) files[to],files[from]=files[from],nil;return true end,
        remove=function(path) files[path]=nil;return true end,
        open=function(path,mode)
            if mode=="rb" then if not files[path] then return nil end
                return {read=function() return files[path] end,close=function() return true end} end
            return {write=function(_,bytes) files[path]=bytes;return true end,
                flush=function() return true end,close=function() return true end}
        end}}
local opens = 0
local ui = Ui:new{catalog={get=function() return source end},reader={},library=library,
    pointer=pointer,ui={show_info=function() end}}
ui.open_descriptor = function() opens=opens+1; return true end
for _,tuple in ipairs(tuples) do
    local descriptor = assert(Driver.resolve(source,{series_id=tuple.series_id},
        {id=tuple.chapter_id, name="Same title", stream={template="https://host/page/{pageNumber}",count=27}}))
    local record = assert(ui:descriptor_record(descriptor,source,assert(pointer:save(descriptor))))
    records[#records+1] = record
    assert(library:add_manga(record.connection,record.manga,{chapter=record.chapter,layout="opds"}))
end
local original_pointer=records[1].chapter.pointer_path
records[1].chapter.pointer_path=records[2].chapter.pointer_path
assert(ui:open_record(records[1])==false and opens==0,"pointer validation must reject a different raw series/chapter tuple")
assert(#library:list_all_mangas()==2,"distinct real Suwayomi id tuples must not overwrite each other in Library")
assert(records[1].manga.path=="opds:s:urn%3Amanga%3A4:urn%3Achapter%3A10%3Aurn%3Achapter%3A11")
assert(records[2].manga.path=="opds:s:urn%3Amanga%3A4%3Aurn%3Achapter%3A10:urn%3Achapter%3A11")
assert(records[1].manga.chapter_id==tuples[1].chapter_id,"records keep raw ids for server routing")
records[1].chapter.pointer_path=original_pointer
assert(ui:open_record(records[1])==true and opens==1)
assert(Identity.opds_path{source_id="s:%",series_id="a/b",chapter_id="中 %:/.~_-"}
    =="opds:s%3A%25:a%2Fb:%E4%B8%AD%20%25%3A%2F.~_-","encode reserved characters and UTF-8 bytes reversibly")
assert(Identity.opds_path{source_id="s",series_id="a%2Fb",chapter_id="c"}
    =="opds:s:a%252Fb:c","literal percent escapes must not alias raw slash ids")
assert(Identity.opds_path{source_id="s",series_id="series",chapter_id="v1"}=="opds:s:series:v1")
print("rebuild_0405_opds_tuple_identity_spec: passed")
