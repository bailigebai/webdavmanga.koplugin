-- Real settings controller, dialog adapter, and registry; only native widgets/IO are injected.
local windows={}
local function widget_class(kind)
    return {new=function(_,model)
        model.kind=kind;model.getFields=function()return {"2345-6789-ABCD"}end;return model
    end}
end
for _,name in ipairs({"buttondialog","confirmbox","infomessage","multiinputdialog"}) do
    package.preload["ui/widget/"..name]=function()return widget_class(name)end
end
package.preload["ui/uimanager"]=function()return {
    show=function(_,w)windows[#windows+1]=w end,
    close=function(_,w)for i=#windows,1,-1 do if windows[i]==w then table.remove(windows,i)end end end,
}end
package.preload["webdavmanga.dialog_keyboard"]=function()return {
    with_top_button=function(model)return model end,show=function()end,hide=function()end,
}end
local UiSettings=require("webdavmanga.ui_settings")
local checks=0;local function expect(v,m)checks=checks+1;assert(v,m)end
local function press(dialog,text)
    for _,row in ipairs(dialog.buttons)do for _,button in ipairs(row)do
        if button.text==text then return button.callback()end
    end end
    error("missing button: "..text)
end
local canceled,resumed,done=0,0,nil
local controller=UiSettings:new{settings={},cache={},client_factory=function()return {}end,async={}}
local function open_license()
    controller:show_license{activate=function(_,callback)
        done=callback;return {cancel=function()canceled=canceled+1 end}
    end,on_result=function(ok)if ok then resumed=resumed+1 end end}
    press(windows[#windows],"激活")
    return done
end
local old_done=open_license();controller:close_all()
expect(canceled==1 and #windows==0,"session exit cancels activation and closes every license window")
old_done(true,{authorized=true})
expect(resumed==0 and #windows==0,"late activation cannot resume reading or reopen a popup after exit")
local fresh_done=open_license();old_done(true,{authorized=true})
expect(resumed==0,"an old activation cannot affect a newly opened session")
fresh_done(true,{authorized=true})
expect(resumed==1,"fresh activation can resume its own reading request")
controller:close_all();expect(canceled==1,"finished activation is not retained as a pending worker")
local old_complete,infos=nil,{}
local cache_controller=UiSettings:new{settings={},cache={},async={},client_factory=function()return {}end,
    ui={show_info=function(_,text)infos[#infos+1]=text end,close_all=function()return true end},
    offline_manager={start=function(_,_,callbacks)old_complete=callbacks.on_complete;return {}end}}
cache_controller:_start_offline_cache{path="/Comics",title="Comic"}
cache_controller:close_all();old_complete{status="complete",completed=1}
expect(#infos==1,"offline completion cannot reopen UI after its originating session exits")
cache_controller:_start_offline_cache{path="/New",title="New"}
old_complete{status="complete",completed=1}
expect(#infos==3,"fresh cache work still reports its own completion")
print(("settings_session_exit_spec: %d checks"):format(checks))
