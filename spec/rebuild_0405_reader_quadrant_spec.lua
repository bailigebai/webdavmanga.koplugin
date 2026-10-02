local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message) end
end

local function index_for(entries)
    return {
        count = function() return #entries end,
        get = function(_, i) return entries[i] end,
        window = function() return entries end,
    }
end

local function fixture(shell_factory)
    local observed = { requests = {}, decodes = 0, views = {}, pages = {}, chapters = 0 }
    local function buffer(w, h, parent)
        local result = { w = w, h = h, parent = parent }
        function result:getWidth() return self.w end
        function result:getHeight() return self.h end
        function result:viewport(x, y, width, height)
            local view = buffer(width, height, self)
            view.x, view.y = x, y
            observed.views[#observed.views + 1] = view
            return view
        end
        function result:free() self.freed = true end
        return result
    end
    local shell = {
        get_content_size = function() return 600, 800 end,
        show_loading = function() end,
        show_status = function() end,
        show_exit_button = function() observed.exit_button = true; return true end,
        close_now = function() observed.closed = true; return true end,
        show_page = function(self, original, view, _title, page_change)
            if observed.reject_page then return false end
            self.current_model = { kind = "page", buffer = original,
                reader_generation = page_change.reader_generation }
            observed.pages[#observed.pages + 1] = { original = original, view = view }
            return true
        end,
    }
    local images = {}
    for i = 1, 3 do images[i] = { name = i .. ".jpg", path = "/chapter/" .. i .. ".jpg" } end
    local context = {
        manga = { name = "Manga", path = "/manga" },
        chapter = { name = "Chapter", path = "/chapter" },
        chapter_index = index_for(images), chapter_position = 1,
        chapters_index = index_for({ { name = "Chapter", path = "/chapter" },
            { name = "Next", path = "/next" } }),
    }
    local settings = { direction = "normal", fit_mode = "page", split_enabled = false,
        prefetch_count = 0, panel_zoom_enabled = true, panel_show_full_page = true }
    local reader = Reader:new{
        loader = { identity = "quadrant", request = function(_, generation, image, callbacks)
            observed.requests[#observed.requests + 1] = { image = image, callbacks = callbacks }
            return {}
        end },
        state = State:new(),
        progress = { chapter_id = function() return "chapter" end,
            resolve = function() return { index = 2, segment = "whole" } end,
            save = function() end },
        settings = { get_reader = function() return settings end,
            get_connection = function() return {} end },
        cache = { key_for = function(_, _, path) return path end, set_protected = function() end },
        render_image = { renderImageFile = function()
            observed.decodes = observed.decodes + 1
            return buffer(800, 1200)
        end },
        ui = { create_shell = function() return shell end, show_shell = function() end,
            confirm = function(_, model) observed.confirmation = model end },
        open_chapter = function() observed.chapters = observed.chapters + 1 end,
        panel_source = {}, panel_detector = {},
        panel_session_factory = function() return {
            start = function() return true end, close = function() end,
            is_active = function() return true end,
        } end,
    }
    if shell_factory then shell = shell_factory(reader, observed) end
    expect(reader:open(context), "fixture must open real Reader")
    observed.requests[1].callbacks.on_ready("/cache/2.jpg", false, { width = 800, height = 1200 })
    expect(reader.page_buffer ~= nil, "fixture must decode a page")
    return reader, observed, context
end

local top_right = { pos = { x = 500, y = 100 } }
local bottom_left = { pos = { x = 100, y = 700 } }
expect(type(Reader.onTwoFingerTap) == "function", "Reader must handle two-finger quadrant taps")

-- Catch crop/zoom order reversal, a second split, and accidental reload/decode.
do
    local r, o = fixture()
    local original = r.page_buffer
    local crop = { x = 10, y = 20, w = 400, h = 600 }
    local segments = { "left", "right" }
    r.page_crop, r.current_segments, r.position.segment = crop, segments, "right"
    r.reader_settings.split_enabled = true
    local fit = r.fit_mode
    o.views = {}
    expect(r:onTwoFingerTap(nil, top_right) == true, "valid tap must display quadrant")
    expect(r.quadrant_zoom == "top_right", "Reader must retain only the quadrant id")
    expect(#o.views == 2 and o.views[1].parent == original
        and o.views[1].x == 10 and o.views[1].y == 20 and o.views[1].w == 400 and o.views[1].h == 600,
        "crop must be the first viewport over the full decoded allocation")
    local view = o.pages[#o.pages].view
    expect(view.parent == o.views[1] and view.x == 200 and view.y == 0
        and view.w == 200 and view.h == 300, "top-right must use cropped dimensions without another split")
    expect(#o.requests == 1 and o.decodes == 1 and o.pages[#o.pages].original == original
        and r.page_buffer == original and r.page_crop == crop and r.current_segments == segments
        and r.reader_settings.split_enabled and r.fit_mode == fit and r.position.segment == "right",
        "zoom must reuse decoded page without changing split, crop, position, fit or Loader work")
    expect(r:onTwoFingerTap(nil, {}) == false and r.quadrant_zoom == "top_right",
        "missing coordinates must not collapse an active quadrant")
    expect(r:onTwoFingerTap(nil, bottom_left) and r.quadrant_zoom == nil,
        "the next valid tap must collapse instead of selecting another quadrant")
    expect(#o.requests == 1 and o.decodes == 1 and r.page_buffer == original
        and o.pages[#o.pages].view.h == 600, "collapse must restore the ordinary split viewport in place")
end

-- Odd crop edges must be fully represented, independent of split settings.
do
    local r, o = fixture()
    r.page_crop = { x = 10, y = 20, w = 401, h = 601 }
    expect(r:onTwoFingerTap(nil, { pos1 = { x = 450, y = 650 }, pos2 = { x = 550, y = 750 } }),
        "two-point midpoint should select a quadrant")
    local view = o.pages[#o.pages].view
    expect(view.x == 200 and view.y == 300 and view.w == 201 and view.h == 301,
        "odd crop right and bottom must include every remaining pixel")
end

-- These transitions must clear zoom before a new physical page is ready.
for _, transition in ipairs({ "next", "previous", "request", "chapter", "reopen", "panel", "close", "close_all", "emergency" }) do
    local r, o, context = fixture()
    r:onTwoFingerTap(nil, top_right)
    if transition == "next" then r:next_page()
    elseif transition == "previous" then r:previous_page()
    elseif transition == "request" then r:request_page(3, "whole")
    elseif transition == "chapter" then r:_ask_next_chapter(); o.confirmation.on_confirm()
    elseif transition == "reopen" then r:open(context)
    elseif transition == "panel" then r:enter_panel_mode()
    elseif transition == "close" then r:force_close("back")
    elseif transition == "close_all" then r:force_close("plugin_teardown")
    elseif transition == "emergency" then
        r:onTap(nil, { ges = "double_tap", pos = { x = 590, y = 5 } })
        expect(o.exit_button, "top-right double tap must still expose the emergency exit")
        r:force_close("exit_button")
    end
    expect(r.quadrant_zoom == nil, transition .. " must clear quadrant zoom")
    if transition == "next" or transition == "previous" or transition == "request" then
        expect(#o.requests == 2 and o.requests[2].image.path ==
            (transition == "previous" and "/chapter/1.jpg" or "/chapter/3.jpg"),
            transition .. " must still request the physical destination")
    elseif transition == "chapter" then expect(o.chapters == 1, "chapter callback must remain reachable")
    elseif transition == "panel" then
        expect(r.panel_entry and r.panel_session and r.panel_entry.viewport == r.page_buffer,
            "panel entry snapshot must contain the ordinary viewport, not a quadrant")
        local count = #o.pages
        expect(r:onTwoFingerTap(nil, top_right) == false and #o.pages == count,
            "panel mode must not accept a quadrant overlay")
        r.quadrant_zoom = "top_right"
        expect(r:_viewport("whole") == r.page_buffer, "panel viewport must ignore stale quadrant state")
    elseif transition == "close" or transition == "close_all" or transition == "emergency" then
        expect(r.closing and o.closed, transition .. " must still close the shell")
    end
end

do
    local r, o = fixture()
    r.fit_mode = "width"
    r:onTwoFingerTap(nil, top_right)
    r:next_page()
    expect(r.position.index == 2 and r.pan_y > 0 and r.quadrant_zoom == "top_right"
        and #o.requests == 1 and o.pages[#o.pages].view.y == 0,
        "same-page vertical pan must keep the selected quadrant")
    r:next_page()
    expect(r.quadrant_zoom == nil and #o.requests == 2,
        "physical page turn after pan must clear the quadrant")
end

do
    local r, o = fixture()
    o.reject_page = true
    expect(r:onTwoFingerTap(nil, top_right) == false and r.quadrant_zoom == nil,
        "a rejected zoom display must retain ordinary state")
    o.reject_page = false
    r:onTwoFingerTap(nil, top_right)
    o.reject_page = true
    expect(r:onTwoFingerTap(nil, bottom_left) == false and r.quadrant_zoom == "top_right",
        "a rejected collapse must retain the still-visible quadrant")
    o.reject_page = false
    r:request_page(3)
    expect(r:onTwoFingerTap(nil, top_right) == false and r.quadrant_zoom == nil,
        "a pending physical page must not reacquire the outgoing page's zoom")
    r:force_close("back")
    expect(r:onTwoFingerTap(nil, top_right) == false, "closed Reader must ignore zoom")
end

-- Exercise real Reader -> Shell model -> ImageWidget options. Only KOReader's
-- unavailable host widgets are doubled; Shell must build its production tree.
local function production_shell(owner, observed)
    local function widget_class()
        local class = {}
        class.__index = class
        function class:new(options)
            local object = setmetatable(options or {}, self)
            if object.init then object:init() end
            return object
        end
        function class:extend(definition)
            local child = setmetatable(definition or {}, { __index = self })
            child.__index = child
            return child
        end
        return class
    end
    local screen = {
        getWidth = function() return 600 end, getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end,
    }
    local modules = {
        device = { screen = screen, input = { group = {} } },
        ["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 0 },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/geometry"] = { new = function(_, values) return values end },
        ["ui/gesturerange"] = { new = function(_, values) return values end },
        ["ui/size"] = { padding = { default = 8 } },
        ["ui/uimanager"] = { setDirty = function() end },
    }
    for _, name in ipairs({
        "ui/widget/button", "ui/widget/container/centercontainer",
        "ui/widget/container/framecontainer", "ui/widget/container/inputcontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
        "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/textwidget",
        "ui/widget/titlebar", "ui/widget/verticalgroup",
    }) do modules[name] = widget_class() end
    local image_class = modules["ui/widget/imagewidget"]
    local new_image = image_class.new
    function image_class:new(options)
        observed.image_options = options
        return new_image(self, options)
    end
    for name, module in pairs(modules) do
        package.loaded[name] = nil
        package.preload[name] = function() return module end
    end
    return require("webdavmanga.ui_reader_shell"):new{ owner = owner, screen = screen }
end

do
    local r, o = fixture(production_shell)
    local original = r.page_buffer
    expect(o.image_options.scale_factor == 1 and o.image_options.image == original,
        "ordinary pages must reach ImageWidget without display scaling")
    for _, point in ipairs({ { x = 100, y = 100 }, { x = 500, y = 100 },
        { x = 100, y = 700 }, { x = 500, y = 700 } }) do
        expect(r:onTwoFingerTap(nil, { pos = point }), "production Shell must show each quadrant")
        expect(o.image_options.scale_factor == 0 and r.shell.current_model.display_scale == 0,
            "quadrant must request ImageWidget best-fit for the current reading area")
        expect(o.image_options.image == r.page_viewport and r.page_viewport.parent == original
            and r.shell.current_model.buffer == original and r.page_buffer == original
            and o.image_options.image_disposable == false and #o.requests == 1 and o.decodes == 1,
            "display scaling must borrow the same page and viewport without Loader or decoder work")
        r:onTwoFingerTap(nil, top_right)
        expect(o.image_options.scale_factor == 1 and o.image_options.image == original,
            "collapse must restore 1x ImageWidget scaling and the original page")
    end
    r.page_crop = { x = 10, y = 20, w = 400, h = 600 }
    r:_display_segment("whole", false)
    expect(o.image_options.scale_factor == 1 and o.image_options.image.w == 400,
        "ordinary crop must not inherit quadrant scaling")
    r.reader_settings.split_cut_percent = 50
    r:_display_segment("right", false)
    expect(o.image_options.scale_factor == 1 and o.image_options.image.w == 200,
        "ordinary split must not inherit quadrant scaling")
    r.page_crop, r.fit_mode, r.position.segment = nil, "width", "whole"
    r:_display_segment("whole", false)
    expect(o.image_options.scale_factor == 1 and o.image_options.image.h == 800,
        "ordinary fit-width scroll viewport must remain at 1x")
    r.fit_mode = "page"
    r:onTwoFingerTap(nil, top_right)
    r:next_page()
    o.requests[2].callbacks.on_ready("/cache/3.jpg", false, { width = 800, height = 1200 })
    expect(o.image_options.scale_factor == 1 and r.quadrant_zoom == nil
        and o.image_options.image == r.page_buffer and o.decodes == 2,
        "accepted physical page must restore ordinary ImageWidget scale after one new decode")
    r:onTwoFingerTap(nil, top_right)
    r:enter_panel_mode()
    expect(o.image_options.scale_factor == 1 and r.panel_entry.viewport == r.page_buffer,
        "panel entry must snapshot and display the unscaled ordinary page")
    r:_show_panel(r.page_buffer, {}, 1, 2)
    expect(o.image_options.scale_factor == 1, "panel publication must not retain quadrant scale")
    r:exit_panel_mode()
    expect(o.image_options.scale_factor == 1 and o.image_options.image == r.page_buffer,
        "panel exit must retain ordinary display scale")
end

-- A same-page reload may be pending while its currently visible page is zoomed.
-- Ignored requests must not silently clear that still-visible quadrant.
do
    local r, o = fixture(production_shell)
    r:onTwoFingerTap(nil, top_right)
    r:request_page(2)
    local pending, serial, viewport, model = r.pending_request, r.request_serial,
        r.page_viewport, r.shell.current_model
    expect(pending and r.quadrant_zoom == "top_right", "same-index accepted reload keeps zoom")
    for _, target in ipairs({ 2, 3, 1 }) do
        r:request_page(target)
        expect(r.pending_request == pending and r.request_serial == serial and #o.requests == 2
            and r.quadrant_zoom == "top_right" and r.page_viewport == viewport
            and r.shell.current_model == model and o.image_options.image == viewport
            and o.image_options.scale_factor == 0,
            "ignored pending request for index " .. target .. " must preserve visible quadrant and serial")
    end
    o.requests[2].callbacks.on_ready("/cache/2.jpg", false, { width = 800, height = 1200 })
    r:request_page(3)
    expect(r.quadrant_zoom == nil and r.request_serial == serial + 1 and #o.requests == 3,
        "an accepted different-index request must still clear zoom")
end

print(("rebuild_0405_reader_quadrant_spec: %d checks"):format(checks))
