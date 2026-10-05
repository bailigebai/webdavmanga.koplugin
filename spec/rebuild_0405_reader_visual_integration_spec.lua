-- Behavioral pipeline: real crop -> processor -> persisted cache -> prepared
-- pages -> Reader -> production Shell/ImageWidget -> real PanelSession.
-- Only unavailable host widgets, native image I/O, and transport are doubled.
local Reader = require("webdavmanga.ui_reader")
local Shell = require("webdavmanga.ui_reader_shell")
local State = require("webdavmanga.state")
local Cache = require("webdavmanga.cache")
local PreparedPages = require("webdavmanga.prepared_pages")
local PageProcessor = require("webdavmanga.page_processor")
local AutoCrop = require("webdavmanga.auto_crop")
local ErrorReporter = require("webdavmanga.error_reporter")
local original_detect = AutoCrop.detect
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local function host_widgets(observed)
    local function class()
        local result = {}
        result.__index = result
        function result:new(options)
            local value = setmetatable(options or {}, self)
            if value.init then value:init() end
            return value
        end
        function result:extend(options)
            local child = setmetatable(options or {}, { __index = self })
            child.__index = child
            return child
        end
        function result:getSize()
            if self.dimen then return self.dimen end
            if self.text then return {w=math.min(#self.text*10,self.max_width or 400),h=20} end
            local child=self[1] and self[1]:getSize() or {w=0,h=0}
            return {w=child.w+2*(self.padding or 0),h=child.h+2*(self.padding or 0)}
        end
        function result:free()
            for _,child in ipairs(self) do if child.free then child:free() end end
        end
        return result
    end
    local screen = { getWidth=function() return 400 end, getHeight=function() return 600 end,
        getSize=function() return {w=400,h=600} end }
    local modules = {
        device={screen=screen,input={group={}}},
        ["ffi/blitbuffer"]={COLOR_WHITE=1,COLOR_BLACK=0},
        ["ui/font"]={getFace=function() return {} end},
        ["ui/geometry"]={new=function(_, value) return value end},
        ["ui/gesturerange"]={new=function(_, value) return value end},
        ["ui/size"]={padding={default=8}},
        ["ui/uimanager"]={setDirty=function() end, close=function() end},
    }
    for _, name in ipairs({"button", "container/centercontainer", "container/framecontainer",
        "container/inputcontainer", "horizontalgroup", "horizontalspan", "imagewidget",
        "linewidget", "overlapgroup", "textwidget", "titlebar", "verticalgroup"}) do
        modules["ui/widget/" .. name] = class()
    end
    local image_class = modules["ui/widget/imagewidget"]
    local new_image = image_class.new
    function image_class:new(options)
        observed.image = options
        return new_image(self, options)
    end
    local button_class = modules["ui/widget/button"]
    local new_button = button_class.new
    function button_class:new(options)
        if options.text == "X 返回漫画" then observed.exit = options.callback end
        return new_button(self, options)
    end
    for name, module in pairs(modules) do package.loaded[name] = module end
    return screen
end

local function fixture()
    local o = { owned={}, views={}, raw_decodes={0,0}, png_decodes={0,0}, detects={0,0},
        network=0, loader_calls=0, returned=0, handles={}, errors={} }
    AutoCrop.detect = function(page,options)
        o.detects[page.id]=o.detects[page.id]+1
        return original_detect(page,options)
    end
    local screen = host_widgets(o)
    local files, stored = {}, {}
    local function buffer(kind, id, w, h, parent)
        local b = {kind=kind,id=id,w=w,h=h,parent=parent,frees=0}
        function b:getWidth() return self.w end
        function b:getHeight() return self.h end
        function b:getPixel(x, y)
            if self.id == 1 and x >= 40 and x < 360 and y >= 60 and y < 540 then return 20 end
            return 255
        end
        function b:viewport(x, y, width, height)
            local view = buffer("view", self.id, width, height, self)
            view.x, view.y = x, y
            return view
        end
        function b:writePNG(path) files[path]={id=self.id,size=100}; return true end
        function b:free()
            self.frees = self.frees + 1
            local model = o.shell and o.shell.current_model
            if model and (model.buffer == self or model.viewport == self) then
                o.freed_while_displayed = true
            end
        end
        local list = parent and o.views or o.owned
        list[#list + 1] = b
        return b
    end
    local cache_options = {root="/cache/visual",limit_bytes=10000,
        md5=function(value) return (value:gsub("[^%w]", "_")) end,
        store={readSetting=function(_, key, default) return stored[key] or default end,
            saveSetting=function(_, key, value) stored[key]=value end,flush=function() end},
        fs={make_path=function() return true end, exists=function(path) return files[path] ~= nil end,
            size=function(path) return files[path] and files[path].size end,
            rename=function(source,target)
                if not files[source] then return nil end
                files[target],files[source]=files[source],nil; return true
            end,
            remove=function(path) files[path]=nil; return true end,list=function() return {} end},
    }
    local cache = Cache:new(cache_options)
    cache:migrate(3)
    local images = {{name="1.png",path="/chapter/1.png",width=400,height=600},
        {name="2.png",path="/chapter/2.png",width=400,height=600}}
    local fetched = {}
    local function fetch(image, callback)
        o.loader_calls = o.loader_calls + 1
        local id = image == images[1] and 1 or 2
        if not fetched[id] then o.network=o.network+1; fetched[id]=true end
        callback("/raw/" .. id .. ".png", true, {width=400,height=600})
    end
    local loader = {identity="visual",
        request=function(_, _, image, callbacks) fetch(image, callbacks.on_ready); return {} end,
        prefetch=function(_, _, requested, _, callback)
            for _, image in ipairs(requested) do
                fetch(image, function(path,cached,metadata) callback(image,path,cached,metadata) end)
            end
        end,
        cancel_generation=function() o.canceled=(o.canceled or 0)+1 end,
    }
    local prepared = PreparedPages:new{loader=loader,cache=cache,
        async={run=function(work,done) done(true,work()); return {} end},
        page_processor={process=function(source,part,profile)
            return PageProcessor.process(source,part,profile,{
                renderer={renderImageFile=function(_,path,_,w,h)
                    local id = tonumber(path:match("/raw/(%d)%.png"))
                    o.raw_decodes[id]=o.raw_decodes[id]+1
                    return buffer("raw",id,w,h)
                end},
                image_probe={inspect=function() return {width=400,height=600,size=100} end},
            })
        end},
    }
    local settings = {auto_crop_enabled=true,auto_crop_max_percent=30,
        fit_mode="page",prefetch_count=0,split_enabled=false,
        panel_zoom_enabled=true,panel_show_full_page=true}
    -- Warm real PreparedPages, then reopen Cache so Reader consumes persisted
    -- metadata rather than the preprocessing callback's transient table.
    prepared:prefetch(1,images,1,function(image)
        return PageProcessor.profile(settings,image,400,600)
    end)
    cache = Cache:new(cache_options)
    prepared.cache = cache
    local panel_source = {open=function(_, _, request, callbacks)
        o.panel_request = request
        local handle = {closes=0}
        function handle:detection_raster() return request.page_buffer end
        function handle:render() return buffer("panel",request.page_buffer.id,400,600) end
        function handle:close() self.closes=self.closes+1; self.closed=true end
        o.handles[#o.handles+1]=handle
        callbacks.on_ready(handle)
        return {cancel=function() end}
    end}
    local reader = Reader:new{loader=loader,prepared_pages=prepared,cache=cache,state=State:new(),
        settings={get_reader=function() return settings end,get_connection=function() return {} end},
        progress={chapter_id=function() return "visual" end,resolve=function() return 1 end,
            save=function() end},
        render_image={renderImageFile=function(_,path,_,w,h)
            local file = assert(files[path], "Reader must decode a published prepared PNG")
            o.png_decodes[file.id]=o.png_decodes[file.id]+1
            return buffer("display",file.id,w,h)
        end},
        ui={create_shell=function(_, owner)
            o.shell=Shell:new{owner=owner,screen=screen}; return o.shell
        end,show_shell=function() return true end},
        error_reporter=ErrorReporter:new{logger={err=function(_,label,_,detail)
            o.errors[#o.errors+1]=label .. ": " .. tostring(detail)
        end}},
        panel_source=panel_source,
        panel_detector={detect=function() return {{id="first",x=0,y=0,w=1,h=1}} end},
        open_chapter=function() error("unexpected chapter change") end,
    }
    local index = {count=function() return 2 end,get=function(_, i) return images[i] end}
    expect(reader:open{manga={name="Visual"},chapter={name="Chapter"},chapter_index=index,
        source_context={on_return=function() o.returned=o.returned+1 end}}, "Reader opens prepared chapter")
    return reader,o
end

local function geometry(view,parent,x,y,w,h,label)
    expect(view and view.parent == parent and view.x == x and view.y == y
        and view.w == w and view.h == h,label)
end

-- Mutations this scenario must catch: losing accepted/refused cache metadata,
-- zoom before crop, scale=1 for zoom, snapshotting a quadrant on panel entry,
-- preserving zoom on page change, and missing/double frees on either close path.
for _, close_path in ipairs({"right_top", "force_panel"}) do
    local r,o = fixture()
    local first = r.page_buffer
    expect(o.raw_decodes[1] == 1 and o.raw_decodes[2] == 1
        and o.detects[1] == 1 and o.detects[2] == 1, "preload decodes and analyzes each raw page once")
    expect(o.png_decodes[1] == 1 and o.png_decodes[2] == 0, "only first prepared PNG is decoded for display")
    expect(r.page_metadata.crop_checked == true and r.page_metadata.crop_reason == "cropped",
        "accepted crop decision survives persisted prepared cache")
    geometry(r.page_viewport,first,40,60,320,480,"ordinary view uses accepted crop")
    local network, calls = o.network,o.loader_calls
    expect(network == 2, "preloading fetched the two source pages")
    for _, quadrant in ipairs({
        {"top_left",100,100,0,0}, {"top_right",300,100,160,0},
        {"bottom_left",100,500,0,240}, {"bottom_right",300,500,160,240},
    }) do
        expect(r.shell.widget:onTwoFingerTap(nil,{pos={x=quadrant[2],y=quadrant[3]}}),
            "host gesture enters " .. quadrant[1])
        expect(r.quadrant_zoom == quadrant[1], "Reader selects requested quadrant")
        geometry(r.page_viewport.parent,first,40,60,320,480,"crop remains the outer viewport")
        geometry(r.page_viewport,r.page_viewport.parent,quadrant[4],quadrant[5],160,240,
            "quadrant coordinates are relative to crop")
        expect(o.image.image == r.page_viewport and o.image.scale_factor == 0
            and o.image.image_disposable == false and r.shell.current_model.buffer == first,
            "production ImageWidget borrows nested quadrant with best-fit")
        expect(r.shell.widget:onTwoFingerTap(nil,{pos={x=100,y=100}}),"second tap collapses")
        geometry(r.page_viewport,first,40,60,320,480,"collapse restores ordinary crop")
        expect(r.quadrant_zoom == nil and o.image.scale_factor == 1,"collapse restores 1x")
    end
    r:onTwoFingerTap(nil,{pos={x=300,y=100}})
    expect(r:enter_panel_mode(),"enter real PanelSession from quadrant")
    geometry(r.panel_entry.viewport,first,40,60,320,480,"panel snapshot restores ordinary crop before entry")
    expect(r.quadrant_zoom == nil and r.panel_session:is_active()
        and o.panel_request.page_buffer == first and o.panel_request.page_crop == nil
        and o.image.scale_factor == 1 and o.image.image.kind == "panel",
        "panel analyzes the full original page to protect dialogue while retaining the ordinary crop for exit")
    local panel = o.image.image
    expect(r:onTwoFingerTap(nil,{pos={x=300,y=100}}) == false,"panel mode rejects quadrant overlay")
    expect(r:exit_panel_mode(),"panel exits to retained page")
    geometry(r.page_viewport,first,40,60,320,480,"panel exit restores ordinary crop")
    expect(panel.frees == 1 and first.frees == 0 and o.handles[1].closes == 1,
        "panel exit frees only panel allocation and native handle")
    expect(r:_display_segment("whole",false),"same-buffer redraw succeeds")
    expect(o.raw_decodes[1] == 1 and o.raw_decodes[2] == 1 and o.png_decodes[1] == 1
        and o.png_decodes[2] == 0 and o.detects[1] == 1 and o.detects[2] == 1
        and o.network == network and o.loader_calls == calls,
        "zoom/collapse/panel/redraw reuse crop and allocation with zero decode, analysis or network work")
    r:onTwoFingerTap(nil,{pos={x=300,y=500}})
    expect(r:next_page(),"turn to second prepared page")
    local second = r.page_buffer
    expect(r.position.index == 2 and second ~= first and first.frees == 1
        and r.quadrant_zoom == nil and o.image.scale_factor == 1,"page change clears zoom and releases outgoing page")
    expect(r.page_metadata.crop_checked == true and r.page_metadata.crop_reason == "near_blank"
        and r.page_crop == nil and r.page_viewport == second,"rejected crop stays cached on second page")
    expect(o.raw_decodes[2] == 1 and o.png_decodes[2] == 1 and o.detects[2] == 1,
        "second prepared PNG decodes once without repeating rejected crop analysis")
    r:onTwoFingerTap(nil,{pos={x=300,y=500}})
    geometry(r.page_viewport,second,200,300,200,300,"rejected crop zoom uses full-page dimensions")
    if close_path == "right_top" then
        expect(r.shell.widget:onDoubleTap(nil,{pos={x=390,y=10}}),
            "top-right double tap exposes emergency exit")
        expect(type(o.exit) == "function" and o.shell.current_model.show_exit_button,
            "production Shell builds the emergency exit action")
        o.exit()
    else
        expect(r:enter_panel_mode(),"force-close scenario has an active owned panel")
        expect(r:force_close("plugin_teardown"),"force close succeeds")
    end
    expect(r:force_close("plugin_teardown"),"repeat close is idempotent")
    expect(r.closing and r.page_buffer == nil and r.page_viewport == nil and r.page_crop == nil
        and r.quadrant_zoom == nil and r.panel_session == nil and o.shell.closed
        and o.shell.current_model == nil and o.canceled == 1,"close detaches display, clears state and cancels generation once")
    expect(o.returned == (close_path == "right_top" and 1 or 0),"only user exit invokes return navigation")
    expect(not o.freed_while_displayed,"owned allocations detach before being freed")
    for _, b in ipairs(o.owned) do expect(b.frees == 1,b.kind .. " allocation must be freed exactly once") end
    for _, b in ipairs(o.views) do expect(b.frees == 0,"borrowed viewport must never free its owner") end
    for _, handle in ipairs(o.handles) do expect(handle.closes == 1,"panel handles close exactly once") end
    expect(o.raw_decodes[1] == 1 and o.raw_decodes[2] == 1 and o.png_decodes[1] == 1
        and o.png_decodes[2] == 1 and o.detects[1] == 1 and o.detects[2] == 1
        and o.network == network and o.loader_calls == calls,"whole journey keeps per-page decode/detect and network budgets")
    expect(#o.errors == 0,"no guarded Reader errors: " .. table.concat(o.errors,"; "))
end
AutoCrop.detect=original_detect
print(("rebuild_0405_reader_visual_integration_spec: %d checks passed"):format(checks))
