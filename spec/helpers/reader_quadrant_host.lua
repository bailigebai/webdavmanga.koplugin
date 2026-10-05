-- Host boundary for Reader/Shell tests. Fit tests load KOReader's actual
-- ImageWidget from KOREADER_FRONTEND; no upstream implementation is copied.
return function(use_image_widget, options)
    options = options or {}
    local o = { requests = {}, decodes = 0, saves = 0, views = {}, scales = {}, dirty = 0 }
    local function buffer(w, h, parent)
        local b = { w = w, h = h, parent = parent, frees = 0 }
        function b:getWidth() return self.w end
        function b:getHeight() return self.h end
        function b:free() self.frees = self.frees + 1 end
        if options.pixel then
            function b:getPixel(x,y)
                assert(self.frees==0,"read after free")
                if self.parent then return self.parent:getPixel((self.x or 0)+x,(self.y or 0)+y) end
                o.reads=(o.reads or 0)+1
                return options.pixel(x,y)
            end
        end
        function b:viewport(x, y, width, height)
            assert(x >= 0 and y >= 0 and width > 0 and height > 0
                and x + width <= self.w and y + height <= self.h, "viewport out of bounds")
            local view = buffer(width, height, self)
            view.x, view.y = x, y
            o.views[#o.views + 1] = view
            return view
        end
        return b
    end
    local function class()
        local c = {}; c.__index = c
        function c:new(value)
            value = setmetatable(value or {}, self)
            if value.init then value:init() end
            return value
        end
        function c:extend(value)
            value = setmetatable(value or {}, { __index = self }); value.__index = value
            return value
        end
        function c:getSize()
            if self.dimen then return self.dimen end
            if self.text then return {w=math.min(#self.text*10,self.max_width or 600),h=20} end
            local child=self[1] and self[1]:getSize() or {w=0,h=0}
            return {w=child.w+2*(self.padding or 0),h=child.h+2*(self.padding or 0)}
        end
        function c:free()
            for _,child in ipairs(self) do if child.free then child:free() end end
        end
        return c
    end
    local screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end, scaleByDPI = function(_, n) return n end }
    local modules = {
        device = { screen = screen, input = { group = {} } },
        ["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 0 },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/geometry"] = { new = function(_, value) return value end },
        ["ui/gesturerange"] = { new = function(_, value) return value end },
        ["ui/size"] = { padding = { default = 8 } },
        ["ui/uimanager"] = { setDirty = function() o.dirty = o.dirty + 1 end, close = function() end },
    }
    for _, name in ipairs({ "button", "container/centercontainer", "container/framecontainer",
        "container/inputcontainer", "horizontalgroup", "horizontalspan", "imagewidget",
        "linewidget", "overlapgroup", "textwidget", "titlebar", "verticalgroup", "widget" }) do
        modules["ui/widget/" .. name] = class()
    end
    if use_image_widget then
        modules.cache = { new = function(_, value) return value end }
        modules.logger = { dbg = function() end }
        modules.util = {}
        modules["ui/renderimage"] = { scaleBlitBuffer = function(_, source, w, h, disposable)
            assert(not disposable, "quadrant scaling must borrow the source allocation")
            local scaled = buffer(w, h, source)
            o.scales[#o.scales + 1] = scaled
            return scaled
        end }
        G_reader_settings = { isTrue = function() return false end }
    end
    for name, module in pairs(modules) do package.loaded[name] = module end
    if use_image_widget then
        local frontend = assert(os.getenv("KOREADER_FRONTEND"),
            "Set KOREADER_FRONTEND to a KOReader frontend checkout for real ImageWidget tests")
        package.loaded["ui/widget/imagewidget"] = dofile(frontend .. "/ui/widget/imagewidget.lua")
    end
    local image_class = package.loaded["ui/widget/imagewidget"]
    local new_image = image_class.new
    function image_class:new(value)
        o.image = new_image(self, value)
        return o.image
    end
    local Reader = require("webdavmanga.ui_reader")
    local Shell = require("webdavmanga.ui_reader_shell")
    local State = require("webdavmanga.state")
    local settings = { direction = "normal", fit_mode = options.fit_mode or "page",
        split_enabled = options.split == true, split_cut_percent = 50,
        prefetch_count = 0, panel_zoom_enabled = true, panel_show_full_page = true }
    local entries = { { name = "1.jpg", path = "/chapter/1.jpg" },
        { name = "2.jpg", path = "/chapter/2.jpg" } }
    local r = Reader:new{
        open_chapter = function() error("unexpected chapter transition") end,
        state = State:new(), settings = { get_reader = function() return settings end,
            get_connection = function() return {} end },
        loader = { identity = "quadrant-host", request = function(_, _, image, callbacks)
            o.requests[#o.requests + 1] = { image = image, callbacks = callbacks }; return {}
        end },
        progress = { chapter_id = function() return "chapter" end,
            resolve = function() return { index = 1, segment = "whole" } end,
            save = function() o.saves = o.saves + 1 end },
        cache = { key_for = function(_, _, path) return path end, set_protected = function() end },
        render_image = { renderImageFile = function()
            o.decodes = o.decodes + 1
            return buffer(options.w or 600, options.h or 800)
        end },
        ui = { create_shell = function(_, owner) return Shell:new{ owner = owner, screen = screen } end,
            show_shell = function() return true end },
        panel_source = {}, panel_detector = {},
        panel_session_factory = function() return { start = function() return true end,
            close = function() end, is_active = function() return true end } end,
    }
    local context = { manga = { name = "Manga", path = "/manga" },
        chapter = { name = "Chapter", path = "/chapter" }, chapter_index = {
            count = function() return #entries end, get = function(_, i) return entries[i] end,
            window = function() return entries end,
        } }
    assert(r:open(context), "Reader must open")
    o.requests[1].callbacks.on_ready("/cache/1.jpg", false,
        { width = options.w or 600, height = options.h or 800 })
    assert(r.page_buffer and r.shell.current_model.kind == "page", "Reader must publish a page")
    return r, o, context
end
