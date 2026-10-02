local Ui=require("webdavmanga.ui_opds")
local source={id="s",server_kind="komga",url="https://host/opds/v1.2/catalog"}
local chapter={id="book-a",name="Same title",kind="volume",
    stream={template="https://host/api/v1/books/book-a/pages/{pageNumber}",count=40,last_read=0}}
local feed={title="Series",entries={chapter}}
local menu,dialog,requested,fetches
fetches=0
local ui=Ui:new{catalog={fetch=function(_,_,url)
    fetches=fetches+1
    assert(not url:find("{pageNumber}",1,true),"PSE template must never be fetched as an Atom feed")
    return feed
end},reader={},pointer={save=function() error("no writes before selection") end},
    async={run=function(work,done)
        local ok,value=pcall(work);done(ok,value);return {cancel=function() end}
    end},
    ui={show_menu=function(_,m) menu=m;return true end,show_info=function() end}}
ui.request_open=function(_,d,s,o) requested={d=d,s=s,o=o};return true end
ui:open_url(source,"https://host/opds/v1.2/series/series-a")
assert(menu.items[1].text=="▶ 巡这个系列","proven unread series starts with resume row")
menu.items[1].callback()
assert(requested and requested.d.chapter_id=="book-a" and requested.d.series_id=="series-a"
    and fetches==1,"series action must resolve the selected PSE chapter without another fetch")
requested=nil
menu.items[2].callback()
assert(requested and requested.d.chapter_id=="book-a" and fetches==1)

source={id="s",server_kind="suwayomi",url="https://host/api/v1/opds"}
local metadata={id="urn:chapter:10:metadata",name="Chapter 10",kind="volume",stream={
    template="https://host/api/v1/manga/4/chapter/10/page/{pageNumber}",count=30}}
local series={id="urn:manga:4",title="Series",entries={
    {id="urn:chapter:10",name="Chapter 10",kind="volume",href="https://host/api/v1/opds/chapter/10"},
    {id="urn:chapter:11",name="Chapter 11",kind="volume",href="https://host/api/v1/opds/chapter/11"}}}
local requests={}
ui.catalog.fetch=function(_,_,url)
    requests[#requests+1]=url
    if url:find("chapter/10",1,true) then return {entries={metadata}} end
    return series
end
ui:open_url(source,"https://host/api/v1/opds/manga/4")
assert(#requests==1 and menu.items[1].text=="Chapter 10","browsing must not eagerly fetch metadata or guess unread")
menu.items[1].callback()
assert(#requests==2 and requested.d.chapter_id=="urn:chapter:10" and requested.d.series_id=="urn:manga:4",
    "Suwayomi clicked metadata feed resolves exactly once with canonical series identity")
ui.progress={list_all_history=function() return {{manga={source_id="s",series_id="urn:manga:4",
    chapter_id="urn:chapter:11"},chapter={chapter_id="urn:chapter:11"},index=12}} end}
ui:open_url(source,"https://host/api/v1/opds/manga/4")
assert(menu.items[1].text=="▶ 巡这个系列","series without unread evidence uses local last chapter")
local old_menu=menu
ui.catalog.fetch=function() return nil,"credential_secret" end
requested=nil
assert(old_menu.items[2].callback()==true and menu==old_menu and requested==nil,
    "accepted async metadata failure must keep current series menu available for retry")
local legacy_fetched=false
ui.catalog.get=function() return source end
ui.catalog.fetch=function() legacy_fetched=true;return feed end
assert(ui:open_record{manga={opds_catalog_id="s",opds_feed_url="https://host/old-feed"}}==false
    and not legacy_fetched,"pointer-enabled production shelf must never replay feed-hash records")
print("rebuild_0405_opds_resume_navigation_spec: passed")
