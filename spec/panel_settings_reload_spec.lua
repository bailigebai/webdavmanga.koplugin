local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end
local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local Settings = require("webdavmanga.settings")
local PanelSource = require("webdavmanga.panel_source")
local PanelDetector = require("webdavmanga.panel_detector")

local function fixture()
    local f = {requests = {}, allocations = {}, violations = {}, shown = nil}
    local saved = {direction = "normal", panel_zoom_enabled = true,
        fit_mode = "page", split_enabled = false, image_prefetch_enabled = false}
    local settings = Settings:new{store = {
        readSetting = function(_, key, fallback)
            if key == "reader" then return saved end
            return fallback
        end,
        saveSetting = function(_, key, value) if key == "reader" then saved = value end end,
        flush = function() return true end,
    }}
    local function buffer(width, height, kind)
        local value = {kind = kind, frees = 0}
        local function use()
            if value.frees > 0 then f.violations[#f.violations + 1] = "used freed " .. kind end
        end
        function value:getWidth() use(); return width end
        function value:getHeight() use(); return height end
        function value:viewport(_, _, w, h) use(); return buffer(w, h, "viewport") end
        function value:scale(w, h) use(); return buffer(w, h, "panel") end
        function value:free()
            self.frees = self.frees + 1
            if f.shown == self then f.violations[#f.violations + 1] = "freed displayed " .. kind end
            if self.frees > 1 then f.violations[#f.violations + 1] = "double free " .. kind end
            local session = f.reader and f.reader.panel_session
            if session and session.handle and session.handle.buffer == self then
                f.violations[#f.violations + 1] = "freed page still borrowed by session"
            end
        end
        f.allocations[#f.allocations + 1] = value
        return value
    end
    f.shell = {
        get_content_size = function() return 600, 800 end,
        show_loading = function() end, show_status = function() end,
        show_page = function(_, value)
            if f.reject_page then return false end
            f.shown = value; return true
        end,
        free_buffer_later = function(_, value) value:free(); return true end,
        close_now = function() f.shown = nil; return true end,
    }
    local images = {
        {path = "/books/001.jpg", name = "001.jpg", width = 600, height = 800},
        {path = "/books/002.jpg", name = "002.jpg", width = 600, height = 800},
    }
    f.reader = Reader:new{
        loader = {identity = "panel-settings", request = function(_, _, image, callbacks)
            f.requests[#f.requests + 1] = {image = image, callbacks = callbacks,
                session = f.reader.panel_session, shown = f.shown}
        end},
        settings = settings, state = State:new(),
        progress = {chapter_id = function() return "chapter" end,
            resolve = function() return {index = 1, segment = "whole"} end, save = function() end},
        cache = {key_for = function(_, _, path) return path end, set_protected = function() end},
        ui = {create_shell = function() return f.shell end, show_shell = function() end},
        render_image = {renderImageFile = function(_, _, _, w, h) return buffer(w, h, "whole") end},
        panel_source = PanelSource:new{mupdf = {}, draw_context = {}},
        panel_detector = {sort = PanelDetector.sort, detect = function(_, options)
            return PanelDetector.sort({
                {id = "left", x = 0, y = 0, w = 0.5, h = 1},
                {id = "right", x = 0.5, y = 0, w = 0.5, h = 1},
            }, options.direction)
        end},
        open_chapter = function() end,
    }
    function f:complete()
        local request = self.requests[#self.requests]
        request.callbacks.on_ready("/cache/" .. request.image.name, false,
            {width = 600, height = 800, format = "jpeg"})
    end
    function f:save(values)
        expect(settings:set_reader(values), "save settings through the real settings store")
        return self.reader:reload_settings(settings:get_reader())
    end
    function f:finish()
        self.reader:force_close("test")
        expect(#self.violations == 0, table.concat(self.violations, ", "))
        for _, value in ipairs(self.allocations) do
            expect(value.frees == 1, "every owned " .. value.kind .. " allocation must be freed once")
        end
    end
    expect(f.reader:open{manga = {path = "/books"}, chapter = {path = "/books"},
        chapter_index = {count = function() return #images end,
            get = function(_, index) return images[index] end}}, "open ordinary reader")
    f:complete()
    expect(f.reader:enter_panel_mode() and f.reader.panel_session:is_active(),
        "enter a real panel session backed by the borrowed whole-page buffer")
    return f
end

do
    local f = fixture()
    local reader = f.reader
    local session, whole, panel = reader.panel_session, reader.page_buffer, f.shown
    expect(f:save{direction = "manga"}, "outer direction save must succeed")
    expect(reader.direction == "manga" and session.direction == "manga"
        and reader.panel_session == session and session:is_active(),
        "outer direction-only reload must reorder the active session with the reader")
    expect(session:current().panel.id == "left" and session:current().index == 2
        and f.shown == panel and #f.requests == 1 and reader.page_buffer == whole,
        "outer direction save must retain the physical panel and avoid reloading its borrowed page")
    reader:previous_page()
    expect(session:current().panel.id == "right" and #f.requests == 1,
        "the next input must follow the newly saved panel order")
    expect(f:save{direction = "normal"}, "reverse the outer direction save")
    expect(session:current().panel.id == "right" and session:current().index == 2
        and session.direction == "normal", "both outer direction changes preserve the physical panel")
    f:finish()
end

for _, change in ipairs({
    {name = "layout", values = {fit_mode = "width"}},
    {name = "filter", values = {kopt_filter_enabled = true, kopt_contrast_enabled = true}},
    {name = "direction and layout", values = {direction = "manga", fit_mode = "width"}},
    {name = "disabled panel mode", values = {panel_zoom_enabled = false}},
    {name = "direct page request"},
}) do
    local f = fixture()
    local reader = f.reader
    local session, whole, panel = reader.panel_session, reader.page_buffer, f.shown
    local handle, callbacks = session.handle, session.callbacks
    if change.values then f:save(change.values) else reader:request_page(1, "whole") end
    expect(reader.panel_session == nil and reader.panel_entry == nil and not session:is_active()
        and handle.closed and handle.buffer == nil,
        change.name .. " reload must close the old session before replacing its borrowed page")
    expect(#f.requests == 2 and f.requests[2].session == nil and f.requests[2].shown == whole
        and f.shown == whole and panel.frees == 1 and whole.frees == 0,
        change.name .. " reload must detach the panel before release and before requesting the new page")
    f:complete()
    local replacement = reader.page_buffer
    expect(replacement ~= whole and f.shown == replacement and whole.frees == 1
        and reader.panel_session == nil and reader.panel_resume == nil,
        change.name .. " reload must publish the new whole page without resuming the stale session")
    callbacks.on_panel(panel, {id = "stale"}, 1, 2)
    callbacks.on_boundary(1)
    callbacks.on_fallback("panel_render_failed")
    expect(f.shown == replacement and #f.requests == 2 and reader.panel_session == nil,
        "late callbacks from the reloaded session must not make an old panel reappear")
    reader:next_page()
    expect(#f.requests == 3 and f.requests[3].image.path == "/books/002.jpg",
        "input after a reload must use ordinary physical navigation")
    f:complete()
    f:finish()
end

do
    local f = fixture()
    local session, panel = f.reader.panel_session, f.shown
    f.reject_page = true
    expect(f.reader:request_page(2, "whole") == false and #f.requests == 1
        and f.reader.panel_session == session and session:is_active() and f.shown == panel
        and panel.frees == 0,
        "a rejected full-page detachment must retain the live panel and abort the page request")
    f.reject_page = false
    f:finish()
end

print(("panel_settings_reload_spec: %d checks"):format(checks))
