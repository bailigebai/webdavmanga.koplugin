local Identity=require("webdavmanga.manga_identity")
local Library=require("webdavmanga.library")
local Progress=require("webdavmanga.progress")
local Ui=require("webdavmanga.ui_opds")
-- The unified Library/Progress records are authoritative; a second OPDS
-- record cache must not be resurrected by production startup or UI injection.
for _, path in ipairs({"main.lua", "webdavmanga/ui_opds.lua"}) do
    local file=assert(io.open(TEST_PLUGIN_ROOT.."/"..path,"rb"))
    local source=file:read("*a");file:close()
    assert(not source:find("opds_memory_cache",1,true) and not source:find("memory_cache",1,true),
        "production must not require or inject a second OPDS record cache")
end
assert(type(Identity.opds_path)=="function", "OPDS identity must derive from stable ids")
assert(Identity.opds_path{source_id="s",series_id="series",chapter_id="v1"}=="opds:s:series:v1")
local function store()
    local values={}
    return {readSetting=function(_,k,d) if values[k]==nil then return d end return values[k] end,
        saveSetting=function(_,k,v) values[k]=v end,flush=function() end}
end
local library_store, progress_store=store(),store()
local library=Library:new{store=library_store,md5=function(v) return v end}
local progress=Progress:new{store=progress_store,md5=function(v) return v end}
local source={id="s",server_kind="komga",url="https://host/opds"}
local saved, opened={},{}
local pointer={ load=function(_,path) return saved[path] end }
local adapter=Ui:new{catalog={get=function(_,id) if id==source.id then return source end end},
    reader={},library=library,progress=progress,pointer=pointer,ui={show_info=function() end}}
adapter.open_descriptor=function(_,d,_,o) opened[#opened+1]={id=d.chapter_id,path=o.pointer_path};return true end
local records={}
for _,id in ipairs({"v1","v2"}) do
    local descriptor={source_id="s",series_id="series",chapter_id=id,chapter_name="Same title",
        series_name="Series",server_kind="komga",page_count=40,
        stream_template="https://host/api/v1/books/"..id.."/pages/{pageNumber}",
        series_feed_url="https://user:password_secret@host/series?token=query_secret"}
    local path="/p/"..id..".meguru"
    saved[path]=descriptor
    local r=adapter:descriptor_record(descriptor,source,path)
    assert(r.manga.path=="opds:s:series:"..id and r.chapter.path==r.manga.path,
        "shelf and chapter identity must not depend on title, feed or list position")
    assert(r.cover_hint and r.cover_hint.image.path==r.chapter.path.."/page-1.jpg",
        "descriptor shelf and Reader must share a stable first-page cover key")
    assert(Identity.manga(r.connection,r.manga.path)==r.manga.path)
    assert(progress:chapter_id(r.connection,r.manga,r.chapter)==r.chapter.path)
    local category=library:list_categories(r.connection)[1] or assert(library:create_category(r.connection,"Favorite"))
    assert(library:add_manga(r.connection,r.manga,{layout="opds",chapter=r.chapter,category_ids={category.id}}))
    assert(library:set_rating(r.connection,r.manga.path,5,5))
    assert(library:set_read(r.connection,r.manga.path,true))
    local cover=assert(library:set_cover(r.connection,r.manga.path,{name="1.jpg",path=r.manga.path.."/page-1.jpg",
        opds_feed_url="https://user:password_secret@host/cover?token=query_secret"}))
    assert(cover.manga_path==r.manga.path and cover.image.path==r.manga.path.."/page-1.jpg",
        "OPDS cover keys and page hints must preserve exact virtual identity")
    assert(not tostring(cover.image.opds_feed_url):find("secret",1,true), "cover hint copies must redact credentials")
    progress:save(r.chapter.path,r.chapter.path.."/page-8.jpg",8,"whole",{
        connection=r.connection,manga=r.manga,chapter=r.chapter,total=40,layout="opds",source_context=r.source_context})
    records[#records+1]=r
end
library=Library:new{store=library_store,md5=function(v) return v end}
progress=Progress:new{store=progress_store,md5=function(v) return v end}
adapter.library,adapter.progress=library,progress
local connection=records[1].connection
local category=library:list_categories(connection)[1]
local shelves={progress:list_all_history(),library:list_mangas(connection,category.id),
    library:list_mangas_by_rating(connection,5,5)}
for _,shelf in ipairs(shelves) do
    assert(#shelf==2,"same-title chapters must coexist in each shelf")
    for _,r in ipairs(shelf) do
        local id=r.manga.chapter_id
        assert(r.manga.source_id=="s" and r.manga.series_id=="series" and r.manga.pointer_path=="/p/"..id..".meguru")
        assert(adapter:open_record(r))
        assert(opened[#opened].id==id and opened[#opened].path==r.manga.pointer_path)
        assert(not tostring(r.manga.opds_feed_url):find("secret",1,true))
    end
end
assert(pointer.find_existing("s","series","v1")=="/p/v1.meguru",
    "existing library/history lookup must reuse original pointer after title changes")
saved["/p/v1.meguru"].chapter_name="Renamed"
saved["/p/v1.meguru"].series_feed_url="https://host/moved"
assert(adapter:open_record(shelves[1][1]))
local standalone=adapter:descriptor_record({source_id="s",chapter_id="v1",server_kind="komga"},source,"/p/standalone.meguru")
assert(standalone.manga.path=="opds:s:standalone%3Av1:v1"
    and standalone.manga.series_id=="standalone:v1"
    and standalone.manga.path~=records[1].manga.path,
    "unknown Komga series uses isolated sentinel; later proven series coexists without implicit migration")
saved["/p/v1.meguru"].chapter_id="wrong"
local count=#opened
assert(adapter:open_record(records[1])==false and #opened==count,"mismatched pointer cannot reopen another chapter")
source.id="new-source"
assert(adapter:open_record(records[2])==false and #opened==count,"recreated source must not bind old shelf records")
-- Exercise the real pointer store and real unified shelf together: no mock
-- hand-written distinct pointer paths can conceal same-title collisions.
local Pointer=require("webdavmanga.meguru_pointer")
local files,encoded,locks={},{},{}
local function copy(t) local out={};for k,v in pairs(t) do out[k]=v end;return out end
local codec={encode=function(t)
    local parts={}
    for k,v in pairs(t) do parts[#parts+1]=k.."="..tostring(v) end
    table.sort(parts)
    local bytes=table.concat(parts,"\n")
    encoded[bytes]=copy(t)
    return bytes
end,decode=function(bytes) return encoded[bytes] and copy(encoded[bytes]) end}
local fs={make_path=function() return true end,exists=function(path) return files[path]~=nil end,
    mkdir=function(path) if locks[path] then return nil end;locks[path]=true;return true end,
    rmdir=function(path) locks[path]=nil;return true end,
    remove=function(path) files[path]=nil;return true end,
    rename=function(from,to) files[to],files[from]=files[from],nil;return true end,
    open=function(path,mode)
        if mode=="rb" then
            if not files[path] then return nil end
            return {read=function() return files[path] end,close=function() return true end}
        end
        return {write=function(_,bytes) files[path]=bytes;return true end,
            flush=function() return true end,close=function() return true end}
    end}
local pointers=Pointer:new{root="/p",fs=fs,json=codec,md5=function() return "123456abcdef0000" end}
local fresh_library=Library:new{store=store(),md5=function(v) return v end}
local dialog
local app=Ui:new{catalog={get=function(_,id) if id=="s" then return {id="s"} end end},
    reader={open=function(_,context) context.source_context.on_first_page();return true end},
    pointer=pointers,library=fresh_library,ui={show_resume=function(_,m) dialog=m end,show_info=function() end}}
for _,id in ipairs({"v1","v2"}) do
    local d={source_id="s",series_id="series",chapter_id=id,series_name="Series",chapter_name="Same title",
        server_kind="komga",page_count=20,
        stream_template="https://user:password_secret@host/books/"..id.."/pages/{pageNumber}?token=query_secret"}
    app:request_open(d,{id="s"},{})
    assert(dialog.items[1].callback())
end
local all=fresh_library:list_all_mangas()
assert(#all==2 and all[1].manga.pointer_path~=all[2].manga.pointer_path)
for _,record in ipairs(all) do
    assert(record.cover_hint and record.cover_hint.image.path==record.manga.path.."/page-1.jpg",
        "successful handoff must persist the common shelf cover hint")
    local reloaded=assert(pointers:load(record.manga.pointer_path))
    assert(reloaded.chapter_id==record.manga.chapter_id and app:open_record(record))
    local renamed=copy(reloaded);renamed.chapter_name="Changed title";renamed.series_feed_url="https://host/moved"
    assert(pointers:save(renamed)==record.manga.pointer_path,"identity lookup reuses path across title/feed changes")
end
local function scan(value)
    if type(value)=="string" then
        assert(not value:find("password_secret",1,true) and not value:find("query_secret",1,true),
            "credentials must not persist in pointers, shelf keys or values")
    elseif type(value)=="table" then for k,v in pairs(value) do scan(k);scan(v) end end
end
scan(files);scan(fresh_library.data)
print("rebuild_0405_opds_stable_shelf_spec: passed")
