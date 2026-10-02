local Ui=require("webdavmanga.ui_opds")
local requests={}
local source={id="s",name="Source",server_kind="suwayomi",url="https://fixture.invalid/opds"}
local ui=Ui:new{catalog={fetch=function(_,id,url) requests[#requests+1]=url; return {entries={}} end},reader={},
    async={run=function(work,done) done(true,work()); return {cancel=function() end} end},
    ui={show_menu=function() return true end,show_info=function() end}}
ui.current={feed={entries={}},feed_url=source.url,title="Root"}
ui:_open_entry(source,{id="urn:suwayomi:manga:1",name="Series",kind="series",
    href="https://fixture.invalid/chapters?filter=unread&sort=number_desc"})
assert(requests[1]=="https://fixture.invalid/chapters?filter=unread&sort=number_asc",
    "#9 initial Suwayomi chapter-list URL must preserve filter and request number_asc")
local first_url=requests[1]
local next_url="https://fixture.invalid/chapters?cursor=c%2B3&filter=unread&sort=server"
local function chapter(n)
    return {id="urn:suwayomi:chapter:"..n,name="Chapter "..n,kind="volume",
        stream={count=4,template="https://fixture.invalid/chapter/"..n.."/page/{pageNumber}"}}
end
local one,two,three=chapter(1),chapter(2),chapter(3)
local stored,context,resume
ui.catalog.get=function() return source end
ui.catalog.fetch=function(_,id,url)
    requests[#requests+1]=url
    assert(id==source.id)
    if url==first_url then return {entries={one,two},next_url=next_url} end
    assert(url==next_url,"#9 pagination tokens must not be normalized or reconstructed")
    return {entries={three}}
end
ui.pointer={save=function(_,desc) stored=desc;return "/p/"..desc.chapter_id..".meguru" end,
    load=function() return stored end}
ui.reader.open=function(_,value) context=value;return true end
ui.ui.show_resume=function(_,model) resume=model end
ui:open_url(source,first_url,"Series",nil,first_url,{series_id="urn:suwayomi:manga:1"})
ui:_open_entry(source,two); assert(resume.items[1].callback())
assert(context.chapter.chapter_id==two.id and context.source_context.navigation.current.previous.chapter_id==one.id,
    "#9 ascending first page has Chapter 1 before Chapter 2")
assert(context.source_context.navigation:open("next"))
assert(requests[#requests]==next_url and context.chapter.chapter_id==three.id,
    "#9 forward neighbor traverses the exact server next URL to Chapter 3")
assert(context.source_context.navigation:open("previous"))
assert(requests[#requests]==first_url and context.chapter.chapter_id==two.id,
    "#9 backward neighbor returns to the last chapter of the preceding ascending page")
print("rebuild_0405_final_sort_spec: initial request and bidirectional paginated neighbors passed")
