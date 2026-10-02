local Ui = require("webdavmanga.ui_opds")
local source = {id="s"}
local clicked = {source_id="s",series_id="series",chapter_id="v1",chapter_name="One",page_count=27,
    server_kind="komga",stream_template="https://host/page/{pageNumber}"}
local function copy(value) local result={};for k,v in pairs(value) do result[k]=v end;return result end
local model, saved, opened
local loaded_count
local ui = Ui:new{catalog={},reader={},pointer={
    save=function(_,d) saved=copy(d);return "/p/book.meguru" end,
    load=function() local d=copy(saved);if loaded_count~=nil then d.page_count=loaded_count end;return d end},
    ui={show_resume=function(_,m) model=m end,show_info=function() end}}
ui.open_descriptor=function(_,d,_,options) opened={descriptor=d,page=options.page};return true end
local cases = {
    {kind="local",id="v1",page=90,count=27,want=27},
    {kind="local",id="v2",page=90,count=7,want=7},
    {kind="server",id="v2",page=90,count=8,want=8},
}
for _,case in ipairs(cases) do
    opened=nil
    local options={chapter_order={"v1","v2"},resolve_chapter=function(id)
        local d=copy(clicked);d.chapter_id=id;d.page_count=case.count;return d end}
    options[case.kind.."_position"]={chapter_id=case.id,chapter_name="Target",page=case.page}
    ui:request_open(clicked,source,options)
    local action
    for _,item in ipairs(model.items) do if item.kind==case.kind then action=item end end
    assert(action and action.callback())
    assert(opened and opened.page==case.want and opened.descriptor.chapter_id==case.id,
        "resume page must fit the resolved target chapter: "..case.kind..":"..case.id)
end
loaded_count=4
ui:request_open(clicked,source,{local_position={chapter_id="v1",page=90}})
model.items[2].callback()
assert(opened.page==4,"readback page_count must be checked after pointer load")
loaded_count=100
ui:request_open(clicked,source,{local_position={chapter_id="v1",page=90}})
model.items[2].callback()
assert(opened.page==27,"a stale longer pointer must not overrun the freshly resolved shorter chapter")
for _,invalid in ipairs({0,-1,1.5,100001,math.huge,"27"}) do
    loaded_count=invalid;opened=nil
    ui:request_open(clicked,source,{local_position={chapter_id="v1",page=90}})
    assert(model.items[2].callback()==false and opened==nil,"invalid readback page count must fail closed")
end
loaded_count=nil
local invalid_target=copy(clicked);invalid_target.page_count=0
opened=nil;saved=nil
assert(ui:request_open(invalid_target,source,{})==false and not saved and not opened,
    "invalid resolved count must fail before pointer save")
invalid_target.page_count=nil;invalid_target.server_last_read=10
local ok,result=pcall(ui.request_open,ui,invalid_target,source,{})
assert(ok and result==false and not saved and not opened,
    "missing clicked page count must fail closed before computing server resume choices")
print("rebuild_0405_opds_resume_bounds_spec: passed")
