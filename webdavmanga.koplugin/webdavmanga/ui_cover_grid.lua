local SafeCallback = require("webdavmanga.safe_callback")

local CoverGrid = {}
CoverGrid.__index = CoverGrid

local MAX_DISPLAY_NAME_CHARS = 16

local function utf8_char_length(value, position)
    local first = value:byte(position)
    if not first then return 0 end
    if first < 0x80 then return 1 end
    if first >= 0xC2 and first <= 0xDF then return 2 end
    if first >= 0xE0 and first <= 0xEF then return 3 end
    if first >= 0xF0 and first <= 0xF4 then return 4 end
    return 1
end

local function display_name(value)
    local text = tostring(value or "")
    local position, count = 1, 0
    while position <= #text and count < MAX_DISPLAY_NAME_CHARS do
        position = position + utf8_char_length(text, position)
        count = count + 1
    end
    if position <= #text then
        local keep_position, kept = 1, 0
        while keep_position <= #text and kept < MAX_DISPLAY_NAME_CHARS - 1 do
            keep_position = keep_position + utf8_char_length(text, keep_position)
            kept = kept + 1
        end
        return text:sub(1, keep_position - 1) .. "…"
    end
    return text
end

CoverGrid.display_name = display_name

local function progress_value(value)
    value = tonumber(value) or 0
    return math.max(0, math.min(1, value))
end

local function cache_indicator(item)
    if item and item.cache_complete == true then return "complete" end
    if item and item.cache_progress ~= nil then return "progress" end
end

CoverGrid.cache_indicator = cache_indicator

local function default_scheduler()
    local ok, manager = pcall(require, "ui/uimanager")
    return ok and manager or nil
end

local function schedule(scheduler, callback)
    if scheduler and type(scheduler.scheduleIn) == "function" then
        local ok, result = pcall(scheduler.scheduleIn, scheduler, 0, callback)
        if ok and result ~= false then return true end
    end
    callback()
    return false
end

local function default_ui()
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local IconWidget = require("ui/widget/iconwidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local ProgressWidget = require("ui/widget/progresswidget")
    local RectSpan = require("ui/widget/rectspan")
    local Screen = Device.screen
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local TitleBar = require("ui/widget/titlebar")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")

    local adapter = { widget = nil }
    local GridCell = InputContainer:extend{}

    function GridCell:_cover_widget(buffer)
        local content
        if buffer then
            self.buffer = buffer
            content = ImageWidget:new{
                image = buffer,
                image_disposable = false,
                width = self.cover_w,
                height = self.cover_h,
                scale_factor = 0,
                file_do_cache = false,
            }
        else
            self.buffer = nil
            content = RectSpan:new{
                width = self.cover_w,
                height = self.cover_h,
            }
        end
        local frame = FrameContainer:new{
            width = self.cover_w,
            height = self.cover_h,
            margin = 0,
            padding = 0,
            bordersize = Size.border.thin,
            CenterContainer:new{
                dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
                content,
            },
        }
        local overlays = { frame }
        if self.item.is_read then
            local badge_size = math.max(14, Screen:scaleBySize(16))
            local badge = FrameContainer:new{
                width = badge_size,
                height = badge_size,
                margin = 0,
                padding = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{
                    text = "✓",
                    face = Font:getFace("cfont", Screen:scaleBySize(14)),
                    width = badge_size,
                    height = badge_size,
                    alignment = "center",
                },
            }
            badge.overlap_offset = {
                math.max(Size.border.thin, self.cover_w - badge_size - Size.border.thin),
                math.max(0, self.cover_h - badge_size - Size.border.thin),
            }
            overlays[#overlays + 1] = badge
        end
        if self.model and self.model.multi_select then
            local select_size = math.max(16, Screen:scaleBySize(18))
            local select_badge = FrameContainer:new{
                width = select_size,
                height = select_size,
                margin = 0,
                padding = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{
                    text = self.item.selected and "✓" or "□",
                    face = Font:getFace("cfont", Screen:scaleBySize(16)),
                    width = select_size,
                    height = select_size,
                    alignment = "center",
                },
            }
            select_badge.overlap_offset = {
                Size.border.thin,
                Size.border.thin,
            }
            overlays[#overlays + 1] = select_badge
        end
        local indicator = cache_indicator(self.item)
        if indicator == "complete" then
            local badge_size = math.max(14, Screen:scaleBySize(16))
            local badge = IconWidget:new{
                icon = "check",
                width = badge_size,
                height = badge_size,
                alpha = true,
            }
            badge.overlap_offset = {
                math.max(0, self.cover_w - badge_size - Size.border.thin),
                Size.border.thin,
            }
            overlays[#overlays + 1] = badge
        elseif indicator == "progress" then
            local height = math.max(Screen:scaleBySize(8), Size.border.thin * 3)
            local track = ProgressWidget:new{
                width = math.max(1, self.cover_w - Size.border.thin * 2),
                height = height,
                bordersize = Size.border.thin,
                margin_h = Size.border.thin,
                margin_v = 0,
                radius = 0,
                bgcolor = Blitbuffer.COLOR_WHITE,
                fillcolor = Blitbuffer.COLOR_BLACK,
                bordercolor = Blitbuffer.COLOR_BLACK,
                percentage = progress_value(self.item.cache_progress),
                allow_mirroring = false,
            }
            track.overlap_offset = {
                Size.border.thin,
                math.max(0, self.cover_h - height - Size.border.thin),
            }
            overlays[#overlays + 1] = track
        end
        if #overlays == 1 then return frame end
        local group = {
            dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
            allow_mirroring = false,
        }
        for _, widget in ipairs(overlays) do group[#group + 1] = widget end
        return OverlapGroup:new(group)
    end

    function GridCell:init()
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
            HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
        local cover_slot = CenterContainer:new{
            dimen = Geom:new{ w = self.cover_w, h = self.cover_h },
            self:_cover_widget(nil),
        }
        self.cover_slot = cover_slot
        local text_widget = TextBoxWidget:new{
            text = display_name(self.item.name),
            face = Font:getFace("cfont", TextBoxWidget:getFontSizeToFitHeight(self.name_h, 2)),
            width = self.cell_w,
            height = self.name_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }
        self[1] = VerticalGroup:new{
            cover_slot,
            text_widget,
        }
    end

    function GridCell:onTapSelect()
        if self.model and self.model.multi_select then
            if self.model.on_toggle_select then
                pcall(self.model.on_toggle_select, self.item)
            end
            return true
        end
        if self.item.on_open then pcall(self.item.on_open) end
        return true
    end

    function GridCell:onHoldSelect()
        if self.item.on_hold then pcall(self.item.on_hold) end
        return true
    end

    function GridCell:set_cover(buffer)
        local previous = self.buffer
        local previous_widget = self.cover_slot[1]
        self.cover_slot[1] = self:_cover_widget(buffer)
        if previous_widget and previous_widget.free then previous_widget:free() end
        if previous and previous ~= buffer and previous.free then previous:free() end
        return true
    end

    function GridCell:set_selected(selected)
        self.item.selected = selected == true
        local previous_widget = self.cover_slot[1]
        self.cover_slot[1] = self:_cover_widget(self.buffer)
        if previous_widget and previous_widget.free then previous_widget:free() end
        return true
    end

    function GridCell:set_progress(progress, complete)
        self.item.cache_progress = progress_value(progress)
        if complete ~= nil then
            self.item.cache_complete = complete == true
        elseif self.item.cache_progress < 1 then
            self.item.cache_complete = false
        end
        local previous_widget = self.cover_slot[1]
        self.cover_slot[1] = self:_cover_widget(self.buffer)
        if previous_widget and previous_widget.free then previous_widget:free() end
        return true
    end

    function GridCell:free_cover()
        local buffer = self.buffer
        if not buffer then return end
        local previous_widget = self.cover_slot[1]
        self.cover_slot[1] = self:_cover_widget(nil)
        if previous_widget and previous_widget.free then previous_widget:free() end
        if buffer.free then buffer:free() end
    end

    local GridWidget = InputContainer:extend{
        -- This is a page, not a dialog. Keeping it modal makes later KOReader
        -- menus and search inputs open underneath the invisible grid layer.
        modal = false,
        fullscreen = true,
        covers_fullscreen = true,
    }

    function GridWidget:_new_title_bar()
        if self.model.on_toggle_view then
            return require("webdavmanga.bookshelf_toolbar").new(self.model,self.screen_w)
        end
        return TitleBar:new{
            title = self.model.title,
            subtitle = self.model.subtitle,
            width = self.screen_w,
            with_bottom_line = true,
        }
    end

    function GridWidget:_footer()
        local count = (self.model.allow_multi_select and 4 or 3)
            + (self.model.on_settings and 1 or 0)
            + (self.model.on_actions and 1 or 0)
        local button_w = math.floor(self.screen_w / count)
        local buttons = {}
        local function add_button(button)
            button.width = #buttons + 1 == count
                and self.screen_w - button_w * (count - 1) or button_w
            buttons[#buttons + 1] = Button:new(button)
        end
        add_button{
                text = "上一页",
                enabled = self.page > 1,
                callback = function()
                    pcall(self.set_page, self, self.page - 1)
                    return true
                end,
            }
        add_button{
                text = "下一页",
                enabled = self.page * self.page_size < #self.model.items,
                callback = function()
                    pcall(self.set_page, self, self.page + 1)
                    return true
                end,
            }
        if self.model.on_settings then
            add_button{
                text = "设置",
                callback = function()
                    pcall(self.model.on_settings)
                    return true
                end,
            }
        end
        if self.model.on_actions then
            add_button{text="操作",callback=function() pcall(self.model.on_actions);return true end}
        end
        if self.model.allow_multi_select then
            add_button{
                text = self.model.multi_select and "批量操作" or "多选",
                callback = function()
                    if self.model.multi_select then
                        if self.model.on_batch_action then
                            pcall(self.model.on_batch_action, self.model:selected_items())
                        end
                    elseif self.model.on_enter_multi_select then
                        pcall(self.model.on_enter_multi_select)
                    end
                    return true
                end,
            }
            add_button{
                text = self.model.multi_select and "退出多选" or "返回",
                callback = function()
                    if self.model.multi_select and self.model.on_exit_multi_select then
                        pcall(self.model.on_exit_multi_select)
                    elseif self.model.on_back then
                        pcall(self.model.on_back)
                    end
                    return true
                end,
            }
        else
            add_button{
                text = "返回",
                callback = function()
                    if self.model.on_back then pcall(self.model.on_back) end
                    return true
                end,
            }
        end
        local group = HorizontalGroup:new{}
        for _, button in ipairs(buttons) do group[#group + 1] = button end
        return group
    end

    function GridWidget:init()
        self.screen_w = math.max(1, Screen:getWidth())
        self.screen_h = math.max(1, Screen:getHeight())
        self.dimen = Screen:getSize()
        self.page = 1
        self.page_size = 1
        self.cells = {}
        local title = self:_new_title_bar()
        local title_h = title:getSize().h
        title:free()
        local footer = self:_footer()
        local footer_h = footer:getSize().h
        footer:free()
        local available_h = math.max(1, self.screen_h - title_h - footer_h)
        self.columns = self.model.columns == 3 and 3 or 5
        self.cell_w = math.max(1, math.floor(self.screen_w / self.columns))
        self.name_h = math.max(Screen:scaleBySize(42), math.floor(available_h * 0.09))
        local wanted_cell_h = Screen:scaleBySize(190)
        self.page_size = math.max(self.columns,
            math.floor(available_h / math.max(1, wanted_cell_h)) * self.columns)
        self.rows = math.max(1, math.floor(self.page_size / self.columns))
        self.page_size = self.rows * self.columns
        self.cell_h = math.max(1, math.floor(available_h / self.rows))
        self.cover_h = math.max(1, self.cell_h - self.name_h - 2 * Size.padding.small)
        self.cover_w = math.max(1, self.cell_w - 2 * Size.padding.small)
        self.cover_width = self.cover_w
        self.cover_height = self.cover_h
        if self.model.initial_item_id then
            for index,item in ipairs(self.model.items) do
                if item.id==self.model.initial_item_id then
                    self.page=math.floor((index-1)/self.page_size)+1;break
                end
            end
        end
        self:_rebuild()
    end

    function GridWidget:_free_page()
        for _, cell in pairs(self.cells) do cell:free_cover() end
        if self.page_group and self.page_group.free then self.page_group:free() end
        self.page_group = nil
        self.cells = {}
    end

    function GridWidget:_rebuild()
        self:_free_page()
        local title = self:_new_title_bar()
        local row_group = VerticalGroup:new{}
        local visible_ids = {}
        local first = (self.page - 1) * self.page_size + 1
        local last = math.min(#self.model.items, first + self.page_size - 1)
        local row
        for index = first, last do
            local item = self.model.items[index]
            if (index - first) % self.columns == 0 then
                row = HorizontalGroup:new{ align = "center" }
                row_group[#row_group + 1] = row
            end
            local cell = GridCell:new{
                item = item,
                model = self.model,
                dimen = Geom:new{ w = self.cell_w, h = self.cell_h },
                cell_w = self.cell_w,
                cover_w = self.cover_w,
                cover_h = self.cover_h,
                name_h = self.name_h,
            }
            row[#row + 1] = cell
            self.cells[item.id] = cell
            visible_ids[#visible_ids + 1] = item.id
        end
        if row then
            while #row < self.columns do
                row[#row + 1] = RectSpan:new{
                    width = self.cell_w,
                    height = self.cell_h,
                }
            end
        end
        while #row_group < self.rows do
            local empty_row = HorizontalGroup:new{ align = "center" }
            for _ = 1, self.columns do
                empty_row[#empty_row + 1] = RectSpan:new{
                    width = self.cell_w,
                    height = self.cell_h,
                }
            end
            row_group[#row_group + 1] = empty_row
        end
        self.page_group = FrameContainer:new{
            width = self.screen_w,
            height = self.screen_h,
            margin = 0,
            padding = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{ title, row_group, self:_footer() },
        }
        self[1] = self.page_group
        self.visible_ids = {}
        for _, id in ipairs(visible_ids) do if id then self.visible_ids[#self.visible_ids + 1] = id end end
    end

    function GridWidget:publish_visible()
        self.model.visible_ids = self.visible_ids
        if self.model.on_visible then pcall(self.model.on_visible, self.visible_ids) end
    end

    function GridWidget:set_page(page)
        local total_pages = math.max(1, math.ceil(#self.model.items / self.page_size))
        local next_page = math.max(1, math.min(total_pages, page))
        if next_page == self.page then return false end
        self.page = next_page
        self:_rebuild()
        self:publish_visible()
        UIManager:setDirty(self, "ui")
        return true
    end

    function GridWidget:set_cover(item_id, buffer)
        local cell = self.cells[item_id]
        if not cell then return false end
        cell:set_cover(buffer)
        UIManager:setDirty(self, function() return "ui", cell.dimen end)
        return true
    end

    function GridWidget:set_selection(item_id, selected)
        local cell = self.cells[item_id]
        if not cell then return false end
        cell:set_selected(selected)
        UIManager:setDirty(self, function() return "ui", cell.dimen end)
        return true
    end

    function GridWidget:set_progress(item_id, progress, complete)
        local cell = self.cells[item_id]
        if not cell then return false end
        cell:set_progress(progress, complete)
        UIManager:setDirty(self, function() return "ui", cell.dimen end)
        return true
    end

    function GridWidget:set_multi_select(enabled)
        self.model.multi_select = enabled == true
        self:_rebuild()
        self:publish_visible()
        UIManager:setDirty(self, "ui")
        return true
    end

    function GridWidget:paintTo(bb, x, y)
        -- UIManager may have one repaint already queued when the grid is
        -- closed.  WidgetContainer:free() clears its child at that point;
        -- skip the stale paint instead of walking a released FrameContainer.
        if self.closed or not self[1] then return end
        local ok, err = pcall(InputContainer.paintTo, self, bb, x, y)
        if ok or self.paint_failed then return end
        self.paint_failed = true
        local function recover()
            if adapter.widget == self and self.model.on_render_error then
                self.model.on_render_error(err)
            end
        end
        if type(UIManager.nextTick) == "function" then
            local scheduled, result = pcall(UIManager.nextTick, UIManager, recover)
            if scheduled and result ~= false then return end
        end
        if type(UIManager.scheduleIn) == "function" then
            pcall(UIManager.scheduleIn, UIManager, 0, recover)
        end
    end

    function GridWidget:free_visible_images()
        for _, cell in pairs(self.cells) do cell:free_cover() end
    end

    function GridWidget:onClose()
        if self.skip_close_callback then return true end
        if self.model.on_back then pcall(self.model.on_back) end
        return true
    end

    function adapter:show_grid(model)
        self:close_grid()
        local widget = GridWidget:new{ model = model }
        self.widget = widget
        model.fullscreen = true
        model.columns = widget.columns
        model.rows = widget.rows
        model.cover_width = widget.cover_w
        model.cover_height = widget.cover_h
        model.cells = {}
        for _, item in ipairs(model.items or {}) do
            model.cells[#model.cells + 1] = {
                id = item.id,
                name = item.name,
                name_lines = 1,
                is_read = item.is_read == true,
                cache_progress = item.cache_progress,
                cache_complete = item.cache_complete == true,
            }
        end
        UIManager:show(widget)
        local function publish()
            if self.widget == widget then widget:publish_visible() end
        end
        if type(UIManager.nextTick) == "function" then
            local ok, result = pcall(UIManager.nextTick, UIManager, publish)
            if ok and result ~= false then return end
        end
        publish()
    end

    function adapter:get_cover_size()
        if not self.widget then return nil end
        return self.widget.cover_w, self.widget.cover_h
    end

    function adapter:update_cover(item_id, buffer)
        if self.widget then return self.widget:set_cover(item_id, buffer) end
        return false
    end

    function adapter:set_selection(item_id, selected)
        for _, cell in ipairs(self.widget and self.widget.model.cells or {}) do
            if cell.id == item_id then cell.selected = selected == true end
        end
        if self.widget then return self.widget:set_selection(item_id, selected) end
        return false
    end

    function adapter:set_progress(item_id, progress, complete)
        for _, cell in ipairs(self.widget and self.widget.model.cells or {}) do
            if cell.id == item_id then
                cell.cache_progress = progress_value(progress)
                if complete ~= nil then cell.cache_complete = complete == true end
            end
        end
        if self.widget then return self.widget:set_progress(item_id, progress, complete) end
        return false
    end

    function adapter:set_multi_select(enabled)
        if self.widget then return self.widget:set_multi_select(enabled) end
        return false
    end

    function adapter:free_visible()
        if self.widget then self.widget:free_visible_images() end
    end

    function adapter:close_grid()
        local widget = self.widget
        self.widget = nil
        if not widget then return end
        widget.closed = true
        widget.skip_close_callback = true
        widget:free_visible_images()
        UIManager:close(widget)
    end

    return adapter
end

function CoverGrid:new(deps)
    deps = deps or {}
    local object = setmetatable({}, self)
    object.cover_service = assert(deps.cover_service, "cover service is required")
    object.loader = assert(deps.loader, "loader is required")
    object.cache = assert(deps.cache, "cache is required")
    object.connection_provider = assert(deps.connection_provider, "connection provider is required")
    object.settings = assert(deps.settings, "settings is required")
    object.render_image = deps.render_image
    object.fit_whole_image = deps.fit_whole_image == true
    object.image_probe = deps.image_probe or require("webdavmanga.image_probe")
    object.render_document_cover = deps.render_document_cover
    object.scheduler = deps.scheduler or default_scheduler()
    object.ui = deps.ui
    if not object.ui and not deps.defer_ui then object.ui=default_ui() end
    object.error_reporter = deps.error_reporter
    object.sequence = 0
    object.view_sequence = 0
    object.active_generation = nil
    object.active_resolution = nil
    object.queue = {}
    object.items_by_id = {}
    object.is_open = false
    object.leave_sequence = 0
    return object
end

function CoverGrid:_guard(view, label, callback, fallback)
    return SafeCallback.wrap(self.error_reporter or self.ui, label, function(...)
        if not self.is_open or view ~= self.view_sequence then return fallback end
        return callback(...)
    end, fallback)
end

function CoverGrid:_new_generation()
    self.sequence = self.sequence + 1
    return "grid:" .. tostring(self.sequence)
end

function CoverGrid:_cancel_active_work()
    local generation = self.active_generation
    local resolution = self.active_resolution
    self.active_generation = nil
    self.active_resolution = nil
    self.queue = {}
    if generation and self.loader.cancel_cover_generation then
        pcall(self.loader.cancel_cover_generation, self.loader, generation)
    end
    if resolution and resolution.cancel then pcall(resolution.cancel, resolution) end
end

function CoverGrid:_is_current(generation)
    return self.is_open and self.active_generation == generation
end

function CoverGrid:_cache_path(image)
    if type(image) ~= "table" or type(image.path) ~= "string" then return nil end
    if not self.cache or type(self.cache.key_for) ~= "function" or type(self.cache.lookup) ~= "function" then return nil end
    local key = self.loader.cover_key and self.loader:cover_key(image)
        or self.cache:key_for(self.loader.identity, image.path)
    return self.cache:lookup(key)
end

function CoverGrid:_target_size()
    if self.ui and type(self.ui.get_cover_size) == "function" then
        local width, height = self.ui:get_cover_size()
        if tonumber(width) and tonumber(height) then return math.floor(width), math.floor(height) end
    end
    return 120, 160
end

function CoverGrid:_renderer()
    if self.render_image then return self.render_image end
    local ok, renderer = pcall(require, "ui/renderimage")
    if ok then self.render_image = renderer end
    return self.render_image
end

function CoverGrid:_render_cover(generation, item, local_path)
    if not self:_is_current(generation) then return false end
    local renderer = self:_renderer()
    if not renderer or type(renderer.renderImageFile) ~= "function" then return false end
    local width, height = self:_target_size()
    if self.fit_whole_image then
        local inspected,info=pcall(self.image_probe.inspect,local_path,nil)
        if not inspected or not info then return false end
        width,height=require("webdavmanga.page_processor").target_size(info.width,info.height,
            {fit_mode="page",split_enabled=false},width,height)
        if not width then return false end
    end
    local ok, buffer = pcall(renderer.renderImageFile, renderer, local_path, false, width, height)
    if not ok or not buffer then return false end
    if not self:_is_current(generation) then
        if buffer.free then pcall(buffer.free, buffer) end
        return false
    end
    local updated
    if self.error_reporter then
        updated = self.error_reporter:guard("load_cover", function()
            return self.ui:update_cover(item.id, buffer)
        end, false, nil, { silent = true })
    else
        local ok, result = pcall(self.ui.update_cover, self.ui, item.id, buffer)
        updated = ok and result
    end
    if updated == false and buffer.free then pcall(buffer.free, buffer) end
    return updated ~= false
end

function CoverGrid:_render_document_cover(generation, item, local_path)
    if not self:_is_current(generation) then return false end
    local width, height = self:_target_size()
    local ok, buffer
    if self.render_document_cover then
        ok, buffer = pcall(self.render_document_cover, local_path, width, height)
    else
        ok, buffer = pcall(function()
            local registry = require("document/documentregistry")
            local reader_ui = require("apps/reader/readerui")
            local provider = registry:getProvider(local_path)
            provider = reader_ui:extendProvider(local_path, provider)
            local document = registry:openDocument(local_path, provider)
            if not document then return nil end
            if document.loadDocument then
                local loaded_ok, loaded = pcall(document.loadDocument, document, false)
                if not loaded_ok or loaded == false then
                    pcall(document.close, document)
                    return nil
                end
            end
            local cover_ok, cover = pcall(document.getCoverPageImage, document)
            pcall(document.close, document)
            if not cover_ok or not cover then return nil end
            local cover_width = tonumber(cover:getWidth()) or width
            local cover_height = tonumber(cover:getHeight()) or height
            local factor = math.min(width / cover_width, height / cover_height)
            local target_width = math.max(1, math.floor(cover_width * factor))
            local target_height = math.max(1, math.floor(cover_height * factor))
            local renderer = self:_renderer()
            if renderer and type(renderer.scaleBlitBuffer) == "function" then
                return renderer:scaleBlitBuffer(cover, target_width, target_height, true)
            end
            return cover
        end)
    end
    if not ok or not buffer or not self:_is_current(generation) then
        if buffer and buffer.free then pcall(buffer.free, buffer) end
        return false
    end
    local updated
    if self.error_reporter then
        updated = self.error_reporter:guard("load_document_cover", function()
            return self.ui:update_cover(item.id, buffer)
        end, false, nil, { silent = true })
    else
        local update_ok, result = pcall(self.ui.update_cover, self.ui, item.id, buffer)
        updated = update_ok and result
    end
    if updated == false and buffer.free then pcall(buffer.free, buffer) end
    return updated ~= false
end

function CoverGrid:_request_download(generation, item, image, on_done)
    if not self:_is_current(generation) then return end
    if self.loader.protect_cover then self.loader:protect_cover(generation, image) end
    local finished = false
    local function done()
        if finished then return end
        finished = true
        if self:_is_current(generation) and on_done then on_done() end
    end
    local local_path = self:_cache_path(image)
    if local_path then
        self:_render_cover(generation, item, local_path)
        done()
        return
    end
    local ok, handle = pcall(self.loader.request_cover, self.loader,
        generation, image, {
            on_ready = function(path)
                self:_render_cover(generation, item, path)
                done()
            end,
            on_error = done,
        })
    if not ok then done(); return nil end
    if handle == nil and not finished then done() end
    return handle
end

function CoverGrid:_resolve_next(generation)
    if not self:_is_current(generation) then return end
    local item = table.remove(self.queue, 1)
    if not item then
        self.active_resolution = nil
        return
    end
    self.active_resolution = nil
    if item.local_document_path then
        self:_render_document_cover(generation, item, item.local_document_path)
        return self:_resolve_next(generation)
    end
    if item.local_cover_path then
        local rendered = self:_render_cover(generation, item, item.local_cover_path)
        if rendered or item.local_deleted then
            return self:_resolve_next(generation)
        end
    end
    if item.offline_shelf then return self:_resolve_next(generation) end
    local settled = false
    local function advance(image)
        if settled then return end
        settled = true
        if not self:_is_current(generation) then return end
        self.active_resolution = nil
        if image then
            return self:_request_download(generation, item, image,
                function() self:_resolve_next(generation) end)
        end
        self:_resolve_next(generation)
    end
    local connection
    if self.error_reporter then
        connection = self.error_reporter:guard("load_cover", self.connection_provider, nil, nil, { silent = true })
    else
        local ok
        ok, connection = pcall(self.connection_provider)
        if not ok then connection = nil end
    end
    if not connection then return advance(nil) end
    local handle
    local ok, result = pcall(self.cover_service.resolve, self.cover_service, connection, {
        manga = item.manga,
        cover_hint = item.cover_hint,
        layout = item.layout,
        chapter = item.chapter,
    }, {
        on_ready = advance,
        on_error = function() advance(nil) end,
    })
    if ok then handle = result end
    if not ok then return advance(nil) end
    if handle and not settled and self:_is_current(generation) then self.active_resolution = handle end
end

function CoverGrid:_visible(view, ids)
    if not self.is_open or view ~= self.view_sequence then return false end
    if self.ui.free_visible then pcall(self.ui.free_visible, self.ui) end
    self:_cancel_active_work()
    local generation = self:_new_generation()
    self.active_generation = generation
    local seen = {}
    for _, id in ipairs(ids or {}) do
        local item = self.items_by_id[id]
        if item and not seen[id] then
            seen[id] = true
            self.queue[#self.queue + 1] = item
        end
    end
    self:_resolve_next(generation)
    return true
end

function CoverGrid:_close_view()
    -- leave_for closes immediately, but its navigation runs next tick. Even
    -- an already closed grid must invalidate that pending action on cancel.
    self.leave_sequence = self.leave_sequence + 1
    if not self.is_open then return false end
    self.is_open = false
    self.view_sequence = self.view_sequence + 1
    self:_cancel_active_work()
    if self.ui.free_visible then pcall(self.ui.free_visible, self.ui) end
    if self.ui.close_grid then pcall(self.ui.close_grid, self.ui) end
    self.items_by_id = {}
    return true
end

function CoverGrid:show(options)
    options = options or {}
    if not self.ui then self.ui=default_ui() end
    if self.is_open then self:_close_view() end
    self.leave_sequence = self.leave_sequence + 1
    self.view_sequence = self.view_sequence + 1
    local view = self.view_sequence
    self.is_open = true
    self.items_by_id = {}
    local items = {}
    for _, item in ipairs(options.items or {}) do
        local current = {}
        for key, value in pairs(item) do current[key] = value end
        current.id = current.id or current.manga and current.manga.path or #items + 1
        current.name = current.name or current.manga and current.manga.name or current.text or ""
        -- The library model calls the secondary action `on_action`; the
        -- cover grid exposes that action through its long-press gesture.
        if not current.on_hold and type(current.on_action) == "function" then
            current.on_hold = current.on_action
        end
        if current.on_open then current.on_open=self:_guard(view,"open cover item",current.on_open,false) end
        if current.on_hold then current.on_hold=self:_guard(view,"manage cover item",current.on_hold,false) end
        self.items_by_id[current.id] = current
        items[#items + 1] = current
    end
    local on_back = options.on_back or function() end
    local on_settings = options.on_settings
    local first_visible=true
    local model = {
        title = options.title,
        subtitle = options.subtitle,
        initial_item_id=options.initial_item_id,
        view_mode=options.view_mode,
        fullscreen = true,
        items = items,
        columns = self.settings:get_reader().grid_columns == 3 and 3 or 5,
        cells = {},
        allow_multi_select = options.allow_multi_select == true,
        multi_select = false,
        selected_ids = {},
        ui = self.ui,
        on_visible = self:_guard(view, "load visible covers", function(ids)
            local anchor=ids and ids[1]
            if first_visible and options.initial_item_id then
                for _,id in ipairs(ids or {}) do if id==options.initial_item_id then anchor=id;break end end
            end
            first_visible=false
            if anchor and options.on_anchor then options.on_anchor(anchor) end
            return self:_visible(view, ids)
        end, false),
        on_back = self:_guard(view, "close cover grid", function()
            self:_close_view()
            on_back()
        end),
        on_settings = type(on_settings) == "function"
            and self:_guard(view, "open cover grid settings", on_settings, false) or nil,
        on_render_error = self:_guard(view, "recover cover grid repaint", function(err)
            if self.error_reporter and type(self.error_reporter.report) == "function" then
                self.error_reporter:report("show cover grid", err)
            end
            self:_close_view()
            on_back()
            return true
        end, true),
    }
    for _,name in ipairs({"on_toggle_view","on_switch_connection","on_actions","on_close"}) do
        if type(options[name])=="function" then model[name]=self:_guard(view,name,options[name],true) end
    end
    function model:selected_items()
        local selected = {}
        for _, item in ipairs(items) do
            if self.selected_ids[item.id] then selected[#selected + 1] = item end
        end
        return selected
    end
    function model:_refresh_selection(item)
        if not item then return end
        item.selected = self.selected_ids[item.id] == true
        if self.ui and type(self.ui.set_selection) == "function" then
            pcall(self.ui.set_selection, self.ui, item.id, item.selected)
        end
    end
    model.on_enter_multi_select = self:_guard(view, "enter cover grid multi-select", function()
        if not model.allow_multi_select then return false end
        model.multi_select = true
        if self.ui and type(self.ui.set_multi_select) == "function" then
            self.ui:set_multi_select(true)
        end
        return true
    end, false)
    model.on_exit_multi_select = self:_guard(view, "exit cover grid multi-select", function()
        model.multi_select = false
        model.selected_ids = {}
        for _, item in ipairs(items) do item.selected = false end
        if self.ui and type(self.ui.set_multi_select) == "function" then
            self.ui:set_multi_select(false)
        end
        return true
    end, false)
    model.on_toggle_select = self:_guard(view, "toggle cover grid selection", function(item)
        if not model.multi_select or not item then return false end
        model.selected_ids[item.id] = not model.selected_ids[item.id] or nil
        model.selected_count = 0
        for _, value in pairs(model.selected_ids) do if value then model.selected_count = model.selected_count + 1 end end
        model:_refresh_selection(item)
        return true
    end, false)
    local original_on_batch = options.on_batch_action
    model.on_batch_action = self:_guard(view, "batch manage cover grid", function(selected)
        if not model.multi_select then return false end
        selected = selected or model:selected_items()
        if #selected == 0 then
            if self.ui and type(self.ui.show_info) == "function" then self.ui:show_info("请先选择漫画。") end
            return false
        end
        self:_close_view()
        if original_on_batch then return original_on_batch(selected) end
        return true
    end, false)
    for _, item in ipairs(items) do
        model.cells[#model.cells + 1] = {
            id = item.id, name = display_name(item.name), name_lines = 2,
            is_read = item.is_read == true,
            cache_progress = item.cache_progress,
            cache_complete = item.cache_complete == true,
        }
    end
    local shown
    if self.error_reporter and type(self.error_reporter.guard) == "function" then
        shown = self.error_reporter:guard("show cover grid", function()
            self.ui:show_grid(model)
            return true
        end, false)
    else
        local ok = pcall(self.ui.show_grid, self.ui, model)
        shown = ok
    end
    if not shown then
        self:_close_view()
        return false
    end
    return true
end

function CoverGrid:update_progress(item_id, progress, complete)
    local item = self.items_by_id[item_id]
    if not self.is_open or not item then return false end
    item.cache_progress = progress_value(progress)
    if complete ~= nil then
        item.cache_complete = complete == true
    elseif item.cache_progress < 1 then
        item.cache_complete = false
    end
    if self.ui and type(self.ui.set_progress) == "function" then
        local ok, result = pcall(self.ui.set_progress, self.ui, item_id,
            item.cache_progress, item.cache_complete)
        return ok and result ~= false
    end
    return false
end

function CoverGrid:leave_for(callback)
    if not self.is_open then return false end
    self:_close_view()
    local token = self.leave_sequence
    if type(callback) == "function" then
        schedule(self.scheduler, function()
            if token == self.leave_sequence then callback() end
        end)
    end
    return true
end

function CoverGrid:close()
    return self:_close_view()
end

function CoverGrid:cancel()
    return self:_close_view()
end

return CoverGrid
