local Ui=require("webdavmanga.ui_opds")
local Parser=require("webdavmanga.opds_parser")
local source={id="s",server_kind="komga",url="https://host/opds/v1.2/catalog"}
local first="https://host/opds/v1.2/series/S"
local second=first.."?page=2"
local third=first.."?page=3"
local function chapter(id)
    return {name=id,kind="volume",stream={count=27,template="https://host/api/v1/books/"..id.."/pages/{pageNumber}"}}
end
local feeds={ [first]={entries={chapter("b1"),chapter("b2")},next_url=second},
    [second]={entries={chapter("b3"),chapter("b4")},previous_url=first,next_url=third},
    [third]={entries={chapter("b5")},previous_url=second} }
local requests,saved,context,dialog,canceled={}, {}, nil,nil,0
local interrupt=false
local app
app=Ui:new{reader={open=function(_,value) context=value;return true end},
    async={run=function(work,done)
        local ok,value=pcall(work);done(ok,value);return {cancel=function() end}
    end},
    ui={show_resume=function(_,model) dialog=model;return true end,show_info=function(_,message) error(message) end},
    pages={cancel_all=function() canceled=canceled+1 end},
    pointer={save=function(_,desc) local path="/p/S/"..desc.chapter_id..".meguru"; saved[#saved+1]={path=path,desc=desc};return path end,
        load=function(_,path) for i=#saved,1,-1 do if saved[i].path==path then return saved[i].desc end end end},
    catalog={get=function() return source end,fetch=function(_,id,url)
        assert(id=="s");requests[#requests+1]=url
        assert(canceled>0,"boundary page request must follow cancellation of the old chapter")
        if interrupt then app:_begin_navigation() end
        return feeds[url]
    end} }
app.current={feed=feeds[first],feed_url=first,title="S",series_context={series_id="S",series_feed_url=first}}
assert(app:_open_entry(source,feeds[first].entries[2]))
assert(dialog.items[1].callback())
assert(#requests==0 and #saved==1,"opening current chapter must not prefetch neighboring feeds")
local nav=context.source_context.navigation
assert(nav.current.next,"last chapter of a feed must expose a lazy next-page neighbor")
assert(#requests==0 and #saved==1,"showing lazy neighbor must neither fetch nor save")
assert(nav:open("next"), "lazy boundary request is accepted before completion")
assert(#requests==1 and requests[1]==second and #saved==2 and context.chapter.chapter_id=="b3",
    "choosing next fetches exactly one adjacent feed and opens its first chapter")
assert(saved[2].desc.series_feed_url==second,"pointer must retain the actual chapter feed page")
local cancellations=canceled
assert(nav:open("next")==false and canceled==cancellations and #requests==1,
    "stale neighbor callbacks must not cancel the new chapter's page generation")
nav=context.source_context.navigation
assert(nav.current.previous and nav:open("previous"))
assert(#requests==2 and requests[2]==first and context.chapter.chapter_id=="b2",
    "previous boundary opens the previous feed's last chapter in server order")
nav=context.source_context.navigation
interrupt=true
assert(nav:open("next")==true and #saved==3 and context.chapter.chapter_id=="b2",
    "an accepted async request superseded after feed completion must not persist/open a stale neighbor")
local parsed=assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom"><link rel="previous" href="?page=1"/></feed>',second))
assert(parsed.previous_url==first.."?page=1","real parser must preserve previous page links")
print("rebuild_0405_opds_paged_neighbors_spec: passed")
