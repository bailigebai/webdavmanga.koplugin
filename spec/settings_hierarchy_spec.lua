-- Production Shell with only the native dialog and window-manager boundary injected.
local fixture = dofile('spec/helpers/reader_quadrant_host.lua')
local checks, failures = 0, {}
local function expect(value, message) checks=checks+1; assert(value, message) end
local function test(name, body)
    local ok, err=pcall(body)
    if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function press(dialog, text)
    for _, row in ipairs(dialog.buttons or {}) do for _, button in ipairs(row) do
        if button.text==text then return button.callback() end
    end end
    error('missing button: '..text)
end
local function setup()
    local reader=fixture(false)
    local shell=reader.shell
    local windows={}
    local reject, reject_close=false,false
    package.loaded['ui/widget/multiinputdialog']={new=function(_,model)
        if reject then error('injected input layout failure') end
        model.getFields=function()return {'37'}end
        return model
    end}
    shell.ui_manager.show=function(_,widget) windows[#windows+1]=widget end
    shell.ui_manager.close=function(_,widget)
        if reject_close then return false end
        for i=#windows,1,-1 do if windows[i]==widget then table.remove(windows,i)end end
    end
    shell:show_controls{title='Parent',section='panel_detection',actions={{text='parent option'}}}
    return reader,shell,windows,function(layout,close)reject,reject_close=layout,close end
end
test('input hides parent and returns after cancel',function()
    local _,shell,windows=setup()
    local returned=0
    expect(shell:show_number_input{value=40,on_save=function()return true end,
        on_return=function()
            expect(#windows==0,'close child before restoring parent')
            returned=returned+1
            shell:show_controls{section='panel_detection',actions={{text='fresh parent'}}}
        end},'open input')
    expect(shell.current_model.kind~='controls' and #(shell.current_model.actions or {})==0,
        'the input must hide every parent settings button')
    local dialog=windows[1]
    press(dialog,'← 返回上一级')
    expect(returned==1 and shell.current_model.kind=='controls','return to direct parent')
    press(dialog,'← 返回上一级')
    expect(returned==1,'stale return cannot reopen parent twice')
end)
test('invalid save stays in child; successful save closes then returns',function()
    local _,shell,windows=setup()
    local allow,returned=false,0
    shell:show_number_input{value=40,on_save=function(value)
        expect(value=='37','pass exact typed number')
        return allow
    end,on_return=function()expect(#windows==0,'save closes child first');returned=returned+1 end}
    press(windows[1],'保存')
    expect(#windows==1 and returned==0,'invalid save must retain editor')
    allow=true;press(windows[1],'保存')
    expect(#windows==0 and returned==1,'successful save returns once')
end)
test('replacement and closed reader reject old input callbacks',function()
    local _,shell,windows=setup()
    local saved,returned=0,0
    local model={value=40,on_save=function()saved=saved+1;return true end,
        on_return=function()returned=returned+1 end}
    shell:show_number_input(model);local old=windows[1]
    shell:show_number_input(model)
    press(old,'保存')
    expect(saved==0 and #windows==1,'replaced input must reject stale save')
    local live=windows[1];shell:close_now();press(live,'保存')
    expect(saved==0 and returned==0 and #windows==0,'closed reader cannot save or restore old settings')
end)
test('input layout failure retains visible parent',function()
    local _,shell,_,reject=setup();local parent=shell.current_model
    reject(true,false)
    local ok,result=pcall(shell.show_number_input,shell,{value=40,on_save=function()return true end})
    expect(ok and result==false and shell.current_model==parent,'failed child layout preserves parent without escaping')
end)
test('close rejection keeps editor owned and parent hidden',function()
    local _,shell,windows,reject=setup();local returned=0
    shell:show_number_input{value=40,on_save=function()return true end,on_return=function()returned=returned+1 end}
    reject(false,true);press(windows[1],'← 返回上一级')
    expect(#windows==1 and shell.input_dialog==windows[1] and returned==0,'rejected close must preserve live editor ownership')
    reject(false,false);press(windows[1],'← 返回上一级')
    expect(#windows==0 and returned==1,'close can be retried')
end)
local function settings_setup()
    local reader,shell=setup()
    local windows={}
    local manager=shell.ui_manager
    manager.show=function(_,widget)windows[#windows+1]=widget end
    manager.close=function(_,widget)
        for i=#windows,1,-1 do if windows[i]==widget then table.remove(windows,i)end end
    end
    local function dialog_class()
        return {new=function(_,model)
            model.getFields=function()
                local values={};for _,f in ipairs(model.fields or {}) do values[#values+1]=f.text end
                return values
            end
            return model
        end}
    end
    for _,name in ipairs({'buttondialog','multiinputdialog','infomessage','confirmbox','textviewer'}) do
        local class=dialog_class()
        if name=='buttondialog' then
            local frontend=assert(os.getenv('KOREADER_FRONTEND'))
            local f=assert(io.open(frontend..'/ui/widget/buttondialog.lua','rb'));local source=f:read('*a');f:close()
            local method=assert(source:match('(function ButtonDialog:onClose%(%)\n.-)\nfunction ButtonDialog:onTapClose'))
            local on_close=assert(loadstring('local UIManager=...;local ButtonDialog={};'..method..';return ButtonDialog.onClose'))(manager)
            local new=class.new
            class.new=function(self,model)local dialog=new(self,model);dialog.onClose=on_close;return dialog end
        end
        package.loaded['ui/widget/'..name]=class
    end
    local Settings=require('webdavmanga.settings')
    local UiSettings=require('webdavmanga.ui_settings')
    local data={}
    local settings=Settings:new{store={readSetting=function(_,k,d)return data[k] or d end,
        saveSetting=function(_,k,v)data[k]=v end,flush=function()return true end}}
    local controller=UiSettings:new{settings=settings,cache={},async={},client_factory=function()return{}end,
        lighting={get=function()return {supported=true,intensity=5,intensity_min=0,intensity_max=24}end}}
    return reader,shell,controller,windows
end
test('replacement failure preserves current editor',function()
    local _,shell,windows,reject=setup()
    local saves=0
    local model={value=40,on_save=function()saves=saves+1;return false end}
    shell:show_number_input(model);local old=windows[1]
    reject(true,false)
    expect(shell:show_number_input(model)==false and windows[1]==old and shell.input_dialog==old,
        'failed replacement layout retains old editor')
    reject(false,true)
    expect(shell:show_number_input(model)==false and #windows==1 and shell.input_dialog==old,
        'failed replacement close retains old editor')
    press(old,'保存');expect(saves==1,'retained editor remains usable')
end)
for _,kind in ipairs({'light','reader_help'}) do
    test(kind..' returns once without reviving closed windows',function()
        local _,_,controller,windows=settings_setup();local returned=0
        controller['show_'..kind](controller,function()returned=returned+1 end)
        local child=windows[1]
        if kind=='reader_help' then child:onClose() else press(child,'← 返回上一级') end
        expect(returned==1 and #windows==0,kind..' direct return')
        controller['show_'..kind](controller,function()returned=returned+1 end)
        child=windows[1];controller:close_all()
        if kind=='reader_help' then child:onClose() else press(child,'← 返回上一级') end
        expect(returned==1 and #windows==0,kind..' teardown cancels return')
    end)
end
test('unavailable preview restores preset page',function()
    local _,_,controller,windows=settings_setup()
    controller:show_gray_settings();local title=windows[1].title
    press(windows[1],'预览当前预设')
    expect(windows[#windows].title==title,'preview rejection restores direct parent')
end)
test('global device orientation returns directly to root and preserves image rotation',function()
    local _,_,controller,windows=settings_setup();local angle
    controller.rotate_device=function(value)angle=value;return true end
    local image_rotation=controller.settings:get_reader().panel_rotation
    controller:show_reader();local title=windows[1].title
    local entry
    for _,row in ipairs(windows[1].buttons) do for _,button in ipairs(row) do
        if button.text:find('设备旋转',1,true)==1 then entry=button end
    end end
    expect(entry,'global reading root offers device rotation');entry.callback()
    expect(#windows==1 and windows[1].title=='设备旋转','orientation replaces root')
    press(windows[1],'270°')
    expect(angle==270 and controller.settings:get_reader().panel_rotation==image_rotation,
        'device orientation does not change panel image rotation')
    press(windows[1],'← 返回上一级')
    expect(#windows==1 and windows[1].title==title,'orientation returns directly to root')
end)
test('global choices return through every direct parent with only one settings window',function()
    local _,_,controller,windows=settings_setup()
    controller:show_reader();local root_title=windows[1].title
    windows[1].buttons[1][1].callback();local section=windows[1]
    expect(#windows==1,'global section replaces root')
    section.buttons[1][1].callback()
    expect(#windows==1,'choice replaces section')
    press(windows[1],'← 返回上一级')
    expect(#windows==1 and windows[1].title==section.title,'choice returns to direct section')
    press(windows[1],'← 返回上一级')
    expect(#windows==1 and windows[1].title==root_title,'section returns to root')
end)
for _,kind in ipairs({'gray','tone'}) do
    test(kind..' preset editor and sample path return to live parent',function()
        local _,_,controller,windows=settings_setup()
        local returned=0
        controller['show_'..kind..'_settings'](controller,function()returned=returned+1 end)
        local title=windows[1].title
        press(windows[1],'新增自定义预设')
        expect(#windows==1 and windows[1].fields,'preset editor replaces parent')
        local obsolete=windows[1]
        press(obsolete,'← 返回上一级')
        expect(#windows==1 and windows[1].title==title,'cancel editor returns to preset page')
        local sample
        for _,row in ipairs(windows[1].buttons) do for _,button in ipairs(row) do
            if button.text:find('设置样本目录',1,true)==1 then sample=button end
        end end
        sample.callback();press(windows[1],'← 返回上一级')
        expect(#windows==1 and windows[1].title==title,'sample path returns to preset page')
        press(windows[1],'← 返回上一级')
        expect(#windows==0 and returned==1,'preset page returns to its caller')
        press(obsolete,'保存')
        expect(#windows==0,'closed editor callbacks cannot resurrect settings')
    end)
end
test('reader external settings hide controls and return to live section',function()
    local reader,shell,controller,windows=settings_setup()
    reader.show_gray_settings=function(on_return)return controller:show_gray_settings(on_return)end
    reader:toggle_controls('gray')
    local manage
    for _,action in ipairs(shell.current_model.actions) do
        if action.text:find('管理',1,true) then manage=action end
    end
    expect(manage,'reader offers preset management')
    manage.callback()
    expect(shell.current_model.kind~='controls' and #windows==1,'external settings hide underlying reader controls')
    press(windows[1],'← 返回上一级')
    expect(#windows==0 and shell.current_model.kind=='controls' and shell.current_model.section=='gray',
        'external return rebuilds direct reader parent')
end)
for _,kind in ipairs({'gray','tone'})do
    test(kind..' native dismiss returns to caller once',function()
        local _,_,controller,windows=settings_setup();local returned=0
        local open=controller['show_'..kind..'_settings']
        open(controller,function()returned=returned+1 end);local dialog=windows[1]
        dialog:onClose();expect(returned==1 and #windows==0,'native dismiss must invoke direct return')
        dialog:onClose();expect(returned==1,'stale native dismiss must not return twice')
    end)
end
test('global native section dismiss returns to root',function()
    local _,_,controller,windows=settings_setup();controller:show_reader();local root=windows[1]
    root.buttons[1][1].callback();local child=windows[1]
    child:onClose();expect(#windows==1 and windows[1].title==root.title,'native section close restores root')
end)
test('failed native child construction restores parent',function()
    local _,_,controller,windows=settings_setup();controller:show_reader();local root=windows[1]
    local class=package.loaded['ui/widget/buttondialog'];local new=class.new;local reject=true
    class.new=function(self,model)if reject then reject=false;error('injected child construction failure')end;return new(self,model)end
    root.buttons[1][1].callback()
    expect(#windows==1 and windows[1].title==root.title,'child failure must restore live parent')
    windows[1].buttons[1][1].callback();expect(#windows==1 and windows[1].title~=root.title,'restored parent remains operable')
end)
test('shared panel menu returns to actual caller irrespective of enabled mode',function()
    local reader=fixture(false)
    for _,origin in ipairs({'web','panel'})do
        for _,child in ipairs({'panel_view','panel_advanced'})do
            reader:toggle_controls(origin)
            local action
            for _,item in ipairs(reader.shell.current_model.actions)do
                if (child=='panel_view' and item.text=='分格视图、旋转与方向')or(child=='panel_advanced' and item.text=='更多分格设置')then action=item end
            end
            expect(action and action.callback(),'open shared menu')
            for _,item in ipairs(reader.shell.current_model.actions)do if item.text=='← 返回上一级'then item.callback();break end end
            expect(reader.shell.current_model.section==origin,'return to origin '..origin)
        end
    end
end)
assert(#failures==0,table.concat(failures,'\n'))
print(('settings_hierarchy_spec: %d checks'):format(checks))
