-- Regression: an already-closed real CoverGrid must not block confirmed exit.
-- KOReader windows and IO are the boundary; Main, Browser, Grid and Registry are real.
local Widget={}
function Widget:extend(def) def.__index=def;return def end
package.loaded['ui/widget/container/widgetcontainer']=Widget
package.loaded.datastorage={};package.loaded.dispatcher={};package.loaded.luasettings={}
package.loaded.logger={warn=function() end}
local manager={_window_stack={},closed={}}
function manager:show(widget) self._window_stack[#self._window_stack+1]={widget=widget} end
function manager:close(widget)
    for i=#self._window_stack,1,-1 do
        if self._window_stack[i].widget==widget then table.remove(self._window_stack,i) end
    end
    self.closed[#self.closed+1]=widget
end
package.loaded['ui/uimanager']=manager
for _,kind in ipairs({'infomessage','confirmbox'}) do
    package.loaded['ui/widget/'..kind]={new=function(_,model) model.kind=kind;return model end}
end
package.loaded['ui/widget/menu']={getItemFontSize=function() return 20 end,new=function(_,model)
    model.title_bar={right_button={}}
    return model
end}
package.loaded['webdavmanga.ui_background']={new=function(model) model.kind='background';return model end}
package.loaded['webdavmanga.bookshelf_toolbar']={new=function(model) return model end}
local Main=require('main')
local Browser=require('webdavmanga.ui_browser')
local Grid=require('webdavmanga.ui_cover_grid')
local Reporter=require('webdavmanga.error_reporter')
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture(mode,path)
    local f={errors={}}
    local host={kind='host'};f.host=host
    manager._window_stack={{widget=host}};manager.closed={}
    local settings={get_connection=function() return {root_path='/m',kind='webdav'} end,
        is_configured=function() return true end,get_browser_path=function() return path end,
        set_browser_path=function() return true end,flush=function() end,
        get_bookshelf_view=function() return mode end,get_reader=function() return {grid_columns=3} end}
    local function grid()
        local visible
        return Grid:new{cover_service={},loader={},cache={},settings=settings,
            connection_provider=settings.get_connection,scheduler={},
            ui={show_grid=function(_,model) visible=model;manager:show(model) end,
                close_grid=function() if visible then manager:close(visible);visible=nil end end}}
    end
    f.history=grid();f.shelf=grid()
    f.plugin=setmetatable({cover_grid=f.history},Main)
    f.plugin.error_reporter=Reporter:new{logger={err=function(_,label,_,detail)
        f.errors[#f.errors+1]=label..': '..detail
    end}}
    f.plugin.settings_ui={close_all=function() return true end}
    f.plugin.reader={force_close=function() return true end}
    f.plugin.library_ui={cancel=function() return true end}
    f.plugin.document_bridge={cancel_all=function() end}
    local empty={count=function() return 0 end,iterator=function() return {},1 end}
    local folder={name='book',path=path..'/book',is_folder=true}
    local folders={count=function() return 1 end,get=function() return folder end,
        iterator=function() return {folder},1 end}
    local directory={folders=function() return folders end,images=function() return empty end,
        documents=function() return empty end,file_count=function() return 0 end,close=function() end}
    local store={load=function(_,_,cb) cb.on_ready(directory);return {cancel=function() end} end}
    f.browser=Browser:new{settings=settings,settings_ui=f.plugin.settings_ui,directory_store=store,
        bookshelf_directory_store=store,bookshelf_grid=f.shelf,cover_grid=f.history,
        open_reader=function() end,error_reporter=f.plugin.error_reporter,
        on_session_end=function() return f.plugin:_close_ui_session() end}
    f.browser:show_library(false,path)
    assert(#f.errors==0,table.concat(f.errors,'; '))
    f.background=manager._window_stack[2].widget
    return f
end
local function request_close(f)
    if f.browser.ui.current_menu then f.browser.ui.current_menu.title_bar.right_button.callback()
    else manager._window_stack[#manager._window_stack].widget.on_close() end
    local dialog=manager._window_stack[#manager._window_stack].widget
    expect(dialog.kind=='confirmbox','visible X must request confirmation')
    return dialog
end
local function confirm(dialog)
    manager:close(dialog) -- Native ConfirmBox dismisses its own window.
    dialog.ok_callback()
end
for _,mode in ipairs({'list','covers'}) do
    local f=fixture(mode,'/m/nested')
    local cancelled=request_close(f);manager:close(cancelled)
    expect(f.browser.background_open and #manager._window_stack>1,'cancelling confirmation retains the plugin')
    confirm(request_close(f))
    expect(#manager._window_stack==1 and manager._window_stack[1].widget==f.host,
        mode..' confirmation must reveal only KOReader even when history was never opened')
    expect(not f.browser.background_open and #f.errors==0,'inactive grid cancellation is successful teardown')
    expect(manager.closed[#manager.closed]==f.background,'the background is removed last')
    expect(f.browser:end_session() and #manager._window_stack==1,'repeated exit stays harmless')
    f.browser:show_library(false,'/m')
    expect(f.browser.background_open,'a fresh plugin session can open after exit')
    confirm(request_close(f))
    expect(#manager._window_stack==1,'the reopened session can also exit')
end
local active=fixture('list','/m')
active.history:show{items={}}
expect(active.history.is_open,'history is actually open before teardown')
expect(active.browser:end_session() and #manager._window_stack==1,
    'Browser and controller cancelling the same active history grid must still complete exit')
local refused=fixture('list','/m')
refused.plugin.settings_ui.close_all=function() return false end
confirm(request_close(refused))
expect(refused.browser.background_open and #manager._window_stack==2,
    'a real foreground-close failure still retains the safe background')
refused.plugin.settings_ui.close_all=function() return true end
confirm(request_close(refused))
expect(#manager._window_stack==1,'retrying after a foreground-close failure must release the background')
local broken=fixture('list','/m')
local cancel_grid=broken.history.cancel
local attempts=0
broken.history.cancel=function(self)
    attempts=attempts+1
    if attempts==2 then error('grid cancellation raised') end
    return cancel_grid(self)
end
confirm(request_close(broken))
expect(broken.browser.background_open and #broken.errors==1,
    'an actual grid cancellation exception still prevents unsafe background removal')
broken.history.cancel=cancel_grid
confirm(request_close(broken))
expect(#manager._window_stack==1,'grid cancellation exceptions can be retried after recovery')
print(('rebuild_0423_plugin_exit_spec: %d checks'):format(checks))
