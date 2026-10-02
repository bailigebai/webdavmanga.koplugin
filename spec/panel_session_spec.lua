local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end
local function near(a, b) return math.abs(a - b) < 0.00001 end
local function new_buffer(width, height, details)
    return {
        details = details,
        getWidth = function() return width end,
        getHeight = function() return height end,
        viewport = function(self, x, y, w, h)
            self.last_viewport = new_buffer(w, h, { owner = self, x = x, y = y })
            return self.last_viewport
        end,
        scale = function(self, w, h)
            self.scale_calls = (self.scale_calls or 0) + 1
            return new_buffer(w, h, { scaled_from = self })
        end,
        free = function(self) self.freed = (self.freed or 0) + 1 end,
    }
end

local ffi_loads = 0
package.preload["ffi/mupdf"] = function() ffi_loads = ffi_loads + 1; error("no native backend") end
package.preload["ffi/drawcontext"] = function() ffi_loads = ffi_loads + 1; error("no native backend") end
local PanelSource = require("webdavmanga.panel_source")
expect(ffi_loads == 0, "requiring PanelSource must not load FFI")
local draw_context = { new = function(rotate, zoom)
    expect(rotate == 0, "use the native draw-context signature")
    return { zoom = zoom }
end }
local function native(width, height)
    local closed = {}
    local page = {
        getSize = function(_, draw)
            expect(draw.zoom == 1, "measure the physical page at zoom 1")
            return width, height
        end,
        draw_new = function(_, draw, w, h, x, y)
            return new_buffer(w, h, { draw = draw, x = x, y = y })
        end,
        close = function() closed.page = (closed.page or 0) + 1 end,
    }
    local document = {
        openPage = function(_, number) expect(number == 1); return page end,
        close = function() closed.document = (closed.document or 0) + 1 end,
    }
    return document, closed, page
end
local document, closed = native(2000, 3000)
local source = PanelSource:new{
    mupdf = { openDocument = function(path)
        expect(path == "/cache/current.jpg"); return document
    end }, draw_context = draw_context,
}
local reader_buffer = new_buffer(600, 900)
local ready
source:open(7, {
    page_path = "/cache/current.jpg", engine = "default", page_buffer = reader_buffer,
    page_crop = { x = 60, y = 90, w = 480, h = 720 },
    screen_width = 600, screen_height = 800,
}, { on_ready = function(handle) ready = handle end })
expect(ready ~= nil, "a local page must open without another download")
local raster = ready:detection_raster()
expect(raster.path == "/cache/current.jpg" and raster.bytes == nil)
expect(raster.width <= 600 and raster.height <= 800
    and raster.width * raster.height <= 480000, "detection is bounded to one screen")
expect(near(raster.crop.x, 0.1) and near(raster.crop.y, 0.1)
    and near(raster.crop.w, 0.8) and near(raster.crop.h, 0.8), "normalize decoded-buffer crop")
local panel = { x = 0.25, y = 0.25, w = 0.5, h = 0.5 }
local rendered = assert(ready:render(panel, { screen_width = 600, screen_height = 800,
    max_pixels = 720000, margin_percent = 0, show_adjacent = true }))
expect(rendered:getWidth() == 533 and rendered:getHeight() == 800, "fit panel without stretching")
expect(near(rendered.details.draw.zoom, 2 / 3)
    and near(rendered.details.x, 400) and near(rendered.details.y, 600), "map cropped panel to physical page")
rendered:free()
local white_margin = assert(ready:render(panel, { margin_percent = 10, show_adjacent = false }))
expect(white_margin:getWidth() == 426 and white_margin:getHeight() == 640,
    "white margins reduce the target by ten percent on each side")
white_margin:free()
local adjacent = assert(ready:render(panel, { margin_percent = 10, show_adjacent = true }))
expect(adjacent.details.x < 400 and adjacent.details.y < 600, "adjacent margin expands source box")
adjacent:free()
local bounded = assert(ready:render(panel, { max_pixels = 100, screen_width = 6000, screen_height = 8000 }))
expect(bounded:getWidth() * bounded:getHeight() <= 100, "honor a smaller caller pixel budget")
bounded:free()
local capped = assert(ready:render(panel, { max_pixels = 999999999, screen_width = 6000, screen_height = 8000 }))
expect(capped:getWidth() * capped:getHeight() <= 720000, "caller cannot raise the physical screen budget")
capped:free()
for _, invalid in ipairs({ {x=0,y=0,w=0,h=1}, {x=0/0,y=0,w=1,h=1}, {x=2,y=0,w=1,h=1} }) do
    expect(ready:render(invalid) == nil, "invalid panels must not allocate")
end
ready:close(); ready:close()
expect(closed.page == 1 and closed.document == 1, "close is explicit and idempotent")
expect(reader_buffer.freed == nil, "never free the Reader-owned buffer")
expect(ready:render(panel) == nil and ready:detection_raster() == nil, "closed handle is unusable")

local fallback, fallback_error
local borrowed = new_buffer(600, 900)
PanelSource:new():open(1, { page_path = "/missing.jpg", page_buffer = borrowed,
    page_crop = { x = 60, y = 90, w = 480, h = 720 }, screen_width = 600, screen_height = 800,
}, { on_ready = function(handle) fallback = handle end, on_error = function(err) fallback_error = err end })
expect(fallback and fallback.kind == "buffer" and not fallback_error,
    "unavailable MuPDF degrades to the current buffer")
local scaled = assert(fallback:render(panel))
expect(scaled:getWidth() == 533 and scaled:getHeight() == 800)
expect(borrowed.last_viewport.details.x == 180 and borrowed.last_viewport.details.y == 270
    and borrowed.last_viewport:getWidth() == 240 and borrowed.last_viewport:getHeight() == 360,
    "degraded path crops the borrowed page before scaling")
expect(borrowed.last_viewport.scale_calls == 1 and borrowed.last_viewport.freed == 1,
    "degraded path scales once and releases the no-copy viewport")
fallback:close(); fallback:close()
expect(borrowed.freed == nil and scaled.freed == nil, "caller owns the returned scaled buffer")
scaled:free()

-- Native draw failures must still use the borrowed screen raster exactly once.
for _, native_failure in ipairs({ "raise", "empty" }) do
    for _, buffer_failure in ipairs({ "none", "raise", "empty" }) do
        local render_doc, render_closed, render_page = native(2000, 3000)
        local draw_calls, viewport_calls = 0, 0
        render_page.draw_new = function()
            draw_calls = draw_calls + 1
            if native_failure == "raise" then error("native draw failed") end
        end
        local screen_buffer = new_buffer(600, 900)
        local make_viewport = screen_buffer.viewport
        screen_buffer.viewport = function(self, ...)
            viewport_calls = viewport_calls + 1
            local viewport = make_viewport(self, ...)
            if buffer_failure ~= "none" then
                viewport.scale = function()
                    if buffer_failure == "raise" then error("buffer scale failed") end
                end
            end
            return viewport
        end
        local render_handle
        PanelSource:new{mupdf = {openDocument = function() return render_doc end},
            draw_context = draw_context}:open(1, {
            page_path = "/current.jpg", page_buffer = screen_buffer,
            page_crop = {x = 60, y = 90, w = 480, h = 720},
            screen_width = 600, screen_height = 800,
        }, {on_ready = function(handle) render_handle = handle end})
        local result, reason = render_handle:render(panel, {
            screen_width = 6000, screen_height = 8000, max_pixels = 999999999,
        })
        if buffer_failure == "none" then
            expect(result ~= nil,
                "native " .. native_failure .. " must fall back to the borrowed screen buffer")
            expect(result:getWidth() * result:getHeight() <= 720000,
                "native draw fallback must retain the 1.5-screen-pixel limit")
        else
            expect(result == nil and reason == "panel_render_failed",
                "failure of native draw and buffer scale must keep the stable render error")
        end
        expect(draw_calls == 1 and viewport_calls == 1,
            "native failure must attempt exactly one buffer fallback")
        local viewport = screen_buffer.last_viewport
        expect(viewport.details.x == 180 and viewport.details.y == 270
            and viewport:getWidth() == 240 and viewport:getHeight() == 360,
            "native fallback must map the same normalized crop to screen-buffer dimensions")
        expect(viewport.freed == 1 and screen_buffer.freed == nil,
            "fallback success or failure must free only its owned viewport")
        render_handle:close(); render_handle:close()
        expect(render_closed.page == 1 and render_closed.document == 1 and screen_buffer.freed == nil,
            "fallback cleanup must close owned native objects without freeing the borrowed page")
        if result then
            expect(result.freed == nil, "successful fallback buffer ownership belongs to the caller")
            result:free()
        end
    end
end

local unavailable
PanelSource:new{ mupdf = {}, draw_context = draw_context }:open(1,
    { page_path = "/invalid.jpg", screen_width = 600, screen_height = 800 },
    { on_error = function(err) unavailable = err end })
expect(unavailable == "panel_source_unavailable", "no backend or buffer yields a stable error")
local failed_document, failed_closed, failed_page = native(2000, 3000)
failed_page.getSize = function() error("bad page") end
PanelSource:new{ mupdf = {openDocument = function() return failed_document end}, draw_context = draw_context }
    :open(1, {page_path="/bad.jpg", screen_width=600, screen_height=800}, {})
expect(failed_closed.page == 1 and failed_closed.document == 1, "partial native open failure closes both resources")

-- Invalid caller budgets must fail before any output allocation.
local limits
PanelSource:new{mupdf={}}:open(1, {page_buffer=new_buffer(600,800), screen_width=600, screen_height=800},
    {on_ready=function(handle) limits=handle end})
for _, budget in ipairs({0, -1, 0/0, math.huge}) do
    expect(limits:render(panel, {max_pixels=budget}) == nil, "invalid explicit pixel budget must be rejected")
end
local narrow = assert(limits:render({x=0,y=0,w=0.000001,h=1}, {max_pixels=1}))
expect(narrow:getWidth() == 1 and narrow:getHeight() == 1, "subpixel rounding still respects the budget")
narrow:free(); limits:close()

for _, invalid_request in ipairs({
    {page_buffer=new_buffer(600,800), screen_width=0.5, screen_height=800},
    {page_buffer=new_buffer(600,800), screen_width=600, screen_height=800, page_crop=true},
    {page_buffer=new_buffer(600,800), screen_width=600, screen_height=800, page_crop={x=0,y=0,w=0,h=1}},
}) do
    local err
    local ok = pcall(function() PanelSource:new{mupdf={}}:open(1, invalid_request,
        {on_error=function(value) err=value end}) end)
    expect(ok and err == "panel_source_unavailable", "malformed geometry reports an error without throwing")
    expect(invalid_request.page_buffer.freed == nil)
end

local throwing_doc, throwing_closed = native(2000,3000)
PanelSource:new{mupdf={openDocument=function() return throwing_doc end},draw_context=draw_context}
    :open(1, {page_path="/throw.jpg",screen_width=600,screen_height=800},
        {on_ready=function() error("reader callback failed") end})
expect(throwing_closed.page == 1 and throwing_closed.document == 1, "callback failure closes native resources")

local broken_buffer = new_buffer(600,800)
broken_buffer.viewport = function(self)
    self.last_viewport = {scale=function() error("out of memory") end,
        free=function(view) view.freed=true end}
    return self.last_viewport
end
local broken_ready
PanelSource:new{mupdf={}}:open(1, {page_buffer=broken_buffer,screen_width=600,screen_height=800},
    {on_ready=function(handle) broken_ready=handle end})
local failed_render, render_error = broken_ready:render(panel)
expect(failed_render == nil and render_error == "panel_render_failed"
    and broken_buffer.last_viewport.freed, "scale failure releases the borrowed viewport")
broken_ready:close()

local thin_ready
local thin_doc = native(2000,3000)
PanelSource:new{mupdf={openDocument=function() return thin_doc end},draw_context=draw_context}
    :open(1, {page_path="/thin.jpg",screen_width=600,screen_height=800},
        {on_ready=function(handle) thin_ready=handle end})
local thin_render = assert(thin_ready:render({x=0,y=0,w=0.0000001,h=1}, {max_pixels=1}))
expect(thin_render:getWidth() == 1 and thin_render:getHeight() == 1
    and near(thin_render.details.draw.zoom, 1/3000),
    "pixel floor must lower native zoom too, not cut away the rest of a thin panel")
thin_render:free(); thin_ready:close()
local PanelSession = require("webdavmanga.panel_session")
local PanelDetector = require("webdavmanga.panel_detector")
local function session_fixture(options)
    options = options or {}
    local f = { published = {}, boundaries = {}, scheduled = {}, buffers = {}, handles = {},
        opens = {}, errors = {}, live = 0, peak = 0, detections = 0 }
    local detector = {
        sort = PanelDetector.sort,
        detect = function(raster, detect_options)
            f.detections = f.detections + 1
            f.detect_options = detect_options
            if options.detect_error then return nil, options.detect_error end
            if options.empty_detection then return {} end
            expect(raster.width == 100, "detect from the opened handle")
            return PanelDetector.sort({
                { id="left", x=0, y=0, w=0.3, h=1 },
                { id="middle", x=0.35, y=0, w=0.3, h=1 },
                { id="right", x=0.7, y=0, w=0.3, h=1 },
            }, detect_options.direction)
        end,
    }
    function f:new_handle()
        local handle = {
            detection_raster = function() return {width=100,height=100} end,
            render = function(_, box, render_options)
                f.render_options = render_options
                if f.fail_render == box.id then return nil, "panel_render_failed" end
                if f.throw_render == box.id then error("native render failure") end
                f.live = f.live + 1; f.peak = math.max(f.peak, f.live)
                local buffer = new_buffer(60,80,{panel_id=box.id})
                buffer.free = function(self)
                    self.freed = (self.freed or 0) + 1; f.live = f.live - 1
                end
                f.buffers[#f.buffers+1] = buffer
                if f.during_render then f.during_render() end
                return buffer
            end,
            close = function(self) self.close_calls=(self.close_calls or 0)+1; self.closed=true end,
        }
        f.handles[#f.handles+1] = handle
        return handle
    end
    local source = {open=function(_, generation, source_request, callbacks)
        local operation = {cancel=function(self) self.cancels=(self.cancels or 0)+1 end}
        f.opens[#f.opens+1] = {generation=generation,request=source_request,callbacks=callbacks,operation=operation}
        if not options.pending then callbacks.on_ready(f:new_handle()) end
        return operation
    end}
    f.session = PanelSession:new{source=source,detector=detector,
        screen_width=600,screen_height=800,
        schedule=function(callback)
            f.scheduled[#f.scheduled+1] = callback
            if options.immediate then callback() end
        end}
    f.callbacks = {
        on_panel=function(buffer, box, index, count)
            if f.on_publish then return f.on_publish(buffer,box,index,count) end
            f.published[#f.published+1] = {buffer=buffer,panel=box,index=index,count=count}
        end,
        on_boundary=function(delta) f.boundaries[#f.boundaries+1]=delta end,
        on_fallback=function(reason) f.errors[#f.errors+1]=reason end,
    }
    function f:start(desired, generation)
        return self.session:start({generation=generation or 3,direction="normal",desired=desired or "first",
            experimental=true,margin_percent=5,show_adjacent=true}, self.callbacks)
    end
    function f:check_released()
        expect(self.live == 0 and self.peak <= 2, "own at most two outputs, release every output")
        for _, buffer in ipairs(self.buffers) do expect(buffer.freed == 1, "free every output exactly once") end
        for _, handle in ipairs(self.handles) do expect(handle.close_calls == 1, "close every handle exactly once") end
        for _, opened in ipairs(self.opens) do expect(opened.operation.cancels == 1, "cancel every operation once") end
    end
    return f
end

local f = session_fixture()
expect(not f.session:is_active() and f.session:current() == nil, "new session is inactive")
expect(f:start(), "start accepts the page")
expect(f.session:is_active() and #f.published == 1 and #f.scheduled == 1,
    "publish first panel before scheduling one look-ahead")
expect(f.opens[1].generation == 3 and f.opens[1].request.screen_width == 600
    and f.opens[1].request.screen_height == 800, "forward generation and screen dimensions")
expect(f.detect_options.experimental == true and f.render_options.margin_percent == 5
    and f.render_options.show_adjacent == true, "forward detection and render preferences")
local first = f.session:current().buffer
f.scheduled[1](); f.scheduled[1]()
expect(#f.buffers == 2 and #f.published == 1, "prefetch once without publishing")
expect(f.session:move(1) and #f.buffers == 2 and f.session:current().panel.id == "middle",
    "forward move consumes the prefetched output")
expect(first.freed == 1 and f.published[2].index == 2 and f.published[2].count == 3)
f.scheduled[2]()
local middle = f.session:current().buffer
local reversed = f.session:set_direction("manga")
expect(reversed.panel.id == "middle" and reversed.buffer == middle and reversed.index == 2,
    "direction change preserves physical panel and its output")
expect(f.detections == 1 and f.buffers[3].freed == 1, "resort boxes without detecting or retaining old prefetch")
f.scheduled[3]()
expect(f.session:move(1) and f.session:current().panel.id == "left", "prefetch follows the new order")
expect(f.session:set_direction("normal").index == 1, "switching direction back preserves stable id")
f.session:close(); f.session:close(); f:check_released()

local last = session_fixture()
last:start("last")
local last_buffer = last.session:current().buffer
expect(last.session:current().index == 3 and #last.scheduled == 0, "desired last starts at final panel")
expect(last.session:move(1) == false and last.boundaries[1] == 1
    and last.session:current().buffer == last_buffer, "forward boundary leaves current output intact")
expect(last.session:move(-1) and last.session:move(-1), "backward navigation renders synchronously")
expect(last.session:move(-1) == false and last.boundaries[2] == -1 and #last.opens == 1,
    "backward boundary delegates without opening another physical page")
expect(last.session:move(0) == false and last.session:move(2) == false, "only adjacent moves are accepted")
last.session:close(); for _, run in ipairs(last.scheduled) do run() end; last:check_released()

local failure = session_fixture()
failure:start(); failure.fail_render="middle"; failure.scheduled[1]()
expect(failure.session:is_active() and #failure.errors == 0 and #failure.buffers == 1,
    "preload failure leaves the current panel displayed")
expect(failure.session:move(1) == false and failure.session:current().panel.id == "left"
    and #failure.errors == 0, "failed neighbor render preserves the current panel")
failure.fail_render=nil; failure.throw_render="middle"
expect(failure.session:move(1) == false and not failure.session:is_active()
    and failure.errors[1]=="panel_render_failed", "repeated foreground allocation failure falls back once")
failure.session:close(); failure:check_released()

local allocation = session_fixture()
allocation:start(); allocation.session:move(1); allocation.scheduled[2]()
local allocation_current, allocation_next = allocation.session:current().buffer, allocation.buffers[3]
allocation.fail_render="left"
expect(not allocation.session:move(-1) and allocation_next.freed==1
    and allocation.session:current().buffer==allocation_current and not allocation_current.freed
    and #allocation.errors==0, "allocation failure drops next before preserving visible current")
allocation.fail_render=nil
expect(allocation.session:move(-1), "a successful retry clears the allocation-failure streak")
allocation.fail_render="middle"
expect(not allocation.session:move(1) and allocation.session:is_active(), "first later failure preserves current")
allocation.on_publish=nil
local visible_on_fallback
allocation.callbacks.on_fallback=function(reason)
    visible_on_fallback=allocation.session:current()
    expect(reason=="panel_render_failed", "fallback exposes only a stable code")
end
allocation.session:move(1)
expect(visible_on_fallback and visible_on_fallback.buffer.freed==1
    and not allocation.session:is_active(), "fallback must let Reader detach current before final release")
allocation.session:close(); allocation:check_released()

local rejected = session_fixture()
rejected:start(); rejected.scheduled[1]()
local kept = rejected.session:current().buffer
rejected.on_publish=function() expect(kept.freed == nil, "publish before freeing current"); return false end
expect(rejected.session:move(1) == false and rejected.session:current().buffer == kept
    and kept.freed == nil and rejected.buffers[2].freed == 1, "rejected publication frees only candidate")
rejected.on_publish=function() error("widget rejected publication") end
expect(rejected.session:move(1) == false and kept.freed == nil, "throwing publication also preserves current")
rejected.session:close(); rejected:check_released()

local released = session_fixture()
released:start(); released.session:release_next(); released.scheduled[1]()
expect(#released.buffers == 1 and released.session:is_active(), "release_next invalidates pending prefetch")
released.session:set_direction("manga"); released.session:set_direction("normal")
released.scheduled[2](); local before_release = released.session:current().buffer
released.session:release_next(); released.session:release_next()
expect(before_release.freed == nil and released.buffers[2].freed == 1
    and released.handles[1].closed == nil, "release_next only frees look-ahead")
released.session:close(); released:check_released()

local pending_session = session_fixture{pending=true}
pending_session:start(); expect(not pending_session.session:is_active(), "pending open is inactive")
pending_session:start("last", 4)
local stale_handle = pending_session:new_handle()
pending_session.opens[1].callbacks.on_ready(stale_handle)
pending_session.opens[1].callbacks.on_error("stale failure")
expect(stale_handle.close_calls == 1 and #pending_session.published == 0 and #pending_session.errors == 0,
    "restarted session drops stale ready/error callbacks")
pending_session.opens[2].callbacks.on_ready(pending_session:new_handle())
expect(pending_session.session:current().panel.id == "right", "new generation publishes normally")
pending_session.session:close()
pending_session:start(); pending_session.session:close()
local after_close = pending_session:new_handle()
pending_session.opens[3].callbacks.on_ready(after_close)
expect(after_close.close_calls == 1 and #pending_session.published == 1
    and not pending_session.session:is_active(), "ready after close only releases its own handle")
pending_session:check_released()

local stale_prefetch = session_fixture()
stale_prefetch:start(); stale_prefetch:start("last",4); stale_prefetch.scheduled[1]()
expect(#stale_prefetch.buffers == 2 and stale_prefetch.session:current().panel.id == "right",
    "queued old prefetch cannot allocate against the replacement handle")
stale_prefetch.session:close(); stale_prefetch:check_released()

for _, mode in ipairs({"detect", "render", "publish", "source"}) do
    local initial = session_fixture{detect_error=mode == "detect" and "no_panels" or nil,
        pending=mode == "source"}
    if mode == "render" then initial.fail_render="left" end
    if mode == "publish" then initial.on_publish=function() return false end end
    initial:start()
    if mode == "source" then initial.opens[1].callbacks.on_error("panel_source_unavailable") end
    expect(not initial.session:is_active() and initial.session:current() == nil and #initial.errors == 1,
        "initial " .. mode .. " failure falls back once and releases ownership")
    initial.session:close(); initial:check_released()
end

local immediate = session_fixture{immediate=true}
immediate:start(); immediate.session:move(1)
expect(immediate.peak == 2 and #immediate.published == 2, "immediate scheduler never owns three outputs")
immediate.session:close(); immediate:check_released()

local closed_during_publish = session_fixture()
closed_during_publish.on_publish=function() closed_during_publish.session:close() end
closed_during_publish:start()
expect(not closed_during_publish.session:is_active() and #closed_during_publish.scheduled == 0,
    "close during publication cannot resurrect the session")
closed_during_publish:check_released()

local closed_during_render = session_fixture()
closed_during_render:start()
closed_during_render.during_render=function() closed_during_render.session:close() end
closed_during_render.scheduled[1]()
expect(not closed_during_render.session:is_active(), "late render result cannot resurrect a closed session")
closed_during_render:check_released()

local empty_detection = session_fixture{empty_detection=true}
empty_detection:start()
expect(empty_detection.errors[1] == "panel_detection_failed", "empty detection supplies a stable fallback code")
empty_detection:check_released()

local restarted_in_publish = session_fixture{immediate=true}
restarted_in_publish.on_publish=function()
    restarted_in_publish.on_publish=nil
    restarted_in_publish:start("last", 4)
end
restarted_in_publish:start()
expect(restarted_in_publish.session:is_active() and restarted_in_publish.session:current().panel.id == "right"
    and #restarted_in_publish.published == 1, "publication from old start cannot overwrite a reentrant restart")
restarted_in_publish.session:close(); restarted_in_publish:check_released()

local invalidated_during_render = session_fixture()
invalidated_during_render:start()
invalidated_during_render.during_render=function() invalidated_during_render.session:release_next() end
invalidated_during_render.scheduled[1]()
expect(invalidated_during_render.buffers[2].freed == 1 and invalidated_during_render.session:is_active()
    and invalidated_during_render.session:current().buffer.freed == nil,
    "prefetch invalidated during render frees only its returned allocation")
invalidated_during_render.session:close(); invalidated_during_render:check_released()

local duplicate_ready = session_fixture{pending=true}
duplicate_ready:start()
local duplicate_handle = duplicate_ready:new_handle()
duplicate_ready.opens[1].callbacks.on_ready(duplicate_handle)
duplicate_ready.opens[1].callbacks.on_ready(duplicate_handle)
duplicate_ready.opens[1].callbacks.on_error("already completed")
expect(#duplicate_ready.published == 1 and duplicate_handle.close_calls == nil and #duplicate_ready.errors == 0,
    "duplicate completion cannot close the live handle or publish twice")
duplicate_ready.session:close(); duplicate_ready:check_released()

-- Real Source cancellation also owns its handle: verify actual native frees, not only the session double.
local integrated_doc, integrated_closed = native(2000,3000)
local integrated_buffer
local integrated = PanelSession:new{
    source=PanelSource:new{mupdf={openDocument=function() return integrated_doc end},draw_context=draw_context},
    detector={detect=function() return {{id="one",x=0,y=0,w=1,h=1}} end,sort=PanelDetector.sort},
    screen_width=600,screen_height=800,
}
expect(integrated:start({generation=1,page_path="/integrated.jpg"}, {
    on_panel=function(buffer) integrated_buffer=buffer end,
}), "real source integrates with session")
integrated:close(); integrated:close()
expect(integrated_buffer.freed == 1 and integrated_closed.page == 1 and integrated_closed.document == 1,
    "real Source operation cancellation and session close release native ownership exactly once")
-- A native render may reenter the event loop after allocation but before returning it.
local reentrant_move = session_fixture()
reentrant_move:start()
local move_result, move_reason
reentrant_move.during_render=function()
    reentrant_move.during_render=nil
    move_result, move_reason=reentrant_move.session:move(1)
end
reentrant_move.scheduled[1]()

local reentrant_sort_options = {}
local reentrant_sort = session_fixture(reentrant_sort_options)
reentrant_sort:start(); reentrant_sort.session:move(1)
reentrant_sort_options.immediate=true
local sort_result, sort_reason
reentrant_sort.during_render=function()
    reentrant_sort.during_render=nil
    sort_result, sort_reason=reentrant_sort.session:set_direction("normal")
end
reentrant_sort.session:set_direction("manga")

local reentrant_backward = session_fixture()
reentrant_backward:start("last"); reentrant_backward.session:move(-1)
local backward_sort_result, backward_sort_reason
reentrant_backward.during_render=function()
    reentrant_backward.during_render=nil
    backward_sort_result, backward_sort_reason=reentrant_backward.session:set_direction("manga")
end
reentrant_backward.session:move(-1)
local backward_current = reentrant_backward.session:current()
expect(reentrant_move.peak <= 2 and reentrant_sort.peak <= 2
    and backward_current.buffer.details.panel_id == backward_current.panel.id,
    "render reentry: preload/move peak=" .. reentrant_move.peak
        .. ", sort/sync-scheduler peak=" .. reentrant_sort.peak
        .. ", backward buffer=" .. backward_current.buffer.details.panel_id
        .. ", panel=" .. backward_current.panel.id)
expect(move_result == false and move_reason == "panel_session_busy"
    and reentrant_move.session:current().panel.id == "left", "reentrant move reports busy without moving")
expect(sort_result == nil and sort_reason == "panel_session_busy",
    "reentrant sort reports busy without starting another synchronous prefetch")
expect(backward_sort_result == nil and backward_sort_reason == "panel_session_busy"
    and backward_current.panel.id == "left", "foreground render cannot publish against a changed order")
expect(reentrant_move.session:move(1) and reentrant_move.session:current().panel.id == "middle",
    "busy gate clears and prefetched output remains consumable")
expect(reentrant_sort.session:set_direction("normal").panel.id == "middle"
    and reentrant_backward.session:set_direction("manga").panel.id == "left",
    "direction changes can be retried after render returns")
for _, reentered in ipairs({reentrant_move, reentrant_sort, reentrant_backward}) do
    reentered.session:close(); reentered:check_released()
end
local restart_during_render = session_fixture{immediate=true}
restart_during_render:start("last")
local restart_result, restart_reason
restart_during_render.during_render=function()
    restart_during_render.during_render=nil
    restart_during_render.session:close()
    restart_result, restart_reason=restart_during_render:start("first",4)
end
expect(restart_during_render.session:move(-1) == false and restart_result == false
    and restart_reason == "panel_session_busy" and not restart_during_render.session:is_active(),
    "close cannot clear an in-flight render reservation and admit a nested start")
expect(restart_during_render:start("first",4), "start can retry after the old render unwinds")
restart_during_render.session:close(); restart_during_render:check_released()

local thrown_busy = session_fixture()
thrown_busy:start(); thrown_busy.throw_render="middle"
expect(thrown_busy.session:move(1) == false, "render exception is contained")
thrown_busy.throw_render=nil
expect(thrown_busy.session:move(1), "render exception must release the busy reservation")
thrown_busy.session:close(); thrown_busy:check_released()

-- PanelSource is default-engine only. Keep a defensive rejection even though
-- Reader blocks memory-engine entry before it can reach this layer.
local unsupported_ready, unsupported_error = false, nil
local unsupported_source = PanelSource:new{
    transfer={run=function() error("memory transfer must not run") end},
    client_factory=function() error("memory client must not be created") end,
    connection_provider=function() error("memory connection must not be read") end,
}
local unsupported_operation = unsupported_source:open(1, {
    engine="memory", page_buffer=new_buffer(600,800), screen_width=600, screen_height=800,
}, {
    on_ready=function() unsupported_ready=true end,
    on_error=function(reason) unsupported_error=reason end,
})
expect(not unsupported_ready and unsupported_error=="panel_engine_unsupported",
    "memory engine must be rejected before opening a panel source")
unsupported_operation:cancel()
print("panel source/session: " .. checks .. " checks passed")
