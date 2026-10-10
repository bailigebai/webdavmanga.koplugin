local Errors = require("webdavmanga.errors")
local DialogKeyboard = require("webdavmanga.dialog_keyboard")
local Path = require("webdavmanga.path")
local SafeCallback = require("webdavmanga.safe_callback")
local UiRegistry = require("webdavmanga.ui_registry")

local UiLibrary = {}
UiLibrary.__index = UiLibrary

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function connection_identity(connection)
    connection = connection or {}
    return table.concat({
        tostring(connection.server_url or ""),
        trim(connection.username),
        Path.normalize_remote(connection.root_path or ""),
    }, "\0")
end

local function route_menu_close(adapter, menu, callback)
    if menu and menu.skip_close_callback then return true end
    if adapter.current_menu == menu then adapter.current_menu = nil end
    if callback then return callback() end
    return true
end

UiLibrary._route_menu_close = route_menu_close

local function default_ui()
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local Menu = require("ui/widget/menu")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")
    local registry = UiRegistry:new(UIManager)
    local adapter = { current_menu = nil }

    local function guarded(label, callback, fallback)
        local wrapped = SafeCallback.wrap(adapter, label, callback, fallback)
        return function(...)
            local result = wrapped(...)
            -- UI callbacks consume their tap even when the underlying
            -- operation returns false and keeps the current view open.
            return result == nil and true or (result == false and true or result)
        end
    end
    local function invoke(label, callback)
        local result = guarded(label, callback, true)()
        -- Menu callbacks are input handlers.  A false business result must
        -- not bubble into KOReader as an unhandled tap.
        return result == nil and true or (result == false and true or result)
    end

    function adapter:show_info(message)
        registry:show(InfoMessage:new{ text = message, timeout = 3 })
    end

    function adapter:close_menu()
        local menu = self.current_menu
        self.current_menu = nil
        if not menu then return end
        menu.skip_close_callback = true
        registry:close(menu)
    end

    function adapter:show_menu(model)
        self:close_menu()
        local items = {}
        for _, item in ipairs(model.items or {}) do
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            if copy.callback then copy.callback = guarded("library menu action", copy.callback, true) end
            if copy.secondary_callback then
                copy.secondary_callback = guarded("library menu secondary action",
                    copy.secondary_callback, true)
            end
            items[#items + 1] = copy
        end
        if model.on_save then
            items[#items + 1] = {
                text = model.save_text or "保存",
                separator = true,
                callback = guarded("save library menu", model.on_save),
            }
        end
        if model.on_back then
            items[#items + 1] = {
                text = model.back_text or "← 返回",
                separator = true,
                callback = guarded("leave library menu", model.on_back),
            }
        end
        local menu
        local function route_back()
            return route_menu_close(adapter, menu, function()
                if model.on_back then
                    return invoke("library menu close callback", model.on_back)
                end
                return true
            end)
        end
        menu = Menu:new{
            title = model.title,
            subtitle = model.subtitle,
            -- Keep the bookshelf surface opaque so stale content from the
            -- underlying KOReader page cannot show through the corners.
            is_popout = false,
            covers_fullscreen = true,
            item_table = items,
            items_max_lines = 2,
            close_callback = route_back,
            onMenuSelect = function(_menu, item, position)
                if item.secondary_callback and position and position.x >= 0.70 then
                    return invoke("library menu secondary action", item.secondary_callback)
                elseif item.callback then
                    return invoke("library menu action", item.callback)
                end
                return true
            end,
        }
        self.current_menu = menu
        registry:show(menu)
    end

    function adapter:show_choice(model)
        local dialog
        dialog = ButtonDialog:new{
            title = model.title,
            buttons = {
                {{ text = "继续阅读", callback = guarded("continue manga", model.buttons.continue, true) }},
                {{ text = "选择章节", callback = guarded("choose manga chapter", model.buttons.chapters, true) }},
                {{ text = "取消", callback = guarded("cancel manga choice", model.buttons.cancel, true) }},
            },
        }
        self.current_choice = dialog
        registry:show(dialog)
    end

    function adapter:close_choice()
        if self.current_choice then registry:close(self.current_choice) end
        self.current_choice = nil
    end

    function adapter:show_input(model)
        local dialog
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.title,
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {{
                description = model.description or "分类名称",
                text = model.value or "",
            }},
            buttons = {{
                {
                    text = "取消",
                    callback = guarded("cancel category input", function()
                    registry:close(dialog)
                        if model.on_back then model.on_back() end
                    end),
                },
                {
                    text = "保存",
                    callback = guarded("save category input", function()
                        local fields = dialog:getFields()
                    if model.on_save(fields[1]) then registry:close(dialog) end
                    end),
                },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        DialogKeyboard.show(dialog)
    end

    function adapter:confirm(model)
        registry:show(ConfirmBox:new{
            text = model.text,
            ok_text = model.ok_text or "确定",
            cancel_text = model.cancel_text or "取消",
            ok_callback = guarded("confirm library action", model.on_confirm),
            cancel_callback = model.cancel_callback
                and guarded("cancel library action", model.cancel_callback) or nil,
        })
    end

    function adapter:close_all()
        self.current_menu = nil
        self.current_choice = nil
        return registry:close_all()
    end

    return adapter
end

local function error_message(code)
    local messages = {
        duplicate_category = "分类名称已存在。",
        invalid_category_name = "请输入分类名称。",
        missing_category = "该分类已不存在。",
        missing_manga = "该漫画已不在分类架中。",
        invalid_category = "所选分类已不存在，请重新选择。",
        invalid_manga_path = "所选漫画目录无效。",
        invalid_cover_hint = "封面目录信息无效。",
        storage_failure = "分类架保存失败，请稍后重试。",
    }
    return messages[code] or ("漫画分类架操作失败（错误类型：%s）。"):format(
        tostring(code or "unknown"))
end

function UiLibrary:new(deps)
    deps = deps or {}
    local object = setmetatable({}, self)
    object.settings = assert(deps.settings, "settings is required")
    object.library = assert(deps.library, "library is required")
    object.cover_service = assert(deps.cover_service, "cover service is required")
    object.cover_grid = assert(deps.cover_grid, "cover grid is required")
    object.progress = deps.progress
    object.browser = assert(deps.browser, "browser is required")
    object.ui = deps.ui or default_ui()
    object.error_reporter = deps.error_reporter
    object.local_archive = deps.local_archive
    object.cache_manga = deps.cache_manga
    object.offline_cache = deps.offline_cache
    object.document_cache = deps.document_cache
    object.document_bridge = deps.document_bridge
    object.offline_manager = deps.offline_manager
    object.scheduler = deps.scheduler
    object.identity_provider = deps.identity_provider
    object.show_offline_cache = deps.show_offline_cache or deps.cache_manga
    object.open_cached_reader = deps.open_cached_reader
    object.open_cached_document = deps.open_cached_document
    object.open_opds_record = deps.open_opds_record
    object.opds_cover = deps.opds_cover
    object.premium_access = deps.premium_access
    object.request_license = deps.request_license
    object.offline_shelf_identity = nil
    object.offline_shelf_root = nil
    object.offline_shelf_return_path = nil
    object.offline_shelf_epoch = nil
    object.offline_shelf_grid_epoch = nil
    object.offline_shelf_ids = nil
    object.current_view = object.library.ALL
    object.relink_return_view = object.library.ALL
    object.unavailable_paths = {}
    object.view_epoch = 0
    object.active_handle = nil
    object.offline_refresh_task = nil
    return object
end

function UiLibrary:_premium_gate(action, manga, continuation)
    local access = self.premium_access
    local method = (action == "cache" or action == "add" or action == "rating")
        and "can_add" or "can_open"
    if not access or type(access[method]) ~= "function" then
        if continuation then return continuation() end
        return true
    end
    local ok, allowed, reason = pcall(access[method], access, manga)
    if ok and allowed == true then
        if continuation then return continuation() end
        return true
    end
    local resumed = false
    local function resume_once()
        if resumed then return end
        resumed = true
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

function UiLibrary:_callback(label, callback, fallback)
    local epoch = self.view_epoch
    local identity = connection_identity(self:_connection())
    return SafeCallback.wrap(self.error_reporter or self.ui, label, function(...)
        if epoch ~= self.view_epoch
            or identity ~= connection_identity(self:_connection()) then return fallback end
        return callback(...)
    end, fallback)
end

function UiLibrary:_record_cover_path(record, connection)
    local archived = record and record.archived_cover_path or nil
    connection = connection or (record and record.connection) or self:_connection()
    if not record or record.layout ~= "opds" or not connection
        or connection.kind ~= "opds" or not self.opds_cover
        or type(self.opds_cover.lookup) ~= "function" then return archived end
    local ok, path = pcall(self.opds_cover.lookup,
        self.opds_cover, connection, record.cover_hint)
    return ok and path or archived
end

function UiLibrary:_connection()
    return self.settings:get_connection()
end

function UiLibrary:_offline_identity()
    if type(self.identity_provider) ~= "function" then return nil end
    local ok, identity = pcall(self.identity_provider)
    return ok and tostring(identity or "") or nil
end

local function offline_index(entries)
    return {
        count = function() return #entries end,
        get = function(_self, position) return entries[position] end,
        find = function(_self, path)
            for position, entry in ipairs(entries) do
                if entry.path == path then return position end
            end
        end,
        window = function(_self, center, radius)
            local first = math.max(1, (tonumber(center) or 1) - (tonumber(radius) or 0))
            local last = math.min(#entries, (tonumber(center) or 1) + (tonumber(radius) or 0))
            local result = {}
            for position = first, last do result[#result + 1] = entries[position] end
            return result
        end,
    }
end

function UiLibrary:_cached_context(model, chapter, chapter_position)
    local chapters_index = offline_index(model.chapters)
    local return_path = self.offline_shelf_return_path
    return {
        manga = model.manga,
        chapter = chapter,
        chapter_index = offline_index(chapter.images),
        chapters_index = chapters_index,
        chapter_position = chapter_position,
        open_chapter = function(_manga, next_chapter)
            local position = chapters_index:find(next_chapter.path)
            if not position then return false end
            return self:_open_cached_chapter(model, chapters_index:get(position), position)
        end,
        layout = #model.chapters == 1 and chapter.path == model.manga.path and "direct" or "chapters",
        source_context = { source = "offline", on_return = function()
            return self:show_offline_shelf({ return_path = return_path })
        end },
    }
end

function UiLibrary:_open_cached_chapter(model, chapter, chapter_position)
    if type(self.open_cached_reader) ~= "function" then return false end
    local context = self:_cached_context(model, chapter, chapter_position)
    if self.cover_grid and self.cover_grid.is_open
        and type(self.cover_grid.leave_for) == "function" then
        return self.cover_grid:leave_for(function() self.open_cached_reader(context) end)
    end
    self.open_cached_reader(context)
    return true
end

function UiLibrary:_open_cached_manga(shelf_model)
    if not shelf_model or not shelf_model._premium_resumed then
        return self:_premium_gate("open", shelf_model and shelf_model.manga, function()
            if type(shelf_model) == "table" then shelf_model._premium_resumed = true end
            return self:_open_cached_manga(shelf_model)
        end)
    end
    if shelf_model then shelf_model._premium_resumed = nil end
    local identity = self.offline_shelf_identity
    if not identity or not self.offline_cache or type(self.offline_cache.reader_model) ~= "function" then
        return false
    end
    local cached_pages = shelf_model.cached_pages
    if cached_pages == 0 then
        for _, current in ipairs(self.offline_cache:list_mangas(identity)) do
            if current.manga.path == shelf_model.manga.path then
                cached_pages = current.cached_pages
                break
            end
        end
    end
    local model, err
    if cached_pages ~= 0 then
        model, err = self.offline_cache:reader_model(identity, shelf_model.manga.path)
    else
        err = "incomplete"
    end
    if not model then
        if type(self.show_offline_cache) == "function" then self.show_offline_cache(shelf_model.manga) end
        return false, err
    end
    local chapters = model.chapters or {}
    if #chapters == 1 and chapters[1] and chapters[1].path == model.manga.path then
        return self:_open_cached_chapter(model, chapters[1], 1)
    end
    local function open_chapter(chapter, position)
        return self:_open_cached_chapter(model, chapter, position)
    end
    local continue_chapter, continue_position = chapters[1], 1
    local history = self:_history_for(model)
    if history and history.chapter then
        for position, chapter in ipairs(chapters) do
            if chapter.path == history.chapter.path then
                continue_chapter, continue_position = chapter, position
                break
            end
        end
    end
    self.ui:show_menu{
        title = model.manga.name,
        items = {
            { text = "继续阅读", callback = function()
                return open_chapter(continue_chapter, continue_position)
            end },
            { text = "选择章节", callback = function()
                local items = {}
                for position, chapter in ipairs(chapters) do
                    local current, current_position = chapter, position
                    items[#items + 1] = { text = current.name, callback = function()
                        return open_chapter(current, current_position)
                    end }
                end
                self.ui:show_menu{ title = model.manga.name, items = items,
                    on_back = function() self:_open_cached_manga(shelf_model) end }
                return true
            end },
        },
        on_back = function()
            return self:show_offline_shelf({ return_path = self.offline_shelf_return_path })
        end,
    }
    return true
end

function UiLibrary:_open_cached_document(model)
    if not model or not model._premium_resumed then
        local copy = model
        return self:_premium_gate("open", model and model.manga or model, function()
            if type(copy) == "table" then copy._premium_resumed = true end
            return self:_open_cached_document(copy)
        end)
    end
    if model then model._premium_resumed = nil end
    if type(self.open_cached_document) ~= "function" then return false end
    local return_path = self.offline_shelf_return_path
    local entry = {
        name = model.name,
        path = model.remote_path,
        local_path = model.local_path,
        file_kind = "document",
        connection = self:_connection(),
    }
    local function open_document()
        return self.open_cached_document(entry, {
            on_closed = function()
                self:show_offline_shelf({ return_path = return_path })
            end,
            on_error = function(err)
                self.ui:show_info(Errors.message(err))
                self:show_offline_shelf({ return_path = return_path })
            end,
        })
    end
    if self.cover_grid and type(self.cover_grid.leave_for) == "function" then
        local left = self.cover_grid:leave_for(open_document)
        if left ~= false then return left end
    end
    return open_document()
end

function UiLibrary:_show_opds_cached_pointers(options)
    local epoch, identity = self:_enter_view()
    local connection, items = self:_connection(), {}
    for _, record in ipairs(self.library:list_mangas(connection, self.library.ALL)) do
        local current = record
        if current.layout == "opds" and current.manga.pointer_path then
            items[#items + 1] = {
                id = current.manga.path, manga = current.manga, name = current.manga.name,
                layout = "opds", offline_shelf = true,
                local_cover_path = self:_record_cover_path(current, connection),
                -- The shelf retains pointers/covers, never downloaded body pages.
                cache_progress = 0, cache_complete = false,
                on_open = function()
                    if not self:_is_current(epoch, identity) then return false end
                    return self:_premium_gate("open", current.manga, function()
                        if not self:_is_current(epoch, identity) then return false end
                        return self.cover_grid:leave_for(function()
                            if self.open_opds_record then
                                return self.open_opds_record(current, function()
                                    return self:show_offline_shelf(options)
                                end)
                            end
                            return false
                        end)
                    end)
                end,
            }
        end
    end
    return self.cover_grid:show{
        title = "缓存漫画", subtitle = "仅阅读指针与封面，正文未离线",
        items = items, allow_multi_select = false,
        on_back = self:_callback("back from OPDS cached pointers", function()
            return self:show_home()
        end, true),
    }
end

function UiLibrary:show_offline_shelf(options)
    options = options or {}
    if self:_connection().kind == "opds" then return self:_show_opds_cached_pointers(options) end
    local return_path = options.return_path
    if not return_path then
        return_path = Path.normalize_remote((self:_connection() or {}).root_path or "/")
    end
    if not self.offline_cache or type(self.offline_cache.list_mangas) ~= "function" then return false end
    local identity = self:_offline_identity()
    if not identity then return false end
    local root = self.offline_cache:root()
    local epoch = self:_enter_view()
    local ok, models = pcall(self.offline_cache.list_mangas, self.offline_cache, identity)
    if not ok or type(models) ~= "table" then return false end
    local items = {}
    for _, model in ipairs(models) do
        local current = model
        items[#items + 1] = {
            id = (current.identity or identity) .. "\0" .. current.manga.path,
            manga = current.manga,
            name = current.manga.name,
            local_cover_path = current.cover_path,
            offline_shelf = true,
            cache_progress = current.progress,
            cache_complete = current.status == "complete"
                and (tonumber(current.progress) or 0) >= 1,
            on_open = function() self:_open_cached_manga(current) end,
            on_action = function()
                if type(self.show_offline_cache) == "function" then return self.show_offline_cache(current.manga) end
            end,
        }
    end
    if self.document_cache and type(self.document_cache.list_documents) == "function" then
        local listed, documents = pcall(
            self.document_cache.list_documents, self.document_cache, identity)
        if listed and type(documents) == "table" then
            for _, document in ipairs(documents) do
                local current = document
                items[#items + 1] = {
                    id = identity .. "\0document\0" .. current.remote_path,
                    manga = { name = current.name, path = current.remote_path },
                    name = current.name,
                    document_cache_key = current.key,
                    local_document_path = current.local_path,
                    offline_shelf = true,
                    cache_progress = 1,
                    cache_complete = true,
                    on_open = function() self:_open_cached_document(current) end,
                }
            end
        end
    end
    if self.document_bridge and type(self.document_bridge.list_pending) == "function" then
        local listed, documents = pcall(
            self.document_bridge.list_pending, self.document_bridge, identity)
        if listed and type(documents) == "table" then
            for _, document in ipairs(documents) do
                local current = document
                items[#items + 1] = {
                    id = identity .. "\0document\0" .. current.remote_path,
                    manga = { name = current.name, path = current.remote_path },
                    name = current.name,
                    document_cache_key = current.key,
                    offline_shelf = true,
                    cache_progress = current.progress,
                    cache_complete = false,
                }
            end
        end
    end
    local shown = self.cover_grid:show{
        title = "缓存漫画", subtitle = ("%d 本漫画"):format(#items), items = items,
        allow_multi_select = true,
        on_batch_action = self:_callback("batch delete offline manga", function(selected)
            return self:_confirm_delete_offline(selected)
        end, false),
        on_settings = self:_callback("open offline shelf settings", function()
            if type(self.show_offline_cache) == "function" then return self.show_offline_cache() end
            return false
        end, false),
        on_back = self:_callback("back from offline shelf", function()
            self:_cancel_offline_refresh()
            self.offline_shelf_identity = nil
            self.offline_shelf_root = nil
            self.offline_shelf_epoch = nil
            self.offline_shelf_grid_epoch = nil
            self.offline_shelf_ids = nil
            self.offline_shelf_return_path = nil
            if return_path and self.browser and type(self.browser.show_library) == "function" then
                return self.browser:show_library(false, return_path)
            end
            return true
        end, true),
    }
    if shown then
        self.offline_shelf_return_path = return_path
        self.offline_shelf_identity = identity
        self.offline_shelf_root = root
        self.offline_shelf_epoch = epoch
        self.offline_shelf_grid_epoch = self.cover_grid.view_sequence
        self.offline_shelf_ids = {}
        for _, item in ipairs(items) do self.offline_shelf_ids[item.id] = true end
        self:_schedule_offline_refresh()
    end
    return shown
end

function UiLibrary:_cancel_offline_refresh()
    local task = self.offline_refresh_task
    self.offline_refresh_task = nil
    if task and self.scheduler and type(self.scheduler.unschedule) == "function" then
        pcall(self.scheduler.unschedule, self.scheduler, task)
    end
    return true
end

function UiLibrary:_schedule_offline_refresh()
    self:_cancel_offline_refresh()
    if not self.scheduler or type(self.scheduler.scheduleIn) ~= "function"
        or not self.offline_shelf_identity or not self.offline_shelf_root then return false end
    local epoch, identity, root, grid_epoch = self.view_epoch,
        self.offline_shelf_identity, self.offline_shelf_root, self.offline_shelf_grid_epoch
    local delay = type(self.settings.get_offline_refresh_seconds) == "function"
        and self.settings:get_offline_refresh_seconds() or 15
    local task
    task = function()
        if self.offline_refresh_task ~= task then return false end
        self.offline_refresh_task = nil
        if epoch ~= self.view_epoch or self.offline_shelf_identity ~= identity
            or self.offline_shelf_root ~= root
            or self.offline_shelf_grid_epoch ~= self.cover_grid.view_sequence
            or grid_epoch ~= self.cover_grid.view_sequence
            or self:_offline_identity() ~= identity
            or self.offline_cache:root() ~= root then return false end
        local ok, models = pcall(self.offline_cache.list_mangas, self.offline_cache, identity)
        if not ok or type(models) ~= "table" then return false end
        local active
        if self.offline_manager and type(self.offline_manager.status) == "function" then
            local status_ok, status = pcall(self.offline_manager.status, self.offline_manager)
            if status_ok and type(status) == "table" and status.running == true
                and status.identity == identity and status.root == root
                and (tonumber(status.total) or 0) > 0 then active = status end
        end
        for _, model in ipairs(models) do
            local manga = model and model.manga
            local item_id = manga and type(manga.path) == "string"
                and identity .. "\0" .. manga.path or nil
            if item_id and self.offline_shelf_ids and self.offline_shelf_ids[item_id] then
                local progress = tonumber(model.progress) or 0
                if active and active.manga_path == manga.path then
                    progress = ((tonumber(active.downloaded) or 0)
                        + (tonumber(active.cached) or 0)) / tonumber(active.total)
                end
                self.cover_grid:update_progress(item_id, progress,
                    model.status == "complete" and progress >= 1)
            end
        end
        if self.document_bridge and type(self.document_bridge.list_pending) == "function" then
            local listed, documents = pcall(
                self.document_bridge.list_pending, self.document_bridge, identity)
            if listed and type(documents) == "table" then
                for _, document in ipairs(documents) do
                    local item_id = identity .. "\0document\0" .. document.remote_path
                    if self.offline_shelf_ids and self.offline_shelf_ids[item_id] then
                        self.cover_grid:update_progress(item_id,
                            tonumber(document.progress) or 0, false)
                    end
                end
            end
        end
        if self.document_cache and type(self.document_cache.list_documents) == "function" then
            local listed, documents = pcall(
                self.document_cache.list_documents, self.document_cache, identity)
            if listed and type(documents) == "table" then
                for _, document in ipairs(documents) do
                    local item_id = identity .. "\0document\0" .. document.remote_path
                    if self.offline_shelf_ids and self.offline_shelf_ids[item_id] then
                        self.cover_grid:update_progress(item_id, 1, true)
                    end
                end
            end
        end
        return self:_schedule_offline_refresh()
    end
    self.offline_refresh_task = task
    local ok, result = pcall(self.scheduler.scheduleIn, self.scheduler, delay, task)
    if not ok or result == false then self.offline_refresh_task = nil; return false end
    return true
end

function UiLibrary:_confirm_delete_offline(items)
    local identity = self.offline_shelf_identity or self:_offline_identity()
    local root = self.offline_shelf_root or self.offline_cache:root()
    local paths, document_keys, seen, rejected = {}, {}, {}, {}
    local status = self.offline_manager and self.offline_manager.status
        and self.offline_manager:status() or nil
    for _, item in ipairs(items or {}) do
        if item and item.document_cache_key then
            local key = tostring(item.document_cache_key)
            if not seen[key] then
                seen[key] = true
                document_keys[#document_keys + 1] = key
            end
        else
        local manga = item and item.manga
        local path = manga and manga.path
        if type(path) == "string" and path ~= "" and not seen[path] then
            seen[path] = true
            if status and status.running == true
                and status.identity == identity and status.root == root
                and status.manga_path == path then
                rejected[#rejected + 1] = path
            else
                paths[#paths + 1] = path
            end
        end
        end
    end
    if #rejected > 0 and self.ui and self.ui.show_info then
        self.ui:show_info("正在下载的漫画不能删除。")
    end
    if #paths == 0 and #document_keys == 0 then
        return self:show_offline_shelf({ return_path = self.offline_shelf_return_path })
    end
    local return_path = self.offline_shelf_return_path
    local confirm = function()
        local result = #paths > 0 and self.offline_cache:delete_mangas(identity, paths)
            or { deleted_paths = {}, failed_paths = {} }
        local deleted = result and result.deleted_paths or {}
        local failed = result and result.failed_paths or {}
        for _, key in ipairs(document_keys) do
            local ok, removed = pcall(self.document_cache.remove, self.document_cache, key)
            if ok and removed then
                deleted[#deleted + 1] = key
            else
                failed[#failed + 1] = key
            end
        end
        if self.ui and self.ui.show_info then
            self.ui:show_info(("已删除 %d 本缓存漫画，%d 本失败。"):format(#deleted, #failed))
        end
        return self:show_offline_shelf({ return_path = return_path })
    end
    local cancel = function()
        return self:show_offline_shelf({ return_path = return_path })
    end
    if self.ui and type(self.ui.confirm) == "function" then
        return self.ui:confirm{
            text = ("确定删除选中的 %d 本缓存漫画或文件？")
                :format(#paths + #document_keys),
            ok_text = "删除",
            cancel_text = "取消",
            on_confirm = self:_callback("confirm offline manga deletion", confirm, false),
            cancel_callback = self:_callback("cancel offline manga deletion", cancel, false),
        }
    end
    if self.ui and type(self.ui.show_info) == "function" then
        self.ui:show_info("当前界面不支持删除确认，已取消删除。")
    end
    self:show_offline_shelf({ return_path = self.offline_shelf_return_path })
    return false
end

function UiLibrary:invalidate_offline_shelf()
    if not self.offline_shelf_identity
        or self.offline_shelf_grid_epoch ~= self.cover_grid.view_sequence then return false end
    return self:cancel()
end

function UiLibrary:update_offline_progress(summary)
    if type(summary) ~= "table" or not self.offline_shelf_identity
        or not self.offline_shelf_root
        or self.offline_shelf_epoch ~= self.view_epoch
        or self.offline_shelf_grid_epoch ~= self.cover_grid.view_sequence
        or self:_offline_identity() ~= self.offline_shelf_identity
        or self.offline_cache:root() ~= self.offline_shelf_root
        or summary.root ~= self.offline_shelf_root
        or summary.identity ~= self.offline_shelf_identity then return false end
    local total = tonumber(summary.total) or 0
    if total <= 0 or type(summary.manga_path) ~= "string" then return false end
    local progress = ((tonumber(summary.downloaded) or 0) + (tonumber(summary.cached) or 0)) / total
    return self.cover_grid:update_progress(summary.identity .. "\0" .. summary.manga_path,
        progress, summary.status == "complete" and (tonumber(summary.failed) or 0) == 0)
end

function UiLibrary:_invalidate_view(cancel_cover_grid)
    self:_cancel_offline_refresh()
    self.view_epoch = self.view_epoch + 1
    self.offline_shelf_identity = nil
    self.offline_shelf_root = nil
    self.offline_shelf_epoch = nil
    self.offline_shelf_grid_epoch = nil
    self.offline_shelf_ids = nil
    self.offline_shelf_return_path = nil
    local handle = self.active_handle
    self.active_handle = nil
    if cancel_cover_grid and self.cover_grid and self.cover_grid.cancel then
        pcall(self.cover_grid.cancel, self.cover_grid)
    end
    if handle and handle.cancel then pcall(handle.cancel, handle) end
    return self.view_epoch
end

function UiLibrary:_enter_view()
    local epoch = self:_invalidate_view(true)
    return epoch, connection_identity(self:_connection())
end

function UiLibrary:_is_current(epoch, identity)
    return epoch == self.view_epoch and identity == connection_identity(self:_connection())
end

function UiLibrary:_begin_operation()
    local epoch = self:_invalidate_view(false)
    local identity = connection_identity(self:_connection())
    local state = { epoch = epoch, identity = identity, settled = false, handle = nil }
    local function terminal(label, callback, fallback)
        return SafeCallback.wrap(self.error_reporter or self.ui, label, function(...)
            if state.settled then return fallback end
            state.settled = true
            if self.active_handle == state.handle then self.active_handle = nil end
            if not self:_is_current(state.epoch, state.identity) then return fallback end
            return callback(...)
        end, fallback)
    end
    local function attach(handle)
        state.handle = handle
        if state.settled then return handle end
        if self:_is_current(state.epoch, state.identity) then
            self.active_handle = handle
        else
            state.settled = true
            if handle and handle.cancel then pcall(handle.cancel, handle) end
        end
        return handle
    end
    return terminal, attach
end

function UiLibrary:_track_view_handle(handle, epoch, identity)
    if not handle then return nil end
    if self:_is_current(epoch, identity) then
        self.active_handle = handle
    elseif handle.cancel then
        pcall(handle.cancel, handle)
    end
    return handle
end

function UiLibrary:cancel(cancel_cover_grid)
    self:_invalidate_view(cancel_cover_grid ~= false)
    if self.ui and type(self.ui.close_all) == "function" then
        pcall(self.ui.close_all, self.ui)
    else
        self:_close_choice()
        if self.ui and type(self.ui.close_menu) == "function" then
            pcall(self.ui.close_menu, self.ui)
        end
    end
    return true
end

function UiLibrary:_categories()
    return self.library:list_categories(self:_connection())
end

function UiLibrary:_view_name(view_id)
    if view_id == self.library.ALL then return "全部漫画" end
    if view_id == self.library.UNCATEGORIZED then return "未分类" end
    for _, category in ipairs(self:_categories()) do
        if category.id == view_id then return category.name end
    end
    return "漫画分类"
end

function UiLibrary:_origin_name(origin)
    if type(origin) == "table" and origin.source == "rating" then
        return tostring(origin.rating) .. " 星评分架"
    end
    return self:_view_name(origin)
end

function UiLibrary:_show_origin(origin)
    if type(origin) == "table" and origin.source == "rating" then
        return self:show_rating_category(origin.rating)
    end
    return self:show_category(origin)
end

function UiLibrary:_show_library_error(code)
    self.ui:show_info(error_message(code))
end

-- Menu callbacks can run before KOReader invokes the menu's close callback.
-- Always tear down the library-owned layer first, otherwise a newly opened
-- history grid can sit above a stale management menu and trap input.
function UiLibrary:_return_to_history()
    if self.ui and type(self.ui.close_menu) == "function" then
        pcall(self.ui.close_menu, self.ui)
    end
    if self.cover_grid and type(self.cover_grid.cancel) == "function" then
        pcall(self.cover_grid.cancel, self.cover_grid)
    end
    if self.browser and type(self.browser.show_history) == "function" then
        return self.browser:show_history()
    end
    return false
end

function UiLibrary:_rating_max()
    if type(self.settings.get_rating_max) == "function" then
        return self.settings:get_rating_max()
    end
    return 5
end

function UiLibrary:_rating_text(record)
    local scale = self:_rating_max()
    local rating = self.library.rating_for and self.library.rating_for(record, scale)
        or tonumber(record and record.rating) or 0
    if rating <= 0 then return "未评分" end
    return ("%d / %d 星"):format(rating, scale)
end

function UiLibrary:_ensure_manga(record)
    local connection = self:_connection()
    if type(self.library.get_manga) == "function" then
        local existing = self.library:get_manga(connection, record.manga.path)
        if existing then return existing end
    end
    local options = {
        layout = record.layout,
        cover_hint = record.cover_hint,
    }
    if record.layout == "direct" and record.cover_hint then
        options.direct_cover_image = record.cover_hint.image
    end
    local ensure = self.library.ensure_manga or self.library.add_manga
    return ensure(self.library, connection, record.manga, options)
end

function UiLibrary:_deleted_message()
    self.ui:show_info("本地漫画文件已删除；封面、评分和阅读记录仍保留。可重新关联目录后继续阅读。")
end

function UiLibrary:_local_delete_error(err)
    local code = type(err) == "table" and err.code or tostring(err or "unknown")
    local messages = {
        not_local = "只有 Kindle 本地漫画可以永久删除。",
        unsafe_target = "目录安全检查失败，未删除任何漫画文件。",
        archive_failed = "封面归档或校验失败，未删除任何漫画文件。",
        delete_failed = "删除未完整完成，请不要重复操作，并检查该漫画目录。",
        metadata_failed = "漫画保留记录保存失败，已停止删除。",
        metadata_finalize_failed = "本地文件已删除且封面已保留，但删除状态保存失败。请勿重复删除，重启 KOReader 后检查记录。",
        already_deleted = "该本地漫画文件夹已经删除。",
    }
    self.ui:show_info(messages[code] or "本地漫画删除失败，未继续操作。")
end

function UiLibrary:_delete_local_manga(record, on_complete)
    if not self.local_archive then return self:_local_delete_error("not_local") end
    local connection = self:_connection()
    local function remove_with_cover(image)
        local deleted, delete_error = self.local_archive:archive_and_delete(
            connection, record, image)
        if not deleted then return self:_local_delete_error(delete_error) end
        self.unavailable_paths[record.manga.path] = nil
        self.ui:show_info("本地漫画文件夹已永久删除；封面、评分和阅读记录已保留。")
        if on_complete then return on_complete(deleted) end
        return true
    end
    if record.archived_cover_path then return remove_with_cover(nil) end
    local terminal, attach = self:_begin_operation()
    local handle = self.cover_service:resolve(connection, record, {
        on_ready = terminal("archive local manga cover", function(image)
            return remove_with_cover(image)
        end),
        on_error = terminal("reject local manga deletion without cover", function()
            self:_local_delete_error({ code = "archive_failed" })
        end),
    })
    attach(handle)
    return handle
end

function UiLibrary:_append_local_delete(items, record, on_complete)
    local connection = self:_connection()
    if not self.local_archive or connection.kind ~= "local" or record.local_deleted then return end
    items[#items + 1] = {
        text = "永久删除本地漫画文件夹",
        callback = self:_callback("request permanent local manga deletion", function()
            self.ui:confirm{
                text = "永久删除“" .. record.manga.name
                    .. "”的本地文件夹及全部内容？此操作不可恢复；封面、评分和阅读记录会保留。",
                ok_text = "永久删除",
                on_confirm = self:_callback("confirm permanent local manga deletion", function()
                    return self:_delete_local_manga(record, on_complete)
                end),
            }
        end),
    }
end

function UiLibrary:show_home()
    if self.browser and type(self.browser.close_menu) == "function" then
        self.browser:close_menu()
    end
    self:_enter_view()
    local connection = self:_connection()
    local all_records = self.library:list_mangas(connection, self.library.ALL)
    local uncategorized = self.library:list_mangas(connection, self.library.UNCATEGORIZED)
    local items = {
        {
            text = "添加漫画",
            callback = self:_callback("open add manga picker", function()
                self:show_add_picker()
            end),
        },
        {
            text = "管理分类",
            callback = self:_callback("open category management", function()
                self:show_categories()
            end),
        },
        {
            text = ("全部漫画（%d）"):format(#all_records),
            callback = self:_callback("open all manga", function()
                self:show_category(self.library.ALL)
            end),
        },
        {
            text = ("未分类（%d）"):format(#uncategorized),
            callback = self:_callback("open uncategorized manga", function()
                self:show_category(self.library.UNCATEGORIZED)
            end),
        },
    }
    for _, category in ipairs(self.library:list_categories(connection)) do
        local category_id = category.id
        local records = self.library:list_mangas(connection, category_id)
        items[#items + 1] = {
            text = ("%s（%d）"):format(category.name, #records),
            callback = self:_callback("open manga category", function()
                self:show_category(category_id)
            end),
        }
    end
    self.ui:show_menu{
        title = "漫画分类架",
        items = items,
        back_text = "← 返回漫画书架",
        on_back = self:_callback("back to WebDAV shelf", function()
            self:cancel()
            self.browser:show_library(false, self.browser.current_path)
        end),
    }
end

function UiLibrary:show_rating_home()
    if self.browser and type(self.browser.close_menu) == "function" then
        self.browser:close_menu()
    end
    self:_enter_view()
    local connection = self:_connection()
    local scale = self:_rating_max()
    local items = {
        {
            text = ("评分档位：%d 星"):format(scale),
            callback = self:_callback("open rating scale settings", function()
                self:show_rating_scale_settings()
            end),
        },
    }
    for rating = scale, 1, -1 do
        local current_rating = rating
        local records = self.library:list_mangas_by_rating(
            connection, current_rating, scale)
        items[#items + 1] = {
            text = ("%d 星（%d）"):format(current_rating, #records),
            callback = self:_callback("open manga rating shelf", function()
                self:show_rating_category(current_rating)
            end),
        }
    end
    self.ui:show_menu{
        title = "漫画评分架",
        subtitle = "仅显示已评分漫画",
        items = items,
        back_text = "← 返回漫画书架",
        on_back = self:_callback("back from manga rating shelf", function()
            self:cancel()
            self.browser:show_library(false, self.browser.current_path)
        end),
    }
end

function UiLibrary:show_rating_scale_settings()
    self:_enter_view()
    local selected = self:_rating_max()
    local items = {}
    for scale = 5, 10 do
        local current_scale = scale
        items[#items + 1] = {
            text = (selected == current_scale and "☑ " or "☐ ")
                .. current_scale .. " 星",
            callback = self:_callback("save rating scale", function()
                local saved, code = self.settings:set_rating_max(current_scale)
                if not saved then
                    self.ui:show_info(error_message(code))
                    return false
                end
                self:show_rating_home()
                return true
            end, false),
        }
    end
    self.ui:show_menu{
        title = "设置评分档位",
        subtitle = "原评分会按比例换算，不会丢失",
        items = items,
        on_back = self:_callback("cancel rating scale settings", function()
            self:show_rating_home()
        end),
    }
end

function UiLibrary:show_rating_category(rating)
    self:_enter_view()
    local scale = self:_rating_max()
    rating = math.floor(tonumber(rating) or 0)
    if rating < 1 or rating > scale then return self:show_rating_home() end
    local origin = { source = "rating", rating = rating }
    self.current_view = origin
    local records = self.library:list_mangas_by_rating(
        self:_connection(), rating, scale)
    local items = {}
    for _, record in ipairs(records) do
        local current = record
        items[#items + 1] = {
            id = current.key or current.manga.path,
            manga = current.manga,
            cover_hint = current.cover_hint,
            layout = current.layout,
            chapter = current.cover_hint and current.cover_hint.chapter or nil,
            is_read = current.is_read == true,
            local_cover_path = self:_record_cover_path(current),
            local_deleted = current.local_deleted == true,
            text = current.manga.name .. "\n" .. current.manga.path,
            mandatory = "管理",
            on_open = self:_callback("open rated manga", function()
                if current.local_deleted then return self:_deleted_message() end
                if self:_uses_grid_open() then
                    self:show_open_choice(current, origin)
                else
                    self:_open_record(current, origin)
                end
            end),
            on_action = self:_callback("manage rated manga", function()
                self:show_manage_manga(current, origin)
            end),
            record = current,
        }
    end
    if self.ui and type(self.ui.close_menu) == "function" then self.ui:close_menu() end
    local shown = self.cover_grid:show{
        title = ("%d 星漫画"):format(rating),
        subtitle = ("%d 本漫画 · 满分 %d 星"):format(#items, scale),
        items = items,
        allow_multi_select = true,
        on_batch_action = self:_callback("manage rating shelf batch", function(selected)
            local selected_records = {}
            for _, item in ipairs(selected or {}) do
                selected_records[#selected_records + 1] = item.record or item
            end
            return self:show_rating_batch(selected_records, function()
                self:show_rating_category(rating)
            end)
        end, false),
        on_back = self:_callback("back from manga rating category", function()
            self:show_rating_home()
        end),
    }
    if shown == false then return self:show_rating_home() end
    if #items == 0 then self.ui:show_info("这个评分档位还没有漫画。") end
end

function UiLibrary:_open_record(record, view_id, premium_checked)
    if not premium_checked then
        return self:_premium_gate("open", record and record.manga, function()
            return self:_open_record(record, view_id, true)
        end)
    end
    if record and record.layout == "opds" and type(self.open_opds_record) == "function" then
        return self.open_opds_record(record, function()
            return self:_show_origin(view_id)
        end)
    end
    local terminal, attach = self:_begin_operation()
    local handle = self.browser:identify_manga(record.manga, {
        allow_cached = true,
        on_success = terminal("open classified manga", function(result)
            self.unavailable_paths[record.manga.path] = nil
            self.browser:present_manga(result, {
                source = type(view_id) == "table" and view_id.source or "category",
                back_text = "← 返回" .. self:_origin_name(view_id),
                on_return = self:_callback("return to manga category", function()
                    self:_show_origin(view_id)
                end),
            })
        end),
        on_failure = terminal("mark unavailable classified manga", function(err)
            self.unavailable_paths[record.manga.path] = true
            self.ui:show_info(Errors.message(err))
            self:_show_origin(view_id)
        end),
    })
    attach(handle)
end

function UiLibrary:_uses_grid_open()
    return self.cover_grid and type(self.cover_grid.leave_for) == "function"
        and self.browser and type(self.browser.prepare_resume) == "function"
        and type(self.browser.prepare_chapter) == "function"
end

function UiLibrary:_history_for(record)
    local progress = self.progress or self.browser and self.browser.progress
    if not progress or type(progress.list_history) ~= "function" then return nil end
    local ok, records = pcall(progress.list_history, progress, self:_connection())
    if not ok or type(records) ~= "table" then return nil end
    local wanted = Path.normalize_remote(record and record.manga and record.manga.path)
    for _, history in ipairs(records) do
        if Path.normalize_remote(history.manga and history.manga.path) == wanted then
            return history
        end
    end
    return nil
end

function UiLibrary:_close_choice()
    if self.ui and type(self.ui.close_choice) == "function" then
        pcall(self.ui.close_choice, self.ui)
    end
end

function UiLibrary:_prepare_and_leave(_view_id, prepare, on_ready)
    local terminal, attach = self:_begin_operation()
    local ready = terminal("finish shelf open", function(context)
        self:_close_choice()
        if self.ui and type(self.ui.close_menu) == "function" then
            pcall(self.ui.close_menu, self.ui)
        end
        if self.cover_grid and type(self.cover_grid.leave_for) == "function" then
            self.cover_grid:leave_for(function() on_ready(context) end)
        else
            on_ready(context)
        end
    end)
    local failed = terminal("fail shelf open", function(err)
        self:_close_choice()
        self.ui:show_info(Errors.message(err))
    end)
    local ok, handle = pcall(prepare, ready, failed)
    if not ok then
        failed(handle)
        return nil
    end
    attach(handle)
    return handle
end

function UiLibrary:_prepare_from_result(result, callbacks)
    if type(result) ~= "table" then
        return callbacks.on_error({ code = "empty", kind = "chapters" })
    end
    if result.layout == "direct" then
        return self.browser:prepare_chapter(result.manga, result.chapter, {
            layout = "direct", cover_hint = result.cover_hint,
        }, callbacks)
    end
    local index = result.chapters_index
    local chapter = index and index.get and index:get(1)
    if not chapter then return callbacks.on_error({ code = "empty", kind = "chapters" }) end
    return self.browser:prepare_chapter(result.manga, chapter, {
        layout = "chapters", cover_hint = result.cover_hint,
    }, callbacks)
end

function UiLibrary:_show_chapter_picker(record, view_id, result)
    local index = result and result.chapters_index
    local count = tonumber(index and index:count()) or 0
    if count == 0 then
        self.ui:show_info(Errors.message({ code = "empty", kind = "chapters" }))
        return
    end
    local page_size = 50
    local total_pages = math.max(1, math.ceil(count / page_size))
    local page = 1
    local function render()
        local items = {}
        local first = (page - 1) * page_size + 1
        local last = math.min(count, first + page_size - 1)
        for position = first, last do
            local chapter = index:get(position)
            if chapter then
                local current = chapter
                items[#items + 1] = {
                    text = current.name,
                    callback = self:_callback("prepare selected chapter", function()
                        self:_prepare_and_leave(view_id, function(on_ready, on_error)
                            return self.browser:prepare_chapter(result.manga, current, {
                                layout = result.layout, cover_hint = result.cover_hint,
                            }, { on_ready = on_ready, on_error = on_error })
                        end, function(context)
                            self.browser:open_prepared_reader(context)
                        end)
                    end),
                }
            end
        end
        if page > 1 then
            table.insert(items, 1, {
                text = "← 上一页",
                callback = self:_callback("previous chapter picker page", function()
                    page = page - 1
                    render()
                    return true
                end, true),
            })
        end
        if page < total_pages then
            items[#items + 1] = {
                text = "下一页 →",
                callback = self:_callback("next chapter picker page", function()
                    page = page + 1
                    render()
                    return true
                end, true),
            }
        end
        self.ui:show_menu{
            title = record.manga.name,
            subtitle = ("选择章节（%d / %d）"):format(page, total_pages),
            items = items,
            on_back = self:_callback("back from chapter picker", function()
                self:show_open_choice(record, view_id)
                return true
            end, true),
        }
    end
    render()
end

function UiLibrary:show_open_choice(record, view_id, premium_checked)
    if not premium_checked then
        return self:_premium_gate("open", record and record.manga, function()
            return self:show_open_choice(record, view_id, true)
        end)
    end
    if record and record.layout == "opds" and type(self.open_opds_record) == "function" then
        return self.cover_grid:leave_for(function()
            return self:_open_record(record, view_id, true)
        end)
    end
    local epoch = self.view_epoch
    local identity = connection_identity(self:_connection())
    local function current()
        return self:_is_current(epoch, identity)
    end
    local function guard(label, callback)
        return self:_callback(label, function()
            if not current() then return end
            return callback()
        end)
    end
    local history = self:_history_for(record)
    local continue_open = guard("continue manga", function()
        self:_prepare_and_leave(view_id, function(on_ready, on_error)
            if history then
                return self.browser:prepare_resume(history, {
                    on_ready = on_ready, on_error = on_error,
                })
            end
            return self.browser:identify_manga(record.manga, {
                allow_cached = true,
                on_success = function(result)
                    self:_prepare_from_result(result, {
                        on_ready = on_ready, on_error = on_error,
                    })
                end,
                on_failure = on_error,
            })
        end, function(context)
            self.browser:open_prepared_reader(context)
        end)
    end)
    local choose_chapter = guard("choose manga chapter", function()
        self:_close_choice()
        local terminal, attach = self:_begin_operation()
        local handle = self.browser:identify_manga(record.manga, {
            allow_cached = true,
            on_success = terminal("show chapter picker", function(result)
                self:_show_chapter_picker(record, view_id, result)
            end),
            on_failure = terminal("load chapter picker", function(err)
                self.ui:show_info(Errors.message(err))
            end),
        })
        attach(handle)
    end)
    local cancel = guard("cancel manga open choice", function() self:_close_choice() end)
    local model = {
        title = record.manga.name,
        buttons = { continue = continue_open, chapters = choose_chapter, cancel = cancel },
    }
    if self.ui and type(self.ui.show_choice) == "function" then
        self.ui:show_choice(model)
    else
        self.ui:show_menu{
            title = model.title,
            items = {
                { text = "继续阅读", callback = model.buttons.continue },
                { text = "选择章节", callback = model.buttons.chapters },
                { text = "取消", callback = model.buttons.cancel },
            },
            on_back = model.buttons.cancel,
        }
    end
end

function UiLibrary:show_category(view_id)
    self:_enter_view()
    view_id = view_id or self.library.ALL
    self.current_view = view_id
    local records = self.library:list_mangas(self:_connection(), view_id)
    local items = {}
    for _, record in ipairs(records) do
        local current = record
        local status = self.unavailable_paths[current.manga.path] and "\n路径不可用" or ""
        items[#items + 1] = {
            id = current.key or current.manga.path,
            manga = current.manga,
            cover_hint = current.cover_hint,
            layout = current.layout,
            chapter = current.cover_hint and current.cover_hint.chapter or nil,
            is_read = current.is_read == true,
            local_cover_path = self:_record_cover_path(current),
            local_deleted = current.local_deleted == true,
            text = current.manga.name .. "\n" .. current.manga.path .. status,
            mandatory = "管理",
            on_open = self:_callback("open classified manga", function()
                if current.local_deleted then return self:_deleted_message() end
                if self:_uses_grid_open() then
                    self:show_open_choice(current, view_id)
                else
                    self:_open_record(current, view_id)
                end
            end),
            on_action = self:_callback("manage classified manga", function()
                self:show_manage_manga(current, view_id)
            end),
            record = current,
        }
    end
    if self.ui and type(self.ui.close_menu) == "function" then self.ui:close_menu() end
    local shown = self.cover_grid:show{
        title = self:_view_name(view_id),
        subtitle = ("%d 本漫画"):format(#items),
        items = items,
        allow_multi_select = true,
        on_batch_action = self:_callback("manage category shelf batch", function(selected)
            local selected_records = {}
            for _, item in ipairs(selected or {}) do
                selected_records[#selected_records + 1] = item.record or item
            end
            if view_id ~= self.library.ALL and view_id ~= self.library.UNCATEGORIZED then
                return self:show_category_batch(selected_records, view_id,
                    self:_view_name(view_id), function() self:show_category(view_id) end)
            end
            return self:show_history_batch(selected_records, function()
                self:show_category(view_id)
            end)
        end, false),
        on_back = self:_callback("back from manga category", function()
            self:show_home()
        end),
    }
    if shown == false then return self:show_home() end
    if #items == 0 then self.ui:show_info("这个分类中还没有漫画。") end
end

function UiLibrary:show_rating_picker(record, on_done, on_back)
    self:_enter_view()
    local scale = self:_rating_max()
    local current_rating = self.library.rating_for
        and self.library.rating_for(record, scale) or tonumber(record.rating) or 0
    local items = {}
    for rating = 0, scale do
        local selected_rating = rating
        items[#items + 1] = {
            text = (current_rating == selected_rating and "☑ " or "☐ ")
                .. (selected_rating == 0 and "未评分" or (selected_rating .. " 星")),
            callback = self:_callback("save manga rating", function()
                if selected_rating > 0 then
                    return self:_premium_gate("rating", record.manga, function()
                        return self:_save_rating(record, selected_rating, scale, on_done)
                    end)
                end
                return self:_save_rating(record, selected_rating, scale, on_done)
            end, false),
        }
    end
    self.ui:show_menu{
        title = "漫画评分",
        subtitle = record.manga.name,
        items = items,
        on_back = self:_callback("cancel manga rating", function()
            if on_back then return on_back() end
            return true
        end),
    }
end

function UiLibrary:_save_rating(record, selected_rating, scale, on_done)
                local saved, code = self.library:set_rating(self:_connection(),
                    record.manga.path, selected_rating, scale)
                if not saved then
                    self:_show_library_error(code)
                    return false
                end
                if on_done then return on_done(saved) end
                return true
end

function UiLibrary:show_add_picker()
    local epoch, identity = self:_enter_view()
    local handle = self.browser:show_folder_picker({
        title = "添加漫画",
        action_text = "添加",
        on_request_handle = function(request_handle)
            self:_track_view_handle(request_handle, epoch, identity)
        end,
        on_pick = self:_callback("recognize manga before add", function(manga)
            return self:_premium_gate("add", manga, function()
            local terminal, attach = self:_begin_operation()
            local recognition_handle = self.browser:identify_manga(manga, {
                allow_cached = false,
                on_success = terminal("choose categories for add", function(result)
                    self:show_category_picker({ manga = result.manga, category_ids = {} }, function(category_ids)
                        local direct_cover = result.layout == "direct"
                            and result.cover_hint and result.cover_hint.image or nil
                        local record, code = self.library:add_manga(self:_connection(), result.manga, {
                            category_ids = category_ids,
                            layout = result.layout,
                            cover_hint = result.cover_hint,
                            direct_cover_image = direct_cover,
                        })
                        if not record then
                            self:_show_library_error(code)
                            return false
                        end
                        self:show_category(self.library.ALL)
                        return true
                    end)
                end),
                on_failure = terminal("reject unrecognized manga", function(err)
                    self.ui:show_info(Errors.message(err))
                end),
            })
            attach(recognition_handle)
            return true
            end)
        end),
        on_back = self:_callback("back from add manga picker", function()
            self:show_home()
        end),
    })
    self:_track_view_handle(handle, epoch, identity)
end

function UiLibrary:_show_category_input(category)
    self:_enter_view()
    local is_rename = category ~= nil
    self.ui:show_input{
        title = is_rename and "重命名分类" or "新建分类",
        value = is_rename and category.name or "",
        on_save = self:_callback("save category name", function(value)
            local name = trim(value)
            local saved, code
            if is_rename then
                saved, code = self.library:rename_category(
                    self:_connection(), category.id, name)
            else
                saved, code = self.library:create_category(self:_connection(), name)
            end
            if not saved then
                self:_show_library_error(code)
                return false
            end
            self:show_categories()
            return true
        end, false),
        on_back = self:_callback("back from category input", function()
            self:show_categories()
        end),
    }
end

function UiLibrary:show_categories()
    self:_enter_view()
    local items = {
        {
            text = "新建分类",
            callback = self:_callback("create category", function()
                self:_show_category_input()
            end),
        },
        { text = "全部漫画（不可修改）" },
        { text = "未分类（不可修改）" },
    }
    for _, category in ipairs(self:_categories()) do
        local current = category
        items[#items + 1] = {
            text = current.name,
            mandatory = "删除",
            callback = self:_callback("rename category", function()
                self:_show_category_input(current)
            end),
            secondary_callback = self:_callback("request category deletion", function()
                self.ui:confirm{
                    text = "删除分类“" .. current.name .. "”？漫画会保留在分类架中。",
                    on_confirm = self:_callback("confirm category deletion", function()
                        if not self.library:remove_category(self:_connection(), current.id) then
                            self:_show_library_error("missing_category")
                            return
                        end
                        self:show_categories()
                    end),
                }
            end),
        }
    end
    self.ui:show_menu{
        title = "管理分类",
        items = items,
        on_back = self:_callback("back from category management", function()
            self:show_home()
        end),
    }
end

function UiLibrary:show_category_picker(record, on_save, on_cancel)
    self:_enter_view()
    assert(type(on_save) == "function", "category save callback is required")
    -- Keep a dialog-local copy so canceling cannot mutate a Library record by reference.
    local selected = {}
    for category_id, value in pairs(record and record.category_ids or {}) do
        if value then selected[category_id] = true end
    end
    local categories = self:_categories()
    local function render()
        local items = {}
        for _, category in ipairs(categories) do
            local current = category
            items[#items + 1] = {
                text = (selected[current.id] and "☑ " or "☐ ") .. current.name,
                callback = self:_callback("toggle manga category", function()
                    selected[current.id] = not selected[current.id] or nil
                    render()
                end),
            }
        end
        self.ui:show_menu{
            title = "选择分类",
            items = items,
            save_text = "保存",
            on_save = self:_callback("save manga categories", function()
                local category_ids = {}
                for _, category in ipairs(categories) do
                    if selected[category.id] then category_ids[#category_ids + 1] = category.id end
                end
                local needs_add = not record
                if record and not needs_add then
                    for _, category_id in ipairs(category_ids) do
                        if not record.category_ids or not record.category_ids[category_id] then
                            needs_add = true
                            break
                        end
                    end
                end
                if needs_add then
                    return self:_premium_gate("add", record and record.manga,
                        function() return on_save(category_ids) end)
                end
                return on_save(category_ids)
            end, false),
            on_back = self:_callback("cancel manga categories", function()
                if on_cancel then return on_cancel() end
                if record then
                    self:show_manage_manga(record, self.current_view)
                else
                    self:show_home()
                end
            end),
        }
    end
    render()
end

function UiLibrary:show_manage_manga(record, current_view)
    self:_enter_view()
    current_view = current_view or self.library.ALL
    self.current_view = current_view
    local fresh = type(self.library.get_manga) == "function"
        and self.library:get_manga(self:_connection(), record.manga.path) or record
    record = fresh or record
    local items = {
        {
            text = "评分：" .. self:_rating_text(record),
            callback = self:_callback("open manga rating", function()
                self:show_rating_picker(record, function(updated)
                    self:show_manage_manga(updated, current_view)
                end, function()
                    self:show_manage_manga(record, current_view)
                end)
            end),
        },
        {
            text = record.is_read and "标记为未读" or "标记为已读",
            callback = self:_callback("toggle manga read status", function()
                local saved, code = self.library:set_read(self:_connection(),
                    record.manga.path, not record.is_read)
                if not saved then
                    self:_show_library_error(code)
                    return false
                end
                self:show_manage_manga(saved, current_view)
                return true
            end),
        },
        {
            text = "编辑分类",
            callback = self:_callback("edit manga categories", function()
                self:show_category_picker(record, function(category_ids)
                    local saved, code = self.library:set_categories(
                        self:_connection(), record.manga.path, category_ids)
                    if not saved then
                        self:_show_library_error(code)
                        return false
                    end
                    self:_show_origin(current_view)
                    return true
                end)
            end),
        },
    }
    items[#items + 1] = {
        text = "缓存到 Kindle",
        callback = self:_callback("open whole manga cache", function()
            return self:_premium_gate("cache", record.manga, function()
                return self.cache_manga(record.manga)
            end)
        end, false),
    }
    if not record.local_deleted then
        items[#items + 1] = {
            text = "刷新封面",
            callback = self:_callback("refresh manga cover", function()
                local terminal, attach = self:_begin_operation()
                local refresh_handle = self.cover_service:refresh(self:_connection(), record, {
                    on_ready = terminal("finish manga cover refresh", function()
                        self:_show_origin(current_view)
                    end),
                    on_error = terminal("fail manga cover refresh", function(err)
                        self.ui:show_info(Errors.message(err))
                    end),
                })
                attach(refresh_handle)
            end),
        }
    end
    items[#items + 1] = {
            text = "重新关联目录",
            callback = self:_callback("open manga relink", function()
                self.relink_return_view = current_view
                self:show_relink_picker(record)
            end),
        }
    if type(current_view) ~= "table"
        and current_view ~= self.library.ALL and current_view ~= self.library.UNCATEGORIZED then
        items[#items + 1] = {
            text = "从当前分类移除",
            callback = self:_callback("request category membership removal", function()
                self.ui:confirm{
                    text = "将“" .. record.manga.name .. "”从当前分类移除？",
                    on_confirm = self:_callback("confirm category membership removal", function()
                        if not self.library:remove_from_category(
                            self:_connection(), record.manga.path, current_view) then
                            self:_show_library_error("missing_manga")
                            return
                        end
                        self:_show_origin(current_view)
                    end),
                }
            end),
        }
    end
    items[#items + 1] = {
        text = "从漫画书架移除",
        callback = self:_callback("request manga removal", function()
            self.ui:confirm{
                text = "从分类架移除“" .. record.manga.name .. "”？不会删除 NAS 文件。",
                on_confirm = self:_callback("confirm manga removal", function()
                    if not self.library:remove_manga(self:_connection(), record.manga.path) then
                        self:_show_library_error("missing_manga")
                        return
                    end
                    self.unavailable_paths[record.manga.path] = nil
                    self:_show_origin(current_view)
                end),
            }
        end),
    }
    self:_append_local_delete(items, record, function()
        self:_show_origin(current_view)
    end)
    self.ui:show_menu{
        title = "管理" .. record.manga.name,
        subtitle = record.manga.path,
        items = items,
        on_back = self:_callback("back from manga management", function()
            self:_show_origin(current_view)
        end),
    }
end

function UiLibrary:_unique_history_records(items)
    local records, seen = {}, {}
    for _, record in ipairs(items or {}) do
        local path = record and record.manga and record.manga.path
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            records[#records + 1] = record
        end
    end
    return records
end

function UiLibrary:_show_history_batch_result(label, success_count, errors)
    local failed = #errors
    local message = ("%s完成：成功 %d 本，失败 %d 本。"):format(
        label, success_count, failed)
    if failed > 0 then
        local details = {}
        for _, failure in ipairs(errors) do
            details[#details + 1] = tostring(failure.name or failure.path or "未知漫画")
                .. "（" .. tostring(failure.code or "unknown") .. "）"
        end
        message = message .. "\n" .. table.concat(details, "；")
    end
    self.ui:show_info(message)
end

function UiLibrary:_batch_delete_history(records, return_to)
    local success_count, errors = 0, {}
    local connection = self:_connection()
    for _, record in ipairs(records or {}) do
        local path = record.manga.path
        local ok, result = pcall(function()
            return self.progress and self.progress:remove_history(connection, path)
        end)
        if ok and result ~= false then
            success_count = success_count + 1
        else
            errors[#errors + 1] = { name = record.manga.name, path = path,
                code = ok and "remove_failed" or result }
        end
    end
    self:_show_history_batch_result("批量删除历史", success_count, errors)
    if return_to then return_to() else self:_return_to_history() end
    return #errors == 0
end

function UiLibrary:_batch_add_categories(records, category_ids, return_to)
    local success_count, errors = 0, {}
    local connection = self:_connection()
    local additions = {}
    for _, category_id in ipairs(category_ids or {}) do additions[category_id] = true end
    for _, record in ipairs(records or {}) do
        local path = record.manga.path
        local ok, saved, code = pcall(function()
            local current = self:_ensure_manga(record)
            if not current then return nil, "missing_manga" end
            local merged, merged_seen = {}, {}
            for category_id, selected in pairs(current.category_ids or {}) do
                if selected and not merged_seen[category_id] then
                    merged_seen[category_id] = true
                    merged[#merged + 1] = category_id
                end
            end
            for _, category_id in ipairs(category_ids or {}) do
                if additions[category_id] and not merged_seen[category_id] then
                    merged_seen[category_id] = true
                    merged[#merged + 1] = category_id
                end
            end
            return self.library:set_categories(connection, path, merged)
        end)
        if ok and saved then
            success_count = success_count + 1
        else
            errors[#errors + 1] = { name = record.manga.name, path = path,
                code = ok and code or saved }
        end
    end
    self:_show_history_batch_result("批量添加分类", success_count, errors)
    if return_to then return_to() else self:_return_to_history() end
    return #errors == 0
end

function UiLibrary:_batch_set_rating(records, rating, scale, return_to)
    local success_count, errors = 0, {}
    local connection = self:_connection()
    for _, record in ipairs(records or {}) do
        local path = record.manga.path
        local ok, saved, code = pcall(function()
            return self.library:set_rating(connection, path, rating, scale)
        end)
        if ok and saved then
            success_count = success_count + 1
        else
            errors[#errors + 1] = { name = record.manga.name, path = path,
                code = ok and code or saved }
        end
    end
    self:_show_history_batch_result("批量评分", success_count, errors)
    if return_to then return_to() else self:_return_to_history() end
    return #errors == 0
end

function UiLibrary:_batch_remove_category(records, category_id, return_to)
    local success_count, errors = 0, {}
    local connection = self:_connection()
    for _, record in ipairs(records or {}) do
        local ok, saved, code = pcall(function()
            return self.library:remove_from_category(connection,
                record.manga.path, category_id)
        end)
        if ok and saved then
            success_count = success_count + 1
        else
            errors[#errors + 1] = { name = record.manga.name,
                path = record.manga.path, code = ok and code or saved }
        end
    end
    self:_show_history_batch_result("批量移出分类", success_count, errors)
    if return_to then return_to() else self:_return_to_history() end
    return #errors == 0
end

function UiLibrary:show_batch_category_picker(records, return_to, back_to_batch)
    self:_enter_view()
    local categories = self:_categories()
    local selected = {}
    local function render()
        local items = {}
        for _, category in ipairs(categories) do
            local current = category
            items[#items + 1] = {
                text = (selected[current.id] and "☑ " or "☐ ") .. current.name,
                callback = self:_callback("toggle batch history category", function()
                    selected[current.id] = not selected[current.id] or nil
                    render()
                end),
            }
        end
        self.ui:show_menu{
            title = "批量添加分类",
            items = items,
            save_text = "保存",
            on_save = self:_callback("save batch history categories", function()
                local category_ids = {}
                for _, category in ipairs(categories) do
                    if selected[category.id] then category_ids[#category_ids + 1] = category.id end
                end
                if #category_ids == 0 then
                    self.ui:show_info("请至少选择一个分类。")
                    return false
                end
                return self:_batch_add_categories(records, category_ids, return_to)
            end, false),
            on_back = self:_callback("cancel batch history categories", function()
                if back_to_batch then return back_to_batch() end
                self:show_history_batch(records, return_to)
            end),
        }
    end
    render()
end

function UiLibrary:show_batch_rating_picker(records, return_to, back_to_batch)
    self:_enter_view()
    local scale = self:_rating_max()
    local items = {}
    for rating = 0, scale do
        local selected_rating = rating
        items[#items + 1] = {
            text = selected_rating == 0 and "☐ 未评分"
                or ("☐ " .. selected_rating .. " 星"),
            callback = self:_callback("save batch history rating", function()
                return self:_batch_set_rating(records, selected_rating, scale, return_to)
            end, false),
        }
    end
    self.ui:show_menu{
        title = "批量评分",
        items = items,
        on_back = self:_callback("cancel batch history rating", function()
            if back_to_batch then return back_to_batch() end
            self:show_history_batch(records, return_to)
        end),
    }
end

function UiLibrary:show_history_batch(items, return_to)
    self:_enter_view()
    local records = self:_unique_history_records(items)
    if #records == 0 then
        self.ui:show_info("没有可管理的漫画。")
        return false
    end
    local count = #records
    self.ui:show_menu{
        title = ("批量管理（%d 本）"):format(count),
        items = {
            {
                text = "批量删除历史",
                callback = self:_callback("request batch history deletion", function()
                    self.ui:confirm{
                        text = ("删除选中的 %d 本漫画的阅读历史？文件、评分、分类和封面不会删除。"):format(count),
                        on_confirm = self:_callback("confirm batch history deletion", function()
                            return self:_batch_delete_history(records, return_to)
                        end, false),
                    }
                end),
            },
            {
                text = "批量添加分类",
                callback = self:_callback("open batch history categories", function()
                    return self:_premium_gate("add", records[1] and records[1].manga,
                        function() return self:show_batch_category_picker(records, return_to) end)
                end),
            },
            {
                text = "批量评分",
                callback = self:_callback("open batch history rating", function()
                    return self:_premium_gate("rating", records[1] and records[1].manga,
                        function() return self:show_batch_rating_picker(records, return_to) end)
                end),
            },
        },
        on_back = self:_callback("back from batch history management", function()
            if return_to then return_to() else self:_return_to_history() end
        end),
    }
    return true
end

function UiLibrary:show_category_batch(records, category_id, category_name,
    return_to)
    self:_enter_view()
    local count = #records
    local back_to_batch = function()
        return self:show_category_batch(records, category_id, category_name, return_to)
    end
    self.ui:show_menu{
        title = ("批量管理（%d 本）"):format(count),
        items = {
            {
                text = "批量添加分类",
                callback = self:_callback("open category batch categories", function()
                    return self:_premium_gate("add", records[1] and records[1].manga,
                        function() return self:show_batch_category_picker(records, return_to, back_to_batch) end)
                end),
            },
            {
                text = "批量评分",
                callback = self:_callback("open category batch rating", function()
                    return self:_premium_gate("rating", records[1] and records[1].manga,
                        function() return self:show_batch_rating_picker(records, return_to, back_to_batch) end)
                end),
            },
            {
                text = "从“" .. tostring(category_name or "当前分类") .. "”批量移除",
                callback = self:_callback("remove category batch members", function()
                    self.ui:confirm{
                        text = ("从当前分类移除选中的 %d 本漫画？不会删除文件。"):format(count),
                        on_confirm = self:_callback("confirm category batch removal", function()
                            return self:_batch_remove_category(records, category_id, return_to)
                        end, false),
                    }
                end),
            },
        },
        on_back = self:_callback("back from category batch management", function()
            if return_to then return_to() end
        end),
    }
    return true
end

function UiLibrary:show_rating_batch(records, return_to)
    self:_enter_view()
    local count = #records
    local back_to_batch = function()
        return self:show_rating_batch(records, return_to)
    end
    self.ui:show_menu{
        title = ("批量管理（%d 本）"):format(count),
        items = {
            {
                text = "批量添加分类",
                callback = self:_callback("open rating batch categories", function()
                    return self:_premium_gate("add", records[1] and records[1].manga,
                        function() return self:show_batch_category_picker(records, return_to, back_to_batch) end)
                end),
            },
            {
                text = "批量调整评分",
                callback = self:_callback("open rating batch rating", function()
                    return self:_premium_gate("rating", records[1] and records[1].manga,
                        function() return self:show_batch_rating_picker(records, return_to, back_to_batch) end)
                end),
            },
            {
                text = "批量清除评分",
                callback = self:_callback("clear rating batch", function()
                    self.ui:confirm{
                        text = ("清除选中的 %d 本漫画的评分？"):format(count),
                        on_confirm = self:_callback("confirm rating batch clear", function()
                            return self:_batch_set_rating(records, 0,
                                self:_rating_max(), return_to)
                        end, false),
                    }
                end),
            },
        },
        on_back = self:_callback("back from rating batch management", function()
            if return_to then return_to() end
        end),
    }
    return true
end

function UiLibrary:show_history_manage(history_record)
    self:_enter_view()
    local record, code = self:_ensure_manga(history_record)
    if not record then
        self:_show_library_error(code)
        return self:_return_to_history()
    end
    local items = {
        {
            text = "评分：" .. self:_rating_text(record),
            callback = self:_callback("open history manga rating", function()
                self:show_rating_picker(record, function()
                    self:show_history_manage(history_record)
                end, function()
                    self:show_history_manage(history_record)
                end)
            end),
        },
        {
            text = record.is_read and "标记为未读" or "标记为已读",
            callback = self:_callback("toggle history manga read status", function()
                local saved, save_code = self.library:set_read(self:_connection(),
                    record.manga.path, not record.is_read)
                if not saved then
                    self:_show_library_error(save_code)
                    return false
                end
                self:show_history_manage(history_record)
                return true
            end),
        },
        {
            text = "编辑分类",
            callback = self:_callback("edit history manga categories", function()
                self:show_category_picker(record, function(category_ids)
                    local saved, save_code = self.library:set_categories(
                        self:_connection(), record.manga.path, category_ids)
                    if not saved then
                        self:_show_library_error(save_code)
                        return false
                    end
                    self:show_history_manage(history_record)
                    return true
                end, function()
                    self:show_history_manage(history_record)
                end)
            end),
        },
        {
            text = "删除阅读历史",
            callback = self:_callback("request history deletion", function()
                self.ui:confirm{
                    text = "删除“" .. history_record.manga.name .. "”的阅读历史？",
                    on_confirm = self:_callback("confirm history deletion", function()
                        local ok = self.progress and self.progress:remove_history(
                            self:_connection(), history_record.manga.path)
                        if ok == false then
                            self.ui:show_info("阅读历史删除失败，请稍后重试。")
                            return false
                        end
                        self:_return_to_history()
                        return true
                    end, false),
                }
            end),
        },
    }
    items[#items + 1] = {
        text = "缓存到 Kindle",
        callback = self:_callback("open whole manga cache", function()
            return self.cache_manga(record.manga)
        end, false),
    }
    self:_append_local_delete(items, record, function()
        self:_return_to_history()
    end)
    self.ui:show_menu{
        title = "管理" .. history_record.manga.name,
        subtitle = history_record.manga.path,
        items = items,
        on_back = self:_callback("back from history manga management", function()
            self:_return_to_history()
        end),
    }
end

function UiLibrary:show_relink_picker(record)
    local epoch, identity = self:_enter_view()
    local return_view = self.relink_return_view or self.current_view or self.library.ALL
    local handle = self.browser:show_folder_picker({
        title = "重新关联" .. record.manga.name,
        action_text = "重连",
        on_request_handle = function(request_handle)
            self:_track_view_handle(request_handle, epoch, identity)
        end,
        on_pick = self:_callback("recognize relink directory", function(manga)
            local terminal, attach = self:_begin_operation()
            local recognition_handle = self.browser:identify_manga(manga, {
                allow_cached = false,
                on_success = terminal("commit manga relink", function(result)
                    local fresh = {
                        manga = result.manga,
                        layout = result.layout,
                        cover_hint = result.cover_hint,
                        direct_cover_image = result.layout == "direct"
                            and result.cover_hint and result.cover_hint.image or nil,
                    }
                    local relinked, code = self.library:relink_manga(
                        self:_connection(), record.manga.path, fresh)
                    if not relinked then
                        self:_show_library_error(code)
                        return
                    end
                    self.unavailable_paths[record.manga.path] = nil
                    self.unavailable_paths[result.manga.path] = nil
                    self:_show_origin(return_view)
                end),
                on_failure = terminal("reject relink directory", function(err)
                    self.ui:show_info(Errors.message(err))
                end),
            })
            attach(recognition_handle)
        end),
        on_back = self:_callback("back from manga relink", function()
            self:show_manage_manga(record, return_view)
        end),
    }, self:_connection().root_path)
    self:_track_view_handle(handle, epoch, identity)
end

return UiLibrary
