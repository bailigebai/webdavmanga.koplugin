local Reader=require("webdavmanga.ui_reader")
local State=require("webdavmanga.state")
local Detector=require("webdavmanga.panel_detector")
local checks=0
local function expect(value,message) checks=checks+1;assert(value,message) end
local function fixture(options)
    options=options or {}
    local width,height=options.width or 600,options.height or 800
    local f={images={},buffers={},handles={},sources={},notices={},failures={}}
    for i=1,4 do f.images[i]={path="/page"..i..".jpg",width=width,height=height,id=i} end
    local values={direction="normal",fit_mode=options.fit_mode or "page",panel_zoom_enabled=true,
        panel_navigation="horizontal",panel_order="normal",split_enabled=options.split==true}
    local function buffer(id)
        local b={id=id,frees=0,getWidth=function() return width end,getHeight=function() return height end}
        function b:viewport(x,y,w,h)
            return {owner=self,x=x,y=y,w=w,h=h,
                getWidth=function() return w end,getHeight=function() return h end}
        end
        function b:free()
            expect(f.shown~=self,"displayed buffer must be detached before release")
            self.frees=self.frees+1;expect(self.frees==1,"each owned buffer releases exactly once")
        end
        f.buffers[#f.buffers+1]=b;return b
    end
    f.shell={current_model={kind="page"},get_content_size=function() return 600,800 end,
        show_page=function(_,b,viewport,_,change)
            if f.reject_show then return false end
            f.shown,f.viewport,f.change=b,viewport,change;return true
        end,
        show_loading=function() end,show_status=function(_,text) f.notices[#f.notices+1]=text end,
        show_error=function(_,error) f.error=error end,
        free_buffer_later=function(_,b) b:free() end,close_now=function() f.shown=nil;return true end}
    f.reader=Reader:new{
        loader={identity="panels",request=function(_,_,image,callbacks)
            f.last_requested=image.id
            callbacks.on_ready(image.path,false,{width=width,height=height})
        end},
        state=State:new(),settings={get_reader=function() return values end,
            get_connection=function() return {} end,set_reader=function(_,next_values) values=next_values;return true end},
        progress={chapter_id=function() return "panels" end,
            resolve=function() return {index=1,segment="whole"} end,save=function() end},
        cache={key_for=function(_,identity,path) return identity..path end,set_protected=function() end},
        render_image={renderImageFile=function(_,path) return buffer(tonumber(path:match("page(%d)"))) end},
        ui={create_shell=function() return f.shell end,show_shell=function() end},open_chapter=function() f.chapter_prompt=true end,
        panel_source={open=function(_,_,request,callbacks)
            f.sources[#f.sources+1]={page=request.image.id,callbacks=callbacks}
            return {cancel=function() end}
        end},
        panel_detector={sort=Detector.sort,detect=function(raster)
            local reason=f.failures[raster.page]
            if reason then return nil,reason end
            if raster.page==2 or raster.page==3 then return nil,"no_panels" end
            return {{id="left",x=0,y=0,w=.45,h=1},{id="right",x=.55,y=0,w=.45,h=1}}
        end},
    }
    function f:complete()
        local pending=self.sources[#self.sources]
        expect(pending~=nil,"panel recognition must have a source request")
        local h={closed=false,closes=0,detection_raster=function() return {page=pending.page} end,
            render=function(_,panel) return buffer(tostring(pending.page).."/"..panel.id) end}
        function h:close() self.closed=true;self.closes=self.closes+1 end
        self.handles[#self.handles+1]=h
        pending.callbacks.on_ready(h)
        return pending,h
    end
    function f:close()
        self.reader:force_close("back")
        for _,b in ipairs(self.buffers) do expect(b.frees==1,"all owned frames release after reader close") end
        for _,h in ipairs(self.handles) do expect(h.closes==1,"panel handles close once") end
    end
    f.reader:open{manga={},chapter={},chapter_index={count=function() return 4 end,
        get=function(_,i) return f.images[i] end}}
    return f
end
local function reach_miss(f)
    local r=f.reader
    r:enter_panel_mode("first");f:complete();r:next_page();r:next_page();f:complete()
    expect(r.position.index==2 and f.shown.id==2,"a no-panel page remains visible as its full physical page")
    expect(r.panel_entry~=nil and r.panel_session==nil,"a no-panel page retains panel reading intent without a failed session")
end

do
    local f=fixture();local r=f.reader
    reach_miss(f)
    expect(r:set_panel_option("panel_view","free"),"free view can be selected on the undetected current page")
    f:complete()
    expect(r.panel_session and r.panel_session:is_active() and r.panel_session.render_options.view=="free"
        and not r.panel_entry.whole_page,"fallback-to-free must create a real camera session immediately")
    expect(r.panel_session:zoom(1.25) and r.panel_session.render_options.zoom==1.25,
        "the current undetected page can now zoom without turning to another page")
    f:close()
end

-- Forward and backward navigation includes consecutive undetected pages.
do
    local f=fixture();local r=f.reader
    reach_miss(f)
    local entry=r.panel_entry
    r:onTap(nil,{pos={x=590,y=400}});f:complete()
    expect(r.position.index==3 and f.shown.id==3 and r.panel_entry==entry,
        "edge tap advances an undetected full page without losing the original exit snapshot")
    r.reader_settings.panel_navigation="vertical"
    r:onSwipe(nil,{direction="north"});f:complete()
    expect(r.position.index==4 and f.shown.id=="4/left","the next detectable page resumes its first panel automatically")
    r:previous_page();f:complete();r:previous_page();f:complete();r:previous_page();f:complete()
    expect(r.position.index==1 and f.shown.id=="1/right","backward traversal resumes the previous detectable page at its last panel")
    f:close()
end
-- Pending detection consumes repeated navigation and explicit exit restores once.
do
    local f=fixture();local r=f.reader
    reach_miss(f);r:next_page()
    local requests=#f.sources
    r:next_page();r:previous_page()
    expect(#f.sources==requests and r.position.index==3,"repeated input during recognition cannot skip a physical page")
    f:complete();r:exit_panel_mode()
    expect(r.panel_entry==nil and r.panel_session==nil and r.position.index==1,
        "explicit exit from an undetected page restores the entry page and disables continuation")
    r:next_page()
    expect(#f.sources==requests and r.position.index==2,"ordinary navigation after exit does not restart panels")
    f:close()
end
-- A missed panel page must show all source pixels even in width and split modes.
for _,options in ipairs({{height=1600,fit_mode="width"},{width=1200,split=true}}) do
    local f=fixture(options);local r=f.reader
    reach_miss(f)
    expect(f.viewport:getWidth()==f.shown:getWidth() and f.viewport:getHeight()==f.shown:getHeight(),
        "a missed page uses its complete viewport rather than a width or split crop")
    expect(f.change.display_scale==0,"a missed tall or split page fits fully inside the screen")
    r:next_page();f:complete()
    expect(r.position.index==3 and f.viewport:getHeight()==f.shown:getHeight(),
        "consecutive missed pages remain complete before physical-page navigation")
    r:exit_panel_mode()
    expect(r.panel_entry==nil and r.position.index==1,"exit restores the entry page after a complete-page fallback")
    expect(f.change.display_scale==1,"exit restores the ordinary page display scale")
    expect(f.viewport:getWidth()==600 and f.viewport:getHeight()==800,
        "exit restores the original width or split viewport")
    f:close()
end
-- Disabled settings and display-mode changes end the retained intent.
do
    local f=fixture();local r=f.reader
    reach_miss(f)
    expect(r:set_panel_option("panel_zoom_enabled",false),"panel disable setting saves")
    expect(r.panel_entry==nil,"disabling panels on a full-page fallback exits panel reading")
    f:close()
end
do
    local f=fixture();local r=f.reader
    reach_miss(f)
    expect(r:_prepare_fit_mode("webtoon") and r.panel_entry==nil,
        "switching to continuous-strip display clears undetected panel reading intent")
    f:close()
end
do
    local f=fixture();local r=f.reader
    reach_miss(f)
    local disabled={};for key,value in pairs(r.reader_settings) do disabled[key]=value end
    disabled.panel_zoom_enabled=false
    r:reload_settings(disabled)
    expect(r.panel_entry==nil and r.panel_session==nil,
        "global settings reload disabling panels exits a full-page fallback instead of trapping navigation")
    r:next_page()
    expect(r.position.index==2,"navigation still works after disabling panels via settings reload")
    f:close()
end
do
    local f=fixture();local r=f.reader
    reach_miss(f)
    local values={};for key,value in pairs(r.reader_settings) do values[key]=value end
    values.image_engine="memory"
    r:reload_settings(values)
    expect(r.panel_entry==nil and r.panel_session==nil,
        "switching to an engine without panels clears retained panel intent")
    r:next_page()
    expect(r.position.index==2,"navigation still works after switching to the memory engine")
    f:close()
end
-- A cancelled page's late detection never restores its panel session.
do
    local f=fixture();local r=f.reader
    reach_miss(f);r:next_page()
    r:exit_panel_mode()
    local _,handle=f:complete()
    expect(handle.closed and r.panel_entry==nil and r.position.index==1,
        "late recognition after exit closes its source and leaves the restored page untouched")
    f:close()
end
-- Resource/decode/render errors are still errors, rather than normal missed panels.
for _,after_page_change in ipairs({false,true}) do
    local f=fixture();local r=f.reader
    if after_page_change then
        r:enter_panel_mode("first");f:complete();r:next_page();r:next_page()
    else
        f.failures[1]="no_panels";r:enter_panel_mode("first")
    end
    local shown=f.shown
    f.reject_show=true;f:complete();f.reject_show=false
    expect(f.shown==shown,"a rejected whole-page fallback preserves the already visible frame")
    expect(r.panel_entry==nil and r.panel_session==nil,
        "a failed fallback display cannot retain the inactive session that closes itself")
    local index=r.position.index
    local ok=pcall(r.onTap,r,nil,{pos={x=590,y=400}})
    expect(ok and r.position.index==index+1,"ordinary edge navigation recovers without indexing a closed session")
    f:close()
end
do
    local f=fixture();local r=f.reader
    f.failures[1]="panel_source_unavailable"
    r:enter_panel_mode("first");f:complete()
    expect(r.panel_entry==nil and r.panel_session==nil,"hard detection errors retain the existing explicit fallback policy")
    f:close()
end
print("rebuild_0414_panel_continuation_spec: "..checks.." checks")
