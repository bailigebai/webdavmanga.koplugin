-- Exercise the production OPDS adapter through Menu:onMenuSelect, rather than
-- calling its row callback directly. KOReader selects a row and then invokes
-- close_callback; the latter must remain reserved for explicit user navigation.
local Ui = require("webdavmanga.ui_opds")
local checks = 0
local function expect(value, message) checks=checks+1;assert(value,message) end
local native_select = function(self, item)
    if item.select_enabled == false then return true end
    if item.select_enabled_func and not item.select_enabled_func() then return true end
    self:onMenuChoice(item)
    if self.close_callback then self.close_callback() end
    return true
end
-- Optional local integration uses the actual method exported from this Kindle.
-- No KOReader source is copied into the plugin or its ordinary CI fixtures.
local native_path=os.getenv("KOREADER_NATIVE_MENU")
if native_path then
    local file=assert(io.open(native_path,"rb"))
    local source=file:read("*a"):gsub("\r\n","\n");file:close()
    local body=assert(source:match("function Menu:onMenuSelect%(item%)\n(.-)\nend"))
    native_select=assert(loadstring("return function(self,item)\n"..body.."\nend"))()
end
local Menu={onMenuSelect=native_select}
function Menu:onMenuChoice(item) if item.callback then item.callback() end;return true end
function Menu:new(model) return setmetatable(model,{__index=self}) end
function Menu:onClose() self.manager:close(self);return self.close_callback() end
local Widget={new=function(_,model)return model end}
package.loaded["ui/widget/menu"]=Menu
package.loaded["ui/widget/infomessage"]=Widget
package.loaded["ui/widget/multiinputdialog"]=Widget
package.loaded["ui/widget/buttondialog"]=Widget
local manager={shown={},closed={}}
function manager:show(widget) widget.manager=self;self.shown[#self.shown+1]=widget end
function manager:close(widget) self.closed[widget]=true end
package.loaded["ui/uimanager"]=manager

local source={id="source",kind="opds",server_kind="suwayomi",
    url="https://fixture.invalid/api/opds/v1.2"}
local root={title="Root",entries={}}
local chapter_url=source.url.."/manga/7"
local image_url="https://fixture.invalid/api/v1/manga/7/chapter/9/page/{pageNumber}"
local chapter={id="urn:chapter:9",name="Chapter",kind="volume",
    href=source.url.."/chapter/9",stream={template=image_url,count=20}}
local metadata={title="Metadata",author="Suwayomi",entries={chapter}}

local function fixture(deferred,needs_metadata)
    manager.shown,manager.closed={},{}
    local s={jobs={},saves=0,opened=0,returns=0,fetches=0,infos=0}
    local descriptor
    local selected={}
    for key,value in pairs(chapter) do selected[key]=value end
    if needs_metadata then selected.stream=nil end
    local feed={title="Series",author="Suwayomi",entries={selected}}
    s.app=Ui:new{
        catalog={active=function()return source end,get=function()return source end,
            fetch=function(_,_,url)
                s.fetches=s.fetches+1
                if url==chapter_url then return feed end
                if url==selected.href then return metadata end
                return root
            end},
        reader={open=function(_,context)s.opened=s.opened+1;s.context=context;return true end},
        pointer={save=function(_,value)s.saves=s.saves+1;descriptor=value;return "fixture" end,
            load=function()return descriptor end},
        async={run=function(work,done)
            if deferred then
                local job={work=work,done=done};s.jobs[#s.jobs+1]=job
                return {cancel=function()job.cancelled=true end}
            end
            done(true,work());return {cancel=function()end}
        end},network_manager={willRerunWhenConnected=function()return false end},
        driver={resolve=function(_,_,entry,details)
            if not entry.stream and not details then return nil,"metadata_required" end
            return {source_id=source.id,server_kind="suwayomi",series_id="7",series_name="Series",
                chapter_id="9",chapter_name="Chapter",page_count=20,stream_template=image_url}
        end},
    }
    local original_info=s.app.ui.show_info
    s.app.ui.show_info=function(...)s.infos=s.infos+1;return original_info(...)end
    s.app:_show_feed(source,feed,"Series",function()
        s.returns=s.returns+1;return s.app:open_url(source,source.url,"Root")
    end,
        chapter_url,nil,{series_id="7",series_name="Series",series_feed_url=chapter_url})
    s.menu=s.app.ui.current_menu
    for _,item in ipairs(s.menu.item_table) do if item.text=="Chapter" then s.row=item end end
    assert(s.row,"fixture must select a chapter row, rather than the series shortcut")
    return s
end

do
    local s=fixture(true,true)
    s.menu:onMenuSelect(s.row)
    s.menu:onMenuSelect(s.menu.item_table[#s.menu.item_table])
    expect(s.returns==1 and s.jobs[1].cancelled,"the explicit return row still retires its pending request")
    s.menu:onClose()
    expect(s.returns==1,"closing an already replaced menu cannot return a second time")
end

do
    local s=fixture(false,false)
    s.menu:onMenuSelect(s.row)
    expect(s.returns==0,"choosing a chapter must not invoke its parent-directory return callback")
    local dialog=manager.shown[#manager.shown]
    expect(dialog.buttons and s.app.current.feed.title=="Series","chapter selection keeps the series and shows resume choices")
    dialog.buttons[1][1].callback()
    expect(s.opened==1 and s.saves==1,"the selected resume choice must save and open its chapter exactly once")
    expect(s.context.chapter_index:count()==20 and s.context.source_context.opds,
        "production adapter hands the OPDS index to the reader")
    dialog.buttons[1][1].callback()
    expect(s.opened==1 and s.saves==1,"repeated resume events cannot reopen the chapter")
end

do
    local s=fixture(true,true)
    s.menu:onMenuSelect(s.row)
    expect(s.returns==0 and #s.jobs==1 and not s.jobs[1].cancelled,
        "choosing a metadata chapter keeps its async request alive")
    s.jobs[1].done(true,s.jobs[1].work())
    local dialog=manager.shown[#manager.shown]
    expect(dialog.buttons,"metadata completion must show the resume dialog")
    dialog.buttons[1][1].callback()
    expect(s.opened==1 and s.saves==1,"metadata chapter opens after a real row selection")
end

do
    local s=fixture(true,true)
    s.menu:onMenuSelect(s.row)
    s.menu:onClose()
    expect(s.returns==1 and s.jobs[1].cancelled,"explicit Back closes the menu and cancels pending metadata")
    local count=#manager.shown
    s.jobs[1].done(true,s.jobs[1].work())
    expect(#manager.shown==count and s.opened==0,"late metadata after Back cannot open a dialog or reader")
end

do
    local s=fixture(false,false)
    s.menu:onMenuSelect(s.row)
    local dialog=manager.shown[#manager.shown]
    dialog.tap_close_callback()
    dialog.buttons[1][1].callback()
    expect(s.opened==0 and s.saves==0,"cancelled resume actions cannot write a pointer or open a reader")
    s.menu:onMenuSelect(s.row)
    manager.shown[#manager.shown].buttons[1][1].callback()
    expect(s.opened==1,"a cancelled chooser leaves its chapter menu available for another selection")
end

do
    local s=fixture(false,false)
    s.row.select_enabled=false
    local count=#manager.shown
    s.menu:onMenuSelect(s.row)
    expect(#manager.shown==count and s.returns==0,"disabled rows neither open nor navigate back")
    s.row.select_enabled=nil
    s.row.select_enabled_func=function()return false end
    s.menu:onMenuSelect(s.row)
    expect(#manager.shown==count and s.returns==0,"dynamic selection eligibility is preserved")
    s.menu:onMenuSelect({text="Loading"})
    expect(s.returns==0,"a loading row without an action does not navigate back")
    local old=s.menu
    s.row.select_enabled_func=nil
    s.app:open_url(source,source.url,"Root")
    count=#manager.shown
    old:onMenuSelect(s.row)
    expect(#manager.shown==count and s.opened==0,"a replaced menu cannot execute its old row")
end

print("rebuild_0413_opds_menu_selection_spec: "..checks.." checks")
