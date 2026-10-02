local Ui=require("webdavmanga.ui_opds")
local Parser=require("webdavmanga.opds_parser")
local Identity=require("webdavmanga.manga_identity")
local source={id="s",server_kind="komga",url="https://host/opds/v1.2/catalog",username="reader",password="fixture-only"}
local url="https://host/opds/v1.2/series/S?cursor=opaque"
local checks=0
local function expect(value,message) checks=checks+1; assert(value,message) end
local function scenario(last_read, readback_count)
    local feed=assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns">'
        ..'<entry><id>A</id><title>Chapter A</title><link rel="http://vaemendis.net/opds-pse/stream" href="https://host/api/v1/books/A/pages/{pageNumber}" pse:count="27" pse:lastRead="27"/></entry>'
        ..'<entry><id>B</id><title>Chapter B</title><link rel="http://vaemendis.net/opds-pse/stream" href="https://host/api/v1/books/B/pages/{pageNumber}" pse:count="27" pse:lastRead="'..last_read..'"/></entry>'
        ..'<link rel="next" href="?cursor=next%2Bpage"/></feed>',url))
    local dialog,opened,saved
    local fetches=0
    local progress={records={}}
    progress.records[Identity.opds_path{source_id="s",series_id="S",chapter_id="A"}]={index=6}
    local app=Ui:new{catalog={get=function() return source end,fetch=function(_,id,requested)
            expect(id=="s" and requested==url,"source identity and pagination URL preserved")
            fetches=fetches+1; return feed end},
        async={run=function(work,done) done(true,work()); return {cancel=function() end} end},
        progress=progress,reader={open=function(_,context) opened=context; return true end},
        pointer={save=function(_,desc) saved=desc; return "/p/"..desc.chapter_id..".meguru" end,
            load=function() local copy={};for k,v in pairs(saved) do copy[k]=v end
                if readback_count then copy.page_count=readback_count end;return copy end},
        ui={show_menu=function() return true end,show_resume=function(_,model) dialog=model;return true end,
            show_info=function(_,message) error(message) end}}
    expect(app:open_url(source,url),"real feed entry loads")
    expect(app:_open_entry(source,app.current.feed.entries[1]),"clicked A uses real driver/UI chooser")
    expect(dialog.items[1].kind=="start" and dialog.items[2].kind=="local"
        and dialog.items[2].text:find("6",1,true),"A start and local page 6 remain available")
    expect(fetches==1 and not saved and not opened,"chooser does not fetch bodies or another catalog page")
    return app,dialog,function() return opened,saved,fetches end
end
do
    local app,dialog,state=scenario("20")
    local server=dialog.items[3]
    expect(server and server.kind=="server" and server.text:find("Chapter B",1,true)
        and server.text:find("21",1,true),"production entry must offer B page 21 from feed metadata")
    expect(server.callback(),"server option opens")
    local context,saved,fetches=state()
    expect(context.chapter.chapter_id=="B" and context.initial_page==21 and saved.chapter_id=="B",
        "B identity and page survive pointer save/readback and Reader handoff")
    expect(context.connection.source_id==source.id and context.chapter_index:get(21).opds_source_id==source.id
        and app.catalog:get(source.id)==source and fetches==1,
        "target retains the source lookup used for page authentication without eager fetch")
    expect(not server.callback(),"repeat confirmation cannot open twice")
end
do
    local _,dialog,state=scenario("20",8)
    expect(dialog.items[3].callback(),"shorter readback opens safely")
    expect(state().initial_page==8,"server page clamps to verified target count")
end
for _,bad in ipairs({"-1","999999","nan","20.5"}) do
    local _,dialog=scenario(bad)
    for _,item in ipairs(dialog.items) do
        expect(not(item.kind=="server" and item.text:find("Chapter B",1,true)),"invalid remote progress cannot become B continuation")
    end
end
print(("rebuild_0405_opds_server_entry_spec: %d checks"):format(checks))
