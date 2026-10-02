local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function count(values, wanted)
    local total = 0
    for _, value in ipairs(values) do
        if value == wanted then total = total + 1 end
    end
    return total
end

local Reader = require("webdavmanga.ui_reader")
local ReaderShell = require("webdavmanga.ui_reader_shell")
local State = require("webdavmanga.state")

local production_gesture_calls = {}

local images = {
    { name = "001.jpg", path = "/manga/chapter/001.jpg" },
    { name = "002.jpg", path = "/manga/chapter/002.jpg" },
    { name = "003.jpg", path = "/manga/chapter/003.jpg" },
}

local function index_for(entries)
    return {
        count = function() return #entries end,
        get = function(_self, index) return entries[index] end,
        find = function(_self, path, hint)
            if entries[hint] and entries[hint].path == path then return hint end
            for index, image in ipairs(entries) do
                if image.path == path then return index end
            end
        end,
        window = function(_self, center, radius)
            local result = {}
            for index = math.max(1, center - radius), math.min(#entries, center + radius) do
                result[#result + 1] = entries[index]
            end
            return result
        end,
    }
end

local context = {
    manga = { name = "Manga", path = "/manga" },
    chapter = { name = "Chapter", path = "/manga/chapter" },
    chapter_index = index_for(images),
    layout = "chapters",
    source_context = {
        manifest_keys = { "manifest:chapters", "manifest:images" },
    },
}

local function reader_settings(split_enabled)
    return {
        direction = "normal", fit_mode = "page", show_page_number = true,
        prefetch_count = 2, split_enabled = split_enabled == true,
        split_min_ratio = 1.2, split_max_ratio = 2.2,
        split_cut_percent = 50,
    }
end

-- The production shell must remain require-able without KOReader widget modules.
local direct_sources = {}
local host_shell = ReaderShell:new{
    owner = {
        force_close = function(_self, source)
            direct_sources[#direct_sources + 1] = source
            return true
        end,
        onTap = function(_self, _arg, _gesture)
            production_gesture_calls[#production_gesture_calls + 1] = "tap"
            return true
        end,
        onSwipe = function(_self, _arg, _gesture)
            production_gesture_calls[#production_gesture_calls + 1] = "swipe"
            return true
        end,
    },
    ui_manager = {
        show = function() end,
        close = function() end,
    },
    scheduler = { scheduleIn = function(_self, _delay, callback) callback() end },
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getSize = function() return { w = 600, h = 800 } end,
    },
    widget_factory = function(model) return model end,
}
host_shell:show_loading("正在加载")
expect(host_shell.widget.left_icon_tap_callback() == true
    and host_shell.widget.onBack() == true
    and host_shell.widget.onClose() == true
    and host_shell.current_model.on_cancel() == true,
    "left-top, hardware Back, close, and loading cancel must call the direct exit")
host_shell:show_error{
    message = "broken",
    normal_tap_callback = function() return true end,
}
expect(host_shell.current_model.normal_tap_callback() == true,
    "the error-layer fixture should consume ordinary taps")
expect(host_shell.current_model.on_back() == true
    and host_shell.widget.left_icon_tap_callback() == true,
    "a consuming error layer must not swallow Back or left-top exit")
expect(table.concat(direct_sources, ",") ==
    "left_top,back,back,loading_cancel,error_back,left_top",
    "all shell exits must identify their direct source")
local picked
host_shell:show_page_picker{
    value = 25, value_min = 1, value_max = 100,
    on_select = function(value) picked = value; return true end,
}
expect(host_shell.current_model.columns == 2
    and #host_shell.current_model.actions == 7,
    "page picker should expose bounded twenty, ten, and one page jumps")
host_shell.current_model.actions[1].callback()
expect(host_shell.current_model.message == "第 5 / 100 张",
    "minus twenty should clamp through the page picker")
host_shell.current_model.actions[5].callback()
expect(host_shell.current_model.message == "第 15 / 100 张",
    "plus ten should update the picker value")
host_shell.current_model.actions[7].callback()
expect(picked == 15, "jump should submit the value after shortcut navigation")
expect(type(host_shell.widget.onTap) == "function"
    and type(host_shell.widget.onSwipe) == "function"
    and type(host_shell.widget.onEdgeTap) == "function"
    and type(host_shell.widget.onGesture) == "function",
    "reader shell must expose tap, swipe, edge-tap, and generic gesture forwarding")
host_shell.widget.onTap(host_shell.widget, nil, { pos = { x = 300, y = 400 } })
host_shell.widget.onSwipe(host_shell.widget, nil, { direction = "west" })
host_shell.widget.onEdgeTap(host_shell.widget, nil, { pos = { x = 2, y = 400 } })
expect(table.concat(production_gesture_calls, ",") == "tap,swipe,tap",
    "reader shell gestures must forward to the controller")
host_shell.owner.onHold = function() return "held" end
expect(host_shell.widget.ges_events.Hold ~= nil and type(host_shell.widget.onHold) == "function",
    "legacy shell must register Hold")
expect(host_shell.widget:onHold(nil, { pos = { x = 100, y = 100 } }) == "held"
    and host_shell.widget:onGesture({ ges = "hold", pos = { x = 100, y = 100 } }) == "held",
    "legacy Hold and generic hold gestures must dispatch to the existing owner")
host_shell.owner.onHold = function() error("hold failed") end
expect(pcall(host_shell.widget.onHold, host_shell.widget, nil, {}),
    "legacy Hold must use the safe owner callback boundary")

-- The production widget must not take ownership of a Reader-owned BlitBuffer.
-- Inject the smallest KOReader-compatible host so this remains a host-side spec.
local function fake_widget_class()
    local class = {}
    class.__index = class
    function class:new(options)
        local object = options or {}
        setmetatable(object, self)
        if object.init then object:init() end
        return object
    end
    function class:extend(definition)
        local child = definition or {}
        setmetatable(child, { __index = self })
        child.__index = child
        return child
    end
    return class
end
local fake_screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    getSize = function() return { w = 600, h = 800 } end,
}
local shown_widgets, closed_widgets = {}, {}
local next_tick_callbacks = {}
local fake_ui_manager = {
    show = function(_self, widget) shown_widgets[#shown_widgets + 1] = widget end,
    close = function(_self, widget) closed_widgets[#closed_widgets + 1] = widget end,
    setDirty = function() end,
    nextTick = function(_self, callback)
        next_tick_callbacks[#next_tick_callbacks + 1] = callback
        return true
    end,
}
local numeric_dialog_options
local numeric_dialog_class = fake_widget_class()
function numeric_dialog_class:new(options)
    numeric_dialog_options = options
    local object = fake_widget_class().new(self, options)
    function object:getFields()
        return self.test_fields or { tostring(options.fields[1].text or "") }
    end
    function object:onShowKeyboard() self.keyboard_shown = true end
    function object:onCloseKeyboard()
        self.keyboard_shown = false
        self.keyboard_closed = true
        return true
    end
    return object
end
local input_container_class = fake_widget_class()
local fail_production_paint = false
function input_container_class.paintTo()
    if fail_production_paint then error("simulated KOReader repaint failure") end
    return true
end
local fake_modules = {
    ["device"] = {
        screen = fake_screen,
        input = { group = {
            PgFwd = { "RPgFwd", "LPgFwd" },
            PgBack = { "RPgBack", "LPgBack" },
            Back = { "Back" },
        } },
    },
    ["ffi/blitbuffer"] = { COLOR_WHITE = 1, COLOR_BLACK = 0 },
    ["ui/widget/button"] = fake_widget_class(),
    ["ui/widget/container/centercontainer"] = fake_widget_class(),
    ["ui/widget/container/framecontainer"] = fake_widget_class(),
    ["ui/widget/container/inputcontainer"] = input_container_class,
    ["ui/font"] = {},
    ["ui/widget/horizontalgroup"] = fake_widget_class(),
    ["ui/widget/horizontalspan"] = fake_widget_class(),
    ["ui/widget/linewidget"] = fake_widget_class(),
    ["ui/widget/multiinputdialog"] = numeric_dialog_class,
    ["ui/widget/overlapgroup"] = fake_widget_class(),
    ["ui/geometry"] = {
        new = function(_self, values) return values end,
    },
    ["ui/gesturerange"] = {
        new = function(_self, values) return values end,
    },
    ["ui/size"] = {},
    ["ui/widget/titlebar"] = fake_widget_class(),
    ["ui/uimanager"] = fake_ui_manager,
    ["ui/widget/verticalgroup"] = fake_widget_class(),
}
local fake_message_face = { name = "cfont" }
fake_modules["ui/font"].getFace = function(_self, name)
    expect(name == "cfont", "reader messages must request KOReader's content font")
    return fake_message_face
end
local text_class = fake_widget_class()
local captured_text_options
function text_class:new(options)
    captured_text_options = options
    return fake_widget_class().new(self, options)
end
fake_modules["ui/widget/textwidget"] = text_class
local image_class = fake_widget_class()
local captured_image_options
function image_class:new(options)
    captured_image_options = options
    return fake_widget_class().new(self, options)
end
fake_modules["ui/widget/imagewidget"] = image_class
for name, module in pairs(fake_modules) do
    package.loaded[name] = nil
    package.preload[name] = function() return module end
end
local production_close_sources = {}
local production_control_sources = {}
local production_shell = ReaderShell:new{
    owner = { force_close = function(_self, source)
        production_close_sources[#production_close_sources + 1] = source
        return true
    end, close_controls = function(_self, source)
        production_control_sources[#production_control_sources + 1] = source
        return true
    end },
    screen = fake_screen,
    ui_manager = fake_ui_manager,
}
production_shell:show_page({ id = "owned" }, { id = "viewport" },
    "1 / 1", nil, 0.5, true)
expect(captured_image_options and captured_image_options.image_disposable == false,
    "production ImageWidget must not free the Reader-owned page buffer")
expect(production_shell.widget.modal == false
    and production_shell.widget.covers_fullscreen == true,
    "the fullscreen reader must not block later KOReader dialogs with a modal layer")
expect(captured_image_options.width == 600 and captured_image_options.height == 800,
    "production page content must use the complete screen without a title-bar gap")
expect(captured_image_options.scale_factor == 1,
    "production reader must preserve the pre-scaled viewport without a second fit")
expect(production_shell.widget.key_events
    and production_shell.widget.key_events.MangaNext
    and production_shell.widget.key_events.MangaPrevious
    and production_shell.widget.key_events.MangaBack,
    "production reader must register Bluetooth HID page and back key aliases")
local next_sequence = production_shell.widget.key_events.MangaNext[1]
local previous_sequence = production_shell.widget.key_events.MangaPrevious[1]
local back_sequence = production_shell.widget.key_events.MangaBack[1]
expect(type(next_sequence) == "table" and type(next_sequence[1]) == "table"
    and next_sequence[1][1] == "RPgFwd"
    and type(previous_sequence[1]) == "table"
    and previous_sequence[1][1] == "RPgBack"
    and type(back_sequence[1]) == "table" and back_sequence[1][1] == "Back",
    "Bluetooth aliases must use KOReader's nested alternative-key sequence format")
local function matches_key(name, sequence)
    local key = { [name] = true }
    for _, requirement in ipairs(sequence or {}) do
        if type(requirement) ~= "table" then
            if not key[requirement] then return false end
        else
            local found = false
            for _, variant in ipairs(requirement) do
                if key[variant] then found = true; break end
            end
            if not found then return false end
        end
    end
    return true
end
expect(matches_key("BtnA", next_sequence)
    and matches_key("RPgBack", previous_sequence)
    and matches_key("BtnSelect", back_sequence),
    "Bluetooth controller aliases must match the same way as KOReader Key:match")
local bluetooth_calls = {}
local bluetooth_shell = ReaderShell:new{
    owner = {
        next_page = function() bluetooth_calls[#bluetooth_calls + 1] = "next"; return true end,
        previous_page = function() bluetooth_calls[#bluetooth_calls + 1] = "previous"; return true end,
    },
    screen = fake_screen,
    ui_manager = fake_ui_manager,
}
expect(bluetooth_shell.widget:onGotoViewRel(1) == true
    and bluetooth_shell.widget:onGotoPageRel(-1) == true
    and bluetooth_shell.widget:onGotoViewRel(0) == true
    and table.concat(bluetooth_calls, ",") == "next,previous",
    "Bluetooth GotoViewRel and GotoPageRel events must turn manga pages safely")
local production_root = production_shell.widget[1]
production_shell.owner.onHold = function() return "production held" end
expect(production_shell.widget.ges_events.Hold ~= nil,
    "production reader shell must register a Hold gesture")
expect(production_shell.widget:onHold(nil, { pos = { x = 100, y = 100 } }) == "production held",
    "production Hold must reach the existing reader owner")
production_shell.owner.onHold = function() error("production hold failed") end
expect(pcall(production_shell.widget.onHold, production_shell.widget, nil, {}),
    "production Hold must use the safe owner callback boundary")
local page_tap_range = production_shell.widget.ges_events.Tap[1].range()
expect(#production_root == 2 and #production_close_sources == 0
    and page_tap_range.y == 0
    and page_tap_range.h == 800,
    "visible progress must overlay the full page while the close control stays hidden")
production_shell:show_page({ id = "owned-2" }, { id = "viewport-2" },
    nil, nil, 0.75, false)
production_root = production_shell.widget[1]
expect(#production_root == 1 and #production_close_sources == 0,
    "disabling progress must leave manga content while the close control stays hidden")
expect(production_shell:show_exit_button() == true,
    "reader shell should reveal the emergency exit button")
production_root = production_shell.widget[1]
    expect(#production_root == 2 and production_root[2].text == "X 返回漫画"
    and production_root[2].width == 280
    and type(production_root[2].callback) == "function",
    "emergency exit button should be large and topmost")
production_root[2].callback()
expect(production_close_sources[#production_close_sources] == "right_top_return",
    "emergency exit button must call the direct reader close path")
production_shell:show_controls{ title = "阅读设置", actions = {} }
expect(production_shell:show_exit_button() == true,
    "reader shell should reveal the emergency exit button while settings are open")
production_root = production_shell.widget[1]
expect(#production_root == 2 and production_root[2].text == "X 返回漫画"
    and type(production_root[2].callback) == "function",
    "settings layer should expose the same topmost exit button")
production_root[2].callback()
expect(production_control_sources[#production_control_sources] == "close_controls"
    and #production_close_sources == 1,
    "settings exit button must close controls without destroying the manga reader")
production_shell:show_controls{ title = "滤镜总览", actions = {} }
production_shell.owner.onRightTopDoubleTap = function()
    return production_shell:show_exit_button()
end
local controls_double_tap_range = production_shell.widget.ges_events.DoubleTap[1].range()
expect(controls_double_tap_range.y == 0,
    "reader settings double-tap exit must include the title-bar top edge")
expect(production_shell.widget:onDoubleTap(nil, {
    ges = "double_tap", pos = { x = 560, y = 30 },
}) == true and production_shell.current_model.show_exit_button == true,
    "double-tap in reader settings must reveal the emergency exit button")
production_close_sources = {}
production_shell:show_loading("正在加载")
expect(captured_text_options and captured_text_options.face == fake_message_face,
    "production loading text must carry a valid KOReader font face")
local loading_tap_range = production_shell.widget.ges_events.Tap[1].range()
expect(loading_tap_range.y == production_shell.top_h
    and loading_tap_range.h == 800 - production_shell.top_h,
    "loading and error content must keep their ordinary title-bar range")
expect(production_shell.widget.ges_events
    and production_shell.widget.ges_events.Tap
    and production_shell.widget.ges_events.Swipe
    and production_shell.widget.ges_events.EdgeTap,
    "production fullscreen widget must register tap, swipe, and edge-tap ranges")

fail_production_paint = true
expect(pcall(production_shell.widget.paintTo, production_shell.widget, {}, 0, 0)
    and #next_tick_callbacks == 1 and #production_close_sources == 0,
    "a KOReader repaint failure must be contained and defer reader cleanup")
fail_production_paint = false
next_tick_callbacks[1]()
expect(production_close_sources[#production_close_sources] == "render_error",
    "deferred repaint recovery must safely exit only the manga reader")

local numeric_saved
expect(production_shell:show_number_input{
    title = "最小宽高比",
    description = "输入数值",
    value = "1.20",
    on_save = function(value)
        numeric_saved = value
        return value == "1.35"
    end,
}, "the production reader shell should open a numeric input dialog")
local numeric_dialog = shown_widgets[#shown_widgets]
expect(numeric_dialog_options.fields[1].input_type == "number"
    and numeric_dialog.keyboard_shown == true
    and type(numeric_dialog_options.enter_callback) == "function"
    and numeric_dialog_options.modal == nil
    and numeric_dialog_options.title_bar_left_icon == "control.collapse"
    and type(numeric_dialog_options.title_bar_left_icon_tap_callback) == "function",
    "ratio input must keep normal KOReader ordering and request the numeric keyboard")
numeric_dialog.test_fields = { "1.25" }
numeric_dialog_options.title_bar_left_icon_tap_callback()
expect(numeric_dialog.keyboard_closed == true
    and numeric_dialog_options.fields[1].text == "1.25",
    "ratio input must expose a fixed top hide-keyboard action without losing text")
numeric_dialog.test_fields = { "invalid" }
numeric_dialog_options.buttons[1][2].callback()
expect(numeric_saved == "invalid" and #closed_widgets == 0,
    "invalid numeric input must keep the dialog open")
numeric_dialog.test_fields = { "1.35" }
numeric_dialog_options.buttons[1][2].callback()
expect(numeric_saved == "1.35" and closed_widgets[1] == numeric_dialog,
    "valid numeric input should close only after it has been saved")
expect(production_shell.input_dialog == nil,
    "saving a numeric input must release the reader's dialog reference")
expect(production_shell:show_number_input{
    title = "裁切强度", value = "25", on_save = function() return false end,
}, "a second numeric input should open")
local interrupted_dialog = shown_widgets[#shown_widgets]
production_shell:close_now()
expect(closed_widgets[#closed_widgets - 1] == interrupted_dialog
    and closed_widgets[#closed_widgets] == production_shell.widget
    and interrupted_dialog.keyboard_closed == true,
    "reader shutdown must release the keyboard and close an interrupted input before its fullscreen window")

-- Free zoom borrows the current session panel while the fullscreen shell stays underneath.
for _, close_failure in ipairs({ "none", "overlay", "input", "fullscreen" }) do
    local zoom_events, stack, cleanup_queue = {}, {}, {}
    local viewer_loads, viewer_cleanups, current_frees, next_frees = 0, 0, 0, 0
    local fail_viewer_cleanup, fail_panel_repaint = false, false
    local next_frees_at_show
    local fail_after_remove
    local underlay = {}
    stack[1] = underlay
    local underlay_exposed, freed_while_visible = false, false
    local zoom_ui = {
        show = function(_self, widget)
            if widget.image then next_frees_at_show = next_frees end
            stack[#stack + 1] = widget
        end,
        close = function(_self, widget)
            zoom_events[#zoom_events + 1] = widget
            -- KOReader sends CloseWidget before removing the stack entry.
            if widget.onCloseWidget then widget:onCloseWidget() end
            for i = #stack, 1, -1 do
                if stack[i] == widget then table.remove(stack, i); break end
            end
            if widget == fail_after_remove then error("UI refresh failed after removal") end
        end,
    }
    local viewer_class = fake_widget_class()
    function viewer_class:onClose() zoom_ui:close(self); return true end
    function viewer_class:onCloseWidget()
        viewer_cleanups = viewer_cleanups + 1
        if self.image_disposable then self.image:free() end
        if fail_viewer_cleanup then error("native cleanup failed") end
    end
    package.loaded["ui/widget/imageviewer"] = nil
    package.preload["ui/widget/imageviewer"] = function()
        viewer_loads = viewer_loads + 1
        return viewer_class
    end
    local panel_buffer = { free = function()
        current_frees = current_frees + 1
        if #stack > 1 then freed_while_visible = true end
    end }
    local Session = require("webdavmanga.panel_session")
    local session = Session:new{
        source = {}, detector = {}, screen_width = 600, screen_height = 800,
        schedule = function(callback) cleanup_queue[#cleanup_queue + 1] = callback end,
    }
    session.active, session.index = true, 1
    session.panels = { { id = "first" }, { id = "second" } }
    session.current_buffer = panel_buffer
    session.next_buffer = { free = function() next_frees = next_frees + 1 end }
    session.next_index = 2
    session:_schedule_next() -- A queued look-ahead must also be invalidated by Hold.
    local repaints, cleanup_seen_on_repaint = 0, 0
    local zoom_shell = ReaderShell:new{
        owner = {}, screen = fake_screen, ui_manager = zoom_ui,
        widget_factory = function(model)
            model.refresh_status = function() end
            model.set_model = function(_self, page)
                if page.kind == "page" and not page.status_text then
                    repaints = repaints + 1
                    cleanup_seen_on_repaint = viewer_cleanups
                    if stack[#stack] == underlay then underlay_exposed = true end
                    if fail_panel_repaint then error("panel repaint failed") end
                end
            end
            return model
        end,
    }
    local zoom_reader = setmetatable({
        shell = zoom_shell, context = context, position = { index = 2, segment = "whole" },
        panel_session = session, panel_entry = {}, request_serial = 1, generation = 3,
        reader_settings = { panel_zoom_enabled = false, panel_initial_zoom = 1.2,
            panel_hold_margin_percent = 5 },
        state = { is_current = function() return false end }, loader = {},
        ui = { schedule = function(_self, callback) cleanup_queue[#cleanup_queue + 1] = callback end },
    }, { __index = Reader })
    zoom_shell:show()
    zoom_reader:_show_panel(panel_buffer, session.panels[1], 1, 2)
    expect(zoom_reader:onHold() == false and viewer_loads == 0,
        "disabled Hold and ordinary panel publishing must not load ImageViewer")
    expect(type(zoom_shell.show_panel_zoom) == "function"
        and type(zoom_shell.close_panel_zoom) == "function",
        "ReaderShell must provide the missing panel zoom overlay API")
    zoom_reader.reader_settings.panel_zoom_enabled = true
    expect(zoom_reader:onHold(nil, { pos = { x = 300, y = 400 } }) == true,
        "holding an active panel must open free zoom")
    local viewer = zoom_shell.panel_zoom
    expect(viewer and stack[#stack] == viewer and viewer_loads == 1 and next_frees_at_show == 1
        and viewer.image == panel_buffer and viewer.image_disposable == false
        and viewer.fullscreen == true and viewer.with_title_bar == false
        and viewer.buttons_visible == false and viewer.scale_factor == 1.2
        and viewer.image_padding == 30,
        "free zoom must borrow the current panel with configured scale and pixel padding")
    cleanup_queue[1]()
    expect(next_frees == 1 and session.next_buffer == nil and current_frees == 0,
        "free zoom must release look-ahead and invalidate queued prefetch without freeing current")
    expect(zoom_reader:onHold() == true and zoom_shell:show_panel_zoom{} == true
        and zoom_shell.panel_zoom == viewer and #stack == 3,
        "repeated Hold and show_panel_zoom must retain one overlay")
    local paints_before_close = repaints
    viewer:onClose()
    expect(zoom_shell.panel_zoom == nil and stack[#stack] == zoom_shell.widget
        and zoom_shell.current_model.buffer == panel_buffer
        and zoom_reader.panel_session == session and session.index == 1
        and repaints == paints_before_close + 1 and cleanup_seen_on_repaint == 1
        and not underlay_exposed and current_frees == 0,
        "native cleanup must precede synchronous restoration of the same panel without underlay")
    zoom_shell:close_panel_zoom()
    viewer:onCloseWidget()
    expect(viewer_cleanups == 1 and repaints == paints_before_close + 1,
        "overlay close and late CloseWidget must be idempotent")
    zoom_reader.reader_settings.panel_initial_zoom = 1.5
    zoom_reader.reader_settings.panel_hold_margin_percent = 10
    zoom_reader:onHold()
    viewer = zoom_shell.panel_zoom
    expect(viewer.scale_factor == 1.5 and viewer.image_padding == 60,
        "reopening must use the latest panel settings")
    fail_viewer_cleanup = true
    expect(pcall(zoom_shell.close_panel_zoom, zoom_shell) and stack[#stack] == zoom_shell.widget,
        "native cleanup failure must not strand the overlay or block its removal")
    fail_viewer_cleanup = false
    expect(zoom_shell.panel_zoom == nil and current_frees == 0 and viewer_cleanups == 2,
        "explicit overlay close must keep the session buffer alive")
    zoom_reader:onHold()
    fail_panel_repaint = true
    expect(pcall(zoom_shell.panel_zoom.onClose, zoom_shell.panel_zoom)
        and stack[#stack] == zoom_shell.widget and zoom_shell.panel_zoom == nil,
        "a restoration callback error must not abort native overlay removal")
    fail_panel_repaint = false
    zoom_reader:onHold()
    viewer = zoom_shell.panel_zoom
    local dialog = { onCloseKeyboard = function() end }
    zoom_shell.input_dialog = dialog
    zoom_ui:show(dialog)
    fail_after_remove = ({ overlay = viewer, input = dialog, fullscreen = zoom_shell.widget })[close_failure]
    local events_before_exit, paints_before_exit = #zoom_events, repaints
    zoom_reader:force_close("back")
    zoom_reader:force_close("back")
    zoom_shell:close_now()
    expect(zoom_events[events_before_exit + 1] == viewer
        and zoom_events[events_before_exit + 2] == dialog
        and zoom_events[events_before_exit + 3] == zoom_shell.widget
        and #zoom_events == events_before_exit + 3,
        "Reader force_close must close all three layers once despite " .. close_failure .. " refresh failure")
    expect(#stack == 1 and zoom_shell.panel_zoom == nil
        and zoom_shell.input_dialog == nil and zoom_shell.current_model == nil,
        "post-removal refresh failure must leave no fullscreen layer or stale UI references")
    expect(current_frees == 0 and session:is_active() and repaints == paints_before_exit,
        "UI-first shutdown must neither repaint a closing panel nor release its buffer early")
    cleanup_queue[#cleanup_queue]()
    expect(current_frees == 1 and not freed_while_visible and not session:is_active(),
        "deferred session cleanup must free the borrowed panel exactly once after UI close")
    expect(zoom_shell:show_panel_zoom{ buffer = panel_buffer } == false,
        "a closed fullscreen shell must never reopen free zoom")
    package.loaded["ui/widget/imageviewer"] = nil
    package.preload["ui/widget/imageviewer"] = nil
end

-- Close-first and itemized cleanup: every cleanup dependency throws, yet later
-- cleanup and the fallback return still run exactly once.
local events = {}
local scheduled = {}
local pending_callbacks
local shell = {
    show_loading = function() events[#events + 1] = "loading" end,
    show_error = function() events[#events + 1] = "error" end,
    show_page = function() events[#events + 1] = "page" end,
}
local failing_buffer = {
    free = function()
        events[#events + 1] = "free"
        error("free failed")
    end,
}
local progress_saves = 0
local reader = Reader:new{
    loader = {
        identity = "server",
        request = function(_self, _generation, _image, callbacks)
            events[#events + 1] = "request"
            pending_callbacks = callbacks
            return {}
        end,
        prefetch = function() events[#events + 1] = "prefetch" end,
        cancel_generation = function()
            events[#events + 1] = "cancel"
            error("cancel failed")
        end,
    },
    progress = {
        chapter_id = function() return "chapter-id" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function() progress_saves = progress_saves + 1 end,
    },
    state = {
        current = nil,
        begin_chapter = function(self) self.current = 7; return 7 end,
        is_current = function(self, generation) return self.current == generation end,
        leave_chapter = function(self)
            events[#events + 1] = "leave"
            self.current = nil
            error("leave failed")
        end,
    },
    settings = {
        get_connection = function() return {} end,
        get_reader = function() return reader_settings(false) end,
    },
    cache = {
        key_for = function(_self, identity, path) return identity .. "|" .. path end,
        set_protected = function()
            events[#events + 1] = "unprotect"
            error("cache failed")
        end,
    },
    ui = {
        create_shell = function() return shell end,
        show_shell = function() events[#events + 1] = "show" end,
        close_shell = function()
            events[#events + 1] = "close"
            error("UI close callback failed after detaching")
        end,
        schedule = function(_self, callback) scheduled[#scheduled + 1] = callback end,
    },
    open_chapter = function() end,
    return_to_root = function() events[#events + 1] = "fallback" end,
}
local failing_context = {}
for key, value in pairs(context) do failing_context[key] = value end
failing_context.source_context = {
    manifest_keys = context.source_context.manifest_keys,
    on_return = function()
        events[#events + 1] = "return"
        error("return failed")
    end,
}

reader:open(failing_context)
expect(events[1] == "show" and events[2] == "loading" and events[3] == "request",
    "ReaderShell must be visible before loading or download starts")
reader.page_buffer = failing_buffer
reader.panel_session = { close = function()
    events[#events + 1] = "panel_close"
    error("panel close failed")
end }
local before_close = #events
expect(reader:force_close("left_top") == true
    and reader:force_close("double_tap") == true,
    "highest-priority exit should be immediate and idempotent")
expect(events[before_close + 1] == "close" and count(events, "close") == 1,
    "UI close must be the first observable exit event and happen once")
expect(#scheduled == 1 and count(events, "cancel") == 0,
    "fallible cleanup must be deferred until after UI close")
expect(reader.panel_session == nil and count(events, "panel_close") == 0,
    "panel session must detach immediately but remain alive until after UI close")
scheduled[1]()
expect(count(events, "panel_close") == 1,
    "detached panel cleanup must run once despite repeated force_close")
expect(count(events, "cancel") == 1 and count(events, "free") == 1
    and count(events, "leave") == 1 and count(events, "unprotect") == 1,
    "cancel, free, state leave, and unprotect must each run despite injected faults")
expect(count(events, "return") == 1 and count(events, "fallback") == 1,
    "a failing return callback must invoke the root-bookshelf fallback")

local pages_before_late = count(events, "page")
pending_callbacks.on_ready("/cache/late.jpg", false,
    { width = 1600, height = 1000, format = "jpeg" })
expect(count(events, "page") == pages_before_late and progress_saves == 0,
    "a late loader callback after close must not reopen UI or checkpoint progress")

local fallback_before_success = count(events, "fallback")
local successful_context = {}
for key, value in pairs(context) do successful_context[key] = value end
successful_context.source_context = {
    on_return = function() events[#events + 1] = "return_ok" end,
}
reader:open(successful_context)
reader:force_close("back")
scheduled[#scheduled]()
expect(count(events, "return_ok") == 1
    and count(events, "fallback") == fallback_before_success,
    "a successful nil-returning callback must not also open the fallback bookshelf")

local returns_before_teardown = count(events, "return_ok")
reader:open(successful_context)
reader:force_close("back")
reader:force_close("plugin_teardown")
scheduled[#scheduled]()
expect(count(events, "return_ok") == returns_before_teardown,
    "plugin teardown during deferred close must suppress the pending UI return")

-- Split navigation owns one decoded buffer and selects two no-copy viewports.
local split_events = {}
local split_scheduled = {}
local split_requests = {}
local render_calls = 0
local viewport_calls = 0
local frees = 0
local copies = 0
local buffer
buffer = {
    getWidth = function() return 1600 end,
    getHeight = function() return 1000 end,
    viewport = function(_self, x, y, w, h)
        viewport_calls = viewport_calls + 1
        return { x = x, y = y, w = w, h = h, owner = buffer }
    end,
    copy = function() copies = copies + 1 end,
    free = function()
        frees = frees + 1
        split_events[#split_events + 1] = "free"
    end,
}
local split_shell = {
    get_content_size = function() return 800, 1000 end,
    show_loading = function() split_events[#split_events + 1] = "loading" end,
    show_error = function() split_events[#split_events + 1] = "error" end,
    show_page = function(_self, owned, viewport)
        expect(owned == buffer, "shell should retain the one owned scaled buffer")
        split_events[#split_events + 1] = "page"
        return viewport ~= nil
    end,
    free_buffer_later = function(_self, owned)
        split_events[#split_events + 1] = "deferred_free"
        return owned:free()
    end,
}
local split_progress = {}
local split_reader = Reader:new{
    loader = {
        identity = "server",
        request = function(_self, _generation, image, callbacks)
            split_requests[#split_requests + 1] = { image = image, callbacks = callbacks }
            return {}
        end,
        prefetch = function()
            split_events[#split_events + 1] = "prefetch"
            error("prefetch failed")
        end,
        cancel_generation = function() split_events[#split_events + 1] = "cancel" end,
    },
    progress = {
        chapter_id = function() return "split-chapter" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function(_self, _id, _path, index, segment)
            split_progress[#split_progress + 1] = { index = index, segment = segment }
            error("checkpoint failed")
        end,
    },
    state = State:new(),
    settings = {
        get_connection = function() return {} end,
        get_reader = function() return reader_settings(true) end,
        set_reader = function() return true end,
        flush = function() end,
    },
    cache = {
        key_for = function(_self, identity, path) return identity .. "|" .. path end,
        set_protected = function()
            split_events[#split_events + 1] = "protect"
            error("cache index failed")
        end,
        remove = function() end,
    },
    ui = {
        create_shell = function() return split_shell end,
        show_shell = function() split_events[#split_events + 1] = "show" end,
        close_shell = function() split_events[#split_events + 1] = "close" end,
        schedule = function(_self, callback) split_scheduled[#split_scheduled + 1] = callback end,
    },
    render_image = {
        renderImageFile = function(_self, path, animated, target_w, target_h)
            render_calls = render_calls + 1
            expect(path == "/cache/spread.jpg" and animated == false,
                "renderer should decode the verified local image exactly once")
            expect(target_w == 1600 and target_h == 1000,
                "split decode should use the explicit larger-segment target size")
            return buffer
        end,
    },
    open_chapter = function() end,
}

split_reader:open(context)
split_requests[1].callbacks.on_ready("/cache/spread.jpg", false,
    { width = 1600, height = 1000, format = "jpeg" })
expect(render_calls == 1 and viewport_calls == 1
    and split_reader.position.segment == "left",
    "the first split segment should decode once and select the left viewport")
split_reader:next_page()
expect(render_calls == 1 and #split_requests == 1 and viewport_calls == 2
    and copies == 0 and split_reader.position.segment == "right",
    "the second segment must switch viewport without download, decode, or copy")
expect(split_progress[1].segment == "left" and split_progress[2].segment == "right",
    "each successfully displayed segment should write a lightweight checkpoint")
split_reader:force_close("back")
expect(split_events[#split_events] == "close" and frees == 0,
    "the owned buffer must remain alive until its widget is detached")
split_scheduled[#split_scheduled]()
expect(frees == 1 and count(split_events, "cancel") == 1,
    "close cleanup should free the one owned buffer exactly once")

print(("reader_exit_spec: %d checks"):format(checks))
