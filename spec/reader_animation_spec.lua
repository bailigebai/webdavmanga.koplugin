local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local ReaderShell = require("webdavmanga.ui_reader_shell")
local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")

-- Native display animation owns its frames; Lua owns no transition timer or old-page buffer.
local scheduled, enabled, directions = {}, {}, {}
local widget = {}
function widget:set_model(model) self.model = model end
local shell = ReaderShell:new{
    owner = { force_close = function() return true end },
    widget_factory = function() return widget end,
    ui_manager = { show = function() end, close = function() end },
    scheduler = { scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback end },
    device = { canDoSwipeAnimation = function() return true end },
    screen = {
        setSwipeAnimations = function(_, value) enabled[#enabled + 1] = value; return true end,
        setSwipeDirection = function(_, forward) directions[#directions + 1] = forward; return true end,
    },
}
shell:show_page({}, {}, "2 / 3", { animate = true, forward = true, refresh_type = "partial" })
expect(widget.model.native_animation == true and enabled[1] == true,
    "partial page changes should arm the native display animation")
expect(directions[1] == true and #scheduled == 0,
    "forward animation should set its direction without blocking Lua on software frames")
local calls = #enabled
shell:show_page({}, {}, "3 / 3", { animate = true, forward = false, refresh_type = "full" })
expect(widget.model.native_animation == false and #enabled == calls,
    "full refreshes should bypass native animation")
shell:show_page({}, {}, "1 / 3", { animate = true, forward = false, refresh_type = "partial" })
expect(widget.model.native_animation == true and directions[#directions] == false,
    "the latest reverse page change must replace the native animation direction")
shell:close_now()
calls = #enabled
expect(shell:show_page({}, {}, "closed", { animate = true }) == false and #enabled == calls
    and #scheduled == 0, "closing the reader leaves no frame callbacks or later animation")

local images = {
    { path = "/manga/001.jpg", name = "001.jpg" },
    { path = "/manga/002.jpg", name = "002.jpg" },
}
local function index_for(entries)
    return {
        count = function() return #entries end,
        get = function(_self, index) return entries[index] end,
        window = function(_self, center, radius)
            local result = {}
            for index = math.max(1, center - radius), math.min(#entries, center + radius) do
                result[#result + 1] = entries[index]
            end
            return result
        end,
    }
end
local requests, buffers = {}, {}
local loader = {
    identity = "nas",
    request = function(_self, _generation, image, callbacks)
        requests[#requests + 1] = { image = image, callbacks = callbacks }
        return {}
    end,
    prefetch = function() end,
    cancel_generation = function() end,
}
local renderer = {
    renderImageFile = function(_self, path)
        local buffer = {
            path = path,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            free = function(self) self.freed = (self.freed or 0) + 1 end,
        }
        buffers[#buffers + 1] = buffer
        return buffer
    end,
}
local pages = {}
local active_shell = {
    supports_animation = true,
    get_content_size = function() return 600, 800 end,
    show_loading = function() end,
    show_page = function(self, buffer, viewport, title, transition)
        pages[#pages + 1] = { buffer = buffer, viewport = viewport, title = title, transition = transition }
        self.transition = transition
        return true
    end,
    cancel_transition = function(self)
        if self.transition and self.transition.on_cancel then self.transition.on_cancel() end
        self.transition = nil
    end,
    free_buffer_later = function(_self, buffer) buffer:free() end,
}
local reader = Reader:new{
    loader = loader,
    progress = {
        chapter_id = function() return "chapter" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function() end,
    },
    state = State:new(),
    settings = {
        get_connection = function() return {} end,
        get_reader = function()
            return { direction = "normal", fit_mode = "page", show_page_number = true,
                prefetch_count = 0, split_enabled = false, split_min_ratio = 1.2,
                split_max_ratio = 2.2, split_cut_percent = 50,
                animation_enabled = true, animation_steps = 2, animation_delay_ms = 10 }
        end,
    },
    cache = {
        key_for = function(_self, identity, path) return identity .. "|" .. path end,
        set_protected = function() end,
    },
    ui = {
        create_shell = function() return active_shell end,
        show_shell = function() end,
        close_shell = function() active_shell:cancel_transition() end,
    },
    render_image = renderer,
    open_chapter = function() end,
}
reader:open{
    manga = { name = "Manga", path = "/manga" },
    chapter = { name = "Chapter", path = "/manga/chapter" },
    chapter_index = index_for(images),
    layout = "chapters",
}
requests[1].callbacks.on_ready("/cache/001.jpg", false, { width = 600, height = 800 })
reader:next_page()
requests[2].callbacks.on_ready("/cache/002.jpg", false, { width = 600, height = 800 })
expect(pages[2].transition and pages[2].transition.animate == true
    and pages[2].transition.forward == true and buffers[1].freed == 1,
    "native forward animation must release the previous Lua buffer exactly once")

reader:request_page(1)
requests[3].callbacks.on_ready("/cache/001-again.jpg", false, { width = 600, height = 800 })
expect(pages[3].transition and pages[3].transition.animate == true
    and pages[3].transition.forward == false and buffers[2].freed == 1,
    "native reverse animation must release its previous Lua buffer exactly once")
reader:force_close("back")
expect(buffers[2].freed == 1 and buffers[3].freed == 1,
    "closing after native animation must free the current buffer without double-freeing the previous one")

print(("reader_animation_spec: %d checks"):format(checks))
