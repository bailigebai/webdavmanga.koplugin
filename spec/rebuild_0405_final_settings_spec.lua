local Settings=require("webdavmanga.settings")
local Ui=require("webdavmanga.ui_settings")
local shown,values={},{}
for _,name in ipairs({"buttondialog","multiinputdialog","infomessage","confirmbox"}) do
    package.loaded["ui/widget/"..name]={new=function(_,model)
        model.getFields=function(self) local fields={};for _,field in ipairs(self.fields or {}) do fields[#fields+1]=field.text end;return fields end
        return model
    end}
end
package.loaded["ui/uimanager"]={show=function(_,m) shown[#shown+1]=m end,close=function() end}
local store={readSetting=function(_,k,f) if values[k]==nil then return f end;return values[k] end,
    saveSetting=function(_,k,v) values[k]=v end,flush=function() return true end}
local settings=Settings:new{store=store,default_opds_pointer_root="/data/streams"}
assert(settings:add_source{kind="opds",name="Server",server_url="https://fixture.invalid/opds"})
local ui=Ui:new{settings=settings,client_factory=function() return {} end,cache={},async={}}
local function click(text)
    for _,row in ipairs(shown[#shown].buttons or {}) do for _,button in ipairs(row) do
        if button.text:find(text,1,true) then return button.callback() end
    end end
    error("missing real widget control: "..text)
end
local failures={}
local function test(name,body) local ok,err=pcall(body); if not ok then failures[#failures+1]=name..": "..tostring(err) end end
test("#10 pointer/cover widget controls save and reload",function()
    ui:show_connection();click("OPDS 指针与封面")
    local form=shown[#shown]
    assert(form.fields and form.fields[1].text=="/data/streams")
    assert(form.subtitle:find("不删除",1,true),"cover toggle must explain existing sidecars remain")
    form.fields[1].text="/books/streams"; click("按服务器建立子目录")
    click("保存系列封面"); click("保存设置")
    local restored=Settings:new{store=store}:get_reader()
    assert(restored.opds_pointer_root=="/books/streams" and restored.opds_pointer_per_server==false and restored.opds_cover_enabled==false,
        "real settings controls failed durable save/reload")
    ui:show_connection();click("OPDS 指针与封面")
    shown[#shown].fields[1].text="../escape";click("保存设置")
    assert(settings:get_reader().opds_pointer_root=="/books/streams","invalid pointer root was persisted")
end)
test("#13 final source warning is source-neutral",function()
    ui:show_connection();click("删除当前连接")
    assert(shown[#shown].ok_callback,"real confirmation model")
    shown[#shown].ok_callback()
    assert(shown[#shown].text=="至少保留一个连接。","warning still claims all sources are WebDAV")
end)
assert(#failures==0,table.concat(failures,"\n"))
print("rebuild_0405_final_settings_spec: actual widgets, persistence, validation and final source warning passed")
