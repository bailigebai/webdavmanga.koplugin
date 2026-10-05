local DialogKeyboard = require("webdavmanga.dialog_keyboard")
local BubbleZoom = require("webdavmanga.bubble_zoom")

local ReaderShell = {}
ReaderShell.__index = ReaderShell

local function invoke_owner(owner, method, ...)
    if not owner or type(owner[method]) ~= "function" then return true end
    local arguments = { n = select("#", ...), ... }
    local unpack_values = table.unpack or unpack
    local ok, result = pcall(function()
        return owner[method](owner, unpack_values(arguments, 1, arguments.n))
    end)
    if ok then return result == nil and true or result end
    local reporter = owner.error_reporter
    if reporter and type(reporter.guard) == "function" then
        pcall(reporter.guard, reporter, "reader input", function()
            error(result, 0)
        end, nil, nil, { silent = true })
    end
    return true
end

local function invoke_function(callback, ...)
    if type(callback) ~= "function" then return true end
    local arguments = { n = select("#", ...), ... }
    local unpack_values = table.unpack or unpack
    local ok, result = pcall(function()
        return callback(unpack_values(arguments, 1, arguments.n))
    end)
    if ok then
        -- A reader button has consumed the input even when its operation
        -- returns false (for example while a page is still loading).
        return result == nil and true or (result == false and true or result)
    end
    return true
end

local function call_owner(shell, source)
    return invoke_owner(shell and shell.owner, "force_close", source)
end

local function screen_dimensions(screen)
    if not screen then return 600, 800 end
    local width = type(screen.getWidth) == "function" and screen:getWidth() or nil
    local height = type(screen.getHeight) == "function" and screen:getHeight() or nil
    return math.max(1, tonumber(width) or 600), math.max(1, tonumber(height) or 800)
end

local function production_dependencies(screen)
    local ok, dependencies = pcall(function()
        local Device = require("device")
        return {
            Blitbuffer = require("ffi/blitbuffer"),
            Button = require("ui/widget/button"),
            CenterContainer = require("ui/widget/container/centercontainer"),
            Device = Device,
            FrameContainer = require("ui/widget/container/framecontainer"),
            Font = require("ui/font"),
            Geom = require("ui/geometry"),
            GestureRange = require("ui/gesturerange"),
            HorizontalGroup = require("ui/widget/horizontalgroup"),
            HorizontalSpan = require("ui/widget/horizontalspan"),
            ImageWidget = require("ui/widget/imagewidget"),
            InputContainer = require("ui/widget/container/inputcontainer"),
            LineWidget = require("ui/widget/linewidget"),
            OverlapGroup = require("ui/widget/overlapgroup"),
            Screen = screen or Device.screen,
            Size = require("ui/size"),
            TextWidget = require("ui/widget/textwidget"),
            TitleBar = require("ui/widget/titlebar"),
            UIManager = require("ui/uimanager"),
            VerticalGroup = require("ui/widget/verticalgroup"),
        }
    end)
    if ok then return dependencies end
    return nil
end

local function production_widget(shell, dependencies)
    local InputContainer = dependencies.InputContainer
    local message_face = dependencies.Font:getFace("cfont")
    assert(message_face, "KOReader content font is unavailable")

    local ReaderWidget = InputContainer:extend{
        -- KOReader's own fullscreen ImageViewer is a normal window. Making
        -- this modal would place ordinary settings/search dialogs below it.
        modal = false,
        fullscreen = true,
        covers_fullscreen = true,
        -- KOReader disables double-tap globally for widgets unless they
        -- explicitly opt in. The emergency right-top exit relies on this
        -- gesture while the manga page is visible.
        disable_double_tap = false,
    }

    function ReaderWidget:_button(action, fallback_text, width)
        return dependencies.Button:new{
            text = action.text or fallback_text or "操作",
            enabled = action.enabled ~= false,
            width = width,
            callback = function(...)
                return invoke_function(action.callback, ...)
            end,
            hold_callback = action.hold_callback and function(...)
                return invoke_function(action.hold_callback,...)
            end,
        }
    end

    function ReaderWidget:_message_content(model)
        local width, height = shell:get_message_content_size()
        local group = dependencies.VerticalGroup:new{
            dependencies.TextWidget:new{
                text = tostring(model.message or ""),
                face = message_face,
            },
        }
        local actions = model.actions or {}
        local columns = tonumber(model.columns) == 2 and 2 or 1
        if columns == 2 then
            local gap = math.max(8, tonumber(dependencies.Size.padding.default) or 8)
            local cell_width = math.max(1, math.floor((width - gap) / 2))
            for index = 1, #actions, 2 do
                local row = dependencies.HorizontalGroup:new{ align = "center" }
                row[#row + 1] = self:_button(actions[index], nil, cell_width)
                row[#row + 1] = dependencies.HorizontalSpan:new{ width = gap }
                if actions[index + 1] then
                    row[#row + 1] = self:_button(actions[index + 1], nil, cell_width)
                else
                    row[#row + 1] = dependencies.HorizontalSpan:new{ width = cell_width }
                end
                group[#group + 1] = row
            end
        else
            for _, action in ipairs(actions) do
                group[#group + 1] = self:_button(action)
            end
        end
        return dependencies.CenterContainer:new{
            dimen = dependencies.Geom:new{ w = width, h = height },
            group,
        }
    end

    function ReaderWidget:_status_content(text)
        if not text or text == "" then return nil end
        return dependencies.FrameContainer:new{
            padding = 4, margin = 0, bordersize = 0,
            background = dependencies.Blitbuffer.COLOR_WHITE,
            allow_mirroring = false,
            dependencies.TextWidget:new{
                text = text,
                face = dependencies.Font:getFace("smallinfofont") or message_face,
                max_width = math.max(1, math.min(shell.screen_w, 260) - 8),
            },
        }
    end

    function ReaderWidget:_page_content(model)
        local width, height = shell:get_content_size()
        local image = dependencies.ImageWidget:new{
            image = model.viewport or model.buffer,
            -- Reader owns the decoded page buffer (and any no-copy viewport).
            -- ImageWidget must never free it while the shell rebuilds.
            image_disposable = false,
            width = width,
            height = height,
            -- Reader has already rendered the buffer to the requested target
            -- size.  Re-fitting it here (scale_factor = 0) would apply the
            -- screen height a second time and squash tall fit-width pages.
            -- A factor of 1 preserves the aspect ratio and lets Reader's
            -- viewport provide the vertical scrolling window.
            -- Quadrants use ImageWidget's best-fit (0) for the actual reading
            -- area: split and tall-page quadrants need not share its aspect.
            scale_factor = model.display_scale or 1,
        }
        return dependencies.FrameContainer:new{
            width = width,
            height = height,
            margin = 0,
            padding = 0,
            bordersize = 0,
            background = model.background == "black" and dependencies.Blitbuffer.COLOR_BLACK
                or dependencies.Blitbuffer.COLOR_WHITE,
            dependencies.CenterContainer:new{
                dimen = dependencies.Geom:new{ w = width, h = height },
                image,
            },
        }, image
    end

    function ReaderWidget:_rebuild()
        local model = shell.current_model or { kind = "loading", message = "" }
        local content, page_image
        if model.kind == "page" then content, page_image = self:_page_content(model)
        else content = self:_message_content(model) end
        local previous = self[1]
        local root = dependencies.OverlapGroup:new{
            dimen = dependencies.Geom:new{ w = shell.screen_w, h = shell.screen_h },
            allow_mirroring = false,
            content,
        }
        local status_index, status_widget
        if model.kind == "page" then
            if model.show_progress ~= false then
                local progress = math.max(0, math.min(1, tonumber(model.progress) or 0))
                local width = math.floor(shell.screen_w * progress)
                local thickness = math.max(1, math.min(4,
                    math.floor(tonumber(model.progress_bar_thickness) or 1)))
                local line_height = 2 * thickness
                local track = dependencies.LineWidget:new{
                    dimen = dependencies.Geom:new{ w = shell.screen_w, h = line_height },
                    background = dependencies.Blitbuffer.COLOR_WHITE,
                }
                local filled = dependencies.LineWidget:new{
                    dimen = dependencies.Geom:new{ w = math.max(1, width), h = line_height },
                    background = dependencies.Blitbuffer.COLOR_BLACK,
                }
                root[#root + 1] = dependencies.OverlapGroup:new{
                    dimen = dependencies.Geom:new{ w = shell.screen_w, h = line_height },
                    track,
                    filled,
                }
            end
            status_widget = self:_status_content(model.status_text)
            status_index = #root + 1
            if status_widget then root[status_index] = status_widget end
            local bubble = shell.bubble_zoom
            if bubble then
                local rect = bubble.rect
                local width, height = rect.w - 4, rect.h - 4
                root[#root + 1] = dependencies.OverlapGroup:new{
                    allow_mirroring = false,
                    dimen = dependencies.Geom:new{w = shell.screen_w, h = shell.screen_h},
                    dependencies.FrameContainer:new{
                        width = rect.w, height = rect.h, margin = 0, padding = 1, bordersize = 1,
                        overlap_offset = {rect.x, rect.y},
                        background = dependencies.Blitbuffer.COLOR_WHITE,
                        dependencies.CenterContainer:new{
                            dimen = dependencies.Geom:new{w = width, h = height},
                            dependencies.ImageWidget:new{
                                image = bubble.buffer, image_disposable = false,
                                width = width, height = height, scale_factor = 0,
                            },
                        },
                    },
                }
            end
        else
            local title_bar = dependencies.TitleBar:new{
                title = tostring(model.title or ""),
                width = shell.screen_w,
                with_bottom_line = true,
                left_icon = "chevron.left",
                left_icon_tap_callback = function()
                    return call_owner(shell, "left_top")
                end,
            }
            root[1] = dependencies.VerticalGroup:new{
                title_bar,
                content,
            }
        end
        -- The emergency button is available on both the manga page and every
        -- reader-settings layer. In settings it only dismisses the layer;
        -- on the page it follows the normal highest-priority close path.
        if model.show_exit_button then
            local source = model.kind == "controls" and "close_controls"
                or "right_top_return"
            root[#root + 1] = dependencies.Button:new{
                text = "X 返回漫画",
                text_font_face = "cfont",
                text_font_size = 24,
                width = math.min(280, math.max(1, shell.screen_w - 20)),
                height = math.max(64, math.floor(shell.screen_h * 0.12)),
                margin = 0,
                padding = 10,
                bordersize = 2,
                overlap_align = "right",
                align = "right",
                valign = "top",
                allow_flash = false,
                show_parent = self,
                callback = function()
                    if source == "close_controls" then
                        return invoke_owner(shell.owner, "close_controls", source)
                    end
                    return call_owner(shell, source)
                end,
            }
        end
        self[1] = root
        self.status_index, self.status_widget = status_index, status_widget
        shell.page_image = page_image
        if previous and previous.free then previous:free() end
    end

    function ReaderWidget:paintTo(bb, x, y)
        local ok, err = pcall(InputContainer.paintTo, self, bb, x, y)
        if ok or self.paint_failed then return end
        self.paint_failed = true
        local function recover()
            if shell.closed or shell.widget ~= self then return end
            local owner = shell.owner
            local reporter = owner and owner.error_reporter
            if reporter and type(reporter.report) == "function" then
                pcall(reporter.report, reporter, "reader repaint", err, { silent = true })
            end
            invoke_owner(owner, "force_close", "render_error")
        end
        if type(dependencies.UIManager.nextTick) == "function" then
            local scheduled, result = pcall(
                dependencies.UIManager.nextTick, dependencies.UIManager, recover)
            if scheduled and result ~= false then return end
        end
        if type(dependencies.UIManager.scheduleIn) == "function" then
            pcall(dependencies.UIManager.scheduleIn, dependencies.UIManager, 0, recover)
        end
    end

    function ReaderWidget:init()
        self.dimen = dependencies.Screen:getSize()
        -- kindle-hid-passthrough exposes gamepad buttons and the Kindle page
        -- keys through KOReader's normal input map.  Keep the aliases broad:
        -- users may map a pad to page keys, a D-pad key, or BtnA/BtnB.
        -- InputContainer expects alternatives to be nested one level deeper:
        -- { { { "RPgFwd", "LPgFwd" } } }, not { { { "..." } } }.
        local input = dependencies.Device and dependencies.Device.input
        local groups = input and input.group or {}
        local function alias_event(group, aliases)
            local keys, seen = {}, {}
            local function add(value)
                if type(value) ~= "string" or seen[value] then return end
                seen[value] = true
                keys[#keys + 1] = value
            end
            for _, value in ipairs(group or {}) do add(value) end
            for _, value in ipairs(aliases or {}) do add(value) end
            -- A sequence containing one alternative group matches any key in
            -- `keys` while remaining compatible with KOReader's Key:match.
            return { { keys } }
        end
        local next_keys = {
            "RPgFwd", "LPgFwd", "PgFwd", "PageDown", "NextPage",
            "Next", "Right", "Down", "BtnA", "BtnX", "BtnDpadRight",
            "BtnDpadDown",
        }
        local previous_keys = {
            "RPgBack", "LPgBack", "PgBack", "PageUp", "PreviousPage",
            "Previous", "Left", "Up", "BtnB", "BtnY", "BtnDpadLeft",
            "BtnDpadUp",
        }
        local back_keys = { "Back", "Escape", "Esc", "BtnSelect" }
        self.key_events = {
            MangaNext = alias_event(groups.PgFwd, next_keys),
            MangaPrevious = alias_event(groups.PgBack, previous_keys),
            MangaBack = alias_event(groups.Back, back_keys),
        }
        local function content_range()
            local page = shell.current_model and shell.current_model.kind == "page"
            local width, height
            if page then width, height = shell:get_content_size()
            else width, height = shell:get_message_content_size() end
            return dependencies.Geom:new{
                x = 0,
                y = page and 0 or shell.top_h,
                w = math.max(1, tonumber(width) or shell.screen_w),
                h = math.max(1, tonumber(height)
                    or (page and shell.screen_h or shell.screen_h - shell.top_h)),
            }
        end
        local function center_tap_range()
            local range = content_range()
            local edge = math.max(1, math.floor(range.w / 10))
            return dependencies.Geom:new{
                x = edge,
                y = range.y,
                w = math.max(1, range.w - 2 * edge),
                h = range.h,
            }
        end
        local function left_edge_range()
            local range = content_range()
            return dependencies.Geom:new{
                x = range.x,
                y = range.y,
                w = math.max(1, math.floor(range.w / 10)),
                h = range.h,
            }
        end
        local function right_edge_range()
            local range = content_range()
            local edge = math.max(1, math.floor(range.w / 10))
            return dependencies.Geom:new{
                x = math.max(range.x, range.x + range.w - edge),
                y = range.y,
                w = edge,
                h = range.h,
            }
        end
        -- Page gestures cover the entire image. Hardware Back remains a direct
        -- exit; the visible return command lives in the center-tap controls.
        self.ges_events = {
            Tap = { dependencies.GestureRange:new{ ges = "tap", range = center_tap_range } },
            TwoFingerTap = {
                dependencies.GestureRange:new{
                    ges = "two_finger_tap", range = content_range,
                },
            },
            TwoFingerHold = { dependencies.GestureRange:new{ges="two_finger_hold",range=content_range} },
            TwoFingerHoldPan = { dependencies.GestureRange:new{ges="two_finger_hold_pan"} },
            -- A lift/cancel must restore the page even outside its original range.
            TwoFingerHoldRelease = {},
            DoubleTap = {
                dependencies.GestureRange:new{
                    ges = "double_tap",
                    range = function()
                        local range = content_range()
                        local top_right_double_tap = true
                        -- Use the entire right 40% of the title/content edge.
                        -- On KPW6 the touch coordinate reported for a title-bar
                        -- double tap can be a few pixels left of the visual
                        -- corner; a quarter-width target made the emergency
                        -- exit appear unreliable.
                        local width = math.max(1, math.floor(range.w * 0.40))
                        local page = shell.current_model
                            and shell.current_model.kind == "page"
                        return dependencies.Geom:new{
                            x = math.max(range.x, range.x + range.w - width),
                            -- Settings/error title bars occupy the normal
                            -- content offset, but the emergency gesture must
                            -- also work in their real top-right corner.
                            y = page and range.y or 0,
                            w = width,
                            h = math.max(1, math.floor(math.max(
                                (page and range.h or shell.screen_h) * 0.20,
                                shell.top_h * 1.5))),
                        }
                    end,
                },
            },
            EdgeTap = {
                dependencies.GestureRange:new{ ges = "tap", range = left_edge_range },
                dependencies.GestureRange:new{ ges = "tap", range = right_edge_range },
            },
            Swipe = { dependencies.GestureRange:new{ ges = "swipe", range = content_range } },
            Hold = { dependencies.GestureRange:new{ ges = "hold", range = content_range } },
            BubbleHoldPan = { dependencies.GestureRange:new{ges="hold_pan"} },
            PanelPan = {dependencies.GestureRange:new{ges="pan"},dependencies.GestureRange:new{ges="two_finger_pan"}},
        }
        for _,ges in ipairs({"two_finger_hold_release","two_finger_hold_pan_release",
            "two_finger_pan_release","hold_release","pan_release","pinch","spread","rotate","two_finger_swipe"}) do
            self.ges_events.TwoFingerHoldRelease[#self.ges_events.TwoFingerHoldRelease+1]
                = dependencies.GestureRange:new{ges=ges}
        end
        self:_rebuild()
    end

    function ReaderWidget:set_model(model)
        self:_rebuild()
        dependencies.UIManager:setDirty(self, model and model.refresh_type or "ui")
    end

    function ReaderWidget:set_status(text)
        if not self.status_index then return false end
        local previous, replacement = self.status_widget, self:_status_content(text)
        local old_size = previous and previous:getSize() or {w = 0, h = 0}
        local new_size = replacement and replacement:getSize() or {w = 0, h = 0}
        local region = dependencies.Geom:new{
            x = self.dimen.x or 0, y = self.dimen.y or 0,
            w = math.min(shell.screen_w, math.max(old_size.w, new_size.w)),
            h = math.min(shell.screen_h, math.max(old_size.h, new_size.h)),
        }
        local function replace(widget)
            if self.status_widget then table.remove(self[1], self.status_index) end
            if widget then table.insert(self[1], self.status_index, widget) end
            self.status_widget = widget
        end
        replace(replacement)
        if region.w > 0 and region.h > 0 then
            -- UI refreshes do not inherit a page's flashing/full refresh mode.
            local ok, err = pcall(dependencies.UIManager.setDirty, dependencies.UIManager, self, "ui", region)
            if not ok then
                replace(previous)
                if replacement then replacement:free() end
                error(err, 0)
            end
        end
        if previous then previous:free() end
        return true
    end

    function ReaderWidget:onBack()
        return call_owner(shell, "back")
    end

    function ReaderWidget:onTap(arg, gesture)
        return invoke_owner(shell.owner, "onTap", arg, gesture)
    end

    function ReaderWidget:onTwoFingerTap(_arg, gesture)
        return invoke_owner(shell.owner, "onTwoFingerTap", shell, gesture)
    end

    function ReaderWidget:onTwoFingerHold(_arg, gesture)
        return invoke_owner(shell.owner,"onTwoFingerHold",shell,gesture)
    end

    function ReaderWidget:onTwoFingerHoldPan(_arg, gesture)
        return invoke_owner(shell.owner,"onTwoFingerHoldPan",shell,gesture)
    end

    function ReaderWidget:onPanelPan(_arg,gesture)
        return invoke_owner(shell.owner,"onPanelPan",shell,gesture)
    end

    function ReaderWidget:onTwoFingerHoldRelease(_arg, gesture)
        return invoke_owner(shell.owner,"onTwoFingerHoldRelease",shell,gesture)
    end

    function ReaderWidget:onBubbleHoldPan()
        return invoke_owner(shell.owner,"onBubbleHoldPan",shell)
    end

    function ReaderWidget:onSuspend()
        shell.bubble_hold_consumed = nil
        shell:close_bubble_zoom()
        invoke_owner(shell.owner,"onTwoFingerHoldRelease",shell)
        return false
    end

    function ReaderWidget:onResume()
        shell.bubble_hold_consumed = nil
        shell:close_bubble_zoom()
        invoke_owner(shell.owner,"onTwoFingerHoldRelease",shell)
        return false
    end

    function ReaderWidget:onDoubleTap(arg, gesture)
        -- Handle the emergency escape in the shell first.  Child dialogs and
        -- older KOReader gesture dispatchers may swallow the owner callback;
        -- the reader must still expose a reliable top-right exit action.
        if shell:show_exit_button() then return true end
        return invoke_owner(shell.owner, "onRightTopDoubleTap", arg, gesture)
    end

    function ReaderWidget:onMangaNext()
        return invoke_function(function() return shell.owner:next_page() end)
    end

    function ReaderWidget:onMangaPrevious()
        return invoke_function(function() return shell.owner:previous_page() end)
    end

    function ReaderWidget:onMangaBack()
        return call_owner(shell, "back")
    end

    -- kindle-hid-passthrough's default mapper action emits KOReader's
    -- dispatcher event instead of a raw key. Handle that event on the active
    -- fullscreen widget so D-pad mappings work exactly like in the stock
    -- reader.
    function ReaderWidget:onGotoViewRel(diff)
        local amount = tonumber(diff)
        if not amount or amount == 0 then return true end
        if amount < 0 then
            return self:onMangaPrevious()
        end
        return self:onMangaNext()
    end

    function ReaderWidget:onGotoPageRel(diff)
        return self:onGotoViewRel(diff)
    end

    function ReaderWidget:onEdgeTap(arg, gesture)
        return self:onTap(arg, gesture)
    end

    function ReaderWidget:onSwipe(arg, gesture)
        return invoke_owner(shell.owner, "onSwipe", arg, gesture)
    end

    function ReaderWidget:onHold(arg, gesture)
        return invoke_owner(shell.owner, "onHold", arg, gesture)
    end

    function ReaderWidget:onClose()
        if shell.closed then return true end
        return call_owner(shell, "back")
    end

    return ReaderWidget:new{}
end

function ReaderShell:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.owner = assert(options.owner, "reader owner is required")
    object.ui_manager = options.ui_manager
    object.scheduler = options.scheduler
    object.screen = options.screen
    object.device = options.device
    object.render_image = options.render_image
    object.widget_factory = options.widget_factory
    object.closed = false
    object.shown = false
    object.supports_animation = options.supports_animation
    object.progress = 0
    object.show_progress = true
    object.input_dialog = nil
    object.status_token = 0

    local dependencies
    if not object.widget_factory then
        dependencies = production_dependencies(object.screen)
        if dependencies then
            object.ui_manager = object.ui_manager or dependencies.UIManager
            object.scheduler = object.scheduler or dependencies.UIManager
            object.screen = object.screen or dependencies.Screen
            object.device = object.device or dependencies.Device
        end
    end
    if object.supports_animation == nil then
        object.supports_animation = object.device ~= nil
            and type(object.device.canDoSwipeAnimation) == "function"
            and object.screen ~= nil
            and type(object.screen.setSwipeAnimations) == "function"
            and type(object.screen.setSwipeDirection) == "function"
    else
        object.supports_animation = object.supports_animation == true
    end
    object.screen_w, object.screen_h = screen_dimensions(object.screen)
    object.top_h = math.max(44, math.floor(object.screen_h * 0.08))
    local base_model = {
        left_icon = "chevron.left",
        left_icon_tap_callback = function() return call_owner(object, "left_top") end,
        onBack = function() return call_owner(object, "back") end,
        onClose = function() return call_owner(object, "back") end,
        ges_events = { Tap = {}, EdgeTap = {}, Swipe = {}, Hold = {} },
        onTap = function(_self, arg, gesture)
            return invoke_owner(object.owner, "onTap", arg, gesture)
        end,
        onEdgeTap = function(_self, arg, gesture)
            return invoke_owner(object.owner, "onTap", arg, gesture)
        end,
        onSwipe = function(_self, arg, gesture)
            return invoke_owner(object.owner, "onSwipe", arg, gesture)
        end,
        onHold = function(_self, arg, gesture)
            return invoke_owner(object.owner, "onHold", arg, gesture)
        end,
        onGesture = function(_self, gesture)
            if type(gesture) ~= "table" then return true end
            if gesture.ges == "tap" then
                return invoke_owner(object.owner, "onTap", nil, gesture)
            elseif gesture.ges == "two_finger_tap" then
                return invoke_owner(object.owner, "onTwoFingerTap", object, gesture)
            elseif gesture.ges == "two_finger_hold" then
                return invoke_owner(object.owner,"onTwoFingerHold",object,gesture)
            elseif gesture.ges == "two_finger_hold_pan" then
                return invoke_owner(object.owner,"onTwoFingerHoldPan",object,gesture)
            elseif gesture.ges == "hold_pan" then
                return invoke_owner(object.owner,"onBubbleHoldPan",object,gesture)
            elseif gesture.ges == "two_finger_hold_release" or gesture.ges == "two_finger_hold_pan_release"
                or gesture.ges == "two_finger_pan_release" or gesture.ges == "hold_release"
                or gesture.ges == "pan_release" or gesture.ges == "pinch" or gesture.ges == "spread"
                or gesture.ges == "rotate" or gesture.ges == "two_finger_swipe" then
                return invoke_owner(object.owner,"onTwoFingerHoldRelease",object,gesture)
            elseif gesture.ges == "double_tap" then
                if object:show_exit_button() then return true end
                return invoke_owner(object.owner, "onRightTopDoubleTap", nil, gesture)
            elseif gesture.ges == "swipe" then
                return invoke_owner(object.owner, "onSwipe", nil, gesture)
            elseif gesture.ges == "hold" then
                return invoke_owner(object.owner, "onHold", nil, gesture)
            end
            return true
        end,
    }
    if object.widget_factory then
        object.widget = object.widget_factory(base_model, object)
    elseif dependencies then
        object.widget = production_widget(object, dependencies)
    else
        object.widget = base_model
    end
    return object
end

function ReaderShell:get_content_size()
    return self.screen_w, self.screen_h
end

function ReaderShell:get_message_content_size()
    return self.screen_w, math.max(1, self.screen_h - self.top_h)
end

function ReaderShell:_publish(model)
    if self.closed then return false end
    local bubble = self.bubble_zoom
    self.bubble_zoom = nil
    local previous = self.current_model
    local previous_token = self.status_token
    if model ~= previous then self.status_token = self.status_token + 1 end
    self.current_model = model
    if self.widget and type(self.widget.set_model) == "function" then
        local ok, err = pcall(self.widget.set_model, self.widget, model)
        if not ok then
            self.current_model, self.bubble_zoom = previous, bubble
            self.status_token = previous_token
            error(err, 0)
        end
    end
    if bubble then self:free_buffer_later(bubble.buffer) end
    return true
end

function ReaderShell:get_page_image_rect()
    local model = self.current_model
    if not model or model.kind ~= "page" then return nil end
    local view = model.viewport or model.buffer
    local w, h = view:getWidth(), view:getHeight()
    local image = self.page_image
    if image and type(image.getCurrentWidth) == "function" then
        image:getSize()
        w, h = image:getCurrentWidth(), image:getCurrentHeight()
    elseif model.display_scale == 0 then
        local scale = math.min(self.screen_w / w, self.screen_h / h)
        w, h = math.floor(w * scale), math.floor(h * scale)
    end
    return {x = math.floor((self.screen_w - w) / 2),
        y = math.floor((self.screen_h - h) / 2), w = w, h = h}
end

function ReaderShell:show_bubble_zoom(source, box, point, scale)
    if self.closed or self.bubble_zoom or not self.current_model
        or self.current_model.kind ~= "page" then return false end
    local rect = BubbleZoom.overlay_rect(box, scale, point, self.screen_w - 4, self.screen_h - 4)
    if not rect then return false end
    rect.w, rect.h = rect.w + 4, rect.h + 4
    rect.x, rect.y = math.min(rect.x, self.screen_w - rect.w), math.min(rect.y, self.screen_h - rect.h)
    local view = source:viewport(box.x, box.y, box.w, box.h)
    local bubble = {buffer = view, rect = rect}
    self.status_token = self.status_token + 1
    self.current_model.status_text = nil
    self.bubble_zoom = bubble
    local ok = pcall(self.widget.set_model, self.widget, self.current_model)
    if not ok then
        self.bubble_zoom = nil
        self:free_buffer_later(view)
        return false
    end
    return true
end

function ReaderShell:close_bubble_zoom()
    if not self.bubble_zoom then return false end
    return self:_publish(self.current_model)
end

function ReaderShell:cancel_transition()
    -- Compatibility no-op for older hosts. Native Kindle swipe animation is
    -- one-shot and owned by the display driver, so there is no timer to cancel.
    return false
end

function ReaderShell:_arm_native_animation(forward)
    if self.closed or not self.supports_animation then return false end
    local device, screen = self.device, self.screen
    if not device or not screen then return false end
    local checked, capable = pcall(device.canDoSwipeAnimation, device)
    if not checked or capable ~= true then return false end
    local enabled, enable_result = pcall(screen.setSwipeAnimations, screen, true)
    if not enabled or enable_result == false then return false end
    local directed, direction_result = pcall(
        screen.setSwipeDirection, screen, forward ~= false)
    if directed and direction_result ~= false then return true end
    pcall(screen.setSwipeAnimations, screen, false)
    return false
end

function ReaderShell:show()
    if self.closed or self.shown then return not self.closed end
    self.shown = true
    if self.ui_manager and type(self.ui_manager.show) == "function" then
        self.ui_manager:show(self.widget)
    end
    return true
end

function ReaderShell:show_loading(title)
    return self:_publish{
        kind = "loading",
        title = title,
        message = title,
        on_cancel = function() return call_owner(self, "loading_cancel") end,
        actions = {{
            text = "取消加载",
            callback = function() return call_owner(self, "loading_cancel") end,
        }},
    }
end

function ReaderShell:show_error(model)
    model = model or {}
    local actions = {}
    for _, action in ipairs(model.actions or {}) do actions[#actions + 1] = action end
    if model.on_retry then actions[#actions + 1] = { text = "重试", callback = model.on_retry } end
    if model.on_previous then actions[#actions + 1] = { text = "上一页", callback = model.on_previous } end
    if model.on_next then actions[#actions + 1] = { text = "下一页", callback = model.on_next } end
    actions[#actions + 1] = {
        text = "返回漫画列表",
        callback = function() return call_owner(self, "error_back") end,
    }
    return self:_publish{
        kind = "error",
        title = model.title or "图片错误",
        message = model.message,
        normal_tap_callback = model.normal_tap_callback,
        on_back = function() return call_owner(self, "error_back") end,
        actions = actions,
    }
end

function ReaderShell:show_page(buffer, viewport, title, page_change, progress,
    show_progress, progress_bar_thickness)
    page_change = type(page_change) == "table" and page_change or {}
    if progress ~= nil then
        self.progress = math.max(0, math.min(1, tonumber(progress) or 0))
    end
    if show_progress ~= nil then self.show_progress = show_progress == true end
    local refresh_type = page_change.refresh_type
    if refresh_type ~= "full" and refresh_type ~= "partial" then
        refresh_type = "partial"
    end
    local native_animation = false
    if refresh_type ~= "full" and page_change.animate == true then
        native_animation = self:_arm_native_animation(page_change.forward)
    end
    return self:_publish{
        kind = "page",
        title = title,
        buffer = buffer,
        viewport = viewport,
        display_scale = page_change.display_scale == 0 and 0 or 1,
        background = page_change.background == "black" and "black" or "white",
        reader_generation = page_change.reader_generation,
        progress = self.progress,
        show_progress = self.show_progress,
        progress_bar_thickness = math.max(1, math.min(4,
            math.floor(tonumber(progress_bar_thickness) or 1))),
        refresh_type = refresh_type,
        native_animation = native_animation,
        animation_forward = page_change.forward ~= false,
    }
end

function ReaderShell:show_panel_zoom(model)
    if self.closed then return false end
    if self.panel_zoom then return true end
    if not model or not model.buffer then return false end
    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        image = model.buffer, image_disposable = false,
        fullscreen = true, with_title_bar = false, buttons_visible = false,
        scale_factor = model.initial_zoom, image_padding = model.padding,
    }
    local on_close_widget, closed = viewer.onCloseWidget, false
    viewer.onCloseWidget = function(widget)
        if closed then return end
        closed = true
        invoke_function(on_close_widget, widget)
        self.panel_zoom = nil
        if not self.closed then invoke_function(model.on_close) end
    end
    self.panel_zoom = viewer
    self.ui_manager:show(viewer)
    return true
end

function ReaderShell:close_panel_zoom()
    local viewer = self.panel_zoom
    if viewer then self.ui_manager:close(viewer) end
    return true
end

function ReaderShell:show_status(message, duration)
    if self.closed or not self.current_model or self.current_model.kind ~= "page" then
        return false
    end
    local model, previous_token = self.current_model, self.status_token
    local previous, text = model.status_text, tostring(message or "")
    if text == "" then text = nil end
    self.status_token = self.status_token + 1
    local token = self.status_token
    if text ~= previous then
        model.status_text = text
        local ok, result = true, true
        if self.widget then
            if self.widget.set_status then
                ok, result = pcall(self.widget.set_status, self.widget, text)
            elseif self.widget.set_model then
                ok, result = pcall(self.widget.set_model, self.widget, model)
            end
        end
        if not ok or result == false then
            model.status_text, self.status_token = previous, previous_token
            return false
        end
    end
    local seconds = tonumber(duration)
    if seconds and seconds > 0 and self.scheduler
        and type(self.scheduler.scheduleIn) == "function" then
        pcall(self.scheduler.scheduleIn, self.scheduler, seconds, function()
            if self.closed or token ~= self.status_token
                or self.current_model ~= model or model.kind ~= "page" then
                return
            end
            self:show_status("")
        end)
    end
    return true
end

function ReaderShell:show_exit_button()
    if self.closed or not self.current_model
        or (self.current_model.kind ~= "page"
            and self.current_model.kind ~= "controls") then
        return false
    end
    if self.current_model.show_exit_button then return true end
    self.current_model.show_exit_button = true
    self.current_model.refresh_type = "ui"
    if self.widget and type(self.widget.set_model) == "function" then
        self.widget:set_model(self.current_model)
    end
    return true
end

function ReaderShell:show_controls(model)
    model = model or {}
    return self:_publish{
        kind = "controls",
        title = model.title or "阅读设置",
        message = model.message or "阅读设置",
        actions = model.actions or {},
        columns = model.columns,
        -- Settings must always have a visible escape hatch.  The right-top
        -- double tap remains available, but it is not safe to depend on a
        -- gesture reaching the shell when a child dialog owns focus.
        show_exit_button = true,
    }
end

function ReaderShell:show_page_picker(model)
    model = model or {}
    local value = tonumber(model.value) or 1
    local minimum = tonumber(model.value_min) or 1
    local maximum = tonumber(model.value_max) or value
    local function update(delta)
        value = math.max(minimum, math.min(maximum, value + delta))
        return self:show_page_picker{
            value = value, value_min = minimum, value_max = maximum,
            on_select = model.on_select,
            columns = model.columns,
        }
    end
    return self:_publish{
        kind = "picker",
        title = "跳转到物理图片",
        message = ("第 %d / %d 张"):format(value, maximum),
        columns = 2,
        actions = {
            { text = "-20", callback = function() return update(-20) end },
            { text = "-10", callback = function() return update(-10) end },
            { text = "-1", callback = function() return update(-1) end },
            { text = "+1", callback = function() return update(1) end },
            { text = "+10", callback = function() return update(10) end },
            { text = "+20", callback = function() return update(20) end },
            { text = "跳转", callback = function() return model.on_select(value) end },
        },
    }
end

function ReaderShell:show_number_input(model)
    model = model or {}
    local ok, MultiInputDialog = pcall(require, "ui/widget/multiinputdialog")
    if not ok then return false end
    local manager = self.ui_manager
    if not manager or type(manager.show) ~= "function" or type(manager.close) ~= "function" then
        return false
    end
    if self.input_dialog then
        DialogKeyboard.hide(self.input_dialog)
        pcall(manager.close, manager, self.input_dialog)
        self.input_dialog = nil
    end
    local dialog
    local function close_dialog()
        if not dialog then return true end
        local current = dialog
        dialog = nil
        if self.input_dialog == current then self.input_dialog = nil end
        DialogKeyboard.hide(current)
        pcall(manager.close, manager, current)
        return true
    end
    dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
        title = model.title or "输入数值",
        fullscreen = true,
        condensed = true,
        enter_callback = function()
            DialogKeyboard.hide(dialog)
            return true
        end,
        fields = {{
            description = model.description,
            input_type = "number",
            text = tostring(model.value or ""),
        }},
        buttons = {{
            {
                text = "取消",
                id = "close",
                callback = function()
                    return close_dialog()
                end,
            },
            {
                text = "保存",
                callback = function()
                    local fields = dialog:getFields()
                    local called, result = pcall(model.on_save, fields and fields[1])
                    local saved = called and result == true
                    if saved then close_dialog() end
                    return true
                end,
            },
        }},
    }, function() return dialog end))
    self.input_dialog = dialog
    manager:show(dialog)
    DialogKeyboard.show(dialog)
    return true
end

function ReaderShell:show_confirmation(model)
    model = model or {}
    return self:_publish{
        kind = "confirmation",
        title = "下一章",
        message = model.text,
        actions = {
            { text = model.ok_text or "继续", callback = model.on_confirm },
            { text = "取消", callback = model.on_cancel or function() return true end },
        },
    }
end

function ReaderShell:show_stream_recovery(model)
    model = model or {}
    local actions = {}
    if type(model.on_retry) == "function" then
        actions[#actions + 1] = { text = "重试流式加载", callback = model.on_retry }
    end
    if type(model.on_download) == "function" then
        actions[#actions + 1] = { text = "完整下载", callback = model.on_download }
    end
    actions[#actions + 1] = { text = "返回", callback = model.on_return }
    return self:_publish{
        kind = "confirmation",
        title = "流式加载失败",
        message = model.text,
        actions = actions,
    }
end

function ReaderShell:free_buffer_later(buffer)
    if not buffer or type(buffer.free) ~= "function" then return false end
    local function release() pcall(buffer.free, buffer) end
    if self.scheduler and type(self.scheduler.scheduleIn) == "function" then
        local ok, result = pcall(self.scheduler.scheduleIn,
            self.scheduler, 0, release)
        if ok and result ~= false then return true end
    end
    release()
    return true
end

function ReaderShell:stop_quadrant_hold_watch()
    local check = self.quadrant_hold_check
    self.quadrant_hold_check = nil
    if check and self.scheduler and type(self.scheduler.unschedule) == "function" then
        pcall(self.scheduler.unschedule, self.scheduler, check)
    end
end

function ReaderShell:start_quadrant_hold_watch(hold)
    self:stop_quadrant_hold_watch()
    local input = self.device and self.device.input
    local detector = input and input.gesture_detector
    if not detector or type(detector.getContact) ~= "function" then return true end
    local slot = input.main_finger_slot
    if type(slot) ~= "number" or not self.scheduler
        or type(self.scheduler.scheduleIn) ~= "function" then return false end
    local first, second = detector:getContact(slot), detector:getContact(slot + 1)
    if not first or not second then return false end
    -- KOReader can silently drop both contacts after a hold becomes a rotation.
    -- Observe only this hold's contacts; never intercept or modify native input.
    local function check()
        if self.quadrant_hold_check ~= check then return end
        if self.closed or self.owner.quadrant_hold ~= hold then
            self:stop_quadrant_hold_watch()
            return
        end
        if detector:getContact(slot) ~= first or detector:getContact(slot + 1) ~= second
            or not first.down or not second.down
            or not first.current_tev or first.current_tev.id == -1
            or not second.current_tev or second.current_tev.id == -1 then
            invoke_owner(self.owner, "onTwoFingerHoldRelease", self)
            self:stop_quadrant_hold_watch()
            return
        end
        if not pcall(self.scheduler.scheduleIn, self.scheduler, 0.05, check) then
            invoke_owner(self.owner, "onTwoFingerHoldRelease", self)
            self:stop_quadrant_hold_watch()
        end
    end
    self.quadrant_hold_check = check
    if not pcall(self.scheduler.scheduleIn, self.scheduler, 0.05, check) then
        self:stop_quadrant_hold_watch()
        return false
    end
    return true
end

function ReaderShell:close_now()
    self:stop_quadrant_hold_watch()
    if self.closed then return true end
    self.closed = true
    local bubble = self.bubble_zoom
    self.bubble_zoom, self.page_image, self.bubble_hold_consumed = nil, nil, nil
    pcall(self.close_panel_zoom, self)
    self.current_model = nil
    local input_dialog = self.input_dialog
    self.input_dialog = nil
    if input_dialog and self.ui_manager and type(self.ui_manager.close) == "function" then
        DialogKeyboard.hide(input_dialog)
        pcall(self.ui_manager.close, self.ui_manager, input_dialog)
    end
    if self.ui_manager and type(self.ui_manager.close) == "function" then
        pcall(self.ui_manager.close, self.ui_manager, self.widget)
    end
    if bubble then self:free_buffer_later(bubble.buffer) end
    return true
end

return ReaderShell
