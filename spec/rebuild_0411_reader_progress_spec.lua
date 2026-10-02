local BookIndex = require("webdavmanga.book_index")
local Reader = require("webdavmanga.ui_reader")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function pages(count)
    local items = {}
    for position = 1, count do
        items[position] = { name = position .. ".jpg", path = "/" .. position .. ".jpg" }
    end
    return items
end

local index = BookIndex.from_items(pages(3))
local state = {
    phase = "warming_20", complete = false, available_pages = 3,
    total_pages = nil, error = nil, generation = "open-a", warm_target = 20,
}
local info, picker, next_chapter, requested, refreshes = nil, nil, 0, nil, 0
local reader = setmetatable({
    context = { chapter_index = index, stream_state = state },
    position = { index = 3, segment = "whole" },
    current_segments = { "whole" },
    fit_mode = "page",
    ui = {
        show_info = function(_, message) info = message; return true end,
        show_page_picker = function(_, model) picker = model; return true end,
    },
    shell = { refresh = function() refreshes = refreshes + 1 end },
    _ask_next_chapter = function() next_chapter = next_chapter + 1; return true end,
    request_page = function(_, page) requested = page; return true end,
}, { __index = Reader })

local warm = reader:_stream_progress()
expect(warm and warm.phase == "warming_20" and warm.available_pages == 3
    and warm.generation == "open-a" and warm.warm_target == 20,
    "warming_20 exposes a read-only progress snapshot")
reader:show_page_picker()
expect(picker == nil and info and info:find("预热", 1, true),
    "warming_20 keeps page jumping gated with a phase-specific hint")
info = nil
reader:next_page()
expect(info and info:find("预热", 1, true) and next_chapter == 0
    and refreshes == 0,
    "warming_20 waits at the known end without refreshing the reader")

state.phase = "indexing"
state.available_pages = 3
state.catalog_pages = 3
info = nil
reader:next_page()
expect(info and info:find("目录", 1, true) and next_chapter == 0,
    "indexing waits at the known end")
info = nil
reader:show_page_picker()
expect(picker == nil and info and info:find("目录", 1, true),
    "indexing keeps the jump picker gated")

expect(index:replace_items(pages(5), "open-a") == true,
    "fixture grows the shared index during background indexing")
state.catalog_pages = 5
state.available_pages = 5
reader:next_page()
expect(requested == 4 and next_chapter == 0,
    "newly available pages remain readable while indexing continues")

local catalog_index = BookIndex.from_items(pages(25))
local catalog_state = {
    phase = "complete", complete = true, available_pages = 3,
    catalog_pages = 25, total_pages = 25, generation = "catalog-complete",
    warm_target = 20,
}
reader.context.chapter_index = catalog_index
reader.context.stream_state = catalog_state
picker, info = nil, nil
reader:show_page_picker()
expect(picker and picker.value_max == 25 and info == nil,
    "completed directory enables jump without claiming all page images readable")
reader.context.chapter_index = index
reader.context.stream_state = state

state.phase = "failed"
state.error = "network_error"
local recovery
state.retry = function() return true end
state.complete_download = function() return true end
reader.ui.show_stream_recovery = function(_, model) recovery = model; return true end
reader.position.index = 5
info = nil
reader:next_page()
expect(recovery and type(recovery.on_retry) == "function"
    and type(recovery.on_download) == "function"
    and type(recovery.on_return) == "function" and next_chapter == 0,
    "failed indexing offers retry, explicit complete download, and return")
state.retry_pending = true
state.retry = function() return false end
info = nil
recovery.on_retry()
expect(info and info:find("收尾", 1, true),
    "retry before child reap shows a bounded finishing hint")
state.retry_pending = nil
requested = nil
reader:previous_page()
expect(requested == 4,
    "failed background work keeps already indexed pages readable")

local panel_state = {
    phase = "indexing", complete = false, available_pages = 3,
    total_pages = nil, error = nil, generation = "panel-open", warm_target = 20,
}
local panel_info, panel_next_chapter = nil, 0
local panel_reader = setmetatable({
    context = { chapter_index = BookIndex.from_items(pages(3)), stream_state = panel_state },
    position = { index = 3, segment = "whole" },
    current_segments = { "whole" },
    fit_mode = "page",
    page_buffer = {},
    reader_settings = { panel_zoom_enabled = true },
    panel_source = {}, panel_detector = {},
    request_serial = 1, generation = 1, direction = "normal",
    ui = { show_info = function(_, message) panel_info = message; return true end },
    shell = { show_status = function() return true end,
        get_content_size = function() return 600, 800 end },
    _active = function() return true end,
    _ask_next_chapter = function() panel_next_chapter = panel_next_chapter + 1; return true end,
    panel_session_factory = function()
        return {
            direction = "normal",
            start = function(self, _, callbacks) self.callbacks = callbacks; return true end,
            move = function(self, delta) return self.callbacks.on_boundary(delta) end,
        }
    end,
}, { __index = Reader })
expect(panel_reader:enter_panel_mode() == true,
    "panel fixture enters the real reader boundary callback")
panel_reader:next_page()
expect(panel_info and panel_info:find("目录", 1, true) and panel_next_chapter == 0,
    "panel boundary waits while the page directory is incomplete")
panel_state.phase, panel_state.complete = "complete", true
panel_reader:next_page()
expect(panel_next_chapter == 1,
    "panel boundary restores normal chapter-end navigation after completion")

local short_index = BookIndex.from_items(pages(3))
local short_state = {
    phase = "complete", complete = true, available_pages = 3,
    total_pages = 3, error = nil, generation = "open-short", warm_target = 20,
}
reader.context.chapter_index = short_index
reader.context.stream_state = short_state
reader.position.index = 3
info, picker = nil, nil
reader:show_page_picker()
reader:next_page()
expect(picker and picker.value_max == 3 and next_chapter == 1 and info == nil,
    "a short complete document restores normal jump and chapter-end navigation")

print(("rebuild_0411_reader_progress_spec: %d checks"):format(checks))
