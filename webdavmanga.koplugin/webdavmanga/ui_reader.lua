local Errors = require("webdavmanga.errors")
local AutoCrop = require("webdavmanga.auto_crop")
local GrayEnhance = require("webdavmanga.gray_enhance")
local ImageFormats = require("webdavmanga.image_formats")
local PageProcessor = require("webdavmanga.page_processor")
local PageSequence = require("webdavmanga.page_sequence")
local Quadrant = require("webdavmanga.quadrant_zoom")
local BubbleZoom = require("webdavmanga.bubble_zoom")
local SafeCallback = require("webdavmanga.safe_callback")
local ToneAdjust = require("webdavmanga.tone_adjust")
local ReaderShell = require("webdavmanga.ui_reader_shell")
local OpdsPages = require("webdavmanga.opds_pages")
local Webtoon = require("webdavmanga.webtoon_session")
local Identity = require("webdavmanga.manga_identity")

local Reader = {}
Reader.__index = Reader

local panel_failure_messages = {
    leptonica_unavailable = "当前 KOReader 不支持智能分格",
    no_panels = "未识别到有效分格",
    too_many_panels = "未识别到有效分格",
    panel_engine_unsupported = "无痕引擎不支持智能分格，请切换默认引擎。",
    panel_source_unavailable = "智能分格不可用，已返回整页",
    panel_render_failed = "分格显示失败，已返回整页",
    panel_content_uncovered = "部分内容无法可靠归入分格，已返回整页以保留对白。",
    panel_layout_uncertain = "分格布局不明确，已返回整页。",
}

local function copy_table(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function same_settings(left, right, ignored_key)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    -- Settings reads rebuild nested presets, so table identity is insufficient.
    for key, value in pairs(left) do
        if key ~= ignored_key and not same_settings(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if key ~= ignored_key and left[key] == nil then return false end
    end
    return true
end

local function clamp(value, minimum, maximum)
    local number = math.floor(tonumber(value) or minimum)
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

local function is_prefetchable_page(image)
    if type(image) ~= "table" then return false end
    if ImageFormats.is_image(image.name or image.path) then return true end
    return image.mobi_record ~= nil
        or image.archive_entry_name ~= nil
        or image.pdf_image == true
        or tonumber(image.mupdf_page) ~= nil
        or image.rendered_image == true
end

local function release_buffer(shell, buffer)
    if not buffer or type(buffer.free) ~= "function" then return false end
    if shell and type(shell.free_buffer_later) == "function" then
        local ok, result = pcall(shell.free_buffer_later, shell, buffer)
        if ok and result ~= false then return true end
    end
    local ok = pcall(buffer.free, buffer)
    return ok
end

local function indexed_context(context)
    assert(type(context) == "table", "reader context is required")
    local chapter_index = context.chapter_index
    assert(type(chapter_index) == "table"
        and type(chapter_index.count) == "function"
        and type(chapter_index.get) == "function",
        "chapter index is required")
    assert((tonumber(chapter_index:count()) or 0) > 0, "chapter images are required")
    return {
        connection = context.connection,
        initial_page = context.initial_page,
        resume_local = context.resume_local == true,
        manga = context.manga,
        chapter = context.chapter,
        chapter_index = chapter_index,
        chapters_index = context.chapters_index,
        chapter_position = context.chapter_position,
        open_chapter = context.open_chapter,
        layout = context.layout,
        cover_hint = context.cover_hint,
        source_context = context.source_context,
        stream_state = context.stream_state,
    }
end

function Reader.image_widget_decoded(widget)
    if not widget or type(widget.getSize) ~= "function" then
        return false, "missing image widget"
    end
    local ok, result = pcall(widget.getSize, widget)
    if not ok then return false, result end
    if widget._is_straight_alpha == false then
        return false, "image decoder returned placeholder"
    end
    return result ~= nil, result and nil or "image widget has no size"
end

function Reader.width_scale(view_width, padding, has_chrome, image_width)
    local available = tonumber(view_width) or 0
    if has_chrome then available = available - 2 * (tonumber(padding) or 0) end
    local original = tonumber(image_width) or 0
    if available <= 0 or original <= 0 then return 1 end
    return available / original
end

function Reader.reset_zoom_state(viewer)
    viewer._min_scale_factor = nil
    viewer._max_scale_factor = nil
    viewer._scale_factor_0 = nil
end

function Reader.crop_strength_from_threshold(threshold)
    return AutoCrop.strength_from_threshold(threshold)
end

function Reader.crop_threshold_from_strength(strength)
    return AutoCrop.threshold_from_strength(strength)
end

local function default_ui()
    local UIManager = require("ui/uimanager")
    local adapter = {}

    function adapter:create_shell(owner)
        self.shell = ReaderShell:new{ owner = owner, ui_manager = UIManager }
        return self.shell
    end
    function adapter:show_shell(shell) return shell:show() end
    function adapter:close_shell(shell)
        if self.shell == shell then self.shell = nil end
        if shell then return shell:close_now() end
        return true
    end
    function adapter:schedule(callback) UIManager:scheduleIn(0, callback) end
    function adapter:show_info(message)
        if self.shell then return self.shell:show_error{ message = message } end
    end
    function adapter:show_controls(model)
        if self.shell then return self.shell:show_controls(model) end
    end
    function adapter:show_page_picker(model)
        if self.shell then return self.shell:show_page_picker(model) end
    end
    function adapter:show_number_input(model)
        if self.shell then return self.shell:show_number_input(model) end
    end
    function adapter:confirm(model)
        if self.shell then return self.shell:show_confirmation(model) end
    end
    function adapter:show_stream_recovery(model)
        if self.shell then return self.shell:show_stream_recovery(model) end
    end
    return adapter
end

local function legacy_shell(owner, ui)
    local viewer = ui:create_viewer(owner, {
        file = nil, title = nil, with_title_bar = true, fit_mode = "page",
    })
    local shell = { owner = owner, ui = ui, viewer = viewer, legacy = true }

    function shell:get_content_size()
        return tonumber(self.viewer and self.viewer.width) or 600,
            tonumber(self.viewer and self.viewer.height) or 800
    end
    function shell:show_loading(title)
        if self.loading and self.loading.close then pcall(self.loading.close) end
        if self.ui.show_loading then
            self.loading = self.ui:show_loading{
                message = title,
                on_cancel = function() return self.owner:force_close("loading_cancel") end,
            }
        end
        return true
    end
    function shell:_close_loading()
        if self.loading and self.loading.close then pcall(self.loading.close) end
        self.loading = nil
    end
    function shell:show_page_path(path, index, title, fit_mode)
        self:_close_loading()
        if not self.viewer or type(self.viewer.set_page) ~= "function" then
            return nil, "legacy viewer has no set_page"
        end
        return self.viewer:set_page(path, index, title, fit_mode)
    end
    function shell:show_error(model)
        self:_close_loading()
        if self.ui.show_page_error then
            model.on_back = function() return self.owner:force_close("error_back") end
            self.ui:show_page_error(model)
        elseif self.ui.show_info then
            self.ui:show_info(model.message)
        end
        return true
    end
    function shell:close_now()
        self:_close_loading()
        if self.viewer and self.ui.close_viewer then self.ui:close_viewer(self.viewer) end
        self.viewer = nil
        return true
    end
    function shell:free_buffer_later(buffer)
        if buffer and buffer.free then pcall(buffer.free, buffer) end
    end
    return shell
end

function Reader:new(deps)
    deps = deps or {}
    local object = setmetatable({}, self)
    object.loader = assert(deps.loader, "loader is required")
    object.prepared_pages = deps.prepared_pages
    object.memory_pages = deps.memory_pages
    object.opds_pages = deps.opds_pages
    object.panel_source = deps.panel_source
    object.panel_detector = deps.panel_detector
    object.panel_session_factory = deps.panel_session_factory or function(options)
        return require("webdavmanga.panel_session"):new(options)
    end
    object.page_processor = deps.page_processor or PageProcessor
    object.progress = assert(deps.progress, "progress is required")
    object.state = assert(deps.state, "state is required")
    object.settings = assert(deps.settings, "settings is required")
    object.cache = assert(deps.cache, "cache is required")
    object.ui = deps.ui or default_ui()
    object.error_reporter = deps.error_reporter
    object.open_chapter = assert(deps.open_chapter, "next chapter callback is required")
    object.return_to_root = deps.return_to_root
    object.open_history = deps.open_history
    object.open_category_shelf = deps.open_category_shelf
    object.show_light_settings = deps.show_light_settings
    object.show_network_settings = deps.show_network_settings
    object.show_reader_help = deps.show_reader_help
    object.show_koreader_menu = deps.show_koreader_menu
    object.show_gray_settings = deps.show_gray_settings
    object.show_tone_settings = deps.show_tone_settings
    object.renderer = deps.render_image
    object.gray_enhance = deps.gray_enhance or GrayEnhance
    object.tone_adjust = deps.tone_adjust or ToneAdjust
    object.processing_warnings = {}
    object.context = nil
    object.shell = nil
    object.viewer = nil
    object.viewer_shown = false
    object.generation = nil
    object.request_serial = 0
    object.decode_attempts = {}
    object.page_buffer = nil
    object.page_viewport = nil
    object.page_path = nil
    object.page_metadata = nil
    object.page_dimensions = nil
    object.position = nil
    object.current_index = nil
    object.current_segments = { "whole" }
    object.page_crop = nil
    object.pan_y = 0
    object.closing = false
    object.close_control = nil
    object.pending_request = nil
    object.prepared_cache_keys = {}
    object.return_to = nil
    object.animation_enabled = false
    object.full_refresh_each_page = false
    object.show_progress_bar = true
    object.progress_bar_thickness = 1
    object.session_image_engine = "default"
    return object
end

function Reader:_callback(label, callback, fallback)
    if type(callback) ~= "function" then
        return function() return fallback end
    end
    return SafeCallback.wrap(self.error_reporter or self.ui, label, callback, fallback)
end

function Reader:_silent(stage, callback, fallback)
    if self.error_reporter and type(self.error_reporter.guard) == "function" then
        local ok, result = pcall(self.error_reporter.guard, self.error_reporter,
            stage, callback, fallback, nil, { silent = true })
        if ok then return result end
        return fallback
    end
    local ok, result = pcall(callback)
    if ok then return result end
    return fallback
end

function Reader:_count()
    return math.max(0, math.floor(tonumber(self.context.chapter_index:count()) or 0))
end

function Reader:_stream_progress()
    local state = self.context and self.context.stream_state
    if not state then return nil end
    local available = tonumber(state.available_pages) or self:_count()
    return {
        phase = state.phase,
        complete = state.complete == true,
        available_pages = math.max(0, math.min(self:_count(), math.floor(available))),
        catalog_pages = math.max(0, math.min(self:_count(),
            math.floor(tonumber(state.catalog_pages) or self:_count()))),
        total_pages = state.total_pages,
        error = state.error,
        generation = state.generation,
        warm_target = state.warm_target,
    }
end

local function stream_wait_message(progress, for_jump)
    if progress.phase == "failed" then
        return "页面目录加载失败，已加载的页面仍可阅读"
    end
    if progress.error then return "页面目录加载失败，请退出后重试。" end
    if progress.phase == "warming_20" then
        local message = ("正在预热页面（%d/%d）"):format(
            progress.available_pages, tonumber(progress.warm_target) or 20)
        return for_jump and message .. "，完成后可跳转" or message
    end
    if progress.phase == "indexing" then
        local message = ("页面目录正在建立，已找到 %d 页；可直接阅读前 %d 页"):format(
            progress.catalog_pages, progress.available_pages)
        return for_jump and message .. "，完成后可跳转" or message
    end
    return for_jump and "页面目录正在加载，完成后可跳转" or "正在加载后续页面"
end

function Reader:_wait_for_stream_end()
    local progress = self:_stream_progress()
    if not progress or progress.complete then return false end
    if progress.phase == "failed" then
        return self:_show_stream_recovery()
    end
    local message = stream_wait_message(progress, false)
    if self.ui.show_info then self.ui:show_info(message)
    elseif self.shell and self.shell.show_status then self.shell:show_status(message) end
    return true
end

function Reader:_show_stream_recovery()
    local state = self.context and self.context.stream_state
    if not state or state.phase ~= "failed" then return false end
    local model = {
        text = "页面目录加载失败，已加载的页面仍可阅读。",
        on_retry = type(state.retry) == "function" and self:_callback("retry stream index", function()
            local started = type(state.retry) == "function" and state.retry() or false
            if started and self.position then
                self:request_page(self.position.index, self.position.segment)
            elseif not started and state.retry_pending == true then
                local message = "上次流式任务正在收尾，请稍后重试。"
                if self.ui and self.ui.show_info then self.ui:show_info(message)
                elseif self.shell and self.shell.show_status then self.shell:show_status(message) end
            end
            return started
        end, false) or nil,
        on_download = type(state.complete_download) == "function"
            and self:_callback("confirm complete download", function()
            return type(state.complete_download) == "function"
                and state.complete_download() or false
        end, false) or nil,
        on_return = self:_callback("return from failed stream", function()
            return self:force_close("stream_failed_return")
        end, false),
    }
    if self.ui and type(self.ui.show_stream_recovery) == "function" then
        self.ui:show_stream_recovery(model)
    elseif self.shell and type(self.shell.show_stream_recovery) == "function" then
        self.shell:show_stream_recovery(model)
    elseif self.ui and type(self.ui.show_info) == "function" then
        self.ui:show_info(model.text)
    end
    return true
end

function Reader:_image(index)
    return self.context.chapter_index:get(index)
end

function Reader:_title(index, segment)
    -- Page numbers are no longer painted in the reader title bar. Keep this
    -- helper for legacy shell call sites, which now receive an empty title.
    return nil
end

function Reader:_progress(index, segment)
    local total = self:_count()
    if total <= 0 then return 0 end
    local segments = self.current_segments or { "whole" }
    local segment_index = 1
    for position, value in ipairs(segments) do
        if value == segment then
            segment_index = position
            break
        end
    end
    local fraction = (index - 1 + segment_index / math.max(1, #segments)) / total
    return math.max(0, math.min(1, fraction))
end

function Reader:_cache_key(image)
    return self.cache:key_for(self.loader.identity, image.path)
end

function Reader:_processing_enabled()
    local settings = self.reader_settings or {}
    return settings.gray_enhance_enabled == true
        or settings.tone_adjust_enabled == true
        or settings.auto_crop_enabled == true
end

function Reader:_preprocess_notice_enabled()
    local settings = self.reader_settings or {}
    return settings.show_preprocess_success ~= false
        and (settings.gray_enhance_enabled == true or settings.tone_adjust_enabled == true)
end

function Reader:_arm_preprocess_notice(index)
    self.preprocess_notice_paths = {}
    if not self:_preprocess_notice_enabled() then
        return
    end
    local total = self:_count()
    local start = math.max(1, math.floor(tonumber(index) or 1) + 1)
    local finish = math.min(total, start + 4)
    for position = start, finish do
        local image = self:_image(position)
        if image and is_prefetchable_page(image) then
            self.preprocess_notice_paths[image.path] = true
        end
    end
end

function Reader:_note_preprocess_success(image, metadata)
    if not self:_preprocess_notice_enabled() or not image or type(metadata) ~= "table"
        or (metadata.prepared ~= true and metadata.memory_processed ~= true)
        or metadata.processing_error
        or not self.preprocess_notice_paths
        or not self.preprocess_notice_paths[image.path] then
        return
    end
    self.preprocess_notice_paths[image.path] = nil
    if self.shell and type(self.shell.show_status) == "function" then
        self.shell:show_status("处理图像成功", 3)
    end
end

function Reader:_processing_profile(image)
    if not self:_processing_enabled() or not self.shell then return nil end
    local width, height = self.shell:get_content_size()
    return self.page_processor.profile(self.reader_settings, image, width, height)
end

function Reader:_memory_processor(image)
    if not self:_processing_enabled()
        or not self.page_processor
        or type(self.page_processor.profile) ~= "function"
        or type(self.page_processor.process_buffer) ~= "function" then
        return nil
    end
    return function(buffer, metadata, source_image)
        local candidate = copy_table(source_image or image)
        candidate.width = metadata and metadata.width or candidate.width
        candidate.height = metadata and metadata.height or candidate.height
        local profile = self:_processing_profile(candidate)
        if not profile then return buffer, {} end
        return self.page_processor.process_buffer(buffer, profile, {
            gray_enhance = self.gray_enhance,
            auto_crop = AutoCrop,
        })
    end
end

function Reader:_prefetch_radius(index)
    if self.loader and type(self.loader.prefetch_count_for) == "function" then
        return math.max(0, math.floor(tonumber(
            self.loader:prefetch_count_for(index)) or 0))
    end
    local near = tonumber(self.reader_settings.prefetch_near_count)
    local far = tonumber(self.reader_settings.prefetch_far_count)
    if near == nil and far == nil then
        near = tonumber(self.reader_settings.prefetch_count) or 0
        far = near
    end
    near = near or 0
    far = far == nil and near or far
    local first_pages = tonumber(self.reader_settings.prefetch_first_pages) or 10
    local radius = tonumber(index) <= first_pages and near or far
    return math.max(0, math.floor(tonumber(radius) or 0))
end

function Reader:_manifest_keys()
    local source = self.context and self.context.source_context or nil
    local result, seen = {}, {}
    local function add(key)
        if type(key) == "string" and key ~= "" and not seen[key] then
            seen[key] = true
            result[#result + 1] = key
        end
    end
    for _, key in ipairs(source and source.manifest_keys or {}) do add(key) end
    add(source and source.chapter_manifest_key)
    add(source and source.chapters_manifest_key)
    add(source and source.chapter_directory and source.chapter_directory.key)
    add(source and source.chapters_directory and source.chapters_directory.key)
    return result
end

function Reader:_protect(index)
    local keys = self:_manifest_keys()
    local retained_prepared = {}
    local last = math.min(self:_count(), index + math.max(1, self:_prefetch_radius(index)))
    for position = math.max(1, index - 1), last do
        local image = self:_image(position)
        if image then
            keys[#keys + 1] = self:_cache_key(image)
            local prepared_key = self.prepared_cache_keys[image.path]
            local profile = self:_processing_profile(image)
            if profile and self.prepared_pages
                and type(self.prepared_pages.cache_key) == "function" then
                prepared_key = self.prepared_pages:cache_key(image, profile)
            end
            if prepared_key then
                keys[#keys + 1] = prepared_key
                retained_prepared[image.path] = prepared_key
            end
        end
    end
    self.prepared_cache_keys = retained_prepared
    self:_silent("protect_reader_cache", function()
        return self.cache:set_protected(keys)
    end)
end

function Reader:_bind_stream_index_growth()
    local context = self.context
    local stream_state = context and context.stream_state
    if not stream_state or not tonumber(stream_state.warm_target) then return end
    local generation = self.generation
    local stream_generation = stream_state.generation
    local known_count = self:_count()
    local callback = function(reported_generation)
        if self.closing or self.context ~= context
            or self.generation ~= generation
            or not self.state:is_current(generation)
            or reported_generation ~= stream_generation
            or stream_state.generation ~= stream_generation then return end
        local available = self:_count()
        if available <= known_count then return end
        local first_new = known_count + 1
        known_count = available
        local last_new = math.min(available,
            math.max(1, math.floor(tonumber(stream_state.warm_target) or 1)))
        if first_new <= last_new then
            self:_prefetch(1, { first = first_new, last = last_new })
        end
    end
    stream_state.on_index_growth = callback
    self.stream_index_growth_callback = callback
end

function Reader:_mark_stream_page_ready(position, reader_generation)
    if self.closing or self.generation ~= reader_generation
        or not self.state:is_current(reader_generation) then return false end
    local state = self.context and self.context.stream_state
    if not state or type(state.mark_ready) ~= "function" then return false end
    return state.mark_ready(position, state.generation) == true
end

function Reader:_stream_page_result_ready(metadata)
    return not (type(metadata) == "table" and metadata.processing_error)
end

function Reader:_prefetch(index, stream_range)
    if self.closing or not self.context or not self.reader_settings
        or not self.state:is_current(self.generation) then return end
    -- Document bridges expose rendered pages through the same Loader queue;
    -- only non-page resources (directory entries and unsupported documents)
    -- are excluded here.
    local current_image = self:_image(index)
    if not is_prefetchable_page(current_image) then
        return
    end
    local radius = self:_prefetch_radius(index)
    local stream_state = self.context.stream_state
    local transient_count
    if stream_range then
        transient_count = math.max(0,
            math.floor(tonumber(stream_range.last) or 0)
                - math.floor(tonumber(stream_range.first) or 1) + 1)
        radius = transient_count
    elseif index == 1 and stream_state and tonumber(stream_state.warm_target) then
        local warm_target = math.max(1, math.floor(tonumber(stream_state.warm_target)))
        transient_count = warm_target - 1
        radius = transient_count
    end
    local memory_source = self:_page_source(current_image)
    if memory_source then
        local future = {}
        if self.reader_settings.image_prefetch_enabled ~= false then
            local first = stream_range and stream_range.first or index + 1
            local last = stream_range and stream_range.last
                or math.min(self:_count(), index + math.min(5, radius))
            for position = first, math.min(self:_count(), last) do
                future[#future + 1] = self:_image(position)
            end
        end
        return self:_silent("prefetch_memory_pages", function()
            return memory_source:prefetch(self.generation, future,
                function(image, metadata) return self:_memory_target(image, metadata) end,
                self:_memory_processor(current_image))
        end)
    end
    if self.reader_settings.image_prefetch_enabled == false then return end
    if radius == 0 or type(self.context.chapter_index.window) ~= "function" then return end
    local window
    if stream_range then
        window = { current_image }
        for position = stream_range.first, stream_range.last do
            window[#window + 1] = self:_image(position)
        end
        window.first_index = index
    else
        window = self.context.chapter_index:window(index, radius)
    end
    if type(window) ~= "table" then return end
    window.first_index = window.first_index or math.max(1, index - radius)
    self:_silent("prefetch_reader_pages", function()
        local generation, context = self.generation, self.context
        local function current()
            return not self.closing and self.context == context
                and self.generation == generation
                and self.state:is_current(generation)
        end
        local function mark_ready(image)
            if not current() or not image
                or type(context.chapter_index.find) ~= "function" then return false end
            local position = context.chapter_index:find(image.path)
            return position and self:_mark_stream_page_ready(position, generation) or false
        end
        local stream_on_ready
        if stream_state and type(stream_state.mark_ready) == "function" then
            stream_on_ready = function(image) mark_ready(image) end
        end
        if not self:_processing_enabled() or not self.prepared_pages then
            return self.loader:prefetch(self.generation, window, index,
                stream_on_ready,
                transient_count, transient_count ~= nil)
        end
        return self.prepared_pages:prefetch(self.generation, window, index,
            function(image) return self:_processing_profile(image) end,
            function(image, profile)
                if not current() or self.current_index ~= index then return end
                self.prepared_cache_keys[image.path]
                    = self.prepared_pages:cache_key(image, profile)
                self:_protect(index)
            end,
            function(image, _path, _cached, metadata)
                if current() then
                    if stream_on_ready and self:_stream_page_result_ready(metadata) then
                        mark_ready(image)
                    end
                    self:_note_preprocess_success(image, metadata)
                end
            end, transient_count, transient_count ~= nil)
    end)
end

function Reader:_active(serial, generation)
    return not self.closing and self.context ~= nil and self.shell ~= nil
        and serial == self.request_serial and generation == self.generation
        and self.state:is_current(generation)
end

function Reader:_renderer()
    if self.renderer then return self.renderer end
    local ok, renderer = pcall(require, "ui/renderimage")
    if ok then self.renderer = renderer end
    return self.renderer
end

local function buffer_size(buffer, fallback_width, fallback_height)
    local width = type(buffer.getWidth) == "function" and buffer:getWidth() or buffer.w
    local height = type(buffer.getHeight) == "function" and buffer:getHeight() or buffer.h
    return math.max(1, math.floor(tonumber(width) or fallback_width or 1)),
        math.max(1, math.floor(tonumber(height) or fallback_height or 1))
end

function Reader:_target_size(width, height, segments)
    local content_w, content_h = self.shell:get_content_size()
    if self.fit_mode == "webtoon" then
        return self.page_processor.target_size(width, height, self.reader_settings, content_w, content_h)
    end
    content_w = math.max(1, tonumber(content_w) or 600)
    content_h = math.max(1, tonumber(content_h) or 800)
    local split = #segments == 2
    local scale
    if split then
        local cut = (tonumber(self.reader_settings.split_cut_percent) or 50) / 100
        local left_w, right_w = width * cut, width * (1 - cut)
        scale = math.min(content_w / math.max(left_w, right_w), content_h / height)
    elseif self.fit_mode == "width" then
        scale = content_w / width
    else
        scale = math.min(content_w / width, content_h / height)
    end
    return math.max(1, math.floor(width * scale)),
        math.max(1, math.floor(height * scale))
end

function Reader:_segments(width, height)
    if self.fit_mode == "webtoon" then return { "whole" } end
    if self.panel_entry then return { "whole" } end
    return PageSequence.segments(width, height, self.reader_settings)
end

function Reader:_memory_eligible(image)
    if image and image.opds_page == true then
        return self.opds_pages ~= nil
            and type(self.opds_pages.eligible) == "function"
            and self.opds_pages:eligible(image) == true
    end
    if self.session_image_engine ~= "memory" or not self.memory_pages
        or type(self.memory_pages.eligible) ~= "function" then return false end
    local connection = self.settings:get_connection()
    return self.memory_pages.eligible(image, connection and connection.kind) == true
end

function Reader:_page_source(image)
    if image and image.opds_page == true and self.opds_pages then
        return self.opds_pages
    end
    if self:_memory_eligible(image) then return self.memory_pages end
    return nil
end

function Reader:_memory_target(image, metadata)
    local width = tonumber(metadata and metadata.width or image and image.width)
    local height = tonumber(metadata and metadata.height or image and image.height)
    if not width or not height or width <= 0 or height <= 0 then
        width, height = self.shell:get_content_size()
    end
    width = math.max(1, math.floor(tonumber(width) or 600))
    height = math.max(1, math.floor(tonumber(height) or 800))
    return self:_target_size(width, height,
        self:_segments(width, height))
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then return true end
    end
    return false
end

local function segment_position(segments, value)
    for index, segment in ipairs(segments or {}) do
        if segment == value then return index end
    end
    return nil
end

function Reader:_page_change(previous_index, next_index, previous_segment, next_segment,
    previous_segments, next_segments)
    local physical_change = previous_index ~= nil and previous_index ~= next_index
    local segment_change = previous_index ~= nil and previous_index == next_index
        and previous_segment ~= next_segment
    local logical_change = physical_change or segment_change
    local forward
    if physical_change then
        forward = next_index > previous_index
    elseif segment_change then
        local previous_position = segment_position(previous_segments, previous_segment)
        local next_position = segment_position(next_segments, next_segment)
        forward = previous_position ~= nil and next_position ~= nil
            and next_position > previous_position
    else
        forward = true
    end
    if self.direction == "manga" then forward = not forward end
    local new_physical_image = previous_index == nil or physical_change
    return {
        animate = logical_change and self.animation_enabled
            and self.shell.supports_animation == true
            and not self.full_refresh_each_page,
        forward = forward,
        refresh_type = new_physical_image and self.full_refresh_each_page
            and "full" or "partial",
    }
end

function Reader:_select_segment(wanted, segments)
    if wanted == "__last" then return segments[#segments] end
    if contains(segments, wanted) then return wanted end
    return segments[1] or "whole"
end

function Reader:_viewport(segment)
    local buffer = self.page_buffer
    local crop = self.page_crop
    if crop and type(buffer.viewport) == "function" then
        buffer = buffer:viewport(crop.x, crop.y, crop.w, crop.h)
    end
    local width, height = buffer_size(buffer)
    if self.quadrant_zoom and not self.panel_entry and not self.panel_session then
        local box = Quadrant.viewport(width, height, self.quadrant_zoom)
        if not box or type(buffer.viewport) ~= "function" then return nil, "missing quadrant viewport" end
        return buffer:viewport(box.x, box.y, box.w, box.h)
    end
    if segment == "left" or segment == "right" then
        local box = PageSequence.viewport(width, height, segment,
            self.reader_settings.split_cut_percent)
        if type(buffer.viewport) ~= "function" then return nil, "missing viewport support" end
        return buffer:viewport(box.x, box.y, box.w, box.h)
    end
    if self.panel_entry and self.panel_entry.whole_page then return buffer end
    if self.fit_mode == "width" then
        local _content_w, content_h = self.shell:get_content_size()
        content_h = math.max(1, math.floor(tonumber(content_h) or height))
        if height > content_h and type(buffer.viewport) == "function" then
            local y = math.max(0, math.min(self.pan_y, height - content_h))
            return buffer:viewport(0, y, width, math.min(content_h, height - y))
        end
    end
    return buffer
end

function Reader:_detect_crop(buffer, metadata)
    -- Disk preparation may apply only gray/tone processing. Crop once when
    -- publishing its decoded buffer; segment/page input reuses page_crop.
    if type(metadata) == "table" and (metadata.crop_checked == true
        or (metadata.crop_checked == nil and (metadata.crop_processed == true or metadata.crop ~= nil))) then
        return metadata.crop
    end
    if not self.reader_settings or self.reader_settings.auto_crop_enabled ~= true then
        return nil
    end
    return self:_silent("detect_reader_crop", function()
        return AutoCrop.detect(buffer, {
            threshold = self.reader_settings.auto_crop_threshold,
            max_percent = self.reader_settings.auto_crop_max_percent,
        })
    end)
end

function Reader:_checkpoint(index, segment, image)
    local progress = self:_stream_progress()
    if progress and not progress.complete then return true end
    self:_silent("checkpoint_reader_progress", function()
        local connection = self.context and self.context.connection
            or self.settings:get_connection()
        return self.progress:save(self.chapter_id, image.path, index, segment, {
            connection = connection,
            manga = self.context.manga,
            chapter = self.context.chapter,
            total = self:_count(),
            layout = self.context.layout,
            cover_hint = self.context.cover_hint,
            source_context = self.context.source_context,
            vertical_fraction = self.fit_mode == "webtoon" and self.webtoon_fraction or nil,
        })
    end)
    local source = self.context and self.context.source_context
    if source and type(source.on_page) == "function" then
        self:_silent("update_source_page_state", function()
            return source.on_page(index, self:_count())
        end)
    end
end

function Reader:_display_segment(segment, checkpoint, page_change)
    if self.closing or not self.page_buffer or not self.position then return false end
    local viewport, viewport_error = self:_silent("select_reader_viewport", function()
        return self:_viewport(segment)
    end)
    if not viewport then return false, viewport_error end
    page_change = copy_table(page_change)
    page_change.reader_generation = self.generation
    local fit_whole_page = self.panel_entry and self.panel_entry.whole_page
    page_change.display_scale = (fit_whole_page or (self.quadrant_zoom and not self.panel_entry
        and not self.panel_session)) and 0 or 1
    local background = self.reader_settings.display_background or "white"
    page_change.background = background == "auto"
        and (self.page_metadata and self.page_metadata.background or Webtoon.background(viewport))
        or background
    local shown = self:_silent("show_reader_page", function()
        return self.shell:show_page(self.page_buffer, viewport,
            self:_title(self.position.index, segment), page_change,
            self:_progress(self.position.index, segment), self.show_progress_bar,
            self.progress_bar_thickness)
    end, false)
    if shown == false then return false end
    self.position.segment = segment
    self.page_viewport = viewport
    self.current_index = self.position.index
    local image = self:_image(self.position.index)
    if not self.first_page_displayed then
        self.first_page_displayed = true
        local source = self.context and self.context.source_context
        if source and type(source.on_first_page) == "function" then
            self:_silent("first_page_displayed", source.on_first_page)
        end
    end
    if checkpoint and image then self:_checkpoint(self.position.index, segment, image) end
    return true
end

function Reader:_publish_buffer(next_buffer, page_path, index, wanted_segment,
        serial, generation, metadata)
    if not self:_active(serial, generation) then
        release_buffer(self.shell, next_buffer)
        return
    end
    local restore = self.panel_restore
    if restore and restore.index ~= index then
        release_buffer(self.shell, next_buffer)
        return self:request_page(restore.index, restore.segment)
    end
    metadata = metadata or {}
    local image = self:_image(index)
    if not image then release_buffer(self.shell, next_buffer); return end
    local width = tonumber(metadata.width or image.width)
    local height = tonumber(metadata.height or image.height)
    local dimensions_unverified = not width or not height or width <= 0 or height <= 0
    if dimensions_unverified then
        width, height = buffer_size(next_buffer)
    end
    local initial_segments = self:_segments(width, height)
    local decoded_width, decoded_height = buffer_size(next_buffer, width, height)
    local crop = self:_detect_crop(next_buffer, metadata)
    local effective_width = crop and crop.width or decoded_width
    local effective_height = crop and crop.height or decoded_height
    local segments = not dimensions_unverified and #initial_segments > 1
        and initial_segments
        or self:_segments(effective_width, effective_height)
    if restore then segments = restore.current_segments end
    local segment = self:_select_segment(restore and restore.segment or wanted_segment, segments)
    local previous_buffer = self.page_buffer
    local previous_crop = self.page_crop
    local previous_dimensions = self.page_dimensions
    local previous_path = self.page_path
    local previous_metadata = self.page_metadata
    local previous_segments = self.current_segments
    local previous_position = self.position
    local previous_pan_y = self.pan_y
    local previous_current_index = self.current_index
    local previous_index = self.position and self.position.index
    self.page_buffer = next_buffer
    self.page_crop = crop
    self.page_path = page_path or image.path
    self.page_metadata = metadata
    self.page_dimensions = { width = effective_width, height = effective_height }
    self.current_segments = segments
    self.position = { index = index, segment = segment }
    self.pan_y = restore and restore.pan_y or 0
    local previous_segment = previous_position and previous_position.segment
    local page_change = self:_page_change(previous_index, index,
        previous_segment, segment, previous_segments, segments)
    local displayed = self:_display_segment(segment, true, page_change)
    if not displayed then
        self.page_buffer = previous_buffer
        self.page_crop = previous_crop
        self.page_dimensions = previous_dimensions
        self.page_path = previous_path
        self.page_metadata = previous_metadata
        self.current_segments = previous_segments
        self.position = previous_position
        self.pan_y = previous_pan_y
        self.current_index = previous_current_index
        release_buffer(self.shell, next_buffer)
        return self:_decode_failed(index, "page widget rejected decoded buffer")
    end
    if previous_buffer and previous_buffer ~= next_buffer then
        release_buffer(self.shell, previous_buffer)
    end
    self.decode_attempts[image.path] = nil
    self:_protect(index)
    self:_prefetch(index)
    self.panel_restore = nil
    local resume = self.panel_resume
    self.panel_resume = nil
    if resume then self:enter_panel_mode(resume) end
end

function Reader:_render_memory_ready(buffer, index, wanted_segment, serial,
        generation, metadata)
    local image = self:_image(index)
    if image then self:_note_preprocess_success(image, metadata) end
    return self:_publish_buffer(buffer, nil, index, wanted_segment,
        serial, generation, metadata)
end

function Reader:_decode_page_path(path, image, metadata)
    local width = tonumber(metadata.width or image.width)
    local height = tonumber(metadata.height or image.height)
    -- Direct local sources may intentionally skip the lightweight header
    -- probe when it cannot recognize a decoder-valid variant.  Render at a
    -- bounded screen-sized target in that case, then use the native decoded
    -- buffer dimensions below for page splitting and viewport calculations.
    local dimensions_unverified = not width or not height
        or width <= 0 or height <= 0
    if dimensions_unverified then
        local content_w, content_h = self.shell:get_content_size()
        width = math.max(1, math.floor(tonumber(content_w) or 600))
        height = math.max(1, math.floor(tonumber(content_h) or 800))
    end
    local initial_segments = self:_segments(width, height)
    local target_w, target_h
    if metadata.prepared == true then target_w, target_h = width, height
    else target_w, target_h = self:_target_size(width, height, initial_segments) end
    local renderer = self:_renderer()
    if not renderer or type(renderer.renderImageFile) ~= "function" then
        return nil, "image renderer unavailable"
    end
    local ok, next_buffer = pcall(renderer.renderImageFile, renderer,
        path, false, target_w, target_h)
    if not ok or not next_buffer then
        return nil, ok and "empty decoded buffer" or next_buffer
    end

    return next_buffer
end

function Reader:_render_ready(path, index, wanted_segment, serial, generation, metadata)
    if not self:_active(serial, generation) then return end
    metadata = metadata or {}
    local processing_error = metadata.processing_error
    if processing_error and not self.processing_warnings[processing_error] then
        self.processing_warnings[processing_error] = true
        self:_silent("prepared_page_fallback", function()
            if self.ui and self.ui.show_info then
                self.ui:show_info("图像预处理失败，已显示原图。\n错误代码："
                    .. tostring(processing_error))
            end
        end)
    end
    local image = self:_image(index)
    if not image then return end
    if metadata.prepared == true and metadata.prepared_key then
        self.prepared_cache_keys[image.path] = metadata.prepared_key
    end

    if self.shell.legacy then
        local rendered, render_error = self:_silent("decode_reader_page", function()
            return self.shell:show_page_path(path, index, self:_title(index, "whole"), self.fit_mode)
        end)
        if not rendered then return self:_decode_failed(index, render_error) end
        self.decode_attempts[image.path] = nil
        self.position = { index = index, segment = "whole" }
        self.page_viewport = nil
        self.current_segments = { "whole" }
        self.current_index = index
        self.viewer_shown = true
        self:_protect(index)
        self:_prefetch(index)
        self:_checkpoint(index, "whole", image)
        return
    end

    local next_buffer, decode_error = self:_decode_page_path(path, image, metadata)
    if not next_buffer then return self:_decode_failed(index, decode_error) end

    return self:_publish_buffer(next_buffer, path, index, wanted_segment,
        serial, generation, metadata)
end

function Reader:_finish_panel_transition()
    if self.panel_resume or self.panel_restore then
        self.panel_entry, self.panel_resume, self.panel_restore, self.pending_request = nil, nil, nil, nil
    end
end

function Reader:_decode_failed(index, _detail)
    if self.closing or not self.context or not self.state:is_current(self.generation) then return end
    if self.panel_restore and self.panel_restore.index ~= index then
        return self:request_page(self.panel_restore.index, self.panel_restore.segment)
    end
    local image = self:_image(index)
    if not image then return end
    local attempts = (self.decode_attempts[image.path] or 0) + 1
    self.decode_attempts[image.path] = attempts
    self:_silent("evict_corrupt_reader_page", function()
        if self.cache.remove then return self.cache:remove(self:_cache_key(image)) end
    end)
    if attempts == 1 then
        self:request_page(index, self.position and self.position.segment or "whole")
        return
    end
    self:_finish_panel_transition()
    self:_silent("show decode error", function()
        self.shell:show_error{
            message = "图片无法解码或文件已损坏。",
            on_retry = self:_callback("retry decode", function()
                self.decode_attempts[image.path] = nil
                return self:request_page(index, "whole")
            end, false),
            on_previous = self:_callback("previous after decode error", function()
                return self:request_page(math.max(1, index - 1), "__last")
            end, false),
            on_next = self:_callback("next after decode error", function()
                return self:request_page(math.min(self:_count(), index + 1), "whole")
            end, false),
        }
    end)
end

function Reader:_new_shell()
    if type(self.ui.create_shell) == "function" then
        return self.ui:create_shell(self)
    end
    if type(self.ui.create_viewer) == "function" then
        return legacy_shell(self, self.ui)
    end
    return ReaderShell:new{ owner = self }
end

function Reader:_show_shell(shell)
    if type(self.ui.show_shell) == "function" then
        local ok, result = pcall(self.ui.show_shell, self.ui, shell)
        if not ok or result == false then return false end
        return true
    end
    if shell.legacy and type(self.ui.show_viewer) == "function" then
        local ok, result = pcall(self.ui.show_viewer, self.ui, shell.viewer)
        if not ok or result == false then return false end
        return true
    end
    local ok, result = pcall(shell.show, shell)
    if not ok or result == false then return false end
    return true
end

function Reader:open(context)
    self.processing_warnings = {}
    if self.context and not self.closing then self:force_close("reopen") end
    self:_reset_quadrant_zoom("open")
    self.closing = false
    self.first_page_displayed = false
    self.context = indexed_context(context)
    local navigation = self.context.source_context and self.context.source_context.navigation
    local series_key = navigation and navigation.series_key
    if self.navigation_series_key ~= series_key then self.auto_next_series = false end
    self.navigation_series_key = series_key
    self.decode_attempts = {}
    self.prepared_cache_keys = {}
    self.request_serial = 0
    self.page_buffer = nil
    self.page_crop = nil
    self.page_dimensions = nil
    self.page_viewport = nil
    self.page_path = nil
    self.page_metadata = nil
    self.position = nil
    self.current_index = nil
    self.current_segments = { "whole" }
    self.pan_y = 0
    self.panel_session, self.panel_entry, self.panel_resume, self.panel_restore = nil, nil, nil, nil
    self.reader_settings = copy_table(self.settings:get_reader())
    self.session_image_engine = self.reader_settings.image_engine == "memory"
        and "memory" or "default"
    self.animation_enabled = self.reader_settings.animation_enabled == true
    self.full_refresh_each_page = self.reader_settings.full_refresh_each_page == true
    self.direction = self.reader_settings.direction or "normal"
    self.fit_mode = self.reader_settings.fit_mode or "page"
    self.show_progress_bar = self.reader_settings.show_progress_bar ~= false
    self.progress_bar_thickness = clamp(
        tonumber(self.reader_settings.progress_bar_thickness) or 1, 1, 4)
    self.show_preprocess_success = self.reader_settings.show_preprocess_success ~= false
    self.preprocess_notice_paths = {}
    self.generation = self.state:begin_chapter(self.context)
    local context_connection = self.context.connection or self.settings:get_connection()
    self.chapter_id = self.progress:chapter_id(
        context_connection, self.context.manga, self.context.chapter)
    self.panel_book_key=nil
    if type(self.progress.md5)=="function" then
        local manga=self.context.manga or {}
        local identity=Identity.manga(context_connection,manga.path or "")
        if manga.source_id and manga.series_id then
            identity=table.concat({"opds-panel-book",tostring(manga.source_id),tostring(manga.series_id)},"\0")
        end
        local ok,key=pcall(self.progress.md5,identity)
        if ok and type(key)=="string" and #key==32 and key:match("^%x+$") then self.panel_book_key=key:lower() end
    end
    if self.panel_book_key and self.settings.get_panel_reader then
        self.reader_settings=copy_table(self.settings:get_panel_reader(self.panel_book_key))
    end
    local resolved = self.progress:resolve(self.chapter_id, self.context.chapter_index,
        { whole = true, left = true, right = true })
    if type(resolved) == "number" then
        resolved = { index = resolved, segment = "whole" }
    end
    resolved = resolved or { index = 1, segment = "whole" }
    if tonumber(self.context.initial_page) then
        local target = clamp(math.floor(self.context.initial_page), 1, self:_count())
        resolved = { index = target, segment = "whole", vertical_fraction =
            self.context.resume_local == true and resolved.index == target and resolved.vertical_fraction or nil }
    end
    self:_arm_preprocess_notice(resolved.index)
    self.return_to = self.context.source_context and self.context.source_context.on_return or nil
    local shell_ok, shell_or_error = pcall(self._new_shell, self)
    if not shell_ok or not shell_or_error then
        if self.state and type(self.state.leave_chapter) == "function" then
            pcall(self.state.leave_chapter, self.state)
        end
        self.context = nil
        self.generation = nil
        return false
    end
    self.shell = shell_or_error
    self.viewer = self.shell.viewer
    local shown = self:_show_shell(self.shell)
    if not shown then
        self:force_close("open_failed")
        return false
    end
    self.viewer_shown = true
    self:_bind_stream_index_growth()
    self.webtoon_resume_fraction = resolved.vertical_fraction
    if not self:request_page(resolved.index, resolved.segment) then
        self:force_close("open_failed")
        return false
    end
    return true
end

-- Ordinary and strip modes share the existing foreground loading contract.
function Reader:_request_page_data(image, generation, callbacks, memory_source)
    local use_memory = memory_source ~= nil
    local profile_provider
    if not use_memory and self:_processing_enabled() then
        profile_provider = self:_processing_profile(image)
        if not profile_provider then
            profile_provider = function(ready_image)
                return self:_processing_profile(ready_image)
            end
        end
    end
    local ok, job_or_error
    if use_memory then
        ok, job_or_error = pcall(memory_source.request, memory_source,
            generation, image,
            function(ready_image, metadata)
                return self:_memory_target(ready_image, metadata)
            end, callbacks, self:_memory_processor(image))
    elseif self.prepared_pages then
        ok, job_or_error = pcall(self.prepared_pages.request, self.prepared_pages,
            generation, image, profile_provider, callbacks)
    else
        ok, job_or_error = pcall(self.loader.request, self.loader,
            generation, image, callbacks)
    end
    if not ok then
        callbacks.on_error({ code = "transport", detail = job_or_error })
        return false
    end
    return true
end

function Reader:_close_webtoon()
    local session = self.webtoon_session
    self.webtoon_session = nil
    if session then session:close() end
    self.webtoon_fraction = nil
    self.webtoon_resume_fraction = nil
    self.webtoon_request = nil
end

function Reader:_publish_webtoon(frame, point, metadata)
    local previous = {}
    local keys = {"page_buffer", "page_crop", "page_path", "page_metadata", "page_dimensions",
        "current_segments", "position", "pan_y", "current_index", "webtoon_fraction", "page_viewport"}
    for _, key in ipairs(keys) do previous[key] = self[key] end
    self.page_buffer, self.page_crop = frame, nil
    self.page_dimensions = {width=frame:getWidth(),height=frame:getHeight()}
    self.page_metadata = metadata
    self.page_path = self:_image(point.index).path
    self.current_segments = {"whole"}
    self.position = {index=point.index,segment="whole"}
    self.webtoon_fraction, self.pan_y = point.fraction, 0
    local change = self:_page_change(previous.current_index, point.index, "whole", "whole")
    if not self:_display_segment("whole", true, change) then
        for _, key in ipairs(keys) do self[key] = previous[key] end
        return false
    end
    release_buffer(self.shell, previous.page_buffer)
    if self.context and not self.closing then
        self:_protect(point.index)
        self:_prefetch(point.index)
    end
    return true
end

function Reader:_request_webtoon(index, fraction)
    local session = self.webtoon_session
    if not session then
        local width, height = self.shell:get_content_size()
        local generation = self.generation
        session = Webtoon:new{
            width = width, height = height, settings = self.reader_settings,
            count = function() return self:_count() end,
            scale = function(buffer, w, h)
                local renderer = self:_renderer()
                if renderer and type(renderer.scaleBlitBuffer) == "function" then
                    return renderer:scaleBlitBuffer(buffer, w, h, false)
                end
                return buffer:scale(w, h)
            end,
            load = function(target, ready, failed)
                local image = self:_image(target)
                local memory_source = self:_page_source(image)
                local callbacks = {
                    on_ready = function(page, second, third)
                        if self.webtoon_session ~= session or not self.context
                            or not self.state:is_current(generation) then
                            if memory_source then release_buffer(nil, page) end
                            return
                        end
                        local metadata = (memory_source and second or third) or {}
                        local buffer, err = page, nil
                        if not memory_source then buffer, err = self:_decode_page_path(page, image, metadata) end
                        if not buffer then return failed({code="decode",reason="webtoon_image_invalid"}) end
                        local crop = self:_detect_crop(buffer, metadata)
                        if self:_stream_page_result_ready(metadata) then self:_mark_stream_page_ready(target,generation) end
                        if metadata.prepared_key then self.prepared_cache_keys[image.path] = metadata.prepared_key end
                        self:_note_preprocess_success(image, metadata)
                        ready(buffer,{crop=crop})
                    end,
                    on_error = failed,
                }
                return self:_request_page_data(image, generation, callbacks, memory_source)
            end,
            show = function(frame, point, metadata)
                if self.webtoon_session ~= session or not self.context
                    or not self.state:is_current(generation) then return false end
                return self:_publish_webtoon(frame,point,metadata)
            end,
            on_error = function(err)
                if self.webtoon_session ~= session or not self.context then return end
                if self.page_buffer then
                    self.shell:show_status("长条图片加载失败；再次翻页可重试。\n" .. Errors.message(err),3)
                else
                    self.shell:show_error{message=Errors.message(err),on_retry=function()
                        return session:seek(index,fraction)
                    end}
                end
            end,
        }
        self.webtoon_session = session
    end
    if not session.busy then self.webtoon_request = {index=index,fraction=fraction} end
    return session:seek(index,fraction)
end

function Reader:request_page(index, wanted_segment)
    if self.closing or not self.context or not self.state:is_current(self.generation) then
        return true
    end
    if self.quadrant_hold and not self:onTwoFingerHoldRelease(self.shell) then return false end
    local target = clamp(index, 1, self:_count())
    if self.fit_mode == "webtoon" and self.shell and not self.shell.legacy then
        local fraction = self.webtoon_resume_fraction
        self.webtoon_resume_fraction = nil
        return self:_request_webtoon(target, fraction)
    end
    local image = self:_image(target)
    if not image then return true end
    wanted_segment = wanted_segment or "whole"
    local pending = self.pending_request
    -- Keep one foreground page request at a time. Rapid alternating taps used
    -- to repeatedly cancel and restart network work, which could make the UI
    -- look frozen on slower NAS connections.
    if pending then return true end
    local session = self.panel_session
    if session then
        -- Explicit panel boundaries already detach and set panel_resume.
        -- Other page requests must end this session before replacing its page.
        if not self:_display_segment("whole", false) then return false end
        self.panel_session, self.panel_entry, self.panel_resume, self.panel_restore = nil, nil, nil, nil
        session:close()
    end
    if self.panel_entry and self.panel_entry.whole_page then
        self.panel_entry.whole_page = nil
        self.panel_resume = target < self.position.index and "last" or "first"
    end
    if self.position and target ~= self.position.index then
        self:_reset_quadrant_zoom("page_request")
    end
    self.request_serial = self.request_serial + 1
    local serial, generation = self.request_serial, self.generation
    self.pending_request = { index = target, segment = wanted_segment, serial = serial }
    if not self.page_buffer then
        self:_silent("show_reader_loading", function()
            return self.shell:show_loading(("正在加载第 %d / %d 张…"):format(target, self:_count()))
        end, true)
    end
    local memory_source = self:_page_source(image)
    local use_memory = memory_source ~= nil
    local callbacks = {
            on_ready = function(page, second, third)
                if not self:_active(serial, generation) then
                    if use_memory then release_buffer(nil, page) end
                    return
                end
                if self.pending_request and self.pending_request.serial == serial then
                    self.pending_request = nil
                end
                local ready_metadata = use_memory and second or third
                if self:_stream_page_result_ready(ready_metadata) then
                    self:_mark_stream_page_ready(target, generation)
                end
                if use_memory then
                    self:_render_memory_ready(page, target, wanted_segment or "whole",
                        serial, generation, second)
                else
                    self:_render_ready(page, target, wanted_segment or "whole",
                        serial, generation, third)
                end
            end,
            on_error = function(err)
                if not self:_active(serial, generation) then return end
                if self.pending_request and self.pending_request.serial == serial then
                    self.pending_request = nil
                end
                if self.panel_restore and self.panel_restore.index ~= target then
                    return self:request_page(self.panel_restore.index, self.panel_restore.segment)
                end
                self:_finish_panel_transition()
                self:_silent("show_reader_error", function()
                    self.shell:show_error{
                        message = image.opds_page and OpdsPages.error_message(err) or Errors.message(err),
                        on_retry = self:_callback("retry reader page", function()
                            return self:request_page(target, wanted_segment)
                        end, false),
                        on_previous = self:_callback("previous reader page", function()
                            return self:previous_page()
                        end, false),
                        on_next = self:_callback("next reader page", function()
                            return self:next_page()
                        end, false),
                    }
                end)
            end,
        }
    return self:_request_page_data(image, generation, callbacks, memory_source)
end

function Reader:_chapter_position()
    local position = tonumber(self.context.chapter_position)
    if position then return math.floor(position) end
    local index = self.context.chapters_index
    if index and type(index.find) == "function" and self.context.chapter then
        return index:find(self.context.chapter.path)
    end
    return nil
end

function Reader:_ask_next_chapter()
    local navigation = self.context.source_context and self.context.source_context.navigation
    if navigation and navigation.current and navigation.current.next then
        local target = navigation.current.next
        if self.auto_next_series then return self:_open_neighbor("next") end
        local model = { text = "本章已读完，是否打开下一章“"
            .. tostring(target.chapter_name or target.name) .. "”？", ok_text = "下一章",
            on_confirm = self:_callback("next series chapter", function() return self:_open_neighbor("next") end, false) }
        if self.ui.confirm then self.ui:confirm(model) else self.shell:show_confirmation(model) end
        return true
    end
    local chapters = self.context.chapters_index
    local position = self:_chapter_position()
    local next_chapter = chapters and position and chapters:get(position + 1) or nil
    if not next_chapter then
        if self.ui.show_info then
            self:_silent("show last chapter message", function()
                self.ui:show_info("已经是最后一章。")
            end)
        else
            self:_silent("show last chapter error", function()
                self.shell:show_error{ message = "已经是最后一章。" }
            end)
        end
        return true
    end
    local manga = self.context.manga
    local open_chapter = self.context.open_chapter or self.open_chapter
    local function open_next()
        return open_chapter(manga, next_chapter)
    end
    local model = {
        text = "本章已读完，是否打开下一章“" .. tostring(next_chapter.name) .. "”？",
        ok_text = "下一章",
        on_confirm = self:_callback("confirm next chapter", function()
            self.return_to = open_next
            return self:force_close("next_chapter")
        end, false),
    }
    self:_silent("show next chapter confirmation", function()
        if self.ui.confirm then self.ui:confirm(model)
        else self.shell:show_confirmation(model) end
    end)
    return true
end

function Reader:_open_neighbor(direction)
    local navigation = self.context and self.context.source_context and self.context.source_context.navigation
    if not navigation or not navigation.current or not navigation.current[direction] then return false end
    self.return_to = function() return navigation:open(direction) end
    return self:force_close("series_chapter")
end

function Reader:_pan_vertical(forward)
    if self.fit_mode ~= "width" or not self.page_buffer or not self.position then return false end
    local buffer = self.page_buffer
    if self.page_crop and type(buffer.viewport) == "function" then
        buffer = buffer:viewport(self.page_crop.x, self.page_crop.y,
            self.page_crop.w, self.page_crop.h)
    end
    local _width, height = buffer_size(buffer)
    local _content_w, content_h = self.shell:get_content_size()
    content_h = math.max(1, math.floor(tonumber(content_h) or height))
    if height <= content_h then return false end
    local step = math.max(1, math.floor(content_h * 0.85))
    local next_y = forward and math.min(height - content_h, self.pan_y + step)
        or math.max(0, self.pan_y - step)
    if next_y == self.pan_y then return false end
    self.pan_y = next_y
    return self:_display_segment(self.position.segment, false)
end

function Reader:next_page()
    if self.quadrant_hold and not self:onTwoFingerHoldRelease(self.shell) then return true end
    if self.webtoon_session then
        if self.webtoon_session:next() then return true end
        if self:_wait_for_stream_end() then return true end
        return self:_ask_next_chapter()
    end
    if self.panel_entry then return self:_move_panel(1) end
    if self:_pan_vertical(true) then return true end
    if not self.position then return true end
    local next_position = PageSequence.next(self.position,
        self.current_segments, self:_count())
    if not next_position then
        if self:_wait_for_stream_end() then return true end
        return self:_ask_next_chapter()
    end
    if next_position.index == self.position.index then
        return self:_display_segment(next_position.segment, true,
            self:_page_change(self.position.index, next_position.index,
                self.position.segment, next_position.segment,
                self.current_segments, self.current_segments))
    end
    return self:request_page(next_position.index, next_position.segment)
end

function Reader:previous_page()
    if self.quadrant_hold and not self:onTwoFingerHoldRelease(self.shell) then return true end
    if self.webtoon_session then return self.webtoon_session:previous() end
    if self.panel_entry then return self:_move_panel(-1) end
    if self:_pan_vertical(false) then return true end
    if not self.position then return true end
    local previous = PageSequence.previous(self.position,
        self.current_segments, self:_count())
    if not previous then return true end
    if previous.index == self.position.index then
        return self:_display_segment(previous.segment, true,
            self:_page_change(self.position.index, previous.index,
                self.position.segment, previous.segment,
                self.current_segments, self.current_segments))
    end
    return self:request_page(previous.index, "__last")
end

function Reader:_reset_quadrant_zoom(_reason)
    self.quadrant_zoom = nil
    self.quadrant_hold = nil
    if self.shell and self.shell.stop_quadrant_hold_watch then self.shell:stop_quadrant_hold_watch() end
end

function Reader:_quadrant_input_ready(source_shell)
    if self.closing or not self.page_buffer or not self.position or not self.shell
        or self.pending_request or self.panel_entry or self.panel_session or self.panel_restore
        or self.shell.bubble_zoom then
        return false
    end
    local model = self.shell.current_model
    if (source_shell and source_shell ~= self.shell) or self.shell.closed
        or not self.state:is_current(self.generation)
        or not model or model.kind ~= "page" or model.buffer ~= self.page_buffer
        or model.reader_generation ~= self.generation then
        return false
    end
    return true
end

function Reader:onTwoFingerTap(source_shell, gesture)
    if source_shell==self.shell and self.panel_session then return self:toggle_controls("panel_view") end
    if self.webtoon_session or not self:_quadrant_input_ready(source_shell) then return false end
    if self.quadrant_hold then return true end
    local width, height = self.shell:get_content_size()
    local quadrant = Quadrant.from_gesture(gesture, width, height)
    if not quadrant then return false end
    local previous = self.quadrant_zoom
    if previous then self:_reset_quadrant_zoom("collapse")
    else self.quadrant_zoom = quadrant end
    local shown = self:_display_segment(self.position.segment, false, { refresh_type = "partial" })
    if not shown then self.quadrant_zoom = previous end
    return shown
end

function Reader:onTwoFingerHold(source_shell, gesture)
    if not self:_quadrant_input_ready(source_shell)
        or (self.webtoon_session and self.webtoon_session.busy) then return false end
    if self.quadrant_hold then return true end
    local width,height = self.shell:get_content_size()
    local quadrant = Quadrant.from_gesture(gesture,width,height)
    if not quadrant then return false end
    self.shell.bubble_hold_consumed = nil
    local previous = self.quadrant_zoom
    self.quadrant_hold = { shell=self.shell, buffer=self.page_buffer, generation=self.generation,
        serial=self.request_serial, previous=previous, time=gesture.time }
    self.quadrant_zoom = quadrant
    local shown = self:_display_segment(self.position.segment,false,{refresh_type="partial"})
    if shown and self.shell.start_quadrant_hold_watch then
        shown = self.shell:start_quadrant_hold_watch(self.quadrant_hold)
        if not shown then
            self.quadrant_zoom,self.quadrant_hold = previous,nil
            self:_display_segment(self.position.segment,false,{refresh_type="partial"})
        end
    end
    if not shown then self.quadrant_zoom,self.quadrant_hold = previous,nil end
    return shown
end

function Reader:onTwoFingerHoldPan(source_shell,gesture)
    if self.panel_session then return self:onPanelPan(source_shell,gesture) end
    return self.quadrant_hold ~= nil and self:_quadrant_input_ready(source_shell)
end

function Reader:onTwoFingerHoldRelease(source_shell, gesture)
    if source_shell==self.shell and self.panel_session and gesture
        and self.shell.current_model and self.shell.current_model.kind=="page" then
        local session=self.panel_session
        if gesture.ges=="pinch" then self.panel_pan=nil;session:zoom(1/1.25);return true end
        if gesture.ges=="spread" then self.panel_pan=nil;session:zoom(1.25);return true end
        if gesture.ges=="pan_release" or gesture.ges=="two_finger_pan_release"
            or gesture.ges=="two_finger_hold_pan_release" then
            local pan=self.panel_pan;self.panel_pan=nil
            local current=session:current()
            if pan and pan.session==session and current and current.buffer==pan.buffer then
                local dx,dy=pan.dx,pan.dy
                if pan.ges=="pan" and gesture.pos and pan.start then
                    dx,dy=gesture.pos.x-pan.start.x,gesture.pos.y-pan.start.y
                end
                session:pan(dx,dy)
            end
            return true
        end
    end
    if source_shell == self.shell and gesture and gesture.ges == "hold_release"
        and source_shell.bubble_hold_consumed then
        source_shell.bubble_hold_consumed = nil
        return true
    end
    local hold = self.quadrant_hold
    if not hold or (source_shell and source_shell ~= hold.shell) then return false end
    if gesture and type(gesture.time)=="number" and type(hold.time)=="number"
        and gesture.time < hold.time then return false end
    self.quadrant_hold = nil
    if self.shell and self.shell.stop_quadrant_hold_watch then self.shell:stop_quadrant_hold_watch() end
    if self.closing or self.shell ~= hold.shell or self.page_buffer ~= hold.buffer
        or self.generation ~= hold.generation or self.request_serial ~= hold.serial
        or not self.state:is_current(hold.generation) then return false end
    self.quadrant_zoom = hold.previous
    -- A dialog may have taken focus before lift. Never replace it with a page;
    -- the restored state is used when normal reading resumes.
    if not self:_quadrant_input_ready(source_shell) then return true end
    return self:_display_segment(self.position.segment,false,{refresh_type="partial"})
end

function Reader:onPanelPan(source_shell,gesture)
    local session=self.panel_session
    if self.closing or source_shell~=self.shell or not session or not gesture
        or not self.shell.current_model or self.shell.current_model.kind~="page" then return false end
    local current=session:current()
    local delta=gesture.relative
    if not current or not delta or type(delta.x)~="number" or type(delta.y)~="number" then return true end
    self.panel_pan={session=session,buffer=current.buffer,ges=gesture.ges,
        dx=delta.x,dy=delta.y,start=gesture.start_pos}
    return true
end

function Reader:show_bubble_at(gesture)
    if self.shell and self.shell.bubble_zoom then return self.shell:close_bubble_zoom() end
    if self.quadrant_hold or not self:_quadrant_input_ready(self.shell)
        or (self.webtoon_session and self.webtoon_session.busy) then return false end
    local viewport = self.page_viewport
    local image = self.shell:get_page_image_rect()
    local point = BubbleZoom.map_point(gesture and gesture.pos, image,
        viewport:getWidth(), viewport:getHeight())
    if not point then
        self.shell:show_status("请在对白气泡内部操作。", 2)
        return true
    end
    local box, reason = BubbleZoom.detect(viewport, point)
    if not box then
        self.shell:show_status(reason == "pixel_unavailable" and "当前图片无法识别对白气泡。"
            or "未识别到明确的封闭对白气泡，请改按气泡空白处。", 2)
        return true
    end
    local scale = (self.reader_settings.bubble_zoom_scale or 2) * image.w / viewport:getWidth()
    local shown = self:_silent("show_bubble_zoom", function()
        return self.shell:show_bubble_zoom(viewport, box, gesture.pos, scale)
    end, false)
    if not shown then self.shell:show_status("气泡放大显示失败，请重试。", 2) end
    return true
end

function Reader:onTap(_, gesture)
    if self.shell and self.shell.bubble_zoom then return self.shell:close_bubble_zoom() end
    local width, height = 600, 800
    if self.shell and self.shell.get_content_size then
        width, height = self.shell:get_content_size()
    end
    local x = gesture and gesture.pos and gesture.pos.x or width / 2
    local y = gesture and gesture.pos and gesture.pos.y or height / 2
    -- Some KOReader builds deliver a double tap through the generic tap
    -- callback instead of the named DoubleTap gesture. Keep the emergency
    -- top-right exit reachable in both dispatch paths.
    if gesture and gesture.ges == "double_tap"
        and x >= width * 0.60 and y <= math.max(height * 0.20, 72)
        and type(self.onRightTopDoubleTap) == "function" then
        return self:onRightTopDoubleTap()
    end
    if self.panel_entry then
        if x>=width/3 and x<=width*2/3 and y>=height/3 and y<=height*2/3 then
            return self:toggle_controls("panel_view")
        end
        if (not self.panel_session and not self.panel_entry.whole_page)
            or (self.panel_session and self.panel_session.render_options.view=="free") then return true end
        local vertical=self.reader_settings.panel_navigation=="vertical"
        local coordinate,size=vertical and y or x,vertical and height or width
        if coordinate>=size/3 and coordinate<=size*2/3 then return self:toggle_controls("panel_view") end
        local delta=coordinate<size/3 and -1 or 1
        if self.reader_settings.panel_reverse_navigation then delta=-delta end
        return self:_move_panel(delta)
    end
    if x >= width / 3 and x <= width * 2 / 3
        and y <= math.max(44, height * 0.12)
        and type(self.show_koreader_menu) == "function" then
        self:_silent("show_koreader_menu", self.show_koreader_menu, false)
        return true
    end
    if self.reader_settings.bubble_zoom_enabled == true
        and self.reader_settings.bubble_zoom_trigger == "tap"
        and not self.panel_entry and not self.panel_session and not self.panel_restore then
        return self:show_bubble_at(gesture)
    end
    if x < width / 3 then
        if self.direction == "manga" then return self:next_page() end
        return self:previous_page()
    elseif x > width * 2 / 3 then
        if self.direction == "manga" then return self:previous_page() end
        return self:next_page()
    end
    return self:toggle_controls()
end

function Reader:onHold(_, gesture)
    if self.closing then return false end
    if self.shell and self.shell.bubble_zoom then
        local consumed = self.shell:close_bubble_zoom()
        self.shell.bubble_hold_consumed = consumed or nil
        return consumed
    end
    if self.reader_settings and self.reader_settings.bubble_zoom_enabled == true
        and self.reader_settings.bubble_zoom_trigger ~= "tap"
        and not self.panel_entry and not self.panel_session and not self.panel_restore then
        local consumed = self:show_bubble_at(gesture)
        if self.shell then self.shell.bubble_hold_consumed = consumed or nil end
        return consumed
    end
    if not self.reader_settings or self.reader_settings.panel_zoom_enabled ~= true then return false end
    if self.shell and self.shell.current_model and self.shell.current_model.kind ~= "page" then return false end
    local session = self.panel_session
    if session and session:is_active() then
        if self.shell.panel_zoom then return true end
        session:release_next()
        local current = session:current()
        if not current or not current.buffer then return false end
        local serial, generation = self.request_serial, self.generation
        local width, height = self.shell:get_content_size()
        return self.shell:show_panel_zoom{
            buffer = current.buffer,
            initial_zoom = self.reader_settings.panel_initial_zoom or 1.2,
            padding = math.floor(math.min(width, height)
                * (self.reader_settings.panel_hold_margin_percent or 5) / 100),
            on_close = function()
                if self.closing or self.panel_session ~= session or self.generation ~= generation
                    or self.request_serial ~= serial then return end
                local panel = session:current()
                if panel and panel.buffer == current.buffer then
                    self:_show_panel(panel.buffer, panel.panel, panel.index, panel.count)
                end
            end,
        }
    end
    if self.panel_entry then return true end
    return self:enter_panel_mode("first")
end

function Reader:onBubbleHoldPan(source_shell)
    return not self.closing and source_shell == self.shell
        and source_shell.bubble_hold_consumed == true
end

function Reader:_show_panel(buffer, _panel, index, count)
    if self.closing or not self.shell or not self.position then return false end
    local shown = self.shell:show_page(buffer, buffer, nil, { refresh_type = "partial" },
        (self.position.index - 1 + index / count) / self:_count(),
        self.show_progress_bar, self.progress_bar_thickness,
        self.reader_settings.kopt_filter_enabled == true and self.reader_settings.kopt_dithering == true)
    if shown == false then return false end
    if self.panel_entry then self.panel_entry.displayed = true end
    -- A failed status redraw must not reject an already displayed allocation.
    pcall(self.shell.show_status,self.shell,("分格 %d / %d"):format(index, count))
    return true
end

function Reader:enter_panel_mode(desired)
    if self.webtoon_session then
        return self.shell:show_status("请先将图片显示切换为整页，再使用智能分格。")
    end
    if self.closing or not self.page_buffer or not self.position or self.pending_request
        or self.panel_restore or self.reader_settings.panel_zoom_enabled ~= true
        or not self.panel_source or not self.panel_detector then return false end
    if self.reader_settings.image_engine == "memory" then
        self.shell:show_status(panel_failure_messages.panel_engine_unsupported)
        return false
    end
    if self.panel_session then return true end
    if self.quadrant_zoom then
        local previous = self.quadrant_zoom
        self:_reset_quadrant_zoom("panel")
        if not self:_display_segment(self.position.segment, false) then
            self.quadrant_zoom = previous
            return false
        end
    end
    if not self.panel_entry then
        self.panel_entry = { index = self.position.index, segment = self.position.segment,
            pan_y = self.pan_y, current_segments = self.current_segments, serial = self.request_serial,
            viewport = self.page_viewport }
    end
    self.panel_entry.whole_page = nil
    self.current_segments, self.pan_y = { "whole" }, 0
    self.shell:show_status("正在识别分格")
    local width, height = self.shell:get_content_size()
    local shell = self.shell
    local schedule
    if type(self.ui.schedule) == "function" then
        schedule = function(callback) return self.ui:schedule(callback) end
    elseif shell.scheduler and type(shell.scheduler.scheduleIn) == "function" then
        schedule = function(callback) return shell.scheduler:scheduleIn(0, callback) end
    end
    local ok, session = pcall(self.panel_session_factory, {
        source = self.panel_source, detector = self.panel_detector, schedule = schedule,
        screen_width = width, screen_height = height,
    })
    if not ok or not session then return self:_panel_fallback("panel_source_unavailable") end
    self.panel_session = session
    local serial, generation = self.request_serial, self.generation
    local function active()
        return self.panel_session == session and self:_active(serial, generation)
    end
    local started = session:start({
        generation = generation, image = self:_image(self.position.index),
        engine = "default",
        page_path = self.page_path, page_buffer = self.page_buffer,
        direction = self:_panel_direction(), desired = desired or "first",
        view=self.reader_settings.panel_view or "context",rotation=self.reader_settings.panel_rotation or 0,
        margin_percent = self.reader_settings.panel_standard_margin_percent,
        show_adjacent = self.reader_settings.panel_show_adjacent ~= false,
        experimental = self.reader_settings.panel_experimental_sort == true,
    }, {
        on_panel = self:_callback("show dynamic panel", function(buffer, panel, index, count)
            if not active() then return false end
            return self:_show_panel(buffer, panel, index, count)
        end, false),
        on_boundary = self:_callback("cross dynamic panel page", function(delta)
            if not active() then return false end
            return self:_request_panel_page(delta)
        end, false),
        on_fallback = self:_callback("fallback dynamic panel", function(reason)
            if active() then return self:_panel_fallback(reason) end
        end, false),
    })
    if started == false and self.panel_session == session then self:_panel_fallback() end
    return true
end

function Reader:_request_panel_page(delta)
    if self.pending_request then return true end
    local target = self.position.index + delta
    if target > self:_count() then
        if self:_wait_for_stream_end() then return true end
        return self:_ask_next_chapter()
    end
    if target < 1 then return true end
    local session = self.panel_session
    if session then
        -- Detach the borrowed panel before its owner releases it.
        if not self:_display_segment("whole", false) then return false end
        self.panel_session = nil
        session:close()
    end
    if self.panel_entry then self.panel_entry.whole_page = nil end
    self.panel_resume = delta > 0 and "first" or "last"
    return self:request_page(target, "whole")
end

function Reader:_move_panel(delta)
    local session = self.panel_session
    if session then
        -- A direction saved during detection or a busy render is reconciled
        -- before the next accepted input, without queuing another render.
        local direction=self:_panel_direction()
        if session.direction ~= direction then
            local current = session:set_direction(direction)
            if not current then return true end
            self:_show_panel(current.buffer, current.panel, current.index, current.count)
        end
        session:move(delta)
    elseif self.panel_entry and self.panel_entry.whole_page then
        return self:_request_panel_page(delta)
    end
    -- Busy detection/rendering and in-flight physical transitions consume input.
    return true
end

function Reader:exit_panel_mode()
    local entry = self.panel_entry
    if not entry then return true end
    local session = self.panel_session
    local retained = entry.serial == self.request_serial and not self.pending_request
    local segments, pan_y = self.current_segments, self.pan_y
    local whole_page = entry.whole_page
    entry.whole_page = nil
    self.current_segments = retained and entry.current_segments or { "whole" }
    self.pan_y = retained and entry.pan_y or 0
    if entry.displayed or not retained or self.position.segment ~= entry.segment
        or self.page_viewport ~= entry.viewport then
        if not self:_display_segment(retained and entry.segment or "whole", false) then
            self.current_segments, self.pan_y = segments, pan_y
            entry.whole_page = whole_page
            return false
        end
    end
    self.panel_session, self.panel_entry, self.panel_resume = nil, nil, nil
    self.panel_pan=nil
    if session then session:close() end
    if not retained then
        self.panel_restore = entry
        if not self.pending_request then return self:request_page(entry.index, entry.segment) end
    end
    return true
end

function Reader:_panel_fallback(reason)
    if self.panel_entry and (reason == "no_panels" or reason == "too_many_panels") then
        local entry, session = self.panel_entry, self.panel_session
        local whole_page = entry.whole_page
        entry.whole_page = true
        if not self:_display_segment("whole", false) then
            entry.whole_page = whole_page
            if session and not session:is_active() then
                -- No panel allocation is visible. Stop the rejected transition
                -- before PanelSession closes itself and invalidates its fields.
                if entry.serial == self.request_serial then
                    self.current_segments, self.pan_y = entry.current_segments, entry.pan_y
                else
                    -- Preserve the ordinary whole-page view already on screen.
                    self.current_segments = { "whole" }
                end
                self.panel_session, self.panel_entry, self.panel_resume, self.panel_pan = nil, nil, nil, nil
                session:close()
            end
            return false
        end
        self.panel_session, self.panel_resume, self.panel_pan = nil, nil, nil
        if session then session:close() end
    elseif not self:exit_panel_mode() then return false end
    if self.shell then self.shell:show_status(panel_failure_messages[reason]
        or panel_failure_messages.panel_source_unavailable) end
    return true
end

function Reader:onRightTopDoubleTap()
    if self.shell and type(self.shell.show_exit_button) == "function" then
        return self.shell:show_exit_button()
    end
    return true
end

function Reader:close_controls()
    if self.closing or not self.position then return false end
    if self.panel_session then
        local current=self.panel_session:current()
        if current then return self:_show_panel(current.buffer,current.panel,current.index,current.count) end
        return false
    end
    return self:_display_segment(self.position.segment or "whole", false, {
        refresh_type = "partial",
    })
end

function Reader:onSwipe(_, gesture)
    if self.shell and self.shell.bubble_zoom then return self.shell:close_bubble_zoom() end
    local direction = gesture and gesture.direction
    if self.panel_entry then
        local session=self.panel_session
        if not session and not self.panel_entry.whole_page then return true end
        if session and session.render_options.view=="free" then
            self.panel_pan=nil
            if gesture.pos and gesture.end_pos then
                session:pan(gesture.end_pos.x-gesture.pos.x,gesture.end_pos.y-gesture.pos.y)
            end
            return true
        end
        local vertical=self.reader_settings.panel_navigation=="vertical"
        local delta
        if vertical then
            if direction=="north" then delta=1 elseif direction=="south" then delta=-1 end
        else
            if direction=="west" then delta=1 elseif direction=="east" then delta=-1 end
        end
        if delta then
            if self.reader_settings.panel_reverse_navigation then delta=-delta end
            return self:_move_panel(delta)
        end
        return true
    end
    if direction == "west" then
        if self.direction == "manga" then return self:previous_page() end
        return self:next_page()
    elseif direction == "east" then
        if self.direction == "manga" then return self:next_page() end
        return self:previous_page()
    end
    return true
end

function Reader:_panel_direction()
    local order=self.reader_settings.panel_order
    return (order=="normal" or order=="manga") and order or self.direction
end

function Reader:set_panel_option(key,value,make_default)
    local previous=copy_table(self.reader_settings)
    local values=copy_table(previous);values[key]=value
    local session=self.panel_session
    local snapshot=self.settings.panel_snapshot and self.settings:panel_snapshot()
    local function commit()
        if self.panel_book_key and self.settings.set_panel_reader then
            return self.settings:set_panel_reader(self.panel_book_key,{[key]=value},make_default)==true
        end
        return self:_persist_reader(values)
    end
    local function rollback()
        self.reader_settings=previous
        if snapshot and self.settings.restore_panel then self.settings:restore_panel(snapshot) end
    end
    local camera_keys={panel_view="view",panel_rotation="rotation",
        panel_standard_margin_percent="margin_percent",panel_show_adjacent="show_adjacent"}
    local camera_key=camera_keys[key]
    local saved
    if session and session:is_active() and camera_key then
        local options={[camera_key]=value}
        if key=="panel_view" then options.zoom,options.pan_x,options.pan_y=1,0,0 end
        saved=session:configure(options,commit,rollback)
    else saved=commit() end
    if not saved then
        local message="分格设置未能应用，已保留原画面与位置。"
        if self.ui and self.ui.show_info then self.ui:show_info(message)
        else self.shell:show_status(message,2) end
        return false
    end
    self.reader_settings=values
    if session and session:is_active() then
        local current=session:set_direction(self:_panel_direction())
        if current then self:_show_panel(current.buffer,current.panel,current.index,current.count) end
    end
    if key=="panel_zoom_enabled" and value==false then self:exit_panel_mode() end
    return true
end

function Reader:_persist_reader(values)
    local previous = copy_table(self.reader_settings)
    local defaults=self.settings:get_reader()
    local global_values=copy_table(values)
    if self.panel_book_key and self.settings.panel_values then
        for k,v in pairs(self.settings:panel_values(previous)) do
            if values[k]==v then global_values[k]=defaults[k] end
        end
    end
    local wrote = false
    local persisted = self:_silent("persist_reader_settings", function()
        if type(self.settings.set_reader) ~= "function" then return false end
        local ok = self.settings:set_reader(global_values)
        if not ok then return false end
        wrote = true
        if type(self.settings.flush) == "function" then
            local flushed = self.settings:flush()
            if flushed == false then return false end
        end
        return true
    end, false)
    if not persisted then
        -- Settings:set_reader updates the store before flush. Restore the
        -- previous value when a later persistence step fails so the next
        -- control render sees one coherent configuration.
        if wrote then
            self:_silent("rollback_reader_settings", function()
                local ok = self.settings:set_reader(defaults)
                if ok and type(self.settings.flush) == "function" then
                    self.settings:flush()
                end
                return ok
            end, false)
        end
        return false
    end
    self.reader_settings = copy_table(values)
    return true
end

function Reader:_prepare_fit_mode(mode)
    if mode ~= "webtoon" then return true end
    if mode == "webtoon" and self.shell and self.shell.legacy then return false end
    if mode == "webtoon" and (self.panel_entry or self.panel_session) then
        if self.page_buffer and not self:_display_segment("whole", false) then return false end
        local panel = self.panel_session
        self.panel_session, self.panel_entry, self.panel_resume, self.panel_restore = nil, nil, nil, nil
        if panel then panel:close() end
    end
    self:_reset_quadrant_zoom("webtoon")
    return true
end

function Reader:set_fit_mode(mode)
    if mode ~= "page" and mode ~= "width" and mode ~= "match" and mode ~= "webtoon" then return false end
    if not self:_prepare_fit_mode(mode) then return false end
    local values = copy_table(self.reader_settings)
    values.fit_mode = mode
    local saved = self:_persist_reader(values)
    if not saved then return false end
    self.fit_mode = mode
    if self.shell and self.shell.legacy and self.shell.viewer
        and self.shell.viewer.set_fit_mode then
        self.shell.viewer:set_fit_mode(mode)
    else
        return self:_restart_processed_page()
    end
    return true
end

function Reader:set_direction(direction)
    if direction ~= "normal" and direction ~= "manga" then return false end
    local values = copy_table(self.reader_settings)
    values.direction = direction
    local saved = self:_persist_reader(values)
    if not saved then return false end
    return self:_apply_direction(direction)
end

function Reader:_apply_direction(direction)
    self.direction = direction
    if self.panel_session then
        local current = self.panel_session:set_direction(self:_panel_direction())
        if current then self:_show_panel(current.buffer, current.panel, current.index, current.count) end
    end
    local width = tonumber(self.page_dimensions and self.page_dimensions.width) or 0
    local height = tonumber(self.page_dimensions and self.page_dimensions.height) or 0
    self.current_segments = self:_segments(width, height)
    return true
end

function Reader:set_animation_enabled(enabled)
    enabled = enabled == true
    local values = copy_table(self.reader_settings)
    values.animation_enabled = enabled
    if not self:_persist_reader(values) then return false end
    self.animation_enabled = enabled
    return true
end

function Reader:set_full_refresh_each_page(enabled)
    enabled = enabled == true
    local values = copy_table(self.reader_settings)
    values.full_refresh_each_page = enabled
    if not self:_persist_reader(values) then return false end
    self.full_refresh_each_page = enabled
    return true
end

function Reader:set_show_progress_bar(enabled)
    enabled = enabled == true
    local values = copy_table(self.reader_settings)
    values.show_progress_bar = enabled
    if not self:_persist_reader(values) then return false end
    self.show_progress_bar = enabled
    return true
end

function Reader:set_show_preprocess_success(enabled)
    enabled = enabled == true
    local values = copy_table(self.reader_settings)
    values.show_preprocess_success = enabled
    if not self:_persist_reader(values) then return false end
    self.show_preprocess_success = enabled
    if not enabled then self.preprocess_notice_paths = {} end
    return true
end

function Reader:set_progress_bar_thickness(value)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < 1 or value > 4 then
        return false
    end
    local values = copy_table(self.reader_settings)
    values.progress_bar_thickness = value
    if not self:_persist_reader(values) then return false end
    self.progress_bar_thickness = value
    if self.position then
        return self:_display_segment(self.position.segment or "whole", false, {
            refresh_type = "partial",
        })
    end
    return true
end

function Reader:_restart_processed_page()
    if self.quadrant_hold and not self:onTwoFingerHoldRelease(self.shell) then return false end
    local target = self.position or self.webtoon_request or self.pending_request
    local fraction = self.webtoon_fraction or (target and target.fraction)
    self:_close_webtoon()
    self.webtoon_resume_fraction = self.fit_mode == "webtoon" and fraction or nil
    if not target then return true end
    local index, segment = target.index, target.segment or "whole"
    self.pending_request = nil
    self.request_serial = self.request_serial + 1
    self.prepared_cache_keys = {}
    if self.prepared_pages
        and type(self.prepared_pages.cancel_processing) == "function" then
        self.prepared_pages:cancel_processing(self.generation)
    end
    return self:request_page(index, segment)
end

function Reader:set_gray_enhance_enabled(enabled)
    if type(enabled) ~= "boolean" then return false end
    local values = copy_table(self.reader_settings)
    values.gray_enhance_enabled = enabled
    if not self:_persist_reader(values) then
        self:_silent("show_gray_setting_error", function()
            self.ui:show_info("去灰增强开关保存失败，当前设置未变。")
        end)
        return false
    end
    self:_arm_preprocess_notice(self.position and self.position.index or 1)
    return self:_restart_processed_page()
end

function Reader:set_gray_enhance_preset(preset_id)
    local enhancer = self.gray_enhance or GrayEnhance
    local custom = self.reader_settings and self.reader_settings.gray_enhance_custom_presets
    if type(enhancer.is_valid_id) == "function"
        and not enhancer.is_valid_id(preset_id, custom) then
        return false
    end
    local values = copy_table(self.reader_settings)
    values.gray_enhance_preset = tostring(preset_id or "original")
    if not self:_persist_reader(values) then return false end
    self:_arm_preprocess_notice(self.position and self.position.index or 1)
    return self:_restart_processed_page()
end

function Reader:reload_settings(values)
    if type(values) ~= "table" then
        values = self.panel_book_key and self.settings.get_panel_reader
            and self.settings:get_panel_reader(self.panel_book_key) or self.settings:get_reader()
    end
    local previous = self.reader_settings or {}
    local next_values = copy_table(values)
    if self.panel_book_key and self.settings.get_panel_overrides then
        for k,v in pairs(self.settings:get_panel_overrides(self.panel_book_key)) do next_values[k]=v end
    end
    if not self:_prepare_fit_mode(next_values.fit_mode) then return false end
    if self.panel_entry and (next_values.panel_zoom_enabled ~= true
        or next_values.image_engine == "memory") then
        if not self:exit_panel_mode() then return false end
    end
    local direction_only = self.panel_session and previous.direction ~= next_values.direction
        and same_settings(previous, next_values, "direction")
    local filter_changed = previous.gray_enhance_enabled ~= next_values.gray_enhance_enabled
        or previous.gray_enhance_preset ~= next_values.gray_enhance_preset
        or previous.tone_adjust_enabled ~= next_values.tone_adjust_enabled
        or previous.tone_adjust_preset ~= next_values.tone_adjust_preset
    self.reader_settings = next_values
    if direction_only then return self:_apply_direction(next_values.direction or "normal") end
    self.animation_enabled = self.reader_settings.animation_enabled == true
    self.full_refresh_each_page = self.reader_settings.full_refresh_each_page == true
    self.direction = self.reader_settings.direction or "normal"
    self.fit_mode = self.reader_settings.fit_mode or "page"
    self.show_progress_bar = self.reader_settings.show_progress_bar ~= false
    self.progress_bar_thickness = clamp(
        tonumber(self.reader_settings.progress_bar_thickness) or 1, 1, 4)
    self.show_preprocess_success = self.reader_settings.show_preprocess_success ~= false
    if filter_changed then
        self:_arm_preprocess_notice(self.position and self.position.index or 1)
    end
    self:_restart_processed_page()
    return true
end

function Reader:set_tone_adjust_enabled(enabled)
    if type(enabled) ~= "boolean" then return false end
    local values = copy_table(self.reader_settings)
    values.tone_adjust_enabled = enabled
    if not self:_persist_reader(values) then return false end
    self:_arm_preprocess_notice(self.position and self.position.index or 1)
    return self:_restart_processed_page()
end

function Reader:set_tone_adjust_preset(preset_id)
    local adjuster = self.tone_adjust or ToneAdjust
    local custom = self.reader_settings and self.reader_settings.tone_adjust_custom_presets
    if type(adjuster.is_valid_id) == "function"
        and not adjuster.is_valid_id(preset_id, custom) then return false end
    local values = copy_table(self.reader_settings)
    values.tone_adjust_preset = tostring(preset_id or "original")
    if not self:_persist_reader(values) then return false end
    self:_arm_preprocess_notice(self.position and self.position.index or 1)
    return self:_restart_processed_page()
end

function Reader:set_auto_crop_enabled(enabled)
    enabled = enabled == true
    local values = copy_table(self.reader_settings)
    values.auto_crop_enabled = enabled
    if not self:_persist_reader(values) then return false end
    if self.position then self:request_page(self.position.index, "whole") end
    return true
end

function Reader:set_split_first_segment(segment)
    if segment ~= "left" and segment ~= "right" then return false end
    local values = copy_table(self.reader_settings)
    values.split_first_segment = segment
    if not self:_persist_reader(values) then return false end
    if self.position then self:request_page(self.position.index, self.position.segment or "whole") end
    return true
end

function Reader:show_ratio_input(name)
    if name ~= "split_min_ratio" and name ~= "split_max_ratio" then return false end
    local is_minimum = name == "split_min_ratio"
    local current = tonumber(self.reader_settings[name]) or (is_minimum and 1.20 or 2.20)
    local model = {
        title = is_minimum and "最小宽高比" or "最大宽高比",
        description = "请输入 1.00 到 4.00 之间的数值",
        value = ("%.2f"):format(current),
        on_save = self:_callback("save split ratio", function(text)
            local value = tonumber(text)
            local minimum = is_minimum and value
                or tonumber(self.reader_settings.split_min_ratio) or 1.20
            local maximum = is_minimum
                and (tonumber(self.reader_settings.split_max_ratio) or 2.20) or value
            if not value or value < 1.00 or value > 4.00 or minimum >= maximum then
                return false
            end
            local values = copy_table(self.reader_settings)
            values[name] = value
            if not self:_persist_reader(values) then return false end
            if self.position then self:request_page(self.position.index, "whole") end
            return true
        end, false),
    }
    if self.ui and type(self.ui.show_number_input) == "function" then
        return self.ui:show_number_input(model)
    end
    if self.shell and type(self.shell.show_number_input) == "function" then
        return self.shell:show_number_input(model)
    end
    return false
end

function Reader:show_split_cut_input()
    local current = clamp(tonumber(self.reader_settings.split_cut_percent) or 50, 10, 90)
    local model = {
        title = "左右切分位置",
        description = "请输入 10 到 90 的整数百分比",
        value = tostring(current),
        on_save = self:_callback("save split cut position", function(text)
            local value = tonumber(text)
            if not value or value % 1 ~= 0 or value < 10 or value > 90 then return false end
            local values = copy_table(self.reader_settings)
            values.split_cut_percent = value
            if not self:_persist_reader(values) then return false end
            if self.position then self:request_page(self.position.index, "whole") end
            return true
        end, false),
    }
    if self.ui and type(self.ui.show_number_input) == "function" then
        return self.ui:show_number_input(model)
    end
    if self.shell and type(self.shell.show_number_input) == "function" then
        return self.shell:show_number_input(model)
    end
    return false
end

function Reader:show_crop_input(name)
    if name ~= "auto_crop_strength" and name ~= "auto_crop_max_percent" then return false end
    local is_strength = name == "auto_crop_strength"
    local current = is_strength
        and Reader.crop_strength_from_threshold(self.reader_settings.auto_crop_threshold)
        or clamp(tonumber(self.reader_settings.auto_crop_max_percent) or 15, 0, 30)
    local model = {
        title = is_strength and "白边识别强度" or "每侧最多裁切比例",
        description = is_strength and "请输入 0 到 100 的整数百分比，越大识别越强"
            or "请输入 0 到 30 的整数百分比",
        value = tostring(current),
        on_save = self:_callback("save auto crop setting", function(text)
            local value = tonumber(text)
            local maximum = is_strength and 100 or 30
            if not value or value % 1 ~= 0 or value < 0 or value > maximum then return false end
            local values = copy_table(self.reader_settings)
            if is_strength then
                values.auto_crop_threshold = Reader.crop_threshold_from_strength(value)
            else
                values.auto_crop_max_percent = value
            end
            if not self:_persist_reader(values) then return false end
            if self.position then self:request_page(self.position.index, "whole") end
            return true
        end, false),
    }
    if self.ui and type(self.ui.show_number_input) == "function" then
        return self.ui:show_number_input(model)
    end
    if self.shell and type(self.shell.show_number_input) == "function" then
        return self.shell:show_number_input(model)
    end
    return false
end

function Reader:onDoubleTap()
    local next_mode = self.fit_mode == "page" and "width"
        or self.fit_mode == "width" and "match" or self.fit_mode == "match" and "webtoon" or "page"
    return self:set_fit_mode(next_mode)
end

function Reader:show_page_picker()
    local progress = self:_stream_progress()
    if progress and not progress.complete then
        local message = stream_wait_message(progress, true)
        if self.ui.show_info then return self.ui:show_info(message) end
        if self.shell and self.shell.show_status then return self.shell:show_status(message) end
        return true
    end
    local model = {
        value = self.position and self.position.index or 1,
        value_min = 1,
        value_max = self:_count(),
        on_select = self:_callback("select reader page", function(index)
            return self:request_page(index, "whole")
        end, false),
    }
    if self.ui.show_page_picker then return self.ui:show_page_picker(model) end
    return self.shell:show_page_picker(model)
end

function Reader:toggle_controls(section)
    self.panel_pan=nil
    section = section or "root"
    local function show_section(name)
        return self:toggle_controls(name)
    end
    local function show_current_page()
        return self:close_controls()
    end
    local function persist_and_reopen(name, callback)
        if callback() == false then return false end
        return show_section(name)
    end
    local function action(text, stage, callback)
        return { text = text, callback = self:_callback(stage, callback, false) }
    end

    local actions
    local title
    if section == "panel_view" then
        title="分格视图 · 点按本书 / 长按默认"
        local function choice(text,key,value)
            local function apply(default)
                if not self:set_panel_option(key,value,default) then return false end
                return show_section("panel_view")
            end
            return {text=text,callback=self:_callback("book panel view",function() return apply(false) end,false),
                hold_callback=self:_callback("default panel view",function() return apply(true) end,false)}
        end
        local views={context="保留周边",cut="独立格",free="自由视图"}
        local view=self.reader_settings.panel_view or "context"
        local next_view=view=="context" and "cut" or view=="cut" and "free" or "context"
        local rotation=self.reader_settings.panel_rotation or 0
        local zoom=self.panel_session and self.panel_session.render_options.zoom or 1
        actions={
            choice("视图："..views[view],"panel_view",next_view),
            choice(("旋转：%d° ↻"):format(rotation),"panel_rotation",(rotation+90)%360),
            action(("放大：%.2f 倍 +"):format(zoom),"zoom panel",function()
                if self.panel_session then self.panel_session:zoom(1.25) end;return show_section("panel_view")
            end),
            action("缩小 −","unzoom panel",function()
                if self.panel_session then self.panel_session:zoom(1/1.25) end;return show_section("panel_view")
            end),
            choice(self.reader_settings.panel_navigation=="vertical" and "导航：上下" or "导航：左右",
                "panel_navigation",self.reader_settings.panel_navigation=="vertical" and "horizontal" or "vertical"),
            choice(self.reader_settings.panel_reverse_navigation and "操作方向：反向" or "操作方向：正向",
                "panel_reverse_navigation",not self.reader_settings.panel_reverse_navigation),
            choice(self:_panel_direction()=="manga" and "顺序：右到左" or "顺序：左到右",
                "panel_order",self:_panel_direction()=="manga" and "normal" or "manga"),
            action("退出分格 → 整页","exit panel view",function() return self:exit_panel_mode() end),
            action("继续看当前格","resume panel view",show_current_page),
            action("漫画阅读设置","open panel settings",function() return show_section("root") end),
        }
    elseif section == "reading" then
        title = "阅读翻页"
        actions = {
            action(self.direction == "manga" and "方向：日漫反向" or "方向：普通",
                "toggle reading direction", function()
                    return persist_and_reopen("reading", function()
                        return self:set_direction(self.direction == "normal" and "manga" or "normal")
                    end)
                end),
            action(self.animation_enabled and "原生动画：开" or "原生动画：关",
                "toggle page animation", function()
                    return persist_and_reopen("reading", function()
                        return self:set_animation_enabled(not self.animation_enabled)
                    end)
                end),
            action(self.full_refresh_each_page and "每页完全刷新：开" or "每页完全刷新：关",
                "toggle full page refresh", function()
                    return persist_and_reopen("reading", function()
                        return self:set_full_refresh_each_page(not self.full_refresh_each_page)
                    end)
                end),
            action((self.show_preprocess_success and "处理成功提示：开" or "处理成功提示：关"),
                "toggle processed page status", function()
                    return persist_and_reopen("reading", function()
                        return self:set_show_preprocess_success(not self.show_preprocess_success)
                    end)
                end),
            action("继续阅读", "return to manga page", show_current_page),
            action("← 返回设置", "back to reader settings", function()
                return show_section("root")
            end),
        }
    elseif section == "display" then
        title = "图片显示"
        local fit_label = self.fit_mode == "page" and "整页"
            or self.fit_mode == "width" and "适宽" or self.fit_mode == "webtoon" and "长条连续阅读" or "调整匹配"
        local function cycle(key, choices)
            local selected = 1
            for i, value in ipairs(choices) do
                if self.reader_settings[key] == value then selected = i % #choices + 1; break end
            end
            local values = copy_table(self.reader_settings)
            values[key] = choices[selected]
            if not self:_persist_reader(values) then return false end
            self:_restart_processed_page()
            return show_section("display")
        end
        local function bubble_setting(key, choices)
            local values = copy_table(self.reader_settings)
            local selected = 1
            for i, value in ipairs(choices) do
                if values[key] == value then selected = i % #choices + 1; break end
            end
            values[key] = choices[selected]
            if not self:_persist_reader(values) then return false end
            return show_section("display")
        end
        actions = {
            action(self.reader_settings.bubble_zoom_enabled == true and "气泡放大：开" or "气泡放大：关",
                "toggle bubble zoom", function() return bubble_setting("bubble_zoom_enabled",{true,false}) end),
            action(self.reader_settings.bubble_zoom_trigger == "tap" and "气泡手势：单指点按" or "气泡手势：单指长按",
                "cycle bubble trigger", function() return bubble_setting("bubble_zoom_trigger",{"hold","tap"}) end),
            action(("气泡倍率：%.1f 倍"):format(self.reader_settings.bubble_zoom_scale or 2),
                "cycle bubble scale", function() return bubble_setting("bubble_zoom_scale",{1.5,2,3}) end),
            action("显示：" .. fit_label,
                "toggle fit mode", function() return self:onDoubleTap() end),
            action("阅读背景：" .. (self.reader_settings.display_background == "black" and "黑色"
                or self.reader_settings.display_background == "white" and "白色" or "自动黑白"),
                "cycle display background", function() return cycle("display_background",{"auto","white","black"}) end),
            action(self.reader_settings.webtoon_smart_enabled ~= false and "长条智能翻屏：开" or "长条智能翻屏：关",
                "toggle smart strip", function() return cycle("webtoon_smart_enabled",{true,false}) end),
            action(("长条重叠：%d%%"):format(self.reader_settings.webtoon_overlap_percent or 5),
                "cycle strip overlap", function() return cycle("webtoon_overlap_percent",{0,5,10,15,20}) end),
            action(("长条最多适高：%d%%"):format(self.reader_settings.webtoon_fit_percent or 5),
                "cycle strip fit", function() return cycle("webtoon_fit_percent",{0,5,10,15}) end),
            action(("长条总边距：%d%%"):format(self.reader_settings.webtoon_margin_percent or 0),
                "cycle strip margin", function() return cycle("webtoon_margin_percent",{0,5,10,15,20}) end),
            action("返回漫画列表", "close reader controls", function()
                return self:force_close("controls_return")
            end),
            action(self.show_progress_bar and "顶部进度条：开" or "顶部进度条：关",
                "toggle progress bar", function()
                    return persist_and_reopen("display", function()
                        return self:set_show_progress_bar(not self.show_progress_bar)
                    end)
                end),
            action(("进度条厚度：%d 倍"):format(self.progress_bar_thickness),
                "adjust progress bar thickness", function()
                    local next_value = self.progress_bar_thickness + 1
                    if next_value > 4 then next_value = 1 end
                    return persist_and_reopen("display", function()
                        return self:set_progress_bar_thickness(next_value)
                    end)
                end),
            action("继续阅读", "return to manga page", show_current_page),
            action("← 返回设置", "back to reader settings", function()
                return show_section("root")
            end),
            action("前光与色温", "open light settings", function()
                if type(self.show_light_settings) ~= "function" then return false end
                return self.show_light_settings()
            end),
        }
    elseif section == "split" then
        title = "宽图拆分"
        actions = {
            action(self.reader_settings.split_enabled and "自动拆分：开" or "自动拆分：关",
                "toggle split pages", function()
                    local values = copy_table(self.reader_settings)
                    values.split_enabled = not values.split_enabled
                    if self:_persist_reader(values) and self.position then
                        self:request_page(self.position.index, "whole")
                    end
                    return true
                end),
            action(("最小比例 %.2f"):format(self.reader_settings.split_min_ratio or 1.20),
                "adjust split minimum", function()
                    return self:show_ratio_input("split_min_ratio")
                end),
            action(("最大比例 %.2f"):format(self.reader_settings.split_max_ratio or 2.20),
                "adjust split maximum", function()
                    return self:show_ratio_input("split_max_ratio")
                end),
            action(("左右切分 %d%%"):format(self.reader_settings.split_cut_percent or 50),
                "adjust split position", function() return self:show_split_cut_input() end),
            action((self.reader_settings.split_first_segment == "right"
                and "拆分首屏：右边" or "拆分首屏：左边"),
                "toggle split first segment", function()
                    local next_segment = self.reader_settings.split_first_segment == "right"
                        and "left" or "right"
                    return self:set_split_first_segment(next_segment)
                end),
            action("继续阅读", "return to manga page", show_current_page),
            action("← 返回设置", "back to reader settings", function()
                return show_section("root")
            end),
        }
    elseif section == "panel" then
        title = "智能分格阅读"
        local function update_panel(key, value,make_default)
            return persist_and_reopen("panel", function()
                return self:set_panel_option(key,value,make_default)
            end)
        end
        local function panel_action(text,stage,callback)
            local value=action(text,stage,function() return callback(false) end)
            value.hold_callback=self:_callback(stage.." default",function() return callback(true) end,false)
            return value
        end
        local function next_panel_value(key, choices, fallback,make_default)
            local current = self.reader_settings[key]
            for index, value in ipairs(choices) do
                if value == current then
                    return update_panel(key, choices[index % #choices + 1],make_default)
                end
            end
            return update_panel(key, fallback or choices[1],make_default)
        end
        local standard_margin = self.reader_settings.panel_standard_margin_percent or 0
        local hold_margin = self.reader_settings.panel_hold_margin_percent or 5
        local initial_zoom = self.reader_settings.panel_initial_zoom or 1.2
        actions = {
            action("分格视图、旋转与方向","open panel view controls",function() return show_section("panel_view") end),
            panel_action(self.reader_settings.panel_zoom_enabled == true
                    and "智能分格：开启" or "智能分格：关闭",
                "toggle panel zoom", function(make_default)
                    return update_panel("panel_zoom_enabled",
                        self.reader_settings.panel_zoom_enabled ~= true,make_default)
                end),
            panel_action(self:_panel_direction() == "manga" and "分格顺序：右到左" or "分格顺序：左到右",
                "toggle panel direction", function(make_default)
                    return update_panel("panel_order",self:_panel_direction()=="normal" and "manga" or "normal",make_default)
                end),
            panel_action(self.reader_settings.panel_show_adjacent ~= false
                    and "显示相邻内容：开启" or "显示相邻内容：关闭",
                "toggle adjacent panel content", function(make_default)
                    return update_panel("panel_show_adjacent",
                        self.reader_settings.panel_show_adjacent == false,make_default)
                end),
            panel_action(("普通分格边距：%d%%"):format(standard_margin),
                "cycle standard panel margin", function(make_default)
                    return next_panel_value("panel_standard_margin_percent", { 0, 2, 5, 10 }, 0,make_default)
                end),
            panel_action(("自由缩放边距：%d%%"):format(hold_margin),
                "cycle hold panel margin", function(make_default)
                    return next_panel_value("panel_hold_margin_percent", { 2, 5, 10, 15, 20 }, 5,make_default)
                end),
            panel_action(("自由缩放倍率：%.1f 倍"):format(initial_zoom),
                "cycle initial panel zoom", function(make_default)
                    return next_panel_value("panel_initial_zoom", { 1.0, 1.2, 1.5, 2.0 }, 1.2,make_default)
                end),
            action("继续阅读", "return to manga page", show_current_page),
            action("← 返回设置", "back to reader settings", function()
                return show_section("root")
            end),
        }
    elseif section == "crop" then
        title = "裁切白边"
        actions = {
            action(self.reader_settings.auto_crop_enabled and "自动裁白边：开" or "自动裁白边：关",
                "toggle auto crop", function()
                    return self:set_auto_crop_enabled(not self.reader_settings.auto_crop_enabled)
                end),
            action(("识别强度 %d%%"):format(
                Reader.crop_strength_from_threshold(self.reader_settings.auto_crop_threshold)),
                "adjust auto crop strength", function()
                    return self:show_crop_input("auto_crop_strength")
                end),
            action(("每侧最多裁切 %d%%"):format(
                clamp(tonumber(self.reader_settings.auto_crop_max_percent) or 15, 0, 30)),
                "adjust auto crop maximum", function()
                    return self:show_crop_input("auto_crop_max_percent")
                end),
            action("继续阅读", "return to manga page", show_current_page),
            action("← 返回设置", "back to reader settings", function()
                return show_section("root")
            end),
        }
    elseif section == "gray" then
        title = "漫画去灰增强"
        local enabled = self.reader_settings.gray_enhance_enabled == true
        actions = {
            action("去灰增强总开关：" .. (enabled and "开启" or "关闭"),
                "toggle gray enhancement", function()
                    if not self:set_gray_enhance_enabled(not enabled) then return false end
                    return show_section("gray")
                end),
        }
        local enhancer = self.gray_enhance or GrayEnhance
        local presets = type(enhancer.all_presets) == "function"
            and enhancer.all_presets(self.reader_settings.gray_enhance_custom_presets)
            or {}
        local selected = self.reader_settings.gray_enhance_preset or "original"
        for _, preset in ipairs(presets) do
            local current = preset
            actions[#actions + 1] = action(
                (current.id == selected and "● " or "○ ") .. tostring(current.name),
                "select gray enhancement " .. tostring(current.id), function()
                    if not self:set_gray_enhance_preset(current.id) then return false end
                    return show_section("gray")
                end)
        end
        if type(self.show_gray_settings) == "function" then
            actions[#actions + 1] = action("管理自定义预设", "manage gray enhancement presets", function()
                return self.show_gray_settings()
            end)
        end
        actions[#actions + 1] = action("继续阅读", "return to manga page", show_current_page)
        actions[#actions + 1] = action("← 返回设置", "back to reader settings", function()
            return show_section("root")
        end)
    elseif section == "tone" then
        title = "亮度与对比度"
        local enabled = self.reader_settings.tone_adjust_enabled == true
        actions = {
            action("亮度与对比度总开关：" .. (enabled and "开启" or "关闭"),
                "toggle tone adjustment", function()
                    if not self:set_tone_adjust_enabled(not enabled) then return false end
                    return show_section("tone")
                end),
        }
        local adjuster = self.tone_adjust or ToneAdjust
        local presets = type(adjuster.all_presets) == "function"
            and adjuster.all_presets(self.reader_settings.tone_adjust_custom_presets)
            or {}
        local selected = self.reader_settings.tone_adjust_preset or "original"
        for _, preset in ipairs(presets) do
            local current = preset
            actions[#actions + 1] = action(
                (current.id == selected and "● " or "○ ") .. tostring(current.name),
                "select tone adjustment " .. tostring(current.id), function()
                    if not self:set_tone_adjust_preset(current.id) then return false end
                    return show_section("tone")
                end)
        end
        if type(self.show_tone_settings) == "function" then
            actions[#actions + 1] = action("管理自定义预设",
                "manage tone adjustment presets", function()
                    return self.show_tone_settings()
                end)
        end
        actions[#actions + 1] = action("继续阅读", "return to manga page", show_current_page)
        actions[#actions + 1] = action("← 返回设置", "back to reader settings", function()
            return show_section("root")
        end)
    else
        section = "root"
        title = "阅读设置"
        actions = {
            action("阅读翻页", "open reading settings", function()
                return show_section("reading")
            end),
            action("图片显示", "open display settings", function()
                return show_section("display")
            end),
            action("宽图拆分", "open split settings", function()
                return show_section("split")
            end),
            action("裁切白边", "open crop settings", function()
                return show_section("crop")
            end),
            action("智能分格阅读", "open dynamic panel settings", function()
                return show_section("panel")
            end),
            action("漫画去灰增强", "open gray enhancement settings", function()
                return show_section("gray")
            end),
            action("亮度与对比度", "open tone adjustment settings", function()
                return show_section("tone")
            end),
            action("跳转图片", "open page picker", function()
                return self:show_page_picker()
            end),
            action("继续阅读", "return to manga page", show_current_page),
            action("返回漫画列表", "close reader controls", function()
                return self:force_close("controls_return")
            end),
        }
        if type(self.open_history) == "function" then
            actions[#actions + 1] = action("阅读历史", "open history from reader", function()
                self.return_to = self.open_history
                return self:force_close("open_history")
            end)
        end
        if type(self.show_reader_help) == "function" then
            actions[#actions + 1] = action("漫画阅读说明", "show manga instructions", self.show_reader_help)
        end
        if type(self.open_category_shelf) == "function" then
            actions[#actions + 1] = action("漫画分类架", "open category shelf from reader", function()
                self.return_to = self.open_category_shelf
                return self:force_close("open_category_shelf")
            end)
        end
        if type(self.show_network_settings) == "function" then
            actions[#actions + 1] = action("网络加载", "open network settings from reader", function()
                return self.show_network_settings()
            end)
        end
        local navigation = self.context.source_context and self.context.source_context.navigation
        if navigation and navigation.current then
            for _, direction in ipairs({ "previous", "next" }) do
                local selected = direction
                local target = navigation.current[selected]
                if target then
                    actions[#actions + 1] = action((selected == "next" and "下一章：" or "上一章：")
                        .. tostring(target.chapter_name or target.name), "open series " .. selected,
                        function() return self:_open_neighbor(selected) end)
                end
            end
            if navigation.current.next then
                actions[#actions + 1] = action("读完自动打开下一章：" .. (self.auto_next_series and "开" or "关"),
                    "toggle auto next chapter", function()
                        self.auto_next_series = not self.auto_next_series
                        return show_section("root")
                    end)
            end
        end
    end
    local segment = self.position and self.position.segment or "whole"
    local model = {
        title = title,
        message = title,
        section = section,
        columns = 2,
        index = self.position and self.position.index or 1,
        total = self:_count(),
        segment = segment,
        fit_mode = self.fit_mode,
        direction = self.direction,
        animation_enabled = self.animation_enabled,
        full_refresh_each_page = self.full_refresh_each_page,
        show_progress_bar = self.show_progress_bar,
        progress_bar_thickness = self.progress_bar_thickness,
        auto_crop_enabled = self.reader_settings.auto_crop_enabled == true,
        auto_crop_strength = Reader.crop_strength_from_threshold(
            self.reader_settings.auto_crop_threshold),
        auto_crop_max_percent = self.reader_settings.auto_crop_max_percent,
        split_enabled = self.reader_settings.split_enabled,
        split_min_ratio = self.reader_settings.split_min_ratio,
        split_max_ratio = self.reader_settings.split_max_ratio,
        split_cut_percent = self.reader_settings.split_cut_percent,
        split_first_segment = self.reader_settings.split_first_segment,
        gray_enhance_enabled = self.reader_settings.gray_enhance_enabled == true,
        gray_enhance_preset = self.reader_settings.gray_enhance_preset,
        gray_enhance_custom_presets = self.reader_settings.gray_enhance_custom_presets,
        tone_adjust_enabled = self.reader_settings.tone_adjust_enabled == true,
        tone_adjust_preset = self.reader_settings.tone_adjust_preset,
        tone_adjust_custom_presets = self.reader_settings.tone_adjust_custom_presets,
        actions = actions,
        on_jump = self:_callback("jump from reader controls", function()
            return self:show_page_picker()
        end, false),
        on_toggle_fit = self:_callback("fit from reader controls", function()
            return self:onDoubleTap()
        end, false),
        on_toggle_direction = self:_callback("direction from reader controls", function()
            return self:set_direction(self.direction == "normal" and "manga" or "normal")
        end, false),
        on_close = self:_callback("close from reader controls", function()
            return self:force_close("controls_return")
        end, true),
    }
    if self.ui.show_controls then return self.ui:show_controls(model) end
    return self.shell:show_controls(model)
end

function Reader:_cleanup_call(stage, callback)
    return self:_silent("close_reader_" .. stage, callback)
end

function Reader:_schedule_cleanup(callback, detached_shell)
    if type(self.ui.schedule) == "function" then
        local ok, result = pcall(self.ui.schedule, self.ui, callback)
        if ok and result ~= false then return true end
    end
    local scheduler = detached_shell or self.shell
    if scheduler and scheduler.scheduler
        and type(scheduler.scheduler.scheduleIn) == "function" then
        local ok, result = pcall(scheduler.scheduler.scheduleIn,
            scheduler.scheduler, 0, callback)
        if ok and result ~= false then return true end
    end
    callback()
    return true
end

function Reader:force_close(source)
    self:_reset_quadrant_zoom("close")
    local teardown_source = source == "plugin_teardown" or source == "connection_switch"
        or source == "reopen"
    if self.closing then
        if teardown_source and self.close_control then
            self.close_control.suppress_return = true
        end
        return true
    end
    self.closing = true
    self:_close_webtoon()
    local close_control = { suppress_return = teardown_source }
    self.close_control = close_control
    self.request_serial = self.request_serial + 1
    local shell = self.shell
    local generation = self.generation
    local buffer = self.page_buffer
    local return_to = self.return_to
    local source_context = self.context and self.context.source_context
    local stream_state = self.context and self.context.stream_state
    if stream_state and stream_state.on_index_growth == self.stream_index_growth_callback then
        stream_state.on_index_growth = nil
    end
    self.stream_index_growth_callback = nil
    if source_context and type(source_context.on_close) == "function" then
        self:_silent("close_source_tasks", function() return source_context.on_close(source) end)
    end
    local panel_session = self.panel_session
    self.panel_session, self.panel_entry, self.panel_resume, self.panel_restore = nil, nil, nil, nil
    local return_to_root = self.return_to_root
    self.shell = nil
    self.viewer = nil
    self.viewer_shown = false
    self.generation = nil
    self.page_buffer = nil
    self.page_crop = nil
    self.page_dimensions = nil
    self.page_viewport = nil
    self.page_path = nil
    self.page_metadata = nil
    self.position = nil
    self.current_index = nil
    self.pending_request = nil
    self.prepared_cache_keys = {}
    self.context = nil
    self.return_to = nil

    local closed = false
    if type(self.ui.close_shell) == "function" then
        local ok, result = pcall(self.ui.close_shell, self.ui, shell)
        closed = ok and result ~= false
    end
    if not closed and shell and type(shell.close_now) == "function" then
        pcall(shell.close_now, shell)
    end

    local function cleanup()
        if panel_session then
            self:_cleanup_call("panel_session", function() return panel_session:close() end)
        end
        local page_source = self.prepared_pages or self.loader
        if generation and page_source.cancel_generation then
            self:_cleanup_call("cancel", function()
                return page_source:cancel_generation(generation)
            end)
        end
        if generation and self.memory_pages
            and type(self.memory_pages.cancel_generation) == "function" then
            self:_cleanup_call("cancel_memory", function()
                return self.memory_pages:cancel_generation(generation)
            end)
        end
        if generation and self.opds_pages
            and type(self.opds_pages.cancel_generation) == "function" then
            self:_cleanup_call("cancel_opds_memory", function()
                return self.opds_pages:cancel_generation(generation)
            end)
        end
        if buffer and type(buffer.free) == "function" then
            self:_cleanup_call("free_buffer", function()
                -- Let the detached shell schedule the actual free when it has
                -- a UI-aware deferral hook; host shells may fall back to the
                -- direct free below.
                return release_buffer(shell, buffer)
            end)
        end

        -- The callback may run after a new Reader:open. In that case the
        -- captured generation no longer belongs to the active state; do not
        -- leave it, clear the new cache lease, or invoke its return callback.
        local state_matches = false
        if generation and type(self.state.is_current) == "function" then
            local ok, matches = pcall(self.state.is_current, self.state, generation)
            state_matches = ok and matches == true
        end
        local owns_closed_session = state_matches and self.generation == nil
            and self.context == nil
        if owns_closed_session and self.state.leave_chapter then
            self:_cleanup_call("leave_state", function()
                return self.state:leave_chapter()
            end)
        end
        if owns_closed_session then
            self:_cleanup_call("unprotect", function()
                return self.cache:set_protected({})
            end)
        end
        if owns_closed_session and not close_control.suppress_return then
            if return_to then
                local returned, return_error = pcall(return_to)
                if not returned then
                    self:_cleanup_call("return", function()
                        error(return_error, 0)
                    end)
                    if return_to_root then
                        self:_cleanup_call("return_fallback", return_to_root)
                    end
                end
            elseif return_to_root then
                self:_cleanup_call("return_root", return_to_root)
            end
        end
        if self.close_control == close_control then self.close_control = nil end
    end
    self:_schedule_cleanup(cleanup, shell)
    return true
end

function Reader:onClose()
    return self:force_close("back")
end

return Reader
