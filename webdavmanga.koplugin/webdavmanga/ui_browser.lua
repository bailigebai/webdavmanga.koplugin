local Errors = require("webdavmanga.errors")
local Cover = require("webdavmanga.cover")
local Formats = require("webdavmanga.image_formats")
local Path = require("webdavmanga.path")
local SafeCallback = require("webdavmanga.safe_callback")

-- Keep the shelf usable even if an older installation is missing the optional
-- generated index; the small built-in table below remains a safe fallback.
local PinyinInitials = {}
do
    local ok, map = pcall(require, "webdavmanga.pinyin_initials")
    if ok and type(map) == "table" then PinyinInitials = map end
end

local Browser = {}
Browser.__index = Browser

function Browser.select_menu_action(item, position)
    local callback
    local cache_start = tonumber(item.cache_start) or 0.50
    local secondary_start = tonumber(item.secondary_start) or 0.70
    if item.secondary_callback and position and position.x >= secondary_start then
        callback = item.secondary_callback
    elseif item.cache_callback and position and position.x >= cache_start then
        callback = item.cache_callback
    elseif item.callback then
        callback = item.callback
    end
    if callback then pcall(callback) end
    return true
end

local function noop_handle() return { cancel = function() end } end
local function identity(connection)
    connection = connection or {}
    local kind = tostring(connection.kind or "webdav")
    local user = tostring(connection.username or ""):match("^%s*(.-)%s*$")
    return table.concat({ kind, tostring(connection.server_url or ""), user,
        Path.normalize_remote(connection.root_path or ""),
        Path.normalize_remote(connection.local_path or "") }, "\0")
end
local function parent_path(path, root)
    path, root = Path.normalize_remote(path), Path.normalize_remote(root)
    if path == root then return root end
    local parent = path:match("^(.*)/[^/]+$") or "/"; if parent == "" then parent = "/" end
    if root ~= "/" and parent ~= root and parent:sub(1, #root + 1) ~= root .. "/" then return root end
    return parent
end
local function directory_index(directory, kind)
    if type(directory) ~= "table" then return nil end
    local value = directory[kind]
    return type(value) == "function" and directory[kind](directory) or value
end

local function default_ui()
    local ConfirmBox = require("ui/widget/confirmbox"); local InfoMessage = require("ui/widget/infomessage")
    local Menu = require("ui/widget/menu"); local UIManager = require("ui/uimanager")
    local adapter = { current_menu = nil }
    local function guarded(label, callback, fallback)
        if type(callback) ~= "function" then
            return function() return fallback end
        end
        return SafeCallback.wrap(adapter, label, callback, fallback)
    end
    local function invoke(label, callback)
        local result = guarded(label, callback, true)()
        -- KOReader treats a false callback result as an unhandled input
        -- event.  Actions in this adapter are already guarded and must
        -- consume the tap even when their business operation fails.
        return result == nil and true or (result == false and true or result)
    end
    function adapter:show_info(message) UIManager:show(InfoMessage:new{ text = message, timeout = 3 }) end
    function adapter:show_busy(message)
        local widget = InfoMessage:new{ text = message }; UIManager:show(widget); return { close = function() UIManager:close(widget) end }
    end
    function adapter:show_progress(model)
        local ok_dialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
        local ok_progress, ProgressWidget = pcall(require, "ui/widget/progresswidget")
        local ok_device, Device = pcall(require, "device")
        if not ok_dialog or not ok_progress or not ok_device then
            return self:show_busy(model.subtitle or model.title)
        end
        local screen = Device.screen
        local progress = ProgressWidget:new{
            width = math.floor(math.min(screen:getWidth(), screen:getHeight()) * 0.75),
            height = screen:scaleBySize(18),
            percentage = 0,
        }
        local widget
        local closed = false
        local function close()
            if closed then return end
            closed = true
            UIManager:close(widget)
        end
        local function cancel()
            close()
            if type(model.on_cancel) == "function" then pcall(model.on_cancel) end
            return true
        end
        widget = ButtonDialog:new{
            title = tostring(model.title or "") .. "\n" .. tostring(model.subtitle or ""),
            width_factor = 0.9,
            dismissable = false,
            _added_widgets = { progress },
            buttons = {{ { text = "取消打开", callback = cancel } }},
        }
        UIManager:show(widget)
        local current_stage
        local stage_titles = { index = "正在建立页面目录", first_page = "正在验证第一页",
            fallback = "正在切换为完整下载", download = "正在下载完整书籍" }
        return {
            update = function(_self, event)
                if closed then return end
                local stage = type(event) == "table" and event.stage
                if stage_titles[stage] and stage ~= current_stage and widget.setTitle then
                    current_stage = stage
                    pcall(widget.setTitle, widget, stage_titles[stage] .. "\n" .. tostring(model.subtitle or ""))
                end
                local value = type(event) == "table" and event.progress or event
                pcall(progress.setPercentage, progress,
                    math.max(0, math.min(1, tonumber(value) or 0)))
                pcall(UIManager.setDirty, UIManager, widget, "ui")
            end,
            close = close,
            cancel = cancel,
        }
    end
    function adapter:confirm(model)
        UIManager:show(ConfirmBox:new{ text = model.text, ok_callback = model.on_confirm,
            cancel_callback = model.on_cancel })
    end
    function adapter:close_menu()
        local menu = self.current_menu
        self.current_menu = nil
        if not menu then return end
        menu.skip_close_callback = true
        UIManager:close(menu)
    end
    function adapter:show_menu(model)
        self:close_menu()
        local menu
        local function route_back()
            if menu and menu.skip_close_callback then return true end
            if self.current_menu == menu then self.current_menu = nil end
            if model.on_back then return invoke("menu close callback", model.on_back) end
            return true
        end
        local function route_close()
            if menu and menu.skip_close_callback then return true end
            if model.on_close then
                return invoke("menu title close callback", model.on_close)
            end
            return route_back()
        end
        local items = {}
        for _, item in ipairs(model.items or {}) do
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            if copy.callback then copy.callback = guarded("menu action", copy.callback, true) end
            if copy.secondary_callback then
                copy.secondary_callback = guarded("menu secondary action", copy.secondary_callback, true)
            end
            if copy.cache_callback then
                copy.cache_callback = guarded("menu cache action", copy.cache_callback, true)
            end
            items[#items + 1] = copy
        end
        if not model.fixed_actions and model.on_refresh then
            items[#items + 1] = {
                text = "↻ 刷新", separator = true,
                callback = guarded("refresh menu", model.on_refresh, true),
            }
        end
        if not model.fixed_actions and model.on_back then
            items[#items + 1] = {
                text = model.back_text or "← 返回上一级", separator = true,
                callback = guarded("back menu", model.on_back, true),
            }
        end
        local shared_font_size
        if model.equal_column_font then
            local perpage = G_reader_settings
                and G_reader_settings:readSetting("items_per_page") or 14
            shared_font_size = G_reader_settings
                and G_reader_settings:readSetting("items_font_size")
                or Menu.getItemFontSize(perpage or 14)
        end
        local custom_title_bar
        if model.on_toggle_view then
            custom_title_bar=require("webdavmanga.bookshelf_toolbar").new({
                title=model.title,subtitle=model.subtitle,view_mode=model.view_mode,
                on_switch_connection=function() return invoke("switch bookshelf connection",model.on_switch_connection) end,
                on_toggle_view=function() return invoke("toggle bookshelf view",model.on_toggle_view) end,
                on_close=route_close,
            })
        end
        menu = Menu:new{ title = model.title, subtitle = model.subtitle,
            custom_title_bar=custom_title_bar,
            -- A popout menu leaves rounded transparent corners.  On Kindle
            -- those corners can reveal a stale KOReader status-bar clock.
            is_popout = false,
            covers_fullscreen = true,
            title_bar_left_icon = model.on_switch_connection and "appbar.menu" or nil,
            items_font_size = shared_font_size,
            items_mandatory_font_size = shared_font_size,
            item_table = items, single_line = true,
            close_callback = route_back,
            onMenuSelect = function(_menu, item, position)
                local cache_start = tonumber(item.cache_start) or 0.50
                local secondary_start = tonumber(item.secondary_start) or 0.70
                if item.secondary_callback and position and position.x >= secondary_start then
                    return invoke("menu secondary action", item.secondary_callback)
                elseif item.cache_callback and position and position.x >= cache_start then
                    return invoke("menu cache action", item.cache_callback)
                elseif item.callback then
                    return invoke("menu action", item.callback)
                end
                return true
            end }
        if model.on_close and menu.title_bar then
            -- KOReader's stock Menu routes both the hardware Back key and the
            -- title-bar X through Menu:onClose().  Keep Back on route_back,
            -- while giving the visible X its own close-plugin confirmation.
            menu.title_bar.close_callback = route_close
            menu.title_bar.right_icon_tap_callback = route_close
            if menu.title_bar.right_button then
                menu.title_bar.right_button.callback = route_close
            end
        end
        if model.on_switch_connection then
            menu.onLeftButtonTap = function()
                return invoke("switch bookshelf connection", model.on_switch_connection)
            end
        end
        self.current_menu = menu
        self.current_model = model
        if model.initial_item_id then
            for position,item in ipairs(items) do
                if item.id==model.initial_item_id then
                    menu.page=menu:getPageNumber(position);menu.itemnumber=position
                    menu:updateItems();break
                end
            end
        end
        UIManager:show(menu)
    end
    function adapter:get_anchor()
        local menu=self.current_menu
        if not menu then return nil end
        local first=((menu.page or 1)-1)*(menu.perpage or 14)+1
        for i=first,math.min(#menu.item_table,first+(menu.perpage or 14)-1) do
            if menu.item_table[i].id then return menu.item_table[i].id end
        end
    end
    return adapter
end

function Browser:new(deps)
    deps = deps or {}; local o = setmetatable({}, self)
    o.settings = assert(deps.settings, "settings is required"); o.settings_ui = assert(deps.settings_ui, "settings UI is required")
    o.directory_store = assert(deps.directory_store, "directory store is required")
    o.ui = deps.ui or default_ui(); o.error_reporter = deps.error_reporter
    o.network_manager = deps.network_manager or { willRerunWhenConnected = function() return false end }
    o.open_reader = assert(deps.open_reader, "reader callback is required"); o.open_document = deps.open_document; o.progress = deps.progress or { list_history = function() return {} end, remove_history = function() end }
    o.premium_access = deps.premium_access
    o.request_license = deps.request_license
    o.cover_grid = deps.cover_grid; o.library = deps.library
    o.bookshelf_grid=deps.bookshelf_grid
    o.bookshelf_directory_store=deps.bookshelf_directory_store
    o.on_bookshelf_refresh=deps.on_bookshelf_refresh
    o.bookshelf_anchors={}
    o.document_cache = deps.document_cache
    o.opds_cover = deps.opds_cover
    o.manage_history = deps.manage_history
    o.manage_history_batch = deps.manage_history_batch
    o.cache_manga = deps.cache_manga or function()
        o.ui:show_info("整部漫画缓存尚未初始化。")
        return false
    end
    o.cache_document = deps.cache_document or function()
        o.ui:show_info("文档缓存尚未初始化。")
        return false
    end
    o.open_category_shelf = deps.open_category_shelf or function() o.ui:show_info("漫画分类架尚未初始化。") end
    o.open_rating_shelf = deps.open_rating_shelf or function() o.ui:show_info("漫画评分架尚未初始化。") end
    o.open_offline_shelf = deps.open_offline_shelf or function() o.ui:show_info("缓存漫画书架尚未初始化。") end
    o.open_opds_record = deps.open_opds_record
    o.current_path = o:_saved_browser_path(); o.return_paths = {}; o.manga_return_paths = o.return_paths; o.page_models = {}; o.active_directories = {}
    o.active_handle, o.active_busy, o.active_document_progress,
        o.request_generation, o.session_epoch = nil, nil, nil, 0, 0
    o.session_identity = identity(o.settings:get_connection()); o.last_library_items, o.last_directory_items, o.last_chapter_items = nil, {}, {}
    o.cache_mode_enabled = false
    return o
end

function Browser:_premium_gate(action, manga, continuation)
    local access = self.premium_access
    local method = action == "cache" and "can_cache" or "can_open"
    if not access or type(access[method]) ~= "function" then
        if continuation then return continuation() end
        return true
    end
    local ok, allowed, reason = pcall(access[method], access, manga)
    if ok and allowed == true then
        if continuation then return continuation() end
        return true
    end
    local resume_called = false
    local function resume_once()
        if resume_called then return end
        resume_called = true
        if continuation then return continuation() end
    end
    if type(self.request_license) == "function" then
        local request = self.request_license(resume_once)
        self._last_license_request = request
        return false
    end
    if self.ui and type(self.ui.show_info) == "function" then
        self.ui:show_info("此功能需要增值版授权（当前原因："
            .. tostring(reason or "license_required") .. "）。\n"
            .. "咸鱼搜索：kindle推箱子，找到傅俊康，购买增值版漫画功能。"
            .. "可以关闭弹窗后删除漫画到5本以内，继续看。")
    end
    return false
end
function Browser:_saved_browser_path()
    if type(self.settings.get_browser_path) == "function" then return self.settings:get_browser_path() end
    return self.settings:get_connection().root_path
end
function Browser:_set_browser_path(path)
    if type(self.settings.set_browser_path) == "function" then local ok = self.settings:set_browser_path(path); if not ok then return false end; if self.settings.flush then self.settings:flush() end end
    self.current_path = path; return true
end
function Browser:_callback(label, callback, fallback) return SafeCallback.wrap(self.error_reporter or self.ui, label, callback, fallback) end
function Browser:_path_is_allowed(path) return Path.is_within_remote(path, self.settings:get_connection().root_path) end
function Browser:_close_directories()
    for path, d in pairs(self.active_directories) do if d and d.close then pcall(d.close, d) end; self.active_directories[path] = nil end
end
function Browser:_close_except(paths)
    for path, d in pairs(self.active_directories) do
        if not paths[path] then if d and d.close then pcall(d.close, d) end; self.active_directories[path] = nil end
    end
end
function Browser:_begin_request(close_directories)
    if self.bookshelf_grid then self.bookshelf_grid:cancel() end
    self.request_generation = self.request_generation + 1
    if self.active_handle and self.active_handle.cancel then
        pcall(self.active_handle.cancel, self.active_handle)
    end
    self.active_handle = nil
    if close_directories then self:_close_directories() end
    return self.request_generation
end
function Browser:reset_session()
    self:cancel(); self:_close_directories(); self.page_models, self.last_directory_items, self.last_chapter_items = {}, {}, {}; self.last_library_items, self.return_paths = nil, {}
    self.current_path = self:_saved_browser_path(); self.manga_return_paths = self.return_paths; self.session_identity = identity(self.settings:get_connection()); self.session_epoch = self.session_epoch + 1
    self.bookshelf_anchors={}
end
function Browser:_ensure_session_identity() if identity(self.settings:get_connection()) == self.session_identity then return false end; self:reset_session(); return true end

function Browser:_load_directory(path, options, on_ready, on_error)
    local store = options and options.store or self.directory_store
    path = Path.normalize_remote(path); local old = self.active_directories[path]; if old and old.close then pcall(old.close, old); self.active_directories[path] = nil end
    local generation = self.request_generation
    local failure = type(on_error) == "function" and on_error or function() end
    if options and options.store then
        local cached=not options.refresh and store.lookup and store:lookup(path)
        if cached then
            if cached.acquire then cached:acquire() end
            self.active_directories[path]=cached;on_ready(cached)
            return {cancel=function() end}
        end
        if self.network_manager and type(self.network_manager.willRerunWhenConnected)=="function"
            and self.network_manager:willRerunWhenConnected(function()
                if generation==self.request_generation then self:_load_directory(path,options,on_ready,on_error) end
            end) then return end
    end
    local handle = store:load(path, { refresh = options and options.refresh, on_ready = self:_callback("directory ready", function(d)
        if generation ~= self.request_generation then if d.close then d:close() end; return end; self.active_directories[path] = d; on_ready(d)
    end), on_error = self:_callback("directory error", failure) })
    if generation == self.request_generation then
        self.active_handle = handle
    elseif handle and handle.cancel then
        pcall(handle.cancel, handle)
    end
    return handle
end
function Browser:cancel()
    self:_begin_request(false)
    if self.active_busy and self.active_busy.close then self.active_busy.close() end; self.active_busy = nil
    if self.active_document_progress then
        local action = self.active_document_progress.cancel
            or self.active_document_progress.close
        if type(action) == "function" then
            pcall(action, self.active_document_progress)
        end
    end
    self.active_document_progress = nil
end

function Browser:close_menu()
    if self.ui and type(self.ui.close_menu) == "function" then
        local ok = pcall(self.ui.close_menu, self.ui)
        return ok
    end
    return true
end

function Browser:_confirm_close_plugin()
    local function close_plugin_ui()
        self:cancel()
        self:_close_directories()
        self:close_menu()
        return true
    end
    if not self.ui or type(self.ui.confirm) ~= "function" then
        return close_plugin_ui()
    end
    self.ui:confirm{
        text = "确定关闭漫画插件吗？",
        on_confirm = self:_callback("confirm close manga plugin", close_plugin_ui, true),
    }
    return true
end

local function utf8_char(value, position)
    position = position or 1
    local first = value:byte(position)
    if not first then return "" end
    local length = first < 0x80 and 1
        or (first >= 0xC2 and first <= 0xDF and 2
            or (first >= 0xE0 and first <= 0xEF and 3
                or (first >= 0xF0 and first <= 0xF4 and 4 or 1)))
    return value:sub(position, position + length - 1)
end

-- Keep a small fallback table for older installations; unknown characters use
-- a stable final bucket when the generated index is unavailable.
local HAN_INITIAL = {
    ["阿"] = "a", ["啊"] = "a", ["爱"] = "a", ["安"] = "a",
    ["白"] = "b", ["百"] = "b", ["保"] = "b", ["北"] = "b",
    ["陈"] = "c", ["成"] = "c", ["春"] = "c", ["大"] = "d",
    ["帝"] = "d", ["东"] = "d", ["多"] = "d", ["方"] = "f",
    ["分"] = "f", ["高"] = "g", ["国"] = "g", ["好"] = "h",
    ["海"] = "h", ["和"] = "h", ["画"] = "h", ["回"] = "h",
    ["机"] = "j", ["家"] = "j", ["江"] = "j", ["金"] = "j",
    ["开"] = "k", ["可"] = "k", ["空"] = "k", ["来"] = "l",
    ["李"] = "l", ["连"] = "l", ["漫"] = "m", ["马"] = "m",
    ["南"] = "n", ["你"] = "n", ["女"] = "n", ["欧"] = "o",
    ["朋"] = "p", ["平"] = "p", ["其"] = "q", ["前"] = "q",
    ["群"] = "q", ["人"] = "r", ["日"] = "r", ["三"] = "s",
    ["山"] = "s", ["上"] = "s", ["生"] = "s", ["书"] = "s",
    ["天"] = "t", ["图"] = "t", ["王"] = "w", ["文"] = "w",
    ["我"] = "w", ["西"] = "x", ["下"] = "x", ["先"] = "x",
    ["小"] = "x", ["新"] = "x", ["学"] = "x", ["一"] = "y",
    ["已"] = "y", ["因"] = "y", ["英"] = "y", ["有"] = "y",
    ["张"] = "z", ["章"] = "z", ["这"] = "z", ["中"] = "z",
    ["子"] = "z", ["自"] = "z", ["做"] = "z", ["最"] = "z",
    ["第"] = "d", ["直"] = "z", ["读"] = "d", ["阅"] = "y",
    ["历"] = "l", ["史"] = "s", ["分"] = "f", ["类"] = "l",
}

local function folder_sort_key(value)
    local text = tostring(value or "")
    local parts, position = {}, 1
    while position <= #text do
        local digit = text:sub(position, position):match("%d")
        if digit then
            local number = text:sub(position):match("^%d+")
            -- Keep numeric runs natural while still allowing them to take
            -- part in a multi-character pinyin key (漫画 2 before 漫画 10).
            parts[#parts + 1] = "0" .. string.rep("0", math.max(0, 12 - #number))
                .. number .. "0"
            position = position + #number
        else
            local character = utf8_char(text, position)
            local initial = PinyinInitials[character] or HAN_INITIAL[character]
            if not initial then
                initial = character:match("^[%a]") and character:lower()
                    or (character:match("^%s") and " " or "{")
            end
            parts[#parts + 1] = initial
            position = position + #character
        end
    end
    local natural = text:lower():gsub("%d+", function(number)
        return string.rep("0", math.max(0, 12 - #number)) .. number
    end)
    return table.concat(parts) .. "\0" .. natural
end

local function sorted_index(index)
    local entries = {}
    local count = tonumber(index and index:count()) or 0
    for position = 1, count do
        local entry = index:get(position)
        if entry then entries[#entries + 1] = entry end
    end
    table.sort(entries, function(left, right)
        local lk, rk = folder_sort_key(left.name or left.path), folder_sort_key(right.name or right.path)
        if lk == rk then return tostring(left.path or "") < tostring(right.path or "") end
        return lk < rk
    end)
    return {
        count = function() return #entries end,
        get = function(_, position) return entries[position] end,
    }
end

Browser.folder_sort_key = folder_sort_key

local function page_entries(index, page, limit)
    local count = tonumber(index and index:count()) or 0; local first = ((page or 1) - 1) * limit + 1; local out = {}
    for i = first, math.min(count, first + limit - 1) do local e = index:get(i); if e then out[#out + 1] = e end end
    return out, count > first + limit - 1, first
end
function Browser:_directory_items(path, folder_index, page, image_index, document_index,
    direct_file_count)
    local root = Path.normalize_remote(self.settings:get_connection().root_path)
    local request_generation = self.request_generation
    local cache_enabled = self.cache_mode_enabled == true
    local items = {
        {
            text = "↻ 刷新", mandatory = cache_enabled and "已开缓存" or "开启缓存",
            mandatory_func = function() return cache_enabled and "已开缓存" or "开启缓存" end,
            secondary_start = 0.5,
            callback = self:_callback("refresh library", function()
                self:show_library(true, path)
            end),
            secondary_callback = self:_callback("toggle bookshelf cache mode", function()
                self.cache_mode_enabled = not self.cache_mode_enabled
                self:show_library(false, path)
                return true
            end),
        },
        {
            text = "阅读历史", mandatory = "缓存漫画",
            mandatory_func = function() return "缓存漫画" end,
            secondary_start = 0.5,
            callback = self:_callback("open reading history", function() self:show_history() end),
            secondary_callback = self:_callback("open offline manga shelf", function()
            if self.ui.close_menu then self.ui:close_menu() end
            self:_begin_request(true)
            return self.open_offline_shelf({ return_path = path })
            end),
        },
        {
            text = "漫画分类架", mandatory = "漫画评分架",
            mandatory_func = function() return "漫画评分架" end,
            secondary_start = 0.5,
            callback = self:_callback("open manga category shelf", function()
                self:_begin_request(true); self.open_category_shelf()
            end),
            secondary_callback = self:_callback("open manga rating shelf", function()
                self:_begin_request(true); self.open_rating_shelf()
            end),
        },
        { text = path == root and "← 退出漫画书架" or "← 返回上一级", callback = self:_callback("back from bookshelf", function() if path == root then if self.ui.close_menu then self.ui:close_menu() end else self:show_library(false, parent_path(path, root)) end end) },
    }
    local back_row_index = #items
    local folders, has_next, first = page_entries(sorted_index(folder_index), 1, math.max(1, tonumber(folder_index and folder_index:count()) or 1)); local epoch = self.session_epoch
    local image_count = tonumber(image_index and image_index:count()) or 0
    local document_count = tonumber(document_index and document_index:count()) or 0
    local file_count = tonumber(direct_file_count) or image_count + document_count
    local has_files = file_count > 0
    local current_folder_index
    if has_files then
        local current_folder = {
            name = path:match("([^/]+)$") or path,
            path = path,
            is_folder = true,
            direct_images = true,
        }
        items[#items + 1] = {
            text = image_count > 0 and document_count > 0
                and "当前文件夹（图片和文件）"
                or (image_count > 0 and "当前文件夹（图片）" or "当前文件夹（文件）"),
            id=current_folder.path,manga=current_folder,
            mandatory = cache_enabled and "缓存  进入漫画" or "进入漫画",
            mandatory_func = function()
                return cache_enabled and "缓存  进入漫画" or "进入漫画"
            end,
            callback = self:_callback("enter current manga", function()
                if epoch ~= self.session_epoch or request_generation ~= self.request_generation then
                    return true
                end
                self:enter_manga(current_folder)
                return true
            end, true),
            secondary_callback = self:_callback("enter current manga", function()
                if epoch ~= self.session_epoch or request_generation ~= self.request_generation then
                    return true
                end
                self:enter_manga(current_folder)
                return true
            end, true),
            cache_callback = cache_enabled and self:_callback("cache current manga", function()
                return self:_premium_gate("cache", current_folder, function()
                    return self.cache_manga(current_folder)
                end)
            end, true) or nil,
            cache_start = 0.70,
            secondary_start = cache_enabled and 0.86 or 0.70,
        }
        current_folder_index = #items
    end
    for _, folder in ipairs(folders) do if self:_path_is_allowed(folder.path) then items[#items + 1] = { text = folder.name,
        id=folder.path,manga=folder,
        mandatory = cache_enabled and "缓存  进入漫画" or "进入漫画",
        mandatory_func = function() return cache_enabled and "缓存  进入漫画" or "进入漫画" end,
        callback = self:_callback("enter directory", function()
            if epoch ~= self.session_epoch then return true end
            if request_generation ~= self.request_generation then return true end
            self:show_library(false, folder.path)
            return true
        end, true),
        secondary_callback = self:_callback("enter manga", function()
            if epoch ~= self.session_epoch then return true end
            if request_generation ~= self.request_generation then return true end
            self:enter_manga(folder)
            return true
        end, true),
        cache_callback = cache_enabled and self:_callback("cache manga", function()
            return self:_premium_gate("cache", folder, function()
                return self.cache_manga(folder)
            end)
        end, true) or nil,
        cache_start = 0.70,
        secondary_start = cache_enabled and 0.86 or 0.70,
    } end end
    -- For a document-only directory put the file-entry action before the
    -- back row, matching the compact document shelf layout. Image folders
    -- retain the established fixed-action ordering.
    if image_count == 0 and file_count > 0
        and (document_count > 0 or file_count > image_count + document_count)
        and items[back_row_index] and items[current_folder_index] then
        items[back_row_index], items[current_folder_index] =
            items[current_folder_index], items[back_row_index]
    end
    return items, { page = 1, first = first, has_next = false }
end
function Browser:_library_menu(path, items)
    local root = Path.normalize_remote(self.settings:get_connection().root_path)
    self.ui:show_menu{ title = "漫画书架", subtitle = path, items = items,
        initial_item_id=self.bookshelf_grid and self.bookshelf_anchors[path] or nil,
        view_mode="list",
        on_toggle_view=self.bookshelf_grid and self:_callback("toggle bookshelf view",function() return self:_toggle_bookshelf_view(path) end,true) or nil,
        fixed_actions = true,
        equal_column_font = true,
        on_switch_connection = self:_callback("switch bookshelf connection", function()
            return self.settings_ui:show_connection(function()
                return self:show_library(false,
                    self.settings:get_connection().root_path)
            end)
        end, true),
        on_back = self:_callback("back from bookshelf menu", function()
            if path == root then
                if self.ui.close_menu then self.ui:close_menu() end
            else
                self:show_library(false, parent_path(path, root))
            end
            return true
        end, true),
        on_close = self:_callback("close manga plugin from bookshelf", function()
            return self:_confirm_close_plugin()
        end, true),
        on_refresh = self:_callback("refresh bookshelf menu", function()
            self:show_library(true, path)
            return true
        end, true),
    }
end
function Browser:_toggle_bookshelf_view(path)
    local mode=self.settings:get_bookshelf_view()
    if mode=="list" and self.ui.get_anchor then
        self.bookshelf_anchors[path]=self.ui:get_anchor() or self.bookshelf_anchors[path]
    end
    self.settings:set_bookshelf_view(mode=="list" and "covers" or "list")
    self.settings:flush()
    self:close_menu()
    self:show_library(false,path)
    return true
end

function Browser:_bookshelf_covers(path,items)
    local grid=self.bookshelf_grid
    local cards,actions={},{}
    local function leave(callback) return function() return grid:leave_for(callback) end end
    for _,item in ipairs(items) do
        if item.manga then
            local card={id=item.id,name=item.manga.name,manga=item.manga}
            card.on_open=leave(function()
                self.bookshelf_anchors[path]=item.id
                return item.callback()
            end)
            card.on_hold=leave(function()
                local cache_action=item.cache_callback or function()
                    return self:_premium_gate("cache",item.manga,function() return self.cache_manga(item.manga) end)
                end
                self.ui:show_menu{title=item.manga.name,items={
                    {text="进入漫画",callback=item.secondary_callback},
                    {text="缓存漫画",callback=cache_action},
                },on_back=function() self:show_library(false,path) end}
            end)
            cards[#cards+1]=card
        else actions[#actions+1]=item end
    end
    self:close_menu()
    grid:show{title="漫画书架",subtitle=path,view_mode="covers",items=cards,
        initial_item_id=self.bookshelf_anchors[path],
        on_anchor=function(id) self.bookshelf_anchors[path]=id end,
        on_toggle_view=leave(function() return self:_toggle_bookshelf_view(path) end),
        on_switch_connection=leave(function()
            return self.settings_ui:show_connection(function() self:show_library(false,self.settings:get_connection().root_path) end)
        end),
        on_close=function() return self:_confirm_close_plugin() end,
        on_actions=leave(function()
            self.ui:show_menu{title="漫画书架操作",subtitle=path,items=actions,fixed_actions=true,
                on_back=function() self:show_library(false,path) end}
        end),
        on_settings=function() return self.settings_ui:show_bookshelf_cache() end,
        on_back=function()
            local root=Path.normalize_remote(self.settings:get_connection().root_path)
            if path==root then self:close_menu();self:_begin_request(true)
            else self:show_library(false,parent_path(path,root)) end
        end,
    }
end

function Browser:show_library(is_refresh, target_path, target_page)
    if not self.settings:is_configured() then self.settings_ui:show_connection(function() self:show_library() end); return end
    self:_ensure_session_identity(); local connection = self.settings:get_connection(); local path = Path.normalize_remote(target_path or self.current_path or self:_saved_browser_path())
    if not Path.is_within_remote(path, connection.root_path) then path = Path.normalize_remote(connection.root_path); self.ui:show_info(Errors.message(Errors.invalid_path())) end
    target_page = target_page or 1; local generation = self:_begin_request(false)
    self:_close_except({ [path] = true })
    local store=self.bookshelf_directory_store or self.directory_store
    if is_refresh then
        if self.on_bookshelf_refresh then self.on_bookshelf_refresh(path)
        elseif store.invalidate then store:invalidate(path) end
    end
    local handle = self:_load_directory(path, { refresh = is_refresh, listing = "folders",store=self.bookshelf_directory_store }, function(d)
        if generation ~= self.request_generation then return end; if not self:_set_browser_path(path) then return end
        local folders, images = directory_index(d, "folders"), directory_index(d, "images")
        local documents = directory_index(d, "documents")
        local direct_file_count = type(d.file_count) == "function" and d:file_count() or nil
        local items, model = self:_directory_items(path, folders, target_page, images,
            documents, direct_file_count); self.page_models[path] = model; self.last_library_items = items; self.last_directory_items[path] = items
        if self.bookshelf_grid and self.settings:get_bookshelf_view()=="covers" then self:_bookshelf_covers(path,items)
        else self:_library_menu(path, items) end
        if (tonumber(folders and folders:count()) or 0) == 0
            and (tonumber(images and images:count()) or 0) == 0
            and (tonumber(documents and documents:count()) or 0) == 0 then
            self.ui:show_info(Errors.message{ code = "empty", kind = "manga" })
        end
    end, function(err) if generation == self.request_generation then self.ui:show_info(Errors.message(err)) end end)
    return handle
end

function Browser:_chapter_items(manga, index, page, source_context)
    local chapters, has_next = page_entries(index, page or 1, 50)
    local items, epoch, request_generation = {}, self.session_epoch, self.request_generation
    for _, chapter in ipairs(chapters) do if self:_path_is_allowed(chapter.path) then items[#items + 1] = { text = chapter.name, callback = self:_callback("open chapter", function()
        if epoch ~= self.session_epoch or request_generation ~= self.request_generation then return true end
        self:open_chapter(manga, chapter, nil, source_context)
        return true
    end, true) } end end
    if has_next then items[#items + 1] = {
        text = "下一页 →",
        callback = self:_callback("next chapter page", function()
            if request_generation ~= self.request_generation then return true end
            self:present_manga({ manga = manga, layout = "chapters", chapters_index = index },
                source_context, (page or 1) + 1)
            return true
        end),
    } end
    return items
end
function Browser:_chapter_menu(manga, items, source_context)
    source_context = source_context or {}
    self.ui:show_menu{ title = manga.name, items = items,
        on_refresh = self:_callback("refresh chapter menu", function()
            self:identify_manga(manga, { refresh = true,
                on_success = function(result) self:present_manga(result, source_context) end,
                on_failure = self:_callback("refresh chapter error", function(err)
                    self.ui:show_info(Errors.message(err))
                end) })
            return true
        end, true),
        on_back = self:_callback("back from chapter menu", function()
            if source_context.on_return then return source_context.on_return() end
            self:show_library(false, self.return_paths[manga.path] or self.current_path)
            return true
        end, true),
    }
end

function Browser:_open_document_with_progress(entry, callbacks)
    callbacks = callbacks or {}
    if self.active_document_progress
        and type(self.active_document_progress.close) == "function" then
        pcall(self.active_document_progress.close, self.active_document_progress)
    end
    self.active_document_progress = nil
    local handle, request_handle
    local closed, cancel_requested = false, false
    local function close_progress()
        if closed then return end
        closed = true
        if handle and type(handle.close) == "function" then
            pcall(handle.close, handle)
        end
        if self.active_document_progress == handle then
            self.active_document_progress = nil
        end
    end
    local function cancel_open()
        if cancel_requested then return true end
        cancel_requested = true
        if request_handle and type(request_handle.cancel) == "function" then
            pcall(request_handle.cancel, request_handle)
        end
        close_progress()
        if type(callbacks.on_cancel) == "function" then
            pcall(callbacks.on_cancel)
        end
        return true
    end
    local function show_progress()
        if type(self.ui.show_progress) == "function" then
            local ok, result = pcall(self.ui.show_progress, self.ui, {
                title = "正在打开漫画书籍",
                subtitle = tostring(entry.name or entry.path or "文档"),
                on_cancel = cancel_open,
            })
            if ok then handle = result end
        end
        self.active_document_progress = handle
    end
    show_progress()
    local opened = callbacks.on_opened
    local failed = callbacks.on_error
    local attached = callbacks.on_open_handle
    callbacks.on_open_handle = function(current)
        request_handle = current
        if cancel_requested and current and type(current.cancel) == "function" then
            pcall(current.cancel, current)
        end
        if attached then pcall(attached, current) end
    end
    callbacks.on_open_progress = function(event)
        if handle and type(handle.update) == "function" then
            pcall(handle.update, handle, event)
        end
    end
    callbacks.on_opened = function(...)
        close_progress()
        if opened then return opened(...) end
    end
    callbacks.on_error = function(...)
        close_progress()
        if failed then return failed(...) end
    end
    callbacks.on_document_fallback_prompt = function(format, reason, retry, structured_error)
        close_progress()
        if cancel_requested then return false end
        local stage = Errors.stream_stage(format, reason)
        local error_value = Errors.stream(format, stage, reason)
        -- The optional metadata disambiguates first-page errors from index
        -- errors. Validate its identity and reconstruct only allowlisted fields;
        -- a caller's raw detail or unrelated error must never enter the dialog.
        if type(structured_error) == "table"
            and rawget(structured_error, "code") == "document"
            and rawget(structured_error, "stage") == "stream"
            and rawget(structured_error, "format") == error_value.format
            and rawget(structured_error, "reason") == error_value.reason then
            local supplied_stage = rawget(structured_error, "stream_stage")
            local candidate = Errors.stream(error_value.format, supplied_stage, error_value.reason)
            if candidate.stream_stage == supplied_stage then error_value = candidate end
        end
        local message = error_value.format:upper() .. " 流式打开失败。\n"
            .. Errors.message(error_value) .. "\n是否完整下载后打开？"
        if type(self.ui.confirm) ~= "function" then
            if failed then failed(error_value) else self.ui:show_info(Errors.message(error_value)) end
            return false
        end
        local decided = false
        return self.ui:confirm{
            text = message,
            on_confirm = self:_callback("confirm complete document download", function()
                if decided or cancel_requested then return true end
                decided = true
                closed, handle, request_handle = false, nil, nil
                show_progress()
                local result = retry()
                if result == false then close_progress() end
                return result
            end, false),
            on_cancel = self:_callback("cancel complete document download", function()
                if decided then return true end
                decided = true
                cancel_open()
                self.ui:show_info("已取消完整下载。")
                return true
            end, true),
        }
    end
    local called, started = pcall(self.open_document, entry, callbacks)
    if not called then
        close_progress()
        callbacks.on_error(Errors.document("staging", started))
        return false
    end
    if started == false then close_progress() end
    return started
end

function Browser:_document_item(manga, document, source_context, epoch)
    if not document or not self:_path_is_allowed(document.path) then return nil end
    local supported = Formats.is_document(document.name or document.path)
    local entry = {
        path = document.path, name = document.name,
        size = document.size,
        file_kind = "document", connection = self.settings:get_connection(),
    }
    local item = {
        text = supported and document.name
            or (tostring(document.name or document.path) .. "\n（不支持的文件格式）"),
        callback = self:_callback("open native document", function()
            if epoch ~= self.session_epoch then return true end
            if not supported then
                self.ui:show_info("该文件不是 KOReader 支持的电子书格式。")
                return true
            end
            if type(self.open_document) ~= "function" then
                self.ui:show_info("原生文档阅读器尚未初始化。")
                return true
            end
            return self:_premium_gate("open", entry, function()
            self:_open_document_with_progress(entry, {
                close_plugin = function() self:close_menu() end,
                on_closed = function()
                    if source_context and source_context.on_return then
                        source_context.on_return()
                    else
                        self:show_library(false, self.current_path)
                    end
                end,
                on_error = self:_callback("open native document error", function(err)
                    self.ui:show_info(Errors.message(err))
                end),
            })
            return true
            end)
        end, true),
    }
    if supported and self.cache_mode_enabled == true then
        item.mandatory = "缓存"
        item.mandatory_func = function() return "缓存" end
        item.cache_start = 0.70
        item.cache_callback = self:_callback("cache native document", function()
            return self:_premium_gate("cache", entry, function()
            local settled = false
            local started = self.cache_document(entry, {
                on_cached = function()
                    settled = true
                    self.ui:show_info("文件已缓存到 Kindle。")
                end,
                on_error = self:_callback("cache native document error", function(err)
                    settled = true
                    self.ui:show_info(Errors.message(err))
                end),
            })
            if started == false and not settled then
                self.ui:show_info("文件缓存未能开始，请检查网络、缓存上限和剩余空间。")
            elseif started ~= false and not settled then
                self.ui:show_info("已开始缓存文件。完成后可在“缓存漫画”中阅读。")
            end
            return started
            end)
        end, true)
    end
    return item
end

function Browser:_document_menu(manga, index, source_context)
    source_context = source_context or {}
    local items, epoch = {}, self.session_epoch
    local count = tonumber(index and index:count()) or 0
    for position = 1, count do
        local item = self:_document_item(manga, index:get(position), source_context, epoch)
        if item then items[#items + 1] = item end
    end
    self.ui:show_menu{ title = manga.name, items = items,
        on_back = self:_callback("back from document menu", function()
            if source_context.on_return then return source_context.on_return() end
            return self:show_library(false, self.return_paths[manga.path] or self.current_path)
        end, true),
    }
end

function Browser:_mixed_menu(result, source_context)
    local items, epoch, manga = {}, self.session_epoch, result.manga
    if result.image_index and (tonumber(result.image_index:count()) or 0) > 0 then
        local chapter = { name = manga.name, path = manga.path,
            is_folder = true, direct_images = true }
        items[#items + 1] = {
            text = "当前文件夹（图片）", mandatory = "进入漫画",
            mandatory_func = function() return "进入漫画" end,
            callback = self:_callback("open mixed image pages", function()
                if epoch ~= self.session_epoch then return true end
                self:open_prepared_reader{ manga = manga, chapter = chapter,
                    chapter_index = result.image_index, layout = "direct",
                    cover_hint = result.cover_hint, source_context = source_context }
                return true
            end, true),
        }
    end
    if result.chapters_index then
        for _, item in ipairs(self:_chapter_items(manga, result.chapters_index, 1, source_context)) do
            items[#items + 1] = item
        end
    end
    if result.documents_index then
        local count = tonumber(result.documents_index:count()) or 0
        for position = 1, count do
            local item = self:_document_item(manga, result.documents_index:get(position),
                source_context, epoch)
            if item then items[#items + 1] = item end
        end
    end
    self.ui:show_menu{ title = manga.name, items = items,
        on_back = self:_callback("back from mixed manga menu", function()
            if source_context and source_context.on_return then return source_context.on_return() end
            self:show_library(false, self.return_paths[manga.path] or self.current_path)
            return true
        end, true),
    }
    return true
end

function Browser:_recognize_directory(manga, directory)
    local folders = type(directory.folders) == "function" and directory:folders() or directory.folders
    local images = type(directory.images) == "function" and directory:images() or directory.images
    local documents = type(directory.documents) == "function" and directory:documents() or directory.documents
    local image_count, folder_count = tonumber(images and images:count()) or 0, tonumber(folders and folders:count()) or 0
    local document_count = tonumber(documents and documents:count()) or 0
    -- Direct images are the primary manga view even when a server also
    -- returns unrelated child folders. Only a co-located document requires
    -- the mixed chooser.
    if image_count > 0 and document_count > 0 then
        return { manga = manga, layout = "mixed", image_index = images,
            chapters_index = folders, documents_index = documents,
            cover_hint = { image = images:get(1) } }
    end
    if image_count > 0 then local chapter = { name = manga.name, path = manga.path, is_folder = true, direct_images = true }; return { manga = manga, layout = "direct", chapter = chapter, chapter_index = images, cover_hint = { image = images:get(1) } } end
    if folder_count > 0 and document_count > 0 then
        return { manga = manga, layout = "mixed", chapters_index = folders,
            documents_index = documents, cover_hint = { chapter = folders:get(1) } }
    end
    if folder_count > 0 then return { manga = manga, layout = "chapters", chapters_index = folders, cover_hint = { chapter = folders:get(1) } } end
    if document_count > 0 then return { manga = manga, layout = "documents", documents_index = documents } end
    return nil, { code = "empty", kind = "chapters" }
end
function Browser:identify_manga(manga, options)
    options = options or {}; self:_ensure_session_identity(); if not self:_path_is_allowed(manga.path) then if options.on_failure then options.on_failure(Errors.invalid_path()) end; return noop_handle() end
    self:_begin_request(false); self:_close_except({ [Path.normalize_remote(manga.path)] = true })
    return self:_load_directory(manga.path, { refresh = options.refresh, listing = "directory" }, function(d) local result, err = self:_recognize_directory(manga, d); if result then if options.on_success then options.on_success(result) end elseif options.on_failure then options.on_failure(err) end end, options.on_failure)
end
function Browser:present_manga(result, source_context, page)
    if result.layout == "direct" then return self:open_prepared_reader{ manga = result.manga, chapter = result.chapter, chapter_index = result.chapter_index, layout = "direct", cover_hint = result.cover_hint, source_context = source_context } end
    if result.layout == "documents" then return self:_document_menu(result.manga, result.documents_index, source_context) end
    if result.layout == "mixed" then return self:_mixed_menu(result, source_context) end
    self:_chapter_menu(result.manga, self:_chapter_items(result.manga, result.chapters_index, page or 1, source_context), source_context)
end
function Browser:enter_manga(manga, is_refresh)
    if self:_ensure_session_identity() then return self:show_library() end; if not self:_path_is_allowed(manga.path) then self.ui:show_info(Errors.message(Errors.invalid_path())); return self:show_library(false, self.current_path) end
    return self:_premium_gate("open", manga, function()
        self.return_paths[manga.path] = self.current_path
        return self:identify_manga(manga, { refresh = is_refresh,
            on_success = function(r) self:present_manga(r) end,
            on_failure = function(err) self.ui:show_info(Errors.message(err)) end })
    end)
end
function Browser:show_chapters(manga, is_refresh) return self:enter_manga(manga, is_refresh) end

function Browser:prepare_chapter(manga, chapter, recognition, callbacks)
    recognition, callbacks = recognition or {}, callbacks or {}; if not self:_path_is_allowed(manga.path) or not self:_path_is_allowed(chapter.path) then if callbacks.on_error then callbacks.on_error(Errors.invalid_path()) end; return noop_handle() end
    local generation = self:_begin_request(false); self:_close_except({ [Path.normalize_remote(manga.path)] = true, [Path.normalize_remote(chapter.path)] = true })
    return self:_load_directory(chapter.path, { refresh = recognition.refresh, listing = "images" }, function(d)
        if generation ~= self.request_generation then return end; local chapter_index = directory_index(d, "images"); if (tonumber(chapter_index and chapter_index:count()) or 0) == 0 then if callbacks.on_error then callbacks.on_error({ code = "empty", kind = "images" }) end; return end
        local manga_directory = self.active_directories[manga.path]; local context = { manga = manga, chapter = chapter, chapter_index = chapter_index, chapters_index = manga_directory and directory_index(manga_directory, "folders") or nil, layout = recognition.layout or (chapter.direct_images and "direct" or "chapters"), cover_hint = recognition.cover_hint, source_context = callbacks.source_context }
        if callbacks.on_ready then callbacks.on_ready(context) end
    end, callbacks.on_error)
end
function Browser:prepare_resume(record, callbacks)
    callbacks = callbacks or {}; local manga = record and record.manga; if type(manga) ~= "table" then if callbacks.on_error then callbacks.on_error(Errors.invalid_path()) end; return noop_handle() end
    return self:identify_manga(manga, { allow_cached = false, on_success = function(result)
        local chapter = record.chapter; if result.layout == "chapters" then local index, position = result.chapters_index, result.chapters_index:find(chapter.path, record.chapter_index); chapter = position and index:get(position) or nil; if not chapter then if callbacks.on_error then callbacks.on_error({ code = "empty", kind = "chapters" }) end; return end end
        self:prepare_chapter(manga, chapter, { layout = result.layout, cover_hint = record.cover_hint }, callbacks)
    end, on_failure = callbacks.on_error })
end
function Browser:open_prepared_reader(context)
    if type(context) ~= "table" or type(context.chapter_index) ~= "table" or (tonumber(context.chapter_index:count()) or 0) < 1 then return false end; self.open_reader(context); return true
end
function Browser:_leave_grid_and_open(context)
    if self.cover_grid and type(self.cover_grid.leave_for) == "function" then
        local left = self.cover_grid:leave_for(function()
            self:open_prepared_reader(context)
        end)
        return left ~= false
    end
    return self:open_prepared_reader(context)
end
function Browser:open_chapter(manga, chapter, recognition, source_context)
    return self:prepare_chapter(manga, chapter, recognition, { source_context = source_context, on_ready = function(c) self:open_prepared_reader(c) end, on_error = function(err) self.ui:show_info(Errors.message(err)) end })
end

local function history_text(record)
    local index, total = math.max(1, math.floor(tonumber(record.index) or 1)), math.max(1, math.floor(tonumber(record.total) or 1)); local ok, ts = pcall(os.date, "%Y-%m-%d %H:%M", tonumber(record.updated_at) or 0); if not ok then ts = "" end
    return ("%s · %s · %d / %d · %d%% · %s"):format(record.manga.name, record.chapter.name, index, total, math.floor(index * 100 / total), ts)
end
function Browser:show_history(options)
    options = options or {}
    local view_connection = options.connection or self.settings:get_connection()
    if not options.connection and self:_ensure_session_identity() then return self:show_library() end
    self:close_menu()
    self:_begin_request(true)
    local connection, records = view_connection,
        self.progress:list_history(view_connection); local items, epoch = {}, self.session_epoch
    for _, record in ipairs(records) do
        local metadata = self.library and self.library:get_manga(connection, record.manga.path) or nil
        local local_document_path
        local local_cover_path = metadata and metadata.archived_cover_path or nil
        if record.layout == "opds" and self.opds_cover
            and type(self.opds_cover.lookup) == "function" then
            local found, path = pcall(self.opds_cover.lookup,
                self.opds_cover, connection, record.cover_hint)
            if found and path then local_cover_path = path end
        end
        if (record.layout == "mobi_images" or record.layout == "archive_images"
            or record.layout == "mupdf_pages" or record.layout == "pdf_images") and self.document_cache
            and type(self.document_cache.key_for) == "function"
            and type(self.document_cache.lookup_record) == "function" then
            local key = self.document_cache:key_for(identity(connection), record.manga.path)
            local path, cached = self.document_cache:lookup_record(key)
            if cached and cached.kind == "document" then local_document_path = path end
        end
        items[#items + 1] = { id = identity(connection) .. "\0" .. Path.normalize_remote(record.manga.path), manga = record.manga, history_record = record, cover_hint = record.cover_hint, layout = record.layout, chapter = record.chapter, text = history_text(record), mandatory = "管理",
        is_read = metadata and metadata.is_read == true,
        local_cover_path = local_cover_path,
        local_document_path = local_document_path,
        local_deleted = metadata and metadata.local_deleted == true,
        on_open = self:_callback("resume reading history", function()
            return self:_premium_gate("open", record.manga, function()
            if epoch ~= self.session_epoch then return self:show_library() end
            if metadata and metadata.local_deleted then
                self.ui:show_info("本地漫画文件已删除；封面、评分和阅读记录仍保留。")
                return true
            end
            if record.layout == "opds" and type(self.open_opds_record) == "function" then
                return self.open_opds_record(record, options.on_back)
            end
            if (record.layout == "mobi_images" or record.layout == "archive_images"
                or record.layout == "mupdf_pages" or record.layout == "pdf_images")
                and type(self.open_document) == "function" then
                local function open_book()
                    return self:_open_document_with_progress({
                        path = record.manga.path, name = record.manga.name,
                        size = record.manga.size, etag = record.manga.etag, modified = record.manga.modified,
                        file_kind = "document", connection = connection,
                    }, {
                        on_closed = function() self:show_history() end,
                        on_error = self:_callback("resume book history error", function(err)
                            self.ui:show_info(Errors.message(err))
                            self:show_history()
                        end),
                    })
                end
                if self.cover_grid and type(self.cover_grid.leave_for) == "function" then
                    return self.cover_grid:leave_for(open_book)
                end
                return open_book()
            end
            self:prepare_resume(record, {
                on_ready = function(c) return self:_leave_grid_and_open(c) end,
                on_error = self:_callback("resume history error", function(err)
                    self.ui:show_info(Errors.message(err))
                end),
            })
            return true
            end)
        end),
        on_action = self:_callback("manage reading history", function()
            if self.manage_history then return self.manage_history(record) end
            self.ui:confirm{
                text = "删除“" .. record.manga.name .. "”的阅读历史？",
                on_confirm = self:_callback("confirm history deletion", function()
                    local ok = self.progress:remove_history(connection, record.manga.path)
                    if ok == false then
                        self.ui:show_info("阅读历史删除失败，请稍后重试。")
                        return false
                    end
                    self:show_history()
                    return true
                end, false),
            }
        end),
    } end
    if not self.cover_grid then self.ui:show_info("阅读历史封面网格尚未初始化。"); return end
    local shown = self.cover_grid:show{
        title = "阅读历史", subtitle = ("%d 本漫画"):format(#items), items = items,
        allow_multi_select = true,
        on_batch_action = self:_callback("manage history batch", function(selected_items)
            local records = {}
            for _, item in ipairs(selected_items or {}) do
                records[#records + 1] = item.history_record or item
            end
            if self.manage_history_batch then
                return self.manage_history_batch(records)
            end
            self.ui:show_info("批量管理尚未初始化，请重启漫画插件。")
            return false
        end, false),
        on_back = self:_callback("back from reading history", function()
            if type(options.on_back) == "function" then return options.on_back() end
            self:show_library(false, self.current_path)
            return true
        end, true),
    }
    if shown == false then return self:show_library(false, self.current_path) end
    if #items == 0 then self.ui:show_info("还没有阅读历史。") end
end
function Browser:show_folder_picker(options, start_path, target_page)
    options = options or {}; local root = Path.normalize_remote(self.settings:get_connection().root_path); local path = Path.normalize_remote(start_path or root); if not Path.is_within_remote(path, root) then self.ui:show_info(Errors.message(Errors.invalid_path())); return noop_handle() end
    target_page = math.max(1, math.floor(tonumber(target_page) or 1))
    self:_begin_request(true)
    local handle = self:_load_directory(path, {}, function(d)
        local items, epoch, request_generation = {}, self.session_epoch, self.request_generation
        local folder_index = sorted_index(directory_index(d, "folders"))
        local folders, has_next = page_entries(folder_index, target_page, 40)
        for _, folder in ipairs(folders) do
            if folder then
                items[#items + 1] = {
                    text = folder.name,
                    mandatory = options.action_text,
                    callback = self:_callback("enter folder picker directory", function()
                        if epoch == self.session_epoch and request_generation == self.request_generation then
                            self:show_folder_picker(options, folder.path)
                        end
                        return true
                    end, true),
                    secondary_callback = self:_callback("pick folder", function()
                        if epoch == self.session_epoch and request_generation == self.request_generation and options.on_pick then
                            options.on_pick(folder)
                        end
                        return true
                    end, true),
                }
            end
        end
        if target_page > 1 then
            items[#items + 1] = {
                text = "← 上一页",
                callback = self:_callback("previous folder picker page", function()
                    if request_generation == self.request_generation then
                        self:show_folder_picker(options, path, target_page - 1)
                    end
                    return true
                end, true),
            }
        end
        if has_next then
            items[#items + 1] = {
                text = "下一页 →",
                callback = self:_callback("next folder picker page", function()
                    if request_generation == self.request_generation then
                        self:show_folder_picker(options, path, target_page + 1)
                    end
                    return true
                end, true),
            }
        end
        self.ui:show_menu{
            title = options.title, subtitle = path, items = items,
            on_back = self:_callback("back from folder picker", function()
                if request_generation ~= self.request_generation then
                    return true
                elseif target_page > 1 then
                    self:show_folder_picker(options, path, target_page - 1)
                elseif path == root then
                    if options.on_back then options.on_back() end
                else
                    self:show_folder_picker(options, parent_path(path, root))
                end
                return true
            end, true),
        }
    end, self:_callback("folder picker error", function(err)
        self.ui:show_info(Errors.message(err))
    end))
    if options.on_request_handle then options.on_request_handle(handle) end; return handle
end
function Browser:cover_context(manga, chapter) return { identity = identity(self.settings:get_connection()), manga = manga, chapter = chapter } end

return Browser
