-- Real Reader teardown crosses the real OPDS navigation boundary.
local host = dofile("spec/helpers/reader_quadrant_host.lua")
local Ui = require("webdavmanga.ui_opds")
local Parser = require("webdavmanga.opds_parser")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function fixture(paged)
    local reader, observed = host(false)
    reader:force_close("fixture")
    local source = { id="s", server_kind="komga", url="https://host/opds/v1.2/catalog" }
    local url = "https://host/opds/v1.2/series/S"
    local xml = '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns">'
    for _, id in ipairs(paged and {"A", "B"} or {"A", "B", "C"}) do
        xml = xml .. '<entry><id>' .. id .. '</id><title>' .. id .. '</title><link rel="http://vaemendis.net/opds-pse/stream" href="https://host/api/v1/books/' .. id .. '/pages/{pageNumber}" pse:count="27"/></entry>'
    end
    local feed = assert(Parser.parse(xml .. '</feed>', url))
    if paged then feed.next_url=url.."?page=2" end
    local s = { closes=0, saves={}, history={}, progress={}, jobs={}, requests=0 }
    reader.ui.close_shell = function() s.closes=s.closes+1; return true end
    local dialog
    s.app = Ui:new{ reader=reader, catalog={get=function() return source end,
        fetch=function() s.requests=s.requests+1; return feed end},
        pointer={save=function(_, desc) s.saves[#s.saves+1]=desc; return desc.chapter_id end,
            load=function(_, path) for i=#s.saves,1,-1 do if s.saves[i].chapter_id==path then return s.saves[i] end end end},
        library={add_manga=function(_, _, manga) s.history[#s.history+1]=manga.chapter_id; return true end},
        pages={cancel_all=function() end, sync_progress=function(_, desc, page) s.progress[#s.progress+1]={desc.chapter_id,page} end},
        async={run=function(work, done) local job={work=work,done=done}; s.jobs[#s.jobs+1]=job; return {cancel=function() job.cancelled=true end} end},
        ui={show_resume=function(_, model) dialog=model; return true end, show_info=function(_, message) error(message) end}}
    s.app.current={feed=feed,feed_url=url,title="S"}
    expect(s.app:_open_entry(source, feed.entries[2]), "entry opens resume chooser")
    expect(dialog.items[1].callback(), "chooser opens B in the real Reader")
    observed.requests[#observed.requests].callbacks.on_ready("/cache/B.jpg",false,{width=600,height=800})
    s.reader, s.observed = reader, observed
    return s
end
for _, direction in ipairs({"previous","next","auto"}) do
    local s=fixture()
    local old_nav=s.reader.context.source_context.navigation
    if direction=="auto" then s.reader.auto_next_series=true; s.reader.position.index=27; s.reader:next_page()
    else s.reader:_open_neighbor(direction) end
    local target=direction=="previous" and "A" or "C"
    expect(s.reader.context and s.reader.context.chapter.chapter_id==target,
        direction .. " must reopen its intended chapter after real Reader teardown")
    expect(s.closes==1 and #s.saves==2 and s.saves[2].chapter_id==target, "one close and one target pointer")
    s.observed.requests[#s.observed.requests].callbacks.on_ready("/cache/target.jpg",false,{width=600,height=800})
    expect(#s.history==2 and s.history[2]==target and #s.progress==2 and s.progress[2][1]==target,
        "target first-page history and server progress occur once")
    expect(not old_nav:open("next") and #s.saves==2, "retired navigation cannot reopen")
    s.reader:force_close("plugin_teardown")
    expect(s.closes==2 and not s.reader.context, "ordinary exit closes without opening another chapter")
end
for _, close_kind in ipairs({"cancel", "plugin_teardown"}) do
    local s=fixture(true)
    local nav=s.reader.context.source_context.navigation
    if close_kind=="cancel" then
        s.reader:_open_neighbor("next")
        expect(#s.jobs==1 and not s.reader.context and #s.saves==1, "chapter handoff schedules only the adjacent feed")
        local pending=s.jobs[1]
        s.app:cancel()
        local value=pending.work(); pending.done(true,value)
        expect(pending.cancelled and #s.saves==1 and not s.reader.context,
            "whole-session cancellation rejects late chapter completion")
    else
        s.reader:force_close("plugin_teardown")
        expect(not nav:open("next") and #s.jobs==0, "ordinary close invalidates old OPDS navigation")
    end
end
print(("rebuild_0405_opds_reader_handoff_spec: %d checks"):format(checks))
