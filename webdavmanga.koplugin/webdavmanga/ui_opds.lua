local Index = require("webdavmanga.opds_chapter_index")
local Identity = require("webdavmanga.manga_identity")
local Resume = require("webdavmanga.opds_resume")
local Driver = require("webdavmanga.opds_driver")
local Pages = require("webdavmanga.opds_pages")
local Navigation = require("webdavmanga.series_navigation")
local Async = require("webdavmanga.async")
local Url = require("webdavmanga.opds_url")

local Ui = {}
Ui.__index = Ui

local function pointer_write_message(reason)
    if reason == "pointer_busy" then
        return "阅读指针正在保存，请稍后重新选择章节重试。若完全退出 KOReader 后仍发生，请确认所有设备均未写入该目录，再检查该系列目录中的空 .meguru-publish.lock 文件夹；只移除确认遗留的空锁目录，不要删除 .meguru 或封面。"
    end
    return "阅读指针保存失败，请重试。"
end

local function default_ui()
    local InfoMessage = require("ui/widget/infomessage")
    local Menu = require("ui/widget/menu")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")
    local adapter = {
        current_menu = nil,
        close_reason = setmetatable({}, { __mode = "k" }),
        closed_menu = setmetatable({}, { __mode = "k" }),
    }

    local function guarded(callback)
        return function(...)
            local ok, result = pcall(callback, ...)
            if not ok then
                adapter:show_info("OPDS 操作失败，请重试。")
                return true
            end
            return result == false and true or result
        end
    end

    function adapter:show_info(message)
        UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 3 })
    end
    function adapter:close_menu(reason)
        local menu = self.current_menu
        if not menu then return false end
        self.close_reason[menu] = reason or "user"
        self.current_menu = nil
        UIManager:close(menu)
        return true
    end
    function adapter:show_menu(model)
        self:close_menu("replace")
        local menu
        local items = {}
        for _, item in ipairs(model.items or {}) do
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            if copy.callback then
                local callback = guarded(copy.callback)
                copy.callback = function(...)
                    if self.current_menu ~= menu then return true end
                    return callback(...)
                end
            end
            items[#items + 1] = copy
        end
        if model.on_refresh then
            items[#items + 1] = { text = "↻ 刷新", separator = true,
                callback = function()
                    if self.current_menu ~= menu then return true end
                    return guarded(model.on_refresh)()
                end }
        end
        if model.on_back then
            items[#items + 1] = { text = "← 返回上一级", separator = true,
                callback = function()
                    if self.current_menu ~= menu then return true end
                    self:close_menu("replace")
                    return guarded(model.on_back)()
                end }
        end
        menu = Menu:new{
            title = model.title, subtitle = model.subtitle,
            covers_fullscreen = true, is_popout = false,
            item_table = items,
            close_callback = function()
                if self.closed_menu[menu] then return true end
                self.closed_menu[menu] = true
                local reason = self.close_reason[menu] or "user"
                self.close_reason[menu] = nil
                if self.current_menu == menu then self.current_menu = nil end
                if reason == "user" and model.on_back then
                    return guarded(model.on_back)()
                elseif reason == "user" and model.on_close then
                    return guarded(model.on_close)()
                end
                return true
            end,
        }
        self.current_menu = menu
        UIManager:show(menu)
    end
    function adapter:show_input(model)
        local dialog
        local fields = model.fields or {
            { description = "名称", text = model.name or "" },
            { description = "OPDS 地址", text = model.url or "" },
            { description = "用户名", text = model.username or "" },
            { description = "密码", text = model.password or "", text_type = "password" },
        }
        if model.fields then
            for index, field in ipairs(fields) do
                if type(field) == "string" then
                    fields[index] = { description = field, text = "" }
                end
            end
        end
        dialog = MultiInputDialog:new{
            title = model.title,
            fields = fields,
            buttons = {{
                { text = "取消", callback = function() UIManager:close(dialog) end },
                { text = "保存", callback = function()
                    local fields = dialog:getFields()
                    UIManager:close(dialog)
                    return model.on_save(fields)
                end },
            }},
        }
        UIManager:show(dialog)
    end
    function adapter:show_resume(model)
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        local buttons = {}
        for _, item in ipairs(model.items) do
            buttons[#buttons + 1] = {{ text = item.text, callback = function()
                local result = item.callback()
                UIManager:close(dialog)
                return result
            end }}
        end
        buttons[#buttons + 1] = {{ text = "取消", callback = function()
            model.on_cancel()
            UIManager:close(dialog)
        end }}
        dialog = ButtonDialog:new{ title = model.title, buttons = buttons,
            dismissable = true, tap_close_callback = model.on_cancel }
        UIManager:show(dialog)
        return true
    end
    return adapter
end

function Ui:new(options)
    options = options or {}
    local object = setmetatable({
        catalog = assert(options.catalog, "catalog is required"),
        client_factory = options.client_factory,
        reader = assert(options.reader, "reader is required"),
        ui = options.ui or default_ui(),
        open_category_shelf = options.open_category_shelf,
        pointer = options.pointer,
        library = options.library,
        progress = options.progress,
        pages = options.pages,
        driver = options.driver or Driver,
        logger = options.logger,
        async = options.async or Async,
        catalog_requests = {},
        current = nil,
        navigation_generation = 0,
        selection_generation = 0,
    }, self)
    if object.pointer then
        object.pointer.find_existing = function(source_id, series_id, chapter_id)
            return object:find_pointer(source_id, series_id, chapter_id)
        end
    end
    return object
end

local function descriptor_identity(descriptor)
    if type(descriptor) ~= "table" then return nil end
    local copy = {}
    for key, value in pairs(descriptor) do copy[key] = value end
    if not copy.series_id and copy.server_kind == "komga" and type(copy.chapter_id) == "string" then
        copy.series_id = "standalone:" .. copy.chapter_id
        copy.series_feed_url = nil
    end
    if not Identity.opds_path(copy) then return nil end
    return copy
end

local function same_opds_identity(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.source_id == right.source_id and left.series_id == right.series_id
        and left.chapter_id == right.chapter_id
end

local function valid_page_count(value)
    return type(value) == "number" and value >= 1 and value <= 100000 and value == math.floor(value)
end

function Ui:find_pointer(source_id, series_id, chapter_id)
    for _, provider in ipairs({ { self.library, "list_all_mangas" }, { self.progress, "list_all_history" } }) do
        local owner, method = provider[1], provider[2]
        if owner and type(owner[method]) == "function" then
            for _, record in ipairs(owner[method](owner)) do
                local resource = record.chapter or record.manga or {}
                if resource.source_id == source_id and resource.series_id == series_id
                    and resource.chapter_id == chapter_id and resource.pointer_path then
                    return resource.pointer_path
                end
            end
        end
    end
end

function Ui:descriptor_record(descriptor, source, pointer_path)
    local desc = descriptor_identity(descriptor)
    if not desc or not source or desc.source_id ~= source.id then return nil end
    local path = Identity.opds_path(desc)
    local metadata = desc.series_feed_url and Driver.redact_url(desc.series_feed_url) or nil
    local function resource(folder)
        return { name = desc.chapter_name or desc.chapter_id, path = path, is_folder = folder,
            source_id = desc.source_id, series_id = desc.series_id, chapter_id = desc.chapter_id,
            pointer_path = pointer_path, opds_catalog_id = desc.source_id, opds_feed_url = metadata }
    end
    return { connection = self:_connection(source), manga = resource(true), chapter = resource(nil),
        layout = "opds", total_pages = desc.page_count,
        cover_hint = { image = { name = "1.jpg", path = path .. "/page-1.jpg" }, chapter = resource(nil) },
        source_context = { opds = true, catalog_id = desc.source_id, source_id = desc.source_id,
            series_id = desc.series_id, chapter_id = desc.chapter_id, pointer_path = pointer_path,
            feed_url = metadata } }
end

function Ui:local_position(descriptor)
    if not self.progress then return nil end
    local path = Identity.opds_path(descriptor)
    local position = path and self.progress.records and self.progress.records[path]
    if position then return { chapter_id = descriptor.chapter_id, chapter_name = descriptor.chapter_name,
        page = position.index } end
end

function Ui:request_open(descriptor, source, options)
    options = options or {}
    local desc = descriptor_identity(descriptor)
    if not desc or not source or desc.source_id ~= source.id then
        return self:_show_info("OPDS 章节身份无效，请重新打开目录。")
    end
    if not valid_page_count(desc.page_count) then
        return self:_show_info("OPDS 章节页数无效，请刷新目录后重试。")
    end
    if not self.pointer or type(self.open_descriptor) ~= "function" then
        return self:_show_info("OPDS 阅读器未初始化。")
    end
    local selection_generation = self:_begin_selection()
    local generation = self.navigation_generation
    local state = "pending"
    local function cancel()
        if state == "pending" then state = "cancelled" end
        return true
    end
    self.pending_resume = { cancel = cancel }
    local local_position = options.local_position or self:local_position(desc)
    local server_position = options.server_position
    if not server_position and desc.server_last_read then
        server_position = { chapter_id = desc.chapter_id, chapter_name = desc.chapter_name,
            page = math.min(desc.page_count, desc.server_last_read + 1) }
    end
    local choices_descriptor = {}
    for key, value in pairs(desc) do choices_descriptor[key] = value end
    choices_descriptor.chapter_order = options.chapter_order or desc.chapter_order
    local model = { title = "▶ 巡这个系列", items = {}, on_cancel = cancel, on_outside = cancel, on_back = cancel }
    for _, choice in ipairs(Resume.choices(choices_descriptor, local_position, server_position)) do
        model.items[#model.items + 1] = { text = choice.label, kind = choice.kind, callback = function()
            if state ~= "pending" or not self:_is_current(generation)
                or self.selection_generation ~= selection_generation then return false end
            state = "selected"
            local selected = desc
            if choice.chapter_id ~= desc.chapter_id then
                if type(options.resolve_chapter) ~= "function" then
                    return self:_show_info("该章节暂时不可用，请刷新系列目录。")
                end
                local ok, resolved = pcall(options.resolve_chapter, choice.chapter_id)
                selected = ok and descriptor_identity(resolved) or nil
                if not selected or selected.source_id ~= desc.source_id or selected.series_id ~= desc.series_id
                    or selected.chapter_id ~= choice.chapter_id then
                    return self:_show_info("该章节暂时不可用，请刷新系列目录。")
                end
            end
            if not valid_page_count(selected.page_count) then
                return self:_show_info("OPDS 章节页数无效，请刷新目录后重试。")
            end
            local saved, path, reason = pcall(self.pointer.save, self.pointer, selected)
            if not saved or not path then return self:_show_info(pointer_write_message(saved and reason)) end
            local loaded, verified = pcall(self.pointer.load, self.pointer, path)
            if not loaded or not verified or not same_opds_identity(verified, selected) then
                return self:_show_info("阅读指针校验失败，请重试。")
            end
            if not valid_page_count(verified.page_count) then
                return self:_show_info("OPDS 章节页数无效，请刷新目录后重试。")
            end
            local page = math.max(1, math.min(choice.page, selected.page_count, verified.page_count))
            local handoff, result = pcall(self.open_descriptor, self, verified, source,
                { pointer_path = path, page = page, on_return = options.on_return,
                    navigation_page = options.navigation_page,
                    chapter_order = options.chapter_order, resolve_chapter = options.resolve_chapter })
            if not handoff or result ~= true then return self:_show_info("OPDS 章节打开失败，请重试。") end
            state = "opened"
            return true
        end }
    end
    if not self.ui.show_resume then return self:_show_info("续读选择界面未初始化。") end
    return self.ui:show_resume(model)
end

function Ui:series_item(chapters, local_position, on_open)
    local target = Resume.series_target(chapters, local_position)
    if not target then return nil end
    return { text = "▶ 巡这个系列", callback = function() return on_open(target) end }
end

function Ui:series_position(source_id, series_id)
    if not self.progress or type(self.progress.list_all_history) ~= "function" then return nil end
    for _, record in ipairs(self.progress:list_all_history()) do
        local manga = record.manga or {}
        if manga.source_id == source_id and manga.series_id == series_id then
            local chapter = record.chapter or manga
            return { chapter_id = chapter.chapter_id, chapter_name = chapter.name, page = record.index }
        end
    end
end

function Ui:_driver_context(page)
    page = page or self.current or {}
    local context = {}
    for key, value in pairs(page.series_context or {}) do context[key] = value end
    context.feed, context.feed_url = page.feed, page.feed_url
    context.series_cover_url = context.series_cover_url or page.feed and page.feed.image_url
    -- A server-issued series URN is evidence; a title or list position is not.
    if not context.series_id and page.feed and type(page.feed.id) == "string"
        and page.feed.id:match("^urn:.*manga:") then
        context.series_id, context.series_name = page.feed.id, page.feed.title
        context.series_feed_url = page.feed_url
    end
    return context
end

function Ui:_series_candidates(source, feed, supplied_context)
    local chapters, series_id, seen = {}, nil, {}
    local context = supplied_context or self:_driver_context()
    for _, child in ipairs(feed.entries or {}) do
        local descriptor = child.stream and self.driver.resolve(source, context, child) or nil
        local id = descriptor and descriptor.chapter_id
        local candidate_series = descriptor and descriptor.series_id
        if not id and context.series_id and type(child.id) == "string" and child.id:match("^urn:")
            and child.kind == "volume" then
            id = child.id:gsub(":metadata$", "", 1)
            candidate_series = context.series_id
        end
        if id and candidate_series then
            if series_id and series_id ~= candidate_series then return {}, nil end
            -- Metadata progress variants are choices for one chapter, not
            -- separate neighbors or a series-wide resume action.
            if seen[id] then return {}, nil end
            seen[id] = true
            series_id = candidate_series
            local last = descriptor and descriptor.server_last_read
            chapters[#chapters + 1] = { chapter_id = id, chapter_name = child.name, entry = child,
                server_page = last ~= nil and math.min(last + 1, descriptor.page_count) or nil,
                is_read = last ~= nil and last >= descriptor.page_count or nil }
            if last ~= nil and last < descriptor.page_count then chapters[#chapters].is_read = false end
        end
    end
    return chapters, series_id
end

-- Chapter selection retires lazy metadata without retiring the visible feed.
function Ui:_begin_selection()
    if self.pending_resume then self.pending_resume.cancel(); self.pending_resume = nil end
    self.selection_generation = self.selection_generation + 1
    for request in pairs(self.catalog_requests) do
        if request.selection_generation then
            request.cancelled = true
            self.catalog_requests[request] = nil
            if request.handle and request.handle.cancel then request.handle:cancel() end
        end
    end
    return self.selection_generation
end

function Ui:_begin_navigation()
    self:_begin_selection()
    self.navigation_generation = self.navigation_generation + 1
    for request in pairs(self.catalog_requests) do
        request.cancelled = true
        if request.handle and request.handle.cancel then request.handle:cancel() end
    end
    self.catalog_requests = {}
    return self.navigation_generation
end

function Ui:cancel()
    self:_begin_navigation()
    self.descriptor_generation = (self.descriptor_generation or 0) + 1
    if self.pages then self.pages:cancel_all() end
    self.current = nil
    if self.ui.close_menu then self.ui:close_menu("replace") end
    return true
end

function Ui:_is_current(generation)
    return generation == self.navigation_generation
end

local function stable_id(value)
    local hash = 2166136261
    value = tostring(value or "")
    for position = 1, #value do
        hash = (hash * 16777619 + value:byte(position)) % 4294967296
    end
    return ("%08x"):format(hash)
end

local function safe_feed_url(value)
    local scheme, authority, path = tostring(value or "")
        :match("^(https?://)([^/?#]+)([^?#]*)")
    if not scheme then return "" end
    return scheme .. authority:gsub("^.*@", "") .. path
end

local function route_book(value)
    local query = tostring(value or ""):match("%?([^#]*)")
    if not query then return nil end
    local book
    for pair in query:gmatch("[^&]+") do
        local key, candidate = pair:match("^([^=]+)=([^=]+)$")
        if key == "book" then
            if book or not candidate:match("^%d+$") or #candidate > 20 then
                return nil
            end
            book = candidate
        end
    end
    return book
end

local function with_route_book(url, book)
    local base, query = tostring(url or ""):match("^([^?#]+)%?([^#]*)")
    if not base then return tostring(url or "") .. "?book=" .. book end
    local parts = {}
    for pair in query:gmatch("[^&]+") do
        if pair:match("^([^=]+)") ~= "book" then parts[#parts + 1] = pair end
    end
    parts[#parts + 1] = "book=" .. book
    return base .. "?" .. table.concat(parts, "&")
end

function Ui:_connection(entry)
    return {
        kind = "opds",
        source_id = entry and entry.id,
        server_url = "opds://source/" .. tostring(entry and entry.id or ""),
        root_path = "/",
    }
end

function Ui:_record(entry, feed)
    local feed_url = self.current and self.current.feed_url or entry.url
    local saved_feed_url = safe_feed_url(feed_url)
    local book = route_book(feed_url)
    local path = "/opds/" .. tostring(entry.id) .. "/"
        .. stable_id(saved_feed_url .. (book and ("?book=" .. book) or ""))
    local first_page
    for _, child in ipairs(feed.entries or {}) do
        if child.kind == "page" and child.image_url then
            first_page = {
                name = child.name or "1.jpg",
                path = path .. "/page-1.jpg",
                image_url = child.image_url,
                opds_page = true,
            }
            break
        end
    end
    return {
        connection = self:_connection(entry),
        manga = {
            name = feed.title or entry.name,
            path = path,
            is_folder = true,
            opds_catalog_id = entry.id,
            opds_feed_url = saved_feed_url,
            opds_route_book = book,
        },
        chapter = {
            name = feed.title or entry.name,
            path = path .. "/chapter",
            opds_catalog_id = entry.id,
            opds_feed_url = saved_feed_url,
            opds_route_book = book,
        },
        layout = "opds",
        cover_hint = first_page and { image = first_page } or nil,
        total_pages = 0,
    }
end

function Ui:_show_info(message)
    if self.ui and self.ui.show_info then self.ui:show_info(message) end
    return false
end

function Ui:_fetch(entry, url)
    local target, reason = Url.request_target(entry.server_url or entry.url, url)
    if not target then return nil, reason end
    if type(self.catalog.fetch) == "function" then
        return self.catalog:fetch(entry.id, target)
    end
    if type(self.client_factory) ~= "function" then return nil, "OPDS 客户端未初始化" end
    local client = self.client_factory(entry)
    return client:fetch(target, { username = entry.username, password = entry.password }, entry.server_url or entry.url)
end

function Ui:_fetch_async(entry, url, done, generation, is_active, selection_generation)
    generation = generation or self.navigation_generation
    local request = { selection_generation = selection_generation }
    self.catalog_requests[request] = true
    request.handle = self.async.run(function()
        local feed, err = self:_fetch(entry, url)
        return { feed = feed, error = err }
    end, function(ok, result)
        self.catalog_requests[request] = nil
        if request.cancelled or not self:_is_current(generation)
            or (selection_generation and self.selection_generation ~= selection_generation)
            or (is_active and not is_active()) then return end
        result = ok and type(result) == "table" and result or {}
        done(result.feed, result.error)
    end, { max_payload_bytes = 8 * 1024 * 1024 })
    if request.cancelled and request.handle and request.handle.cancel then request.handle:cancel() end
    return true
end

function Ui:_entry_items(entry, feed)
    local items = {}
    local candidates, series_id = self:_series_candidates(entry, feed)
    if series_id then
        local item = self:series_item(candidates, self:series_position(entry.id, series_id),
            function(target) return self:_open_entry(entry, target.entry) end)
        if item then items[#items + 1] = item end
    end
    for _, child in ipairs(feed.entries or {}) do
        if child.kind == "page" then
            -- Pages are opened as one virtual chapter below, not as menus.
        elseif child.href or child.stream then
            items[#items + 1] = {
                text = child.name,
                callback = function() return self:_open_entry(entry, child) end,
            }
        end
    end
    local page_count = 0
    for _, child in ipairs(feed.entries or {}) do
        if child.kind == "page" and child.image_url then page_count = page_count + 1 end
    end
    if page_count > 0 then
        items[#items + 1] = {
            text = "打开本卷（" .. page_count .. " 页）",
            callback = function()
                if self.pointer then return self:_show_info("该目录未提供稳定的 OPDS-PSE 章节，请打开服务器章节目录。") end
                return self:_open_pages(entry, feed)
            end,
        }
    end
    return items
end

function Ui:_show_feed(entry, feed, title, on_back, feed_url, generation, series_context)
    generation = generation or self:_begin_navigation()
    feed_url = feed_url or entry.url or entry.href
    local page = { entry = entry, feed = feed,
        feed_url = feed_url, title = title, on_back = on_back,
        generation = generation, series_context = series_context }
    self.current = page
    local items = self:_entry_items(entry, feed)
    if feed.search_url and self.ui.show_input then
        items[#items + 1] = {
            text = "搜索",
            callback = function()
                return self.ui:show_input{
                    title = "搜索 " .. tostring(title or "OPDS"),
                    fields = { "" },
                    on_save = function(fields)
                        local query = tostring(fields[1] or "")
                        if query == "" then return false end
                        local encoded = query:gsub("([^%w%-%._~])", function(value)
                            return ("%%%02X"):format(value:byte())
                        end)
                        local url = feed.search_url:gsub("{searchTerms}", encoded)
                        return self:open_url(entry, url, "搜索：" .. query, on_back, url)
                    end,
                }
            end,
        }
    end
    if feed.next_url then
        items[#items + 1] = {
            text = "下一页目录",
            callback = function()
                return self:open_url(entry, feed.next_url, title, on_back, feed.next_url, series_context)
            end,
        }
    end
    if #items == 0 then
        items[1] = { text = "该 OPDS 目录没有可阅读的卷或图片。",
            callback = function() return true end }
    end
    for _, item in ipairs(items) do
        local callback = item.callback
        item.callback = function(...)
            if not self:_is_current(generation) then return false end
            return callback(...)
        end
    end
    return self.ui:show_menu{
        title = title or feed.title or entry.name,
        items = items,
        on_refresh = function()
            if not self:_is_current(generation) then return false end
            return self:open_url(entry, feed_url, title, on_back, feed_url, series_context)
        end,
        on_back = on_back and function()
            if self.current ~= page then return false end
            if not self:_is_current(generation) then self:_begin_navigation() end
            return on_back()
        end or nil,
        on_close = not on_back and function()
            if self.current ~= page then return false end
            self:_begin_navigation()
            self.current = nil
            return true
        end or nil,
    }
end

local function fetch_error_message(err)
    if type(err) ~= "table" then return "网络或服务器暂时不可用，请重试。" end
    if err.code == "http" then
        local status = tonumber(err.http_status)
        if status == 401 or status == 403 then
            return "认证失败，请检查 OPDS 账号或密钥。"
        end
        if status and status >= 100 and status <= 599 and status % 1 == 0 then
            return ("服务器返回 HTTP %d，请稍后重试。"):format(status)
        end
    elseif err.code == "tls" then
        return "HTTPS 证书验证失败，请检查系统时间和证书。"
    elseif err.code == "decode" then
        return "OPDS 目录响应无法解析。"
    end
    return "网络或服务器暂时不可用，请重试。"
end

function Ui:open_url(entry, url, title, on_back, feed_url, series_context)
    local generation = self:_begin_navigation()
    local pending = { entry = entry, feed_url = feed_url or url, title = title, generation = generation }
    self.current = pending
    local function leave()
        if self.current ~= pending then return false end
        self:_begin_navigation()
        self.current = nil
        if on_back then return on_back() end
        return true
    end
    self:_fetch_async(entry, url, function(feed, err)
    if not feed then
        local page = { entry = entry, feed_url = feed_url or url,
            title = title, on_back = on_back, generation = generation }
        self.current = page
        return self.ui:show_menu{
            title = "OPDS 加载失败",
            items = {{ text = "重试", callback = function()
                if not self:_is_current(generation) then return false end
                return self:open_url(entry, url, title, on_back, feed_url or url, series_context)
            end }},
            subtitle = fetch_error_message(err),
            on_back = on_back and function()
                if self.current ~= page then return false end
                if not self:_is_current(generation) then self:_begin_navigation() end
                return on_back()
            end or nil,
            on_close = not on_back and function()
                if self.current ~= page then return false end
                self:_begin_navigation()
                self.current = nil
                return true
            end or nil,
        }
    end
    return self:_show_feed(entry, feed, title, on_back, feed_url or url, generation, series_context)
    end, generation)
    if self.current == pending then
        self.ui:show_menu{ title = title or entry.name, items = {{text="正在加载目录…"}},
            on_back = leave, on_close = leave }
    end
    return true
end

local CHAPTER_ERRORS = {
    unsupported_server = "无法识别 OPDS 服务类型，请在连接设置中选择正确的服务类型。",
    ambiguous_server = "OPDS 服务类型信息冲突，请在连接设置中选择正确的服务类型。",
    missing_source_id = "OPDS 连接记录无效，请重新进入连接目录。",
    missing_chapter_id = "该条目没有提供有效章节编号，无法打开。",
    missing_stream = "该章节没有提供逐页阅读链接。",
    invalid_page_count = "该章节的页数无效，请刷新目录后重试。",
    invalid_stream_template = "该章节的逐页图片链接无效，请刷新目录后重试。",
    chapter_identity_mismatch = "章节详情与所选章节不一致，请刷新目录后重试。",
    series_identity_mismatch = "章节详情与所属系列不一致，请刷新目录后重试。",
    metadata_unavailable = "章节详情加载失败，请刷新目录后重试。",
    metadata_choice_required = "该章节有多个同步阅读位置，请从章节详情中选择。",
}

function Ui:_chapter_error(reason)
    -- Only fixed categories reach the device log/UI. Driver errors must never
    -- expose request URLs, credentials or server-provided content.
    local known = type(reason) == "string" and CHAPTER_ERRORS[reason] ~= nil
    if self.logger and type(self.logger.warn) == "function" then
        pcall(self.logger.warn, "WebDavManga OPDS:", "chapter_resolve",
            "reason=" .. (known and reason or "unknown"))
    end
    return self:_show_info(known and CHAPTER_ERRORS[reason]
        or "OPDS 章节解析失败，请刷新目录后重试。")
end

function Ui:_open_entry(entry, child)
    local parent = self.current
    local parent_url = parent and parent.feed_url
    local context = self:_driver_context(parent)
    local metadata_chapter = self.pointer and child.kind == "volume"
        and (entry.server_kind == "suwayomi"
            or ((entry.server_kind == nil or entry.server_kind == "auto")
                and Url.server_evidence(context, "suwayomi")))
    if child.stream or metadata_chapter then
        local selection_generation = self:_begin_selection()
        local generation = self.navigation_generation
        local descriptor, err = self.driver.resolve(entry, context, child)
        local function opened(descriptor, reason)
            if not descriptor then return self:_chapter_error(reason or err) end
            local page = self:_navigation_page(descriptor, entry, parent.feed, parent_url, context)
            local server_position
            local target = page and Resume.series_target(page.entries)
            local clicked_seen = false
            for _, candidate in ipairs(page and page.entries or {}) do
                if candidate.chapter_id == descriptor.chapter_id then clicked_seen = true end
                if clicked_seen and candidate == target and candidate.server_page then
                    server_position = { chapter_id = candidate.chapter_id,
                        chapter_name = candidate.chapter_name, page = candidate.server_page }
                    break
                end
            end
            descriptor.series_feed_url = Driver.redact_url(page and page.url or context.series_feed_url or parent_url)
            return self:request_open(descriptor, entry, { navigation_page = page,
                server_position = server_position,
                chapter_order = page and page.entries, resolve_chapter = page and page.resolve,
                on_return = function()
                    return self:open_url(entry, parent_url, parent.title, parent.on_back, parent_url, parent.series_context)
                end })
        end
        if not descriptor and err == "metadata_required" and child.href then
            return self:_fetch_async(entry, child.href, function(metadata)
                if not metadata then return opened(nil, "metadata_unavailable") end
                local resolved, reason = self.driver.resolve(entry, context, child, metadata)
                if not resolved and reason == "metadata_choice_required" then
                    local choice_context = { series_id = context.series_id, series_name = context.series_name,
                        series_cover_url = context.series_cover_url, series_feed_url = parent_url }
                    return self:_show_feed(entry, metadata, child.name, function()
                        return self:open_url(entry, parent_url, parent.title, parent.on_back,
                            parent_url, parent.series_context)
                    end, child.href, nil, choice_context)
                end
                return opened(resolved, reason)
            end, generation, nil, selection_generation)
        end
        return opened(descriptor)
    end
    local series_context = parent and parent.series_context
    if child.kind == "series" then
        series_context = { series_id = child.id ~= child.href and child.id or nil,
            series_name = child.name, series_feed_url = child.href, series_cover_url = child.image_url }
    end
    local url = child.href
    if child.kind == "series" and (entry.server_kind == "suwayomi"
        or Url.server_evidence(self:_driver_context(parent), "suwayomi")) then
        local base, query = url:match("^([^?#]+)%?([^#]*)")
        base = base or url:gsub("#.*$", "")
        local pairs = {}
        for pair in tostring(query or ""):gmatch("[^&]+") do
            if pair:match("^([^=]+)") ~= "sort" then pairs[#pairs+1] = pair end
        end
        pairs[#pairs+1] = "sort=number_asc"
        url = base .. "?" .. table.concat(pairs,"&")
        series_context.series_feed_url = url
    end
    return self:open_url(entry, url, child.name, function()
        return self:open_url(entry, parent_url, parent.title,
            parent.on_back, parent_url, parent.series_context)
    end, nil, series_context)
end

function Ui:show_missing_source(desc, options)
    local position = self:local_position(desc)
    self.missing_source_metadata = { descriptor = desc, pointer_path = options and options.pointer_path,
        local_position = position }
    return self:_show_info(tostring(desc.chapter_name or desc.chapter_id) .. " · 本地第 "
        .. tostring(position and position.page or 1) .. " 页\n此 OPDS 连接已不存在（source_missing）。")
end

function Ui:_navigation_page(desc, source, feed, url, supplied_context)
    if not feed then return nil end
    local context = {}
    for key, value in pairs(supplied_context or {}) do context[key] = value end
    context.series_id, context.series_name = desc.series_id, desc.series_name
    context.series_cover_url = desc.series_cover_url or context.series_cover_url or feed.image_url
    context.feed, context.feed_url, context.series_feed_url = feed, url, url
    local order, series_id = self:_series_candidates(source, feed, context)
    if series_id ~= desc.series_id then return nil end
    local function resolve(id, done)
        local current_source = source
        if self.catalog.get then current_source = self.catalog:get(desc.source_id) end
        if not current_source then return nil end
        for _, candidate in ipairs(order) do
            if candidate.chapter_id == id then
                local result, err = self.driver.resolve(current_source, context, candidate.entry)
                if not result and err == "metadata_required" then
                    if not done then return nil end
                    return self:_fetch_async(current_source, candidate.entry.href, function(metadata)
                        local resolved = metadata and self.driver.resolve(current_source, context, candidate.entry, metadata)
                        if resolved then resolved.series_feed_url = Driver.redact_url(url) end
                        done(resolved)
                    end)
                end
                if result then result.series_feed_url = Driver.redact_url(url) end
                if done then return done(result) end
                return result
            end
        end
    end
    return { entries = order, resolve = resolve, url = url,
        previous_url = feed.previous_url, next_url = feed.next_url }
end

function Ui:_descriptor_order(desc, source, done, active)
    local url = desc.series_feed_url and Pages.restore_url(desc.series_feed_url, source)
    if not url then return nil end
    return self:_fetch_async(source, url, function(feed)
        local page = self:_navigation_page(desc, source, feed, url)
        if page then done(page) end
    end, nil, active)
end

function Ui:open_descriptor(descriptor, source, options)
    options = options or {}
    local desc = descriptor_identity(descriptor)
    if not desc then return self:_show_info("OPDS 章节身份无效。") end
    -- Look up by id again: an open pointer must never retain an edited password.
    if self.catalog.get then source = self.catalog:get(desc.source_id) end
    if not source or source.id ~= desc.source_id then
        return self:show_missing_source(desc, options)
    end
    self:_begin_navigation()
    self.descriptor_generation = (self.descriptor_generation or 0) + 1
    local token, generation = self.descriptor_generation, self.navigation_generation
    local reader_started, chapter_handoff = false, false
    local function active()
        return self.descriptor_generation == token and self:_is_current(generation)
            and (not reader_started or self.reader.closing ~= true or chapter_handoff)
    end
    local record = self:descriptor_record(desc, source, options.pointer_path)
    local first_page_displayed = false
    record.source_context.on_first_page = function()
        if first_page_displayed or chapter_handoff or not active() then return end
        first_page_displayed = true
        if self.library then
            local ok, added = pcall(self.library.add_manga, self.library, record.connection, record.manga,
                {layout="opds", chapter=record.chapter, cover_hint=record.cover_hint})
            if not ok or not added then self:_show_info("章节已打开，但书架记录保存失败，请稍后重试。") end
        end
        if options.on_first_page then options.on_first_page() end
    end
    local index, err = Pages.virtual_index(desc, record.chapter.path)
    if not index then return self:_show_info("OPDS 页面索引无效（" .. tostring(err) .. "）。") end
    local on_return = options.on_return or function()
        if self.open_category_shelf then return self.open_category_shelf{ reset_source = true } end
        return true
    end
    record.source_context.on_return = function()
        if self.descriptor_generation == token then self.descriptor_generation = token + 1 end
        return on_return()
    end
    record.source_context.on_close = function(reason)
        if self.descriptor_generation ~= token then return end
        -- Reader closes before invoking its captured neighbor callback. Keep only
        -- this OPDS session alive for that handoff; cancel() still retires it.
        if reason == "series_chapter" then chapter_handoff = true; return end
        self.descriptor_generation = token + 1
        self:_begin_navigation()
    end
    local cover_requested = false
    record.source_context.on_page = function(page)
        if chapter_handoff or not active() then return end
        if self.pages and self.pages.sync_progress then self.pages:sync_progress(desc, page) end
        if not cover_requested and self.pages and self.pages.ensure_descriptor_cover then
            cover_requested = true
            self.pages:ensure_descriptor_cover(desc, record.connection, record.cover_hint, function(path)
                record.cover_hint.image = { name = ".cover.jpg", path = path }
                if self.library then
                    self.library:add_manga(record.connection, record.manga,
                        { layout = "opds", chapter = record.chapter, cover_hint = record.cover_hint })
                end
            end)
        end
    end
    local page = options.navigation_page
    local order, resolve = page and page.entries or options.chapter_order, page and page.resolve or options.resolve_chapter
    if not active() then return false end
    local load_navigation
    if (order and resolve) or desc.series_feed_url then
        local nav
        nav = Navigation:new{ is_current = active, cancel = function()
            if self.pages then self.pages:cancel_all() end
        end, extend = function(direction)
            if not active() or not page then return nil end
            local current_source = self.catalog:get(desc.source_id)
            local next_url = direction == "next" and page.next_url or page.previous_url
            -- This is a live server-issued route, not persisted metadata.
            -- Preserve opaque pagination bytes; _fetch enforces same origin.
            local url = next_url
            if not url or url == page.url then return nil end
            self:_fetch_async(current_source, url, function(feed)
                local adjacent = self:_navigation_page(desc, current_source, feed, url)
                if not adjacent then return end
                if direction == "next" then adjacent.previous_url = adjacent.previous_url or page.url
                else adjacent.next_url = adjacent.next_url or page.url end
                local target = adjacent.entries[direction == "next" and 1 or #adjacent.entries]
                if target then nav.open_entry(target, adjacent) end
            end, generation, active)
            return nil, nil, true
        end, open_entry = function(entry, adjacent)
            if not active() then return false end
            local selected_page = adjacent or page
            local function open_resolved(next_desc)
                if not active() or not next_desc or not self.pointer then return false end
                local saved, path, reason = pcall(self.pointer.save, self.pointer, next_desc)
                if not saved or not path then return self:_show_info(pointer_write_message(saved and reason)) end
                local verified = path and self.pointer:load(path)
                if not verified or not same_opds_identity(verified, next_desc) then return false end
                return self:open_descriptor(verified, nil, { pointer_path = path, page = 1,
                    navigation_page = selected_page,
                    chapter_order = order, resolve_chapter = resolve, on_return = options.on_return })
            end
            if selected_page then return selected_page.resolve(entry.chapter_id, open_resolved) end
            return open_resolved(resolve(entry.chapter_id))
        end }
        nav.series_key = desc.source_id .. "\0" .. desc.series_id
        local function update_navigation(next_page)
            if not active() then return end
            if next_page then page, order, resolve = next_page, next_page.entries, next_page.resolve end
            nav:neighbors{ kind = "opds", chapter_id = desc.chapter_id, entries = order,
                previous_available = page and page.previous_url, next_available = page and page.next_url }
        end
        update_navigation()
        if not order then load_navigation = function() self:_descriptor_order(desc, source, update_navigation, active) end end
        record.source_context.navigation = nav
    end
    local context = { connection = record.connection, manga = record.manga, chapter = record.chapter,
        chapter_index = index, initial_page = options.page, layout = "opds",
        cover_hint = record.cover_hint, source_context = record.source_context }
    if self.ui.close_menu then self.ui:close_menu("replace") end
    local opened = self.reader:open(context) == true
    reader_started = true
    if opened and load_navigation then load_navigation() end
    return opened
end

function Ui:_open_pages(entry, feed, on_return)
    local record = self:_record(entry, feed)
    local images = {}
    for _, child in ipairs(feed.entries or {}) do
        if child.kind == "page" and child.image_url then
            local page = #images + 1
            images[#images + 1] = {
                name = child.name or (page .. ".jpg"),
                path = record.manga.path .. "/page-" .. tostring(page) .. ".jpg",
                image_url = child.image_url,
                opds_page = true,
                opds_source_id = entry.id,
            }
        end
    end
    if #images == 0 then return self:_show_info("本卷没有可阅读的图片页面。") end
    images[1].opds_cover = true
    images[1].opds_cover_connection = record.connection
    record.cover_hint = { image = images[1] }
    record.total_pages = #images
    local chapter = record.chapter
    local context = {
        connection = record.connection,
        manga = record.manga,
        chapter = chapter,
        chapter_index = Index:new(images),
        chapters_index = Index:new{ chapter },
        chapter_position = 1,
        layout = "opds",
        cover_hint = record.cover_hint,
        source_context = {
            opds = true,
            catalog_id = entry.id,
            feed_url = record.manga.opds_feed_url,
            on_return = on_return or function() return self:show_home() end,
        },
    }
    if self.ui.close_menu then self.ui:close_menu("replace") end
    return self.reader:open(context)
end

function Ui:open_record(record, on_return)
    if type(record) ~= "table" or type(record.manga) ~= "table" then return false end
    local resource = record.chapter or record.manga
    if resource.source_id or resource.pointer_path then
        local source = self.catalog.get and self.catalog:get(resource.source_id)
        if not self.pointer then
            return self:_show_info("此 OPDS 连接已不存在，请重新添加并打开目录。")
        end
        local loaded, descriptor = pcall(self.pointer.load, self.pointer, resource.pointer_path)
        if not loaded or not descriptor or not same_opds_identity(descriptor, resource)
            or not Identity.opds_path(resource) then
            return self:_show_info("OPDS 阅读指针无效或章节身份不匹配。")
        end
        if not source or source.id ~= resource.source_id then
            return self:show_missing_source(descriptor, { pointer_path = resource.pointer_path })
        end
        if type(self.open_descriptor) ~= "function" then return self:_show_info("OPDS 阅读器未初始化。") end
        return self:open_descriptor(descriptor, source, { pointer_path = resource.pointer_path,
            on_return = on_return })
    end
    if self.pointer then
        return self:_show_info("旧 OPDS 记录缺少章节身份，请从服务器目录重新打开。")
    end
    local catalog_id = record.manga.opds_catalog_id
    local feed_url = record.manga.opds_feed_url
    local entry = self.catalog.get and self.catalog:get(catalog_id) or nil
    if not entry or type(feed_url) ~= "string" or feed_url == "" then
        return self:_show_info("OPDS 记录已失效，请重新打开服务器目录。")
    end
    feed_url = safe_feed_url(feed_url)
    local book = record.manga.opds_route_book
    if type(book) ~= "string" or not book:match("^%d+$") or #book > 20 then
        book = nil
    end
    if feed_url == safe_feed_url(entry.url) then
        feed_url = entry.url
    end
    if book then feed_url = with_route_book(feed_url, book) end
    local generation = self:_begin_navigation()
    return self:_fetch_async(entry, feed_url, function(feed, err)
        if not feed then
            return self:_show_info("OPDS 加载失败：" .. fetch_error_message(err))
        end
        self.current = { entry = entry, feed = feed, feed_url = feed_url }
        return self:_open_pages(entry, feed, on_return)
    end, generation)
end

function Ui:show_home()
    local active = self.catalog.active and self.catalog:active()
    if not active then
        self:_begin_navigation()
        self.current = nil
        if self.ui.close_menu then self.ui:close_menu("replace") end
        return self:_show_info("请先在连接设置中添加 OPDS 连接。")
    end
    return self:open_catalog(active)
end

function Ui:show_manage()
    return self:_show_info("请在连接设置中管理 OPDS 连接。")
end

function Ui:open_catalog(entry)
    if self.catalog.set_active then self.catalog:set_active(entry.id) end
    return self:open_url(entry, entry.url, entry.name,
        function()
            self:_begin_navigation()
            self.current = nil
            if type(self.open_category_shelf) == "function" then
                return self.open_category_shelf{ reset_source = true }
            end
            return true
        end, entry.url)
end

return Ui
