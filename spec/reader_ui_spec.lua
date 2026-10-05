local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")

expect(math.abs(Reader.width_scale(1000, 10, true, 500) - 1.96) < 0.0001,
    "fit-width scale should account for viewer padding")
expect(Reader.width_scale(1000, 10, false, 500) == 2,
    "fullscreen fit-width scale should use the entire width")
local stale_zoom = { _min_scale_factor = 0.5, _max_scale_factor = 4, _scale_factor_0 = 1.5 }
Reader.reset_zoom_state(stale_zoom)
expect(stale_zoom._min_scale_factor == nil and stale_zoom._max_scale_factor == nil
    and stale_zoom._scale_factor_0 == nil,
    "switching image should discard stale scale extrema")
expect(Reader.image_widget_decoded({ getSize = function() return { w = 10, h = 20 } end }),
    "a decoded KOReader widget should be accepted")
expect(not Reader.image_widget_decoded({
        _is_straight_alpha = false,
        getSize = function() return { w = 10, h = 20 } end,
    }), "KOReader's decoder placeholder should be rejected")
expect(not Reader.image_widget_decoded({ getSize = function() error("decode") end }),
    "widget decode exceptions should be rejected")

local function list_index(entries)
    return {
        count = function() return #entries end,
        get = function(_self, index) return entries[index] end,
        find = function(_self, path, hint)
            if entries[hint] and entries[hint].path == path then return hint end
            for index, entry in ipairs(entries) do
                if entry.path == path then return index end
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

local chapters = {
    { name = "第1话", path = "/漫画/A/第1话" },
    { name = "第2话", path = "/漫画/A/第2话" },
}
local images = {
    { name = "001.jpg", path = "/漫画/A/第1话/001.jpg" },
    { name = "002.jpg", path = "/漫画/A/第1话/002.jpg" },
    { name = "003.webp", path = "/漫画/A/第1话/003.webp" },
}
local context = {
    manga = { name = "A", path = "/漫画/A" },
    chapter = chapters[1],
    chapter_index = list_index(images),
    chapters_index = list_index(chapters),
    chapter_position = 1,
    layout = "chapters",
    cover_hint = { chapter = chapters[1] },
    source_context = { manifest_keys = { "manifest:chapters", "manifest:images" } },
    -- Task 9 removes these producers; Task 8 must ignore, not retain, the arrays.
    chapters = chapters,
    images = images,
}

local reader_settings = {
    direction = "normal", prefetch_count = 2, fit_mode = "page",
    show_page_number = true, split_enabled = false,
    split_min_ratio = 1.20, split_max_ratio = 2.20,
    split_cut_percent = 50,
    panel_zoom_enabled = false, panel_show_adjacent = true,
    panel_standard_margin_percent = 0, panel_hold_margin_percent = 5,
    panel_initial_zoom = 1.2, panel_experimental_sort = false,
}
local setting_saves = 0
local fail_reader_set = false
local fail_reader_flush = false
local settings = {
    get_connection = function()
        return { server_url = "https://nas/dav", root_path = "/漫画", username = "u" }
    end,
    get_reader = function() return reader_settings end,
    set_reader = function(_self, values)
        if fail_reader_set then error("reader settings write failed") end
        reader_settings = values
        setting_saves = setting_saves + 1
        return true
    end,
    flush = function()
        if fail_reader_flush then error("reader settings flush failed") end
    end,
}

local saved = {}
local progress = {
    chapter_id = function() return "chapter-id" end,
    resolve = function() return { index = 2, segment = "whole" } end,
    save = function(_self, chapter_id, path, index, segment, history_context)
        saved[#saved + 1] = {
            chapter_id = chapter_id, path = path, index = index,
            segment = segment, history_context = history_context,
        }
    end,
}

local requests, prefetches, canceled = {}, {}, {}
local loader = {
    identity = "nas|漫画",
    request = function(_self, generation, image, callbacks)
        requests[#requests + 1] = { generation = generation, image = image, callbacks = callbacks }
        return {}
    end,
    prefetch = function(_self, generation, window, physical_index)
        prefetches[#prefetches + 1] = {
            generation = generation, window = window, physical_index = physical_index,
        }
    end,
    cancel_generation = function(_self, generation) canceled[#canceled + 1] = generation end,
}

local protected, removed = {}, {}
local cache = {
    key_for = function(_self, identity, path) return identity .. "|" .. path end,
    set_protected = function(_self, keys) protected[#protected + 1] = keys end,
    remove = function(_self, key) removed[#removed + 1] = key end,
}

local events, scheduled = {}, {}
local pages, freed = {}, 0
local shell
shell = {
    get_content_size = function() return 600, 800 end,
    show_loading = function(_self, title) events[#events + 1] = "loading:" .. title end,
    show_error = function(_self, model) shell.error = model; events[#events + 1] = "error" end,
    show_page = function(_self, buffer, viewport, title)
        pages[#pages + 1] = { buffer = buffer, viewport = viewport, title = title }
        events[#events + 1] = "page"
        return true
    end,
    free_buffer_later = function(_self, buffer)
        events[#events + 1] = "detach"
        buffer:free()
    end,
}
local ui
ui = {
    create_shell = function() return shell end,
    show_shell = function() events[#events + 1] = "show" end,
    close_shell = function() events[#events + 1] = "close" end,
    schedule = function(_self, callback) scheduled[#scheduled + 1] = callback end,
    show_controls = function(_self, model) ui.controls = model end,
    show_page_picker = function(_self, model) ui.picker = model end,
    confirm = function(_self, model) ui.confirmation = model end,
    show_info = function(_self, message) ui.info = message end,
}

local render_calls = {}
local fail_render_count = 0
local renderer = {
    renderImageFile = function(_self, path, animated, width, height)
        render_calls[#render_calls + 1] = {
            path = path, animated = animated, width = width, height = height,
        }
        if fail_render_count > 0 then
            fail_render_count = fail_render_count - 1
            error("decode failed")
        end
        local buffer
        buffer = {
            w = width, h = height, viewport_calls = {},
            getWidth = function(self) return self.w end,
            getHeight = function(self) return self.h end,
            viewport = function(self, x, y, w, h)
                self.viewport_calls[#self.viewport_calls + 1] = { x = x, y = y, w = w, h = h }
                return self.viewport_calls[#self.viewport_calls]
            end,
            free = function(self)
                if not self.freed then self.freed = true; freed = freed + 1 end
            end,
        }
        return buffer
    end,
}

local opened_next
local reader = Reader:new{
    loader = loader, progress = progress, state = State:new(), settings = settings,
    cache = cache, ui = ui, render_image = renderer,
    open_chapter = function(manga, chapter) opened_next = { manga = manga, chapter = chapter } end,
}

reader:open(context)
expect(events[1] == "show" and events[2]:find("loading:", 1, true) == 1,
    "fullscreen shell should be shown before its loading content")
expect(reader.context.images == nil and reader.context.chapters == nil
    and reader.context.chapter_index == context.chapter_index,
    "reader session should retain indexes and discard legacy arrays")
expect(#requests == 1 and requests[1].image == images[2],
    "segment-aware progress should choose the first physical request")
expect(#saved == 0 and #pages == 0,
    "progress and page publication must wait for a successful decode")

requests[1].callbacks.on_ready("/cache/002.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })
expect(#render_calls == 1 and render_calls[1].width == 533 and render_calls[1].height == 800,
    "whole-page rendering should decode once at the explicit fitted target")
expect(#pages == 1 and pages[1].title == nil and reader.position.index == 2,
    "successful render should publish physical index without a page title")
expect(#saved == 1 and saved[1].path == images[2].path
    and saved[1].index == 2 and saved[1].segment == "whole",
    "successful whole-page display should checkpoint physical image and segment")
expect(saved[1].history_context.total == 3
    and saved[1].history_context.manga == context.manga
    and saved[1].history_context.chapter == context.chapter
    and saved[1].history_context.layout == "chapters"
    and saved[1].history_context.chapters == nil,
    "checkpoint history should be complete without a sibling chapter array")
expect(protected[#protected][1] == "manifest:chapters"
    and protected[#protected][2] == "manifest:images"
    and #protected[#protected] == 5,
    "current, adjacent, and two active manifest cache keys should be protected")
expect(prefetches[1].physical_index == 2 and prefetches[1].window.first_index == 1
    and #prefetches[1].window == 3,
    "prefetch should receive only a bounded ChapterIndex window plus physical index")

local function tap(x) return { pos = { x = x, y = 400 } } end
reader:onTap(nil, tap(300))
expect(ui.controls and ui.controls.index == 2 and ui.controls.total == 3,
    "center tap should open physical-image controls")
local labels = {}
for _, action in ipairs(ui.controls.actions) do labels[#labels + 1] = action.text end
labels = table.concat(labels, "|"):lower()
expect(labels:find("阅读翻页", 1, true) and labels:find("图片显示", 1, true)
    and labels:find("宽图拆分", 1, true) and labels:find("裁切白边", 1, true)
    and labels:find("跳转图片", 1, true) and labels:find("返回漫画列表", 1, true),
    "root controls should expose current section entry points")
for _, action in ipairs(ui.controls.actions) do
    if action.text == "宽图拆分" then action.callback(); break end
end
expect(ui.controls.title == "宽图拆分", "split entry should open the split submenu")
ui.show_number_input = function(_self, model) ui.number_input = model; return true end
local previous_min = reader_settings.split_min_ratio
local previous_max = reader_settings.split_max_ratio
local previous_cut = reader_settings.split_cut_percent
ui.controls.actions[2].callback()
expect(ui.number_input.on_save("1.30"), "minimum ratio input should persist a valid value")
ui.controls.actions[3].callback()
expect(ui.number_input.on_save("2.30"), "maximum ratio input should persist a valid value")
ui.controls.actions[4].callback()
expect(ui.number_input.on_save("55"), "split position input should persist a valid value")
expect(reader_settings.split_min_ratio ~= previous_min
    and reader_settings.split_max_ratio ~= previous_max
    and reader_settings.split_cut_percent ~= previous_cut
    and reader_settings.split_min_ratio < reader_settings.split_max_ratio,
    "minimum, maximum, and cut controls should adjust and persist valid split settings")
requests[#requests].callbacks.on_ready("/cache/002.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })
ui.controls.actions[#ui.controls.actions].callback()
expect(ui.controls.actions[1].text == "阅读翻页", "split back should return to root controls")
ui.controls.on_toggle_direction()
expect(reader.direction == "manga" and reader_settings.direction == "manga"
    and setting_saves >= 4,
    "direction control should persist normal/manga navigation")

reader:toggle_controls("root")
local panel_entry
for _, item in ipairs(ui.controls.actions) do
    if item.text == "智能分格阅读" then panel_entry = item end
end
expect(panel_entry ~= nil, "reader controls must expose dynamic panel settings")
panel_entry.callback()
expect(ui.controls.section == "panel" and ui.controls.columns == 2,
    "dynamic panel settings must use a separate two-column level")
expect(ui.controls.direction == reader.direction,
    "panel direction must reuse the reader direction")
local function panel_action(prefix)
    for _, item in ipairs(ui.controls.actions) do
        if item.text:find(prefix, 1, true) == 1 then return item end
    end
end
panel_action("智能分格").callback()
panel_action("显示相邻内容").callback()
panel_action("普通分格边距").callback()
panel_action("自由缩放边距").callback()
panel_action("自由缩放倍率").callback()
expect(reader_settings.panel_zoom_enabled == true
    and reader_settings.panel_show_adjacent == false
    and reader_settings.panel_standard_margin_percent == 2
    and reader_settings.panel_hold_margin_percent == 10
    and reader_settings.panel_initial_zoom == 1.5,
    "each dynamic panel control must persist its documented next value")
local pages_before_continue = #pages
expect(panel_action("继续阅读").callback() and reader.position.index == 2
    and #pages == pages_before_continue + 1 and events[#events] == "page",
    "panel continue must return to the current reading page")
reader:toggle_controls("root")
panel_entry = nil
for _, item in ipairs(ui.controls.actions) do
    if item.text == "智能分格阅读" then panel_entry = item end
end
expect(panel_entry ~= nil, "reader root must retain the panel settings entry")
panel_entry.callback()
panel_action("← 返回设置").callback()
expect(ui.controls.section == "root", "panel return must reopen reader settings")

local outer_values, outer_flushes = {}, 0
local outer_settings = Settings:new{ store = {
    readSetting = function(_, key, default)
        return outer_values[key] == nil and default or outer_values[key]
    end,
    saveSetting = function(_, key, value) outer_values[key] = value end,
    flush = function() outer_flushes = outer_flushes + 1; return true end,
} }
local outer_model
local outer = UiSettings:new{
    settings = outer_settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {},
    ui = {
        show_reader = function(_, model) outer_model = model end,
        show_info = function() end,
    },
}
outer:show_reader()
expect(outer_model and outer_model.initial_section == nil
    and outer_model.values.panel_show_adjacent == true,
    "outer reader settings must start from the root settings page")
local outer_reader_values = {}
for key, value in pairs(outer_model.values) do outer_reader_values[key] = value end
outer_reader_values.panel_zoom_enabled = true
outer_reader_values.panel_show_adjacent = false
outer_reader_values.panel_standard_margin_percent = 10
outer_reader_values.panel_hold_margin_percent = 20
outer_reader_values.panel_initial_zoom = 2.0
outer_reader_values.panel_experimental_sort = true
expect(outer_model.on_save(outer_reader_values),
    "outer dynamic panel settings must persist through its existing save callback")
local outer_reader = outer_settings:get_reader()
expect(outer_flushes == 1 and outer_reader.panel_zoom_enabled == true
    and outer_reader.panel_show_adjacent == false
    and outer_reader.panel_standard_margin_percent == 10
    and outer_reader.panel_hold_margin_percent == 20
    and outer_reader.panel_initial_zoom == 2.0
    and outer_reader.panel_experimental_sort == true,
    "outer dynamic panel save must flush and retain all documented values")

local root_values, shown_dialogs = {}, {}
local root_settings = Settings:new{ store = {
    readSetting = function(_, key, default)
        return root_values[key] == nil and default or root_values[key]
    end,
    saveSetting = function(_, key, value) root_values[key] = value end,
    flush = function() return true end,
} }
local ui_manager = {
    show = function(_, dialog) shown_dialogs[#shown_dialogs + 1] = dialog; return true end,
    close = function() return true end,
    nextTick = function() return false end,
}
local dialog_module = { new = function(_, model) return model end }
local ui_modules = {
    ["ui/widget/buttondialog"] = dialog_module,
    ["ui/widget/confirmbox"] = dialog_module,
    ["ui/widget/infomessage"] = dialog_module,
    ["ui/widget/multiinputdialog"] = dialog_module,
    ["ui/uimanager"] = ui_manager,
}
local previous_preload, previous_loaded = {}, {}
for name, module in pairs(ui_modules) do
    previous_preload[name] = package.preload[name]
    previous_loaded[name] = package.loaded[name]
    package.loaded[name] = nil
    package.preload[name] = function() return module end
end
local real_outer = UiSettings:new{
    settings = root_settings,
    client_factory = function() return {} end,
    async = { run = function() end },
    cache = {},
}
real_outer:show_reader()
local root_dialog = shown_dialogs[#shown_dialogs]
local outer_panel_entry
for _, row in ipairs(root_dialog.buttons) do
    for _, button in ipairs(row) do
        if button.text:find("智能分格阅读", 1, true) == 1 then outer_panel_entry = button end
    end
end
expect(outer_panel_entry ~= nil, "outer root settings must expose the panel entry")
outer_panel_entry.callback()
local outer_panel_dialog = shown_dialogs[#shown_dialogs]
local outer_panel_field
for _, row in ipairs(outer_panel_dialog.buttons) do
    for _, button in ipairs(row) do
        if button.text == "智能分格\n当前：关闭" then outer_panel_field = button end
    end
end
expect(outer_panel_dialog.title == "智能分格阅读默认值" and outer_panel_field ~= nil,
    "outer panel entry must open the real two-column dynamic panel page")
for name in pairs(ui_modules) do
    package.preload[name] = previous_preload[name]
    package.loaded[name] = previous_loaded[name]
end

-- Persistence failures must be reported safely and leave the in-memory reader
-- mode untouched until set_reader+flush have both succeeded.
local direction_before_failed_save = reader.direction
fail_reader_set = true
local set_ok, set_result = pcall(function()
    return reader:set_direction(direction_before_failed_save == "normal" and "manga" or "normal")
end)
fail_reader_set = false
expect(set_ok and set_result == false and reader.direction == direction_before_failed_save
    and reader.reader_settings.direction == direction_before_failed_save,
    "set_direction must not escape a settings write failure or mutate memory")

local persisted_direction_before_flush = reader.direction
fail_reader_flush = true
local flush_ok, flush_result = pcall(function()
    return reader:set_direction(persisted_direction_before_flush == "normal" and "manga" or "normal")
end)
fail_reader_flush = false
expect(flush_ok and flush_result == false and reader.direction == persisted_direction_before_flush
    and reader.reader_settings.direction == persisted_direction_before_flush
    and reader_settings.direction == persisted_direction_before_flush,
    "set_direction must roll back a flush failure before committing memory")

local fit_mode_before_failed_save = reader.fit_mode
fail_reader_set = true
local fit_ok, fit_result = pcall(function()
    return reader:set_fit_mode(fit_mode_before_failed_save == "page" and "width" or "page")
end)
fail_reader_set = false
expect(fit_ok and fit_result == false and reader.fit_mode == fit_mode_before_failed_save
    and reader.reader_settings.fit_mode == fit_mode_before_failed_save,
    "set_fit_mode must not mutate memory when settings persistence fails")
ui.controls.on_jump()
expect(ui.picker.value == 2 and ui.picker.value_min == 1 and ui.picker.value_max == 3,
    "jump picker should use physical image bounds")
ui.picker.on_select(99)
expect(requests[#requests].image == images[3], "physical jump should clamp high input")

-- Settle the clamped jump, then start the pan fixture before the last page.
requests[#requests].callbacks.on_ready("/cache/003.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })
reader:request_page(2, "whole")
requests[#requests].callbacks.on_ready("/cache/002.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })

-- Fit-width must vertically pan before requesting another physical image.
reader.direction = "normal"
reader:set_fit_mode("width")
local width_request = requests[#requests]
width_request.callbacks.on_ready("/cache/tall.jpg", false,
    { width = 800, height = 1600, format = "jpeg" })
local requests_before_pan = #requests
expect(render_calls[#render_calls].width == 600 and render_calls[#render_calls].height == 1200,
    "fit-width decode should match content width and retain vertical overflow")
reader:next_page()
expect(#requests == requests_before_pan
    and #reader.page_buffer.viewport_calls >= 2 and reader.pan_y > 0,
    "fit-width navigation should pan vertically before changing physical images")
reader:next_page()
expect(#requests == requests_before_pan + 1,
    "fit-width navigation should advance only after reaching the vertical edge")

-- Split controls produce two segments from one physical download/decode/buffer.
reader_settings.split_enabled = true
reader_settings.fit_mode = "page"
reader.fit_mode = "page"
reader.reader_settings = reader_settings
reader:request_page(1, "whole")
local split_request = requests[#requests]
local decodes_before_split = #render_calls
split_request.callbacks.on_ready("/cache/spread.jpg", false,
    { width = 1600, height = 1000, format = "jpeg" })
expect(#render_calls == decodes_before_split + 1 and reader.position.segment == "right",
    "manga direction should enter a split spread on its right segment")
local split_download_count = #requests
local split_buffer = reader.page_buffer
reader:next_page()
expect(#requests == split_download_count and #render_calls == decodes_before_split + 1
    and reader.page_buffer == split_buffer and reader.position.segment == "left"
    and #split_buffer.viewport_calls == 2,
    "second split segment should reuse download, decode, and owned buffer")
reader:previous_page()
expect(reader.position.segment == "right" and #requests == split_download_count,
    "previous within a split image should reverse viewport without a request")

fail_render_count = 2
reader:request_page(1, "whole")
local corrupt_first = requests[#requests]
corrupt_first.callbacks.on_ready("/cache/corrupt.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })
local corrupt_retry = requests[#requests]
expect(corrupt_retry ~= corrupt_first and removed[#removed]:find("001.jpg", 1, true),
    "first decode failure should evict the corrupt cache entry and retry once")
corrupt_retry.callbacks.on_ready("/cache/corrupt-again.jpg", false,
    { width = 800, height = 1200, format = "jpeg" })
expect(shell.error and shell.error.on_retry and shell.error.on_previous and shell.error.on_next,
    "second decode failure should stay inside the shell with recoverable actions")

-- Adjacent chapter navigation comes from chapters_index, never a sibling array.
reader_settings.split_enabled = false
reader.reader_settings = reader_settings
reader:request_page(3, "whole")
local last_request = requests[#requests]
last_request.callbacks.on_ready("/cache/003.webp", false,
    { width = 800, height = 1200, format = "webp" })
reader:next_page()
expect(ui.confirmation and ui.confirmation.text:find("第2话", 1, true),
    "end of chapter should resolve its neighbor through chapters_index")
ui.confirmation.on_confirm()
expect(events[#events] == "close" and #scheduled >= 1,
    "next chapter transition should close the shell before cleanup")
scheduled[#scheduled]()
expect(opened_next and opened_next.chapter == chapters[2],
    "deferred return callback should open the indexed adjacent chapter")

-- A late callback from the closed session cannot reopen the shell.
local pages_after_close = #pages
last_request.callbacks.on_ready("/cache/late.webp", false,
    { width = 800, height = 1200, format = "webp" })
expect(#pages == pages_after_close, "late page callbacks must not reopen a closed reader")
expect(#protected[#protected] == 0 and #canceled >= 1,
    "deferred exit cleanup should cancel generation and release reader protection")

-- A delayed cleanup from an older session must not leave the state owned by a
-- newer open session.
local generation_state = State:new()
local generation_scheduled = {}
local generation_shell = {
    get_content_size = function() return 600, 800 end,
    show_loading = function() end,
    show_page = function() return true end,
    close_now = function() return true end,
}
local generation_reader = Reader:new{
    loader = {
        identity = "generation",
        request = function() return {} end,
        cancel_generation = function() end,
    },
    progress = {
        chapter_id = function() return "generation-chapter" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function() end,
    },
    state = generation_state,
    settings = {
        get_connection = function() return {} end,
        get_reader = function() return reader_settings end,
        set_reader = function() return true end,
        flush = function() end,
    },
    cache = {
        key_for = function(_self, identity, path) return identity .. "|" .. path end,
        set_protected = function() end,
    },
    ui = {
        create_shell = function() return generation_shell end,
        show_shell = function() end,
        close_shell = function() end,
        schedule = function(_self, callback) generation_scheduled[#generation_scheduled + 1] = callback end,
    },
    open_chapter = function() end,
}
generation_reader:open(context)
generation_reader:force_close("back")
generation_reader:open(context)
local new_generation = generation_reader.generation
expect(#generation_scheduled == 1, "the old session should leave one deferred cleanup")
generation_scheduled[1]()
expect(generation_state:is_current(new_generation),
    "old deferred cleanup must not leave a newer reader generation")

-- Dynamic panels borrow session buffers; every physical transition returns the
-- shell to its retained page before the session may release a panel.
do
    local PanelSession = require("webdavmanga.panel_session")
    local panel_requests, source_requests, sessions, moves = {}, {}, {}, {}
    local shown, status, panel_frees = nil, nil, 0
    local panel_allocations, lifetime_valid = 0, true
    local fail_detection, fail_panel_render = false, false
    local fail_panel_request = false
    local values = {
        direction = "normal", fit_mode = "page", split_enabled = true,
        split_min_ratio = 1.2, split_max_ratio = 2.2, split_cut_percent = 50,
        panel_zoom_enabled = false, panel_standard_margin_percent = 2,
        panel_show_adjacent = true, panel_experimental_sort = true,
    }
    local panel_shell = {
        get_content_size = function() return 600, 800 end,
        show_loading = function() end,
        show_error = function(self, model) self.error = model end,
        show_status = function(_self, message) status = message; return true end,
        show_page = function(_self, buffer) shown = buffer; return true end,
        show_exit_button = function(self) self.exit_visible = true; return true end,
        free_buffer_later = function(_self, buffer) buffer:free(); return true end,
    }
    local source = {
        open = function(_self, generation, request, callbacks)
            source_requests[#source_requests + 1] = { generation = generation,
                request = request, callbacks = callbacks }
            return { cancel = function() end }
        end,
    }
    local detector = {
        detect = function()
            if fail_detection then return nil, "panel_detection_failed" end
            return { { id = "a" }, { id = "b" } }
        end,
        sort = function(panels, direction)
            local a = panels[1].id == "a" and panels[1] or panels[2]
            local b = panels[1].id == "b" and panels[1] or panels[2]
            return direction == "manga" and { b, a } or { a, b }
        end,
    }
    local function complete_source()
        local handle = {
            detection_raster = function() return {} end,
            render = function(_self, panel)
                if fail_panel_render then error("native allocation failed") end
                panel_allocations = panel_allocations + 1
                return { id = panel.id, free = function(buffer)
                    -- Session intentionally contains free() exceptions: record
                    -- violations here and assert outside that protected call.
                    if shown == buffer or buffer.freed then lifetime_valid = false end
                    buffer.freed = true
                    panel_frees = panel_frees + 1
                end }
            end,
            close = function(self) self.closed = true end,
        }
        source_requests[#source_requests].callbacks.on_ready(handle)
    end
    local r = Reader:new{
        loader = { identity = "panels", request = function(_self, generation, image, callbacks)
            panel_requests[#panel_requests + 1] = { image = image, callbacks = callbacks }
            if fail_panel_request then error("boundary request launch failed") end
            return {}
        end },
        progress = progress, state = State:new(), cache = cache, render_image = renderer,
        settings = { get_connection = settings.get_connection,
            get_reader = function() return values end,
            set_reader = function(_self, updated) values = updated; return true end },
        ui = { create_shell = function() return panel_shell end, show_shell = function() end },
        open_chapter = function() end,
        panel_source = source, panel_detector = detector,
        panel_session_factory = function(options)
            expect(options.source == source and options.detector == detector,
                "Reader must pass its injected panel dependencies into the one session")
            local session = PanelSession:new(options)
            local move = session.move
            session.move = function(self, delta)
                moves[#moves + 1] = delta
                return move(self, delta)
            end
            sessions[#sessions + 1] = session
            return session
        end,
    }
    local function complete_page()
        local request = panel_requests[#panel_requests]
        request.callbacks.on_ready("/cache/" .. request.image.name, false,
            { width = 1600, height = 1000, format = "jpeg" })
    end
    r:open(context)
    complete_page()
    r:_display_segment("right", false)
    r.pan_y = 137
    local original, segments = r.page_buffer, r.current_segments
    expect(type(r.onHold) == "function", "Reader must provide Hold entry for dynamic panels")
    expect(r:onHold(nil, tap(300)) == false and #sessions == 0 and #source_requests == 0,
        "disabled Hold must not create a session or open a source")
    r.reader_settings.panel_zoom_enabled = true
    panel_shell.current_model = { kind = "controls" }
    expect(r:onHold(nil, tap(300)) == false and #sessions == 0,
        "Hold on a settings or error layer must not start panel recognition")
    panel_shell.current_model = { kind = "page" }
    expect(r:onHold(nil, tap(300)) == true and #sessions == 1
        and status == "正在识别分格", "Hold must start one session using the small status surface")
    expect(source_requests[1].request.page_buffer == original
        and source_requests[1].request.page_path == "/cache/002.jpg"
        and source_requests[1].generation == r.generation
        and source_requests[1].request.experimental == true
        and source_requests[1].request.margin_percent == 2,
        "panel detection must use the current page, generation and existing settings")
    r:next_page(); r:previous_page()
    expect(#panel_requests == 1 and r.pan_y == 0,
        "recognition-pending navigation must be consumed without physical paging or panning")
    r:set_direction("manga")
    complete_source()
    expect(shown.id == "a" and r.page_buffer == original
        and #r.current_segments == 1 and r.current_segments[1] == "whole",
        "panel mode must borrow the crop buffer while retaining one whole page and pausing split")
    r:previous_page()
    expect(shown.id == "b" and #panel_requests == 1,
        "a direction saved during recognition must be applied before the next panel input")
    r:set_direction("normal"); r:previous_page()
    sessions[1].rendering = true
    r:next_page()
    sessions[1].rendering = false
    expect(#panel_requests == 1 and shown.id == "a",
        "panel_session_busy is consumed and must never fall through to physical navigation")
    r:next_page(); r:previous_page()
    expect(moves[#moves - 1] == 1 and moves[#moves] == -1 and shown.id == "a",
        "hardware handlers must move panels")
    r:onTap(nil, tap(590)); r:onTap(nil, tap(10))
    r:onSwipe(nil, { direction = "west" }); r:onSwipe(nil, { direction = "east" })
    expect(shown.id == "a" and #panel_requests == 1, "edge taps and swipes must stay within panels")
    r:set_direction("manga")
    expect(shown.id == "a" and sessions[1]:current().index == 2,
        "direction changes must preserve the physical panel by stable id")
    local start_moves = #moves
    r.reader_settings.panel_reverse_navigation=true
    r:onTap(nil, tap(590)); r:onTap(nil, tap(10))
    r:onSwipe(nil, { direction = "west" }); r:onSwipe(nil, { direction = "east" })
    expect(moves[start_moves + 1] == -1 and moves[start_moves + 2] == 1
        and moves[start_moves + 3] == -1 and moves[start_moves + 4] == 1
        and shown.id == "a", "explicit navigation reversal reverses edge and swipe once, independently of panel order")
    r:onTap(nil, { ges = "double_tap", pos = { x = 590, y = 10 } })
    expect(panel_shell.exit_visible and r.panel_session == sessions[1],
        "emergency double tap must stay ahead of panel input routing")
    local old_reader_callbacks = sessions[1].callbacks
    r:exit_panel_mode()
    expect(r.panel_session == nil and not sessions[1]:is_active() and shown == original
        and r.position.index == 2 and r.position.segment == "right" and r.pan_y == 137
        and r.current_segments == segments and #panel_requests == 1,
        "explicit panel exit must restore the exact entry state without reloading the retained page")

    r:onHold(nil, tap(300)); complete_source()
    local replacement_session, replacement_buffer = r.panel_session, shown
    old_reader_callbacks.on_panel({}, {}, 1, 1)
    old_reader_callbacks.on_boundary(1)
    old_reader_callbacks.on_fallback("panel_render_failed")
    expect(r.panel_session==replacement_session and shown==replacement_buffer and #panel_requests==1,
        "late Reader callbacks must compare session identity within the same generation")
    local zoom_options
    panel_shell.show_panel_zoom=function(_,options) zoom_options=options; return true end
    r:onHold(nil,tap(300))
    local generation, request_serial = r.generation,r.request_serial
    for _, invalidation in ipairs({"generation","request_serial"}) do
        r[invalidation]=r[invalidation]+1
        status="unchanged"
        replacement_session.callbacks.on_panel({}, {}, 1, 1)
        replacement_session.callbacks.on_boundary(1)
        replacement_session.callbacks.on_fallback("raw stale failure")
        zoom_options.on_close()
        expect(status=="unchanged" and shown==replacement_buffer and r.panel_session==replacement_session
            and #panel_requests==1, "all Reader callbacks, including zoom restore, reject stale "..invalidation)
        r.generation,r.request_serial=generation,request_serial
    end
    fail_panel_render=true
    r:next_page()
    expect(r.panel_session==replacement_session and shown==replacement_buffer and not replacement_buffer.freed,
        "first foreground allocation failure must preserve the visible current panel")
    local show_page = panel_shell.show_page
    panel_shell.show_page=function(self,buffer,...)
        if buffer==original then return false end
        return show_page(self,buffer,...)
    end
    r:next_page()
    expect(r.panel_session==replacement_session and replacement_session:is_active()
        and shown==replacement_buffer and not replacement_buffer.freed and lifetime_valid
        and r.pan_y==0 and #r.current_segments==1,
        "a rejected full-page restore must retain the still-visible panel allocation")
    panel_shell.show_page=show_page
    r:next_page()
    expect(r.panel_session==nil and shown==original and replacement_buffer.freed and lifetime_valid
        and status=="分格显示失败，已返回整页",
        "repeated allocation failure must detach the panel before releasing and returning to the retained page")
    fail_panel_render=false

    r:set_direction("normal")
    fail_detection = true
    r:onHold(nil, tap(300)); complete_source()
    expect(r.panel_session == nil and r.page_buffer == original and not original.freed
        and shown == original and #panel_requests == 1,
        "detection failure must retain the same full-page allocation")
    fail_detection = false
    r:onHold(nil, tap(300)); complete_source()
    r:next_page(); r:next_page()
    expect(shown == original and not sessions[#sessions]:is_active()
        and panel_requests[#panel_requests].image == images[3] and r.panel_resume == "first",
        "last panel must detach before loading the next physical page")
    r:next_page()
    expect(#panel_requests == 2, "input during a physical panel transition must not queue requests")
    complete_page()
    expect(source_requests[#source_requests].request.desired == "first"
        and #r.current_segments == 1 and original.freed,
        "new page must resume at its first panel without retaining the old whole-page buffer")
    complete_source()
    r:previous_page()
    expect(panel_requests[#panel_requests].image == images[2] and r.panel_resume == "last",
        "first panel must load the previous physical page")
    complete_page(); complete_source()
    expect(shown.id == "b", "previous physical page must resume at its last panel")
    r:exit_panel_mode()
    expect(#panel_requests == 4 and panel_requests[4].image == images[2],
        "after replacing the entry buffer, exit must reload its physical page through the normal loader")
    complete_page()
    expect(r.position.index == 2 and r.position.segment == "right" and r.pan_y == 137
        and #r.current_segments == 2 and r.panel_session == nil and panel_frees > 0,
        "cross-page exit must restore split and pan state after the original page is decoded")

    r:onHold(nil, tap(300)); complete_source(); r:next_page(); r:next_page()
    r:exit_panel_mode()
    complete_page()
    expect(panel_requests[#panel_requests].image == images[2] and r.panel_session == nil,
        "exit during an in-flight boundary request must restore the entry page after that request settles")
    complete_page()
    expect(r.position.index == 2 and r.position.segment == "right" and r.pan_y == 137,
        "in-flight exit must restore its entry snapshot exactly")

    -- An abandoned boundary page must not win over the saved exit destination,
    -- even when its decoder would fail every attempt.
    local recovery_segments = r.current_segments
    r:onHold(nil, tap(300)); complete_source(); r:next_page(); r:next_page()
    r:exit_panel_mode()
    local decode_image = renderer.renderImageFile
    local abandoned_decodes = 0
    renderer.renderImageFile = function(self, path, ...)
        if path == "/cache/003.webp" then
            abandoned_decodes = abandoned_decodes + 1
            error("abandoned target cannot decode")
        end
        return decode_image(self, path, ...)
    end
    complete_page()
    if panel_requests[#panel_requests].image == images[3] then complete_page() end
    expect(abandoned_decodes <= 1 and panel_requests[#panel_requests].image == images[2]
        and r.pending_request and r.pending_request.segment == "right",
        "abandoned target decode failure must request entry recovery instead of retrying the target")
    complete_page()
    renderer.renderImageFile = decode_image
    expect(r.position.index == 2 and r.position.segment == "right" and r.pan_y == 137
        and r.current_segments == recovery_segments and r.panel_restore == nil and r.pending_request == nil,
        "decode-failure exit recovery must restore the exact entry snapshot and settle")

    -- All terminal crossing failures leave usable ordinary navigation.
    for _, failure in ipairs({ "transport", "launch", "decode" }) do
        r:onHold(nil, tap(300)); complete_source(); r:next_page()
        fail_panel_request = failure == "launch"
        r:next_page()
        fail_panel_request = false
        if failure == "transport" then
            panel_requests[#panel_requests].callbacks.on_error({ code = "transport" })
        elseif failure == "decode" then
            fail_render_count = 2
            complete_page(); complete_page()
        end
        local failed_request_count = #panel_requests
        expect(r.panel_entry == nil and r.panel_session == nil and r.panel_resume == nil
            and r.panel_restore == nil and r.pending_request == nil,
            "boundary " .. failure .. " failure must end panel mode without a half-active entry")
        r:next_page()
        expect(#panel_requests == failed_request_count + 1 and panel_requests[#panel_requests].image == images[3],
            "next on a failed boundary error page must issue an ordinary physical request")
        complete_page()
        r:previous_page(); r:previous_page()
        expect(#panel_requests == failed_request_count + 2 and panel_requests[#panel_requests].image == images[2],
            "previous navigation after boundary failure must remain available")
        complete_page()
    end

    -- Once entry recovery itself fails, both ordinary directions must be free
    -- to leave that bad page, rather than being redirected there forever.
    for _, failure in ipairs({ "decode", "transport", "launch" }) do
        for _, delta in ipairs({ 1, -1 }) do
            r.pan_y = 137
            r:onHold(nil, tap(300)); complete_source(); r:next_page(); r:next_page()
            r:exit_panel_mode()
            local abandoned = panel_requests[#panel_requests]
            panel_shell.error = nil
            fail_panel_request = failure == "launch"
            abandoned.callbacks.on_error({ code = "transport" })
            fail_panel_request = false
            expect(panel_requests[#panel_requests].image == images[2],
                "abandoned target failure must still attempt entry recovery first")
            if failure == "decode" then
                fail_render_count = 2
                complete_page()
                expect(r.panel_restore and r.panel_restore.index == 2 and r.pending_request ~= nil,
                    "the entry's first decode failure must preserve restoration for its normal retry")
                complete_page()
            elseif failure == "transport" then
                panel_requests[#panel_requests].callbacks.on_error({ code = "transport" })
            end
            expect(r.panel_restore == nil and r.panel_entry == nil and r.panel_resume == nil
                and r.panel_session == nil and r.pending_request == nil
                and panel_shell.error and panel_shell.error.message,
                "entry " .. failure .. " failure must settle restoration before ordinary navigation")
            local requests_before_escape = #panel_requests
            if delta > 0 then r:next_page() else r:previous_page() end
            expect(#panel_requests == requests_before_escape + 1
                and panel_requests[#panel_requests].image == images[2 + delta],
                "ordinary navigation after failed entry recovery must request the chosen healthy page")
            complete_page()
            expect(#panel_requests == requests_before_escape + 1 and r.position.index == 2 + delta
                and r.panel_restore == nil and shown == r.page_buffer,
                "healthy page publication must not be redirected back to the failed entry")
            r:request_page(2, "right"); complete_page()
        end
    end

    r:onHold(nil, tap(300)); complete_source(); r:next_page(); r:next_page()
    fail_render_count = 1
    complete_page()
    expect(r.panel_entry ~= nil and r.panel_resume == "first" and r.pending_request ~= nil,
        "a retryable decode failure must preserve the pending first-panel transition")
    complete_page(); complete_source()
    expect(r.position.index == 3 and r.panel_session:is_active() and shown.id == "a",
        "a successful boundary decode retry must resume panel mode normally")
    r:exit_panel_mode(); complete_page()

    r:onHold(nil, tap(300)); complete_source()
    local cleanup, close_order = {}, {}
    panel_shell.close_now = function()
        close_order[#close_order + 1] = "close"
        shown = nil
        return true
    end
    r.ui.schedule = function(_self, callback) cleanup[#cleanup + 1] = callback end
    local frees_before_close = panel_frees
    local closing_session = r.panel_session
    r:force_close("back"); r:force_close("back")
    expect(#close_order == 1 and #cleanup == 1 and panel_frees == frees_before_close
        and r.panel_session == nil and closing_session:is_active(),
        "real session ownership must outlive shell close until deferred cleanup runs")
    cleanup[1]()
    expect(panel_frees == frees_before_close + 1 and not closing_session:is_active(),
        "deferred cleanup must release the real panel allocation once")
    expect(lifetime_valid and panel_frees == panel_allocations,
        "every allocated panel must be detached before being freed exactly once")
end

-- Every stable panel failure is a small status update, retaining navigation.
do
    local cases = {
        {"leptonica_unavailable", "当前 KOReader 不支持智能分格"},
        {"no_panels", "未识别到有效分格"},
        {"too_many_panels", "未识别到有效分格"},
        {"panel_source_unavailable", "智能分格不可用，已返回整页"},
        {"panel_render_failed", "分格显示失败，已返回整页"},
        {"ffi secret / nas password", "智能分格不可用，已返回整页"},
    }
    for _, case in ipairs(cases) do
        local events, requests, shown, source_callback = {}, {}, nil, nil
        local panel_shell = {
            get_content_size=function() return 600,800 end,
            show_loading=function() end,
            show_page=function(_,buffer) shown=buffer; events[#events+1]={"page"}; return true end,
            show_status=function(_,message) events[#events+1]={"status",message}; return true end,
            show_error=function() events[#events+1]={"error"} end,
            free_buffer_later=function(_,buffer) buffer:free(); return true end,
        }
        local r = Reader:new{
            loader={identity="failure-matrix",request=function(_,generation,image,callbacks)
                requests[#requests+1]={image=image,callbacks=callbacks}; return {}
            end},progress=progress,state=State:new(),cache=cache,render_image=renderer,
            settings={get_connection=settings.get_connection,get_reader=function() return {
                direction="normal",fit_mode="page",split_enabled=true,
                split_min_ratio=1.2,split_max_ratio=2.2,split_cut_percent=50,panel_zoom_enabled=true,
            } end},open_chapter=function() end,
            ui={create_shell=function() return panel_shell end,show_shell=function() end},
            panel_source={open=function(_,generation,request,callbacks) source_callback=callbacks; return {} end},
            panel_detector={detect=function()
                if case[1]=="panel_render_failed" then return {{id="one"}} end
                return nil,case[1]
            end},
        }
        r:open(context)
        requests[1].callbacks.on_ready("/cache/002.jpg",false,{width=1600,height=1000,format="jpeg"})
        r:_display_segment("right",false); r.pan_y=137
        local original, viewport, segments, saves = r.page_buffer,r.page_viewport,r.current_segments,#saved
        events={}
        r:enter_panel_mode()
        if case[1]=="panel_source_unavailable" or case[1]:find("secret",1,true) then
            source_callback.on_error(case[1])
        else
            source_callback.on_ready({detection_raster=function() return {} end,
                render=function() error("raw native allocation failure") end,
                close=function(self) self.closed=true end})
        end
        local missed=case[1]=="no_panels" or case[1]=="too_many_panels"
        expect(events[1][1]=="status" and events[#events][1]=="status"
            and events[#events][2]==case[2] and #events==(missed and 3 or 2),
            case[1].." must show its safe localized status and only restore a page when needed")
        if missed then
            expect(r.panel_session==nil and r.panel_entry~=nil and r.panel_entry.whole_page
                and r.panel_entry.segment=="right" and r.panel_entry.pan_y==137
                and r.page_buffer==original and not original.freed and shown==original
                and r.position.index==2 and r.position.segment=="whole" and r.pan_y==0
                and #r.current_segments==1 and #saved==saves,
                case[1].." retains the exit snapshot while showing this page whole without saving new progress")
        else expect(r.panel_session==nil and r.panel_entry==nil and r.page_buffer==original
            and not original.freed and shown==original and r.page_viewport==viewport
            and r.position.index==2 and r.position.segment=="right" and r.pan_y==137
            and r.current_segments==segments and #saved==saves,
            case[1].." must preserve the exact page, viewport, position and persisted progress")
        end
        r:next_page()
        expect(#requests==2 and requests[2].image==images[3], case[1].." must leave ordinary next_page usable")
        requests[2].callbacks.on_ready("/cache/003.webp",false,{width=1600,height=1000,format="webp"})
        expect(r.position.index==3 and shown==r.page_buffer and #saved==saves+1,
            case[1].." must publish and checkpoint the next ordinary page")
    end
end

print(("reader_ui_spec: %d checks"):format(checks))
