local loaded, Resume = pcall(require, "webdavmanga.opds_resume")
assert(loaded, "resume choices module must exist")
local Ui = require("webdavmanga.ui_opds")
local desc = { source_id = "s", series_id = "series", chapter_id = "v1",
    chapter_name = "Volume 1", page_count = 100, server_kind = "komga",
    stream_template = "https://host/api/v1/books/v1/pages/{pageNumber}",
    chapter_order = { "v1", "v2", "v3" } }
local choices = Resume.choices(desc, {chapter_id="v1",page=30},
    {chapter_id="v2",chapter_name="Volume 2",page=2})
assert(#choices == 3 and choices[1].kind == "start" and choices[1].chapter_id == "v1"
    and choices[1].page == 1 and choices[2].kind == "local" and choices[2].page == 30
    and choices[3].kind == "server" and choices[3].label:find("Volume 2",1,true),
    "choices must keep clicked start, local, then proven later server chapter")
assert(not pcall(function() choices[1].page = 99 end), "actions must be immutable")
assert(#Resume.choices(desc) == 1, "no progress offers only clicked chapter start")
for _, page in ipairs({1, 29, 30, 31, 35}) do
    assert(#Resume.choices(desc, {chapter_id="v1",page=30}, {chapter_id="v1",page=page}) == 2,
        "server behind or within five-page preload tolerance must not prompt")
end
assert(#Resume.choices(desc, {chapter_id="v1",page=30}, {chapter_id="v1",page=36}) == 3)
assert(#Resume.choices(desc, {chapter_id="v2",page=20}, {chapter_id="v1",page=99}) == 2)
assert(#Resume.choices(desc, nil, {chapter_id="unproven",chapter_name="Later",page=90}) == 1,
    "unknown chapter order must not guess that server is ahead")
assert(#Resume.choices(desc, nil, {chapter_id="v1",page=9}) == 2)
assert(desc.chapter_id == "v1" and desc.page_count == 100, "choices must not mutate input")
local chapters = {{chapter_id="v1",is_read=true},{chapter_id="v2",is_read=false}}
assert(Resume.series_target(chapters, {chapter_id="v1",page=90}).chapter_id == "v2")
chapters[2].is_read = nil
assert(Resume.series_target(chapters, {chapter_id="v1",page=90}).chapter_id == "v1")
assert(Resume.series_target(chapters) == nil, "unknown unread state must not select first chapter")

local events, model, opened, notices, opened_context = {}, nil, nil, {}, nil
local fail_save, fail_open, fail_library, throw_library = false, false, false, false
local throw_save, fail_load, stored_descriptor = false, false, desc
local busy_save = false
local source = { id="s", server_kind="komga" }
local pointer = {
    save = function(_, descriptor)
        events[#events+1] = "save:" .. descriptor.chapter_id
        if busy_save then return nil,"pointer_busy" end
        if throw_save then error("credential_secret") end
        if fail_save then return nil,"disk_secret" end
        stored_descriptor = descriptor
        return "/p/volume.meguru"
    end,
    load = function() events[#events+1]="load"; if fail_load then return nil end; return stored_descriptor end,
}
local adapter = Ui:new{
    catalog={get=function(_,id) if id == "s" then return source end end},
    reader={open=function(_, context)
        opened_context=context
        events[#events+1]="open"
        if not fail_open then context.source_context.on_first_page() end
        return not fail_open
    end},
    pointer=pointer,
    library={ add_manga=function()
        events[#events+1]="library"
        if throw_library then error("credential_secret") end
        return not fail_library
    end },
    ui={show_resume=function(_, value) model=value end,
        show_info=function(_,text) notices[#notices+1]=text end},
}
adapter.open_descriptor = function(_, descriptor, received_source, options)
    opened={descriptor=descriptor,source=received_source,options=options}
    return Ui.open_descriptor(adapter, descriptor, received_source, options)
end
for _,cancel in ipairs({"on_cancel","on_outside","on_back"}) do
    adapter:request_open(desc,source,{local_position={chapter_id="v1",page=30}})
    assert(#events==0,"showing choices must not persist anything")
    local stale=model.items[1].callback
    model[cancel]()
    stale()
    assert(#events==0,"cancel/outside/back invalidates all stale action callbacks")
end
adapter:request_open(desc,source,{})
fail_save=true
model.items[1].callback()
assert(table.concat(events,",")=="save:v1", "pointer failure must prevent reader/library/history handoff")
assert(not notices[#notices]:find("secret",1,true))
events={};fail_save=false;busy_save=true
adapter:request_open(desc,source,{})
model.items[1].callback()
assert(table.concat(events,",")=="save:v1", "busy publication never reaches Reader or history")
assert(notices[#notices]:find("重试",1,true) and notices[#notices]:find("完全退出 KOReader",1,true)
    and notices[#notices]:find(".meguru-publish.lock",1,true), "busy pointer explains retry and safe abandoned-lock recovery")
busy_save=false
events={};fail_save=false;fail_open=true
adapter:request_open(desc,source,{})
model.items[1].callback()
assert(table.concat(events,",")=="save:v1,load,open", "failed handoff must not add visible shelf records")
events={};fail_open=false
adapter:request_open(desc,source,{local_position={chapter_id="v1",page=30}})
model.items[2].callback()
assert(table.concat(events,",")=="save:v1,load,open,library" and opened.options.page==30)
assert(opened_context.resume_local==true,"OPDS local continue must distinguish saved strip position from page-start actions")
model.items[1].callback()
assert(#events==4,"double callbacks must not save or open twice")
for _,throws in ipairs({false,true}) do
    events={};fail_library=true;throw_library=throws
    adapter:request_open(desc,source,{})
    assert(model.items[1].callback() == true, "library failure must not undo successful reader handoff")
    assert(table.concat(events,",")=="save:v1,load,open,library")
    assert(not notices[#notices]:find("secret",1,true))
end
events={};fail_library=false;throw_library=false
adapter:request_open(desc,source,{local_position={chapter_id="v1",page=30},
    server_position={chapter_id="v2",chapter_name="Volume 2",page=2},
    resolve_chapter=function(id)
        assert(id=="v2")
        local target={};for k,v in pairs(desc) do target[k]=v end
        target.chapter_id,target.chapter_name="v2","Volume 2"
        return target
    end})
model.items[3].callback()
assert(table.concat(events,",")=="save:v2,load,open,library"
    and opened.descriptor.chapter_id=="v2" and opened.options.page==2,
    "server continue must save/open its proven target chapter, not the clicked chapter")
events={};throw_save=true
adapter:request_open(desc,source,{})
model.items[1].callback()
assert(table.concat(events,",")=="save:v1","pointer exception must not reach handoff or shelf")
events={};throw_save=false;fail_load=true
adapter:request_open(desc,source,{})
model.items[1].callback()
assert(table.concat(events,",")=="save:v1,load","readback failure must not reach handoff or shelf")
events={};fail_load=false
adapter:request_open(desc,source,{})
local replaced=model
adapter:_begin_navigation()
replaced.items[1].callback()
assert(#events==0,"navigation cancels pending resume actions")
-- KOReader's ButtonDialog invokes tap_close_callback for both Back and an
-- outside tap (upstream frontend/ui/widget/buttondialog.lua:onClose).
local widget={new=function(_,value) return value end}
package.loaded["ui/widget/infomessage"]=widget
package.loaded["ui/widget/menu"]=widget
package.loaded["ui/widget/multiinputdialog"]=widget
package.loaded["ui/widget/buttondialog"]={new=function(_,value)
    value.onClose=function(self) if self.tap_close_callback then self.tap_close_callback() end end
    return value
end}
local shown
package.loaded["ui/uimanager"]={show=function(_,value) shown=value end,close=function() end}
local actual=Ui:new{catalog={},reader={},pointer=pointer}
actual.open_descriptor=adapter.open_descriptor
events={}
actual:request_open(desc,source,{})
local dismissed=shown
dismissed:onClose()
dismissed.buttons[1][1].callback()
assert(#events==0,"real adapter must bind KOReader outside/back dismissal to cancel")
print("rebuild_0405_opds_resume_spec: passed")
