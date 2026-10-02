local Ui = require("webdavmanga.ui_opds")
local requests, jobs, shown = {}, {}, {}
local source={id="s",name="Source",url="https://fixture.invalid/opds",server_kind="suwayomi"}
local async={run=function(work, done)
    local j={work=work,done=done}; function j:cancel() self.cancelled=true end
    jobs[#jobs+1]=j; return j
end}
local catalog={get=function() return source end,active=function() return source end,set_active=function() end,
    fetch=function(_,id,url)
        requests[#requests+1]=url
        return {entries={},title="Result"}
    end}
local ui=Ui:new{catalog=catalog,async=async,reader={},ui={show_menu=function(_,m) shown[#shown+1]=m; return true end,
    close_menu=function() end,show_info=function() end}}
local function complete(j, failure)
    if failure then return j.done(false,nil,"private transport failure") end
    j.done(true,{feed=j.work().feed})
end
assert(ui:show_home(),"public catalog action schedules work")
assert(#requests==0 and #jobs==1,"#8 catalog callback must return before transport runs")
local first=jobs[1]
ui:open_url(source,"https://fixture.invalid/next","Next")
assert(first.cancelled,"#8 switching feed cancels the actual request handle")
complete(jobs[2]); local current=ui.current
complete(first)
assert(ui.current==current,"#8 late prior success cannot replace current menu")
ui:show_home(); local pending=jobs[#jobs]; local menu=shown[#shown]
menu.on_back()
assert(pending.cancelled,"#8 pending root back cancels request")
local count=#shown; complete(pending,true)
assert(#shown==count,"#8 late error after back cannot reopen a menu")
ui:show_home(); pending=jobs[#jobs]; ui:cancel(); count=#shown
complete(pending)
assert(pending.cancelled and #shown==count and not ui.current,"#8 close/source switch makes late success inert")
-- The initial series request adds ascending order; server-issued next URLs are
-- exact navigation routes and retain their token order.
ui:open_url(source,source.url,"Root"); complete(jobs[#jobs])
ui.current.feed={entries={}}
ui:_open_entry(source,{id="urn:suwayomi:manga:1",name="Series",kind="series",href="https://fixture.invalid/chapters?filter=unread&sort=number_desc"})
assert(#requests==4,"#9 initial chapter request remains deferred")
complete(jobs[#jobs])
assert(requests[#requests]=="https://fixture.invalid/chapters?filter=unread&sort=number_asc","#9 initial chapter list requests numeric ascending order")
local next_url="https://fixture.invalid/chapters?cursor=a%2Bb&sort=server&filter=unread"
ui:_show_feed(source,{entries={},next_url=next_url},"Series",nil,requests[#requests],nil,{series_id="urn:suwayomi:manga:1"})
shown[#shown].items[1].callback(); complete(jobs[#jobs])
assert(requests[#requests]==next_url,"#9 server pagination URL remains byte-for-byte unchanged")
print("rebuild_0405_final_async_spec: scheduled cancellation, stale results and initial sort passed")
