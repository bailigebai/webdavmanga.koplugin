local Progress = require("webdavmanga.progress")
local Identity = require("webdavmanga.manga_identity")
local connection={kind="opds",source_id="s"}
for _,legacy in ipairs({true,false}) do
    local values={}
    local progress=Progress:new{md5=function(v) return v end,store={
        readSetting=function(_,k,d) if values[k]==nil then return d end;return values[k] end,
        saveSetting=function(_,k,v) values[k]=v end,flush=function() end}}
    local paths={}
    for _,chapter in ipairs({"a/b","a//b"}) do
        local resource={source_id="s",series_id="series",chapter_id=chapter,name=chapter}
        -- Existing records can contain pre-encoding paths. They must still be
        -- removed exactly, without ordinary directory slash normalization.
        resource.path=legacy and ("opds:s:series:"..chapter) or Identity.opds_path(resource)
        paths[#paths+1]=resource.path
        progress:save(resource.path,resource.path.."/page-1.jpg",1,"whole",{
            connection=connection,manga=resource,chapter=resource,layout="opds"})
    end
    assert(#progress:list_all_history()==2)
    local first=next(progress.history)
    local target=first==paths[1] and paths[2] or paths[1]
    assert(progress:remove_history(connection,target))
    local remaining=progress:list_all_history()
    assert(#remaining==1 and remaining[1].manga.path==first,
        "deleting one special OPDS id must preserve the other exact history record")
end
print("rebuild_0405_opds_history_delete_spec: passed")
