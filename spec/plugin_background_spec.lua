-- Exercise real plugin entry dispatch and Browser ownership; IO/window edges are injected.
local Widget={}
function Widget:extend(definition) definition.__index=definition;return definition end
package.preload["ui/widget/container/widgetcontainer"]=function() return Widget end
package.preload["datastorage"]=function() return {} end
package.preload["dispatcher"]=function() return {} end
package.preload["luasettings"]=function() return {} end
package.preload["logger"]=function() return {warn=function() end} end
local Plugin=require("main")
local Browser=require("webdavmanga.ui_browser")
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture(kind)
    local f={events={},calls={},queue={}}
    local function event(name) f.events[#f.events+1]=name end
    local function opened(name) f.calls[name]=f.surface~=nil;event(name);return true end
    local connection={kind=kind or "webdav",root_path="/m"}
    local settings={get_connection=function() return connection end,is_configured=function() return true end,
        get_browser_path=function() return "/m/nested" end,get_reader=function() return {} end}
    local plugin=setmetatable({settings=settings},Plugin);f.plugin=plugin
    plugin.error_reporter={guard=function(_,label,callback,fallback)
        local ok,result=pcall(callback);if ok then return result end
        f.error=label..": "..tostring(result);return fallback
    end}
    plugin.settings_ui={close_all=function() event("settings close");return true end}
    for _,name in ipairs({"connection","reader","light","cache","about"}) do
        plugin.settings_ui["show_"..name]=function() return opened(name) end
    end
    plugin.reader={force_close=function(_,reason) event("reader close");f.reader_close_reason=reason end}
    plugin.library_ui={cancel=function() event("library close") end}
    for _,name in ipairs({"offline_shelf","home","rating_home"}) do
        plugin.library_ui["show_"..name]=function() return opened(name) end
    end
    plugin.opds_ui={show_home=function() return opened("opds") end,cancel=function() event("opds close") end,
        open_descriptor=function() return opened("pointer") end}
    plugin.document_bridge={cancel_all=function() event("document cancel") end}
    plugin.offline_manager={cancel_all=function() event("offline task cancel");return false end}
    plugin.cover_grid={cancel=function() event("history grid close") end}
    plugin.browser=Browser:new{settings=settings,settings_ui=plugin.settings_ui,open_reader=function() end,
        directory_store={load=function(_,_,callbacks) f.pending=callbacks;return {cancel=function() end} end},
        on_session_end=function() return plugin:_close_ui_session() end,
        ui={show_background=function(_,model) f.surface=model;event("background show") end,
            close_background=function() event("background close");f.surface=nil end,
            close_menu=function() event("browser close") end,show_info=function() end,show_menu=function() end}}
    return f
end
local f=fixture("opds")
f.plugin.browser.navigation_path="/m/old-webdav-folder"
f.plugin:onShowWebDavManga()
expect(f.calls.opds,"opening OPDS directly establishes the plugin background before any window")
expect(not f.plugin.browser.navigation_path,"external OPDS entry forgets the background Back route of an old WebDAV directory")
expect(f.events[1]=="background show","background precedes cancellation and frontend transitions")
local menu={};f.plugin:addToMainMenu(menu);local entries=menu.webdavmanga.sub_item_table_func()
for _,entry in ipairs(entries) do
    if entry.text~="漫画书架" and entry.text~="阅读历史" then entry.callback() end
end
for _,name in ipairs({"connection","reader","light","cache","about","offline_shelf","home","rating_home"}) do
    expect(f.calls[name],"direct "..name.." entry remains inside the plugin surface")
end
local surfaces=0;for _,name in ipairs(f.events) do if name=="background show" then surfaces=surfaces+1 end end
expect(surfaces==1,"all entry paths share one background instead of stacking surfaces")
f.plugin.browser:end_session()
expect(not f.surface and f.events[#f.events]=="background close","explicit exit closes all foreground windows before the background")
expect(f.reader_close_reason=="plugin_teardown","session exit suppresses deferred reader return navigation")
for _,name in ipairs({"settings close","reader close","opds close","library close","document cancel","history grid close","offline task cancel"}) do
    local found=false;for _,value in ipairs(f.events) do if value==name then found=true end end
    expect(found,"session exit owns "..name)
end
f.plugin:onShowWebDavManga();expect(f.surface and f.calls.opds,"a UI session exit does not permanently stop the plugin")
local isolated=fixture();local isolated_menu={};isolated.plugin:addToMainMenu(isolated_menu)
isolated_menu.webdavmanga.sub_item_table_func()
expect(not isolated.surface,"constructing KOReader's menu alone must not cover the host")
local pointer=fixture("opds")
pointer.plugin.meguru_pointer={load=function() return {source_id="opds"} end}
pointer.plugin.settings.get_source=function() return {kind="opds"} end
pointer.plugin:open_pointer("book.meguru")
expect(pointer.calls.pointer,"opening an associated reading pointer retains the plugin background")
-- A standalone settings session must not treat an old saved folder as a loading route.
local settings_entry=fixture();local settings_menu={};settings_entry.plugin:addToMainMenu(settings_menu)
for _,entry in ipairs(settings_menu.webdavmanga.sub_item_table_func()) do
    if entry.text=="阅读设置" then entry.callback() end
end
settings_entry.surface.on_back()
expect(not settings_entry.surface and not settings_entry.pending,"Back from standalone settings exits without reopening a stale directory")
expect(not f.error and not pointer.error and not settings_entry.error,"all routes complete without hidden callback errors")
local refused=fixture();refused.plugin:onShowWebDavManga()
refused.plugin.settings_ui.close_all=function() return false end
expect(refused.plugin.browser:end_session()==false and refused.surface,
    "a failed foreground close keeps the background for a safe retry")
refused.plugin.settings_ui.close_all=function() return true end
expect(refused.plugin.browser:end_session() and not refused.surface,"retrying a failed UI close can finish cleanly")
local stopping=fixture("opds");stopping.plugin:onShowWebDavManga()
for _,key in ipairs({"cover","loader","memory_pages","opds_pages","offline_manager","directory_store"}) do
    stopping.plugin[key]={cancel_all=function() stopping.events[#stopping.events+1]=key.." cancel" end}
end
stopping.plugin._flush_stores=function() return true,{} end
expect(stopping.plugin:onExit() and not stopping.error,"host exit closes an active plugin session without callback errors")
expect(stopping.events[#stopping.events]=="background close","host teardown releases the background after OPDS/library/settings and reader")
print(("plugin_background_spec: %d checks"):format(checks))
