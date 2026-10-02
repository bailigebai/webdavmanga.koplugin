local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local CoverGrid = require("webdavmanga.ui_cover_grid")
-- Keep the historical cover lifecycle scenarios on the shipped grid adapter.
local CoverList = {}
function CoverList:new(deps)
    deps.settings = { get_reader = function() return { grid_columns = 3 } end }
    deps.render_image = { renderImageFile = function(_, path)
        return { path = path, free = function(self) self.freed = true end }
    end }
    if deps.ui and deps.ui.update_cover then
        local update = deps.ui.update_cover
        deps.ui.update_cover = function(ui, id, buffer) return update(ui, id, buffer.path) end
    end
    return CoverGrid:new(deps)
end
local Cover = require("webdavmanga.cover")

local connection = {
    server_url = "https://nas.example/dav",
    username = "reader",
    root_path = "/漫画",
}
local manga_a = { name = "漫画 A", path = "/漫画/A", is_folder = true }
local manga_b = { name = "漫画 B", path = "/漫画/B", is_folder = true }
local chapter_a = { name = "第 1 话", path = "/漫画/A/第 1 话", is_folder = true }

local ui = {
    updates = {},
    closes = 0,
    show_grid = function(self, model) self.last_model = model end,
    update_cover = function(self, item_id, local_path)
        self.updates[#self.updates + 1] = { id = item_id, path = local_path }
    end,
    close_grid = function(self)
        self.closes = self.closes + 1
        self.freed_visible_images = true
    end,
}

local cover_requests = {}
local cover_service = {
    resolve = function(_self, requested_connection, record, callbacks)
        local request = {
            connection = requested_connection,
            record = record,
            manga = record.manga,
            callbacks = callbacks,
            canceled = false,
        }
        cover_requests[#cover_requests + 1] = request
        return {
            cancel = function() request.canceled = true end,
        }
    end,
}

local loader_requests = {}
local canceled_generations = {}
local loader = {
    identity = "https://nas.example/dav\0reader\0/漫画",
    request_cover = function(_self, generation, image, callbacks)
        local request = {
            generation = generation,
            image = image,
            callbacks = callbacks,
        }
        loader_requests[#loader_requests + 1] = request
        return request
    end,
    cancel_cover_generation = function(_self, generation)
        canceled_generations[#canceled_generations + 1] = generation
    end,
}

local cached_paths = {}
local cache = {
    key_for = function(_self, identity, remote_path)
        expect(identity == loader.identity, "cover cache keys should use the loader identity")
        return "key:" .. remote_path
    end,
    lookup = function(_self, key) return cached_paths[key] end,
}

local opened, acted, backed
local list = CoverList:new{
    cover_service = cover_service,
    loader = loader,
    cache = cache,
    ui = ui,
    connection_provider = function() return connection end,
}

list:show{
    title = "阅读历史",
    subtitle = "2 本漫画",
    items = {
        {
            id = "a",
            manga = manga_a,
            text = "漫画 A · 3/10",
            mandatory = "删除",
            cover_hint = { image = { name = "001.jpg", path = "/漫画/A/001.jpg" } },
            layout = "chapters",
            chapter = chapter_a,
            chapters = { chapter_a },
            images = { { name = "current.jpg", path = "/漫画/A/current.jpg" } },
            catalog = {
                identity = loader.identity,
                chapters = { chapter_a },
                images = { [chapter_a.path] = {
                    { name = "catalog.jpg", path = "/漫画/A/第 1 话/catalog.jpg" },
                } },
            },
            on_open = function() opened = "a" end,
            on_action = function() acted = "a" end,
        },
        {
            id = "b",
            manga = manga_b,
            text = "漫画 B",
            mandatory = "管理",
            on_open = function() opened = "b" end,
            on_action = function() acted = "b" end,
        },
    },
    on_back = function() backed = true end,
}

expect(ui.last_model.title == "阅读历史" and ui.last_model.subtitle == "2 本漫画",
    "show should forward list chrome to the adapter")
expect(ui.last_model.items[1].local_cover_path == nil and ui.last_model.items[2].local_cover_path == nil,
    "rows should start with placeholders")
expect(ui.last_model.items[1].mandatory == "删除",
    "the row should retain its right-side action label")

ui.last_model.items[1].on_open()
expect(opened == "a" and acted == nil, "body taps should route only to on_open")
ui.last_model.items[1].on_action()
expect(acted == "a" and opened == "a", "right actions should route only to on_action")
acted = nil
ui.last_model.items[1].on_hold()
expect(acted == "a", "holding a row should route to the row action")

ui.last_model.on_visible({ "a" })
expect(#cover_requests == 1 and cover_requests[1].manga.path == manga_a.path,
    "only visible rows should request cover metadata")
expect(cover_requests[1].connection == connection
    and cover_requests[1].record.cover_hint.image.path == "/漫画/A/001.jpg"
    and cover_requests[1].record.layout == "chapters"
    and cover_requests[1].record.chapter.path == chapter_a.path
    and cover_requests[1].record.chapters == nil
    and cover_requests[1].record.images == nil and cover_requests[1].record.catalog == nil,
    "resolution should receive validated identity and cover hints without legacy unbounded catalog arrays")

cover_requests[1].callbacks.on_ready{
    name = "001.jpg", path = "/漫画/A/001.jpg", size = 123,
}
expect(#loader_requests == 1 and loader_requests[1].image.path == "/漫画/A/001.jpg",
    "an uncached resolved image should enter the cover loader")
local first_generation = loader_requests[1].generation
loader_requests[1].callbacks.on_ready("/cache/a.jpg")
expect(#ui.updates == 1 and ui.updates[1].id == "a" and ui.updates[1].path == "/cache/a.jpg",
    "a ready cover should refresh only its row")

ui.last_model.on_visible({ "b" })
expect(canceled_generations[#canceled_generations] == first_generation,
    "changing visible rows should cancel the previous loader generation")
expect(#cover_requests == 2 and cover_requests[2].manga.path == manga_b.path,
    "the new page should resolve its visible row")

ui.last_model.on_visible({ "a" })
expect(cover_requests[2].canceled,
    "changing pages should cancel an unfinished metadata resolution")
expect(#canceled_generations >= 2 and canceled_generations[#canceled_generations] ~= first_generation,
    "each visible page should receive a distinct monotonic loader generation")
cover_requests[2].callbacks.on_ready{ name = "late.jpg", path = "/漫画/B/late.jpg" }
expect(#loader_requests == 1,
    "late metadata from a canceled page must not enter the loader")
expect(#cover_requests == 3 and cover_requests[3].manga.path == manga_a.path,
    "the replacement visible page should start its own metadata resolution")

cached_paths["key:/漫画/A/cached.jpg"] = "/cache/a-cached.jpg"
cover_requests[3].callbacks.on_ready{ name = "cached.jpg", path = "/漫画/A/cached.jpg" }
expect(#loader_requests == 1 and ui.updates[#ui.updates].path == "/cache/a-cached.jpg",
    "a cached cover should update directly without a loader request")

local queue_ui = {
    updates = {},
    show_grid = function(self, model) self.model = model end,
    update_cover = function(self, id, path) self.updates[#self.updates + 1] = { id = id, path = path } end,
    close_grid = function() end,
}
local queue_cover_requests = {}
local queue_service = {
    resolve = function(_self, _connection, record, callbacks)
        queue_cover_requests[#queue_cover_requests + 1] = { record = record, callbacks = callbacks }
        return { cancel = function() end }
    end,
}
local queue_loader_requests = {}
local queue_loader = {
    identity = loader.identity,
    request_cover = function(_self, generation, image, callbacks)
        queue_loader_requests[#queue_loader_requests + 1] = {
            generation = generation, image = image, callbacks = callbacks,
        }
    end,
    cancel_cover_generation = function() end,
}
local queue_list = CoverList:new{
    cover_service = queue_service,
    loader = queue_loader,
    cache = cache,
    ui = queue_ui,
    connection_provider = function() return connection end,
}
queue_list:show{
    title = "分类",
    items = {
        { id = "a", manga = manga_a, text = "漫画 A" },
        { id = "b", manga = manga_b, text = "漫画 B" },
    },
}
queue_ui.model.on_visible({ "a", "b" })
expect(#queue_cover_requests == 1 and queue_cover_requests[1].record.manga.path == manga_a.path,
    "metadata resolution should process visible rows one at a time in FIFO order")
queue_cover_requests[1].callbacks.on_error({ code = "transport" })
expect(#queue_cover_requests == 2 and queue_cover_requests[2].record.manga.path == manga_b.path,
    "one metadata failure should advance the remaining visible rows")
queue_cover_requests[2].callbacks.on_ready{ name = "b.jpg", path = "/漫画/B/b.jpg" }
expect(#queue_loader_requests == 1,
    "a later row should still reach the loader after an earlier metadata failure")
queue_loader_requests[1].callbacks.on_error({ code = "transport" })
expect(#queue_ui.updates == 0,
    "a download failure should retain the placeholder instead of updating a broken image")

local integrated_loader_requests = {}
local integrated_factory_calls = 0
local integrated_cover = Cover:new{
    library = {
        get_cover = function() return nil end,
        set_cover = function(_self, _connection, path, image)
            return { manga_path = path, image = image }
        end,
        set_no_cover = function(_self, _connection, path)
            return { manga_path = path, none = true }
        end,
    },
    directory_store = { load = function()
        integrated_factory_calls = integrated_factory_calls + 1
        error("direct known image must not load a directory")
    end },
    async = {
        run = function(work, done)
            local ok, result = pcall(work)
            done(ok, ok and result or nil, ok and nil or result)
            return { cancel = function() end }
        end,
    },
}
local integrated_list = CoverList:new{
    cover_service = integrated_cover,
    loader = {
        identity = loader.identity,
        request_cover = function(_self, _generation, image)
            integrated_loader_requests[#integrated_loader_requests + 1] = image
        end,
        cancel_cover_generation = function() end,
    },
    cache = { key_for = function(_self, _identity, path) return path end,
        lookup = function() return nil end },
    ui = { show_grid = function(self, model) self.model = model end,
        update_cover = function() end, close_grid = function() end },
    connection_provider = function() return connection end,
}
integrated_list:show{
    title = "非法记录隔离",
    items = {
        { id = "bad", manga = { name = "bad", path = "/private/bad" }, text = "bad" },
        { id = "good", manga = manga_b, text = "good",
            cover_hint = { image = { name = "good.jpg", path = "/漫画/B/good.jpg" } } },
    },
}
integrated_list.ui.model.on_visible({ "bad", "good" })
expect(#integrated_loader_requests == 1
    and integrated_loader_requests[1].path == "/漫画/B/good.jpg"
    and integrated_factory_calls == 0,
    "a synchronously rejected first record terminates once and lets the legal FIFO row advance")

local late_updates = #ui.updates
ui.last_model.on_visible({ "b" })
local pending_close_request = cover_requests[#cover_requests]
local closing_generation = canceled_generations[#canceled_generations]
list:close()
expect(ui.closes == 1 and ui.freed_visible_images,
    "closing should delegate visible image cleanup to the adapter")
expect(pending_close_request.canceled,
    "closing should cancel an unfinished metadata resolution")
expect(canceled_generations[#canceled_generations] ~= closing_generation,
    "closing should invalidate the current cover generation")
pending_close_request.callbacks.on_ready{ name = "late.jpg", path = "/漫画/B/late.jpg" }
expect(#ui.updates == late_updates,
    "a late callback after close must not update the UI")

ui.last_model.on_back()
expect(backed == nil, "callbacks from a closed model should be stale")

list:show{
    title = "阅读历史",
    items = { { id = "a", manga = manga_a, text = "漫画 A" } },
    on_back = function() backed = true end,
}
ui.last_model.on_back()
expect(backed and ui.closes == 2, "back should close the list before routing to on_back")

list:show{
    title = "分类",
    items = { { id = "b", manga = manga_b, text = "漫画 B" } },
}
local canceled_model = ui.last_model
expect(list:cancel() and ui.closes == 3,
    "cancel should close the visible list through the same lifecycle")
local requests_after_cancel = #cover_requests
canceled_model.on_visible({ "b" })
expect(#cover_requests == requests_after_cancel,
    "a canceled model should not start new cover work")

local function fake_widget_class(parent, kind)
    local class = {}
    class.__index = class
    setmetatable(class, { __index = parent })
    function class:extend(definition)
        definition = definition or {}
        definition.__index = definition
        definition._fake_kind = definition._fake_kind or self._fake_kind
        setmetatable(definition, { __index = self })
        return definition
    end
    function class:new(values)
        values = values or {}
        values._fake_kind = values._fake_kind or self._fake_kind or kind
        setmetatable(values, { __index = self })
        if values.init then values:init() end
        return values
    end
    class._fake_kind = kind
    return class
end

local Widget = fake_widget_class(nil, "widget")
function Widget:getSize()
    if self.dimen then return { w = self.dimen.w or 0, h = self.dimen.h or 0 } end
    if self._fake_kind == "title" then return { w = self.width or 600, h = 48 } end
    if self._fake_kind == "button" then return { w = self.width or 100, h = 48 } end
    if self._fake_kind == "vertical" then
        local width, height = 0, 0
        for _, child in ipairs(self) do
            local size = child:getSize()
            width = math.max(width, size.w)
            height = height + size.h
        end
        return { w = width, h = height }
    end
    if self._fake_kind == "horizontal" then
        local width, height = 0, 0
        for _, child in ipairs(self) do
            local size = child:getSize()
            width = width + size.w
            height = math.max(height, size.h)
        end
        return { w = width, h = height }
    end
    if self.width or self.height then return { w = self.width or 0, h = self.height or 0 } end
    if self[1] and self[1].getSize then return self[1]:getSize() end
    return { w = 0, h = 0 }
end
function Widget:free()
    self.freed = true
    for _, child in ipairs(self) do
        if child and child.free then child:free() end
    end
end

local fake_screen = {
    getWidth = function() return 600 end,
    getHeight = function() return 500 end,
    getSize = function() return { x = 0, y = 0, w = 600, h = 500 } end,
    scaleBySize = function(_self, value) return value end,
}
local fake_ui_manager = { dirty = {}, events = {} }
function fake_ui_manager:show(widget)
    self.shown = widget
    self.events[#self.events + 1] = { kind = "show", widget = widget }
end
function fake_ui_manager:close(widget) self.closed = widget end
function fake_ui_manager:setDirty(owner, refresh_type, region)
    if type(refresh_type) == "function" then refresh_type, region = refresh_type() end
    self.dirty[#self.dirty + 1] = {
        owner = owner, refresh_type = refresh_type, region = region,
    }
end

local fake_classes = {
    ["ui/widget/button"] = fake_widget_class(Widget, "button"),
    ["ui/widget/container/centercontainer"] = fake_widget_class(Widget, "center"),
    ["ui/widget/container/framecontainer"] = fake_widget_class(Widget, "frame"),
    ["ui/widget/container/inputcontainer"] = fake_widget_class(Widget, "input"),
    ["ui/widget/container/leftcontainer"] = fake_widget_class(Widget, "left"),
    ["ui/widget/horizontalgroup"] = fake_widget_class(Widget, "horizontal"),
    ["ui/widget/horizontalspan"] = fake_widget_class(Widget, "span"),
    ["ui/widget/iconwidget"] = fake_widget_class(Widget, "icon"),
    ["ui/widget/imagewidget"] = fake_widget_class(Widget, "image"),
    ["ui/widget/overlapgroup"] = fake_widget_class(Widget, "overlap"),
    ["ui/widget/progresswidget"] = fake_widget_class(Widget, "progress"),
    ["ui/widget/rectspan"] = fake_widget_class(Widget, "rect"),
    ["ui/widget/textwidget"] = fake_widget_class(Widget, "text"),
    ["ui/widget/textboxwidget"] = fake_widget_class(Widget, "text"),
    ["ui/widget/titlebar"] = fake_widget_class(Widget, "title"),
    ["ui/widget/verticalgroup"] = fake_widget_class(Widget, "vertical"),
}
fake_classes["ui/widget/textboxwidget"].getFontSizeToFitHeight = function(_self, height)
    return math.max(8, math.floor(height / 2))
end

local fake_modules = {
    ["ffi/blitbuffer"] = { COLOR_WHITE = 1 },
    ["device"] = { screen = fake_screen },
    ["ui/font"] = { getFace = function(_name, size) return { size = size } end },
    ["ui/geometry"] = { new = function(_self, values) return values end },
    ["ui/gesturerange"] = { new = function(_self, values) return values end },
    ["ui/size"] = {
        border = { thin = 1 },
        padding = { small = 4 },
    },
    ["ui/uimanager"] = fake_ui_manager,
}
for name, module in pairs(fake_classes) do fake_modules[name] = module end
for name, module in pairs(fake_modules) do
    package.loaded[name] = nil
    package.preload[name] = function() return module end
end

local adapter_cover_requests = {}
local adapter_loader_requests = {}
local adapter_list = CoverList:new{
    cover_service = {
        resolve = function(_self, _connection, record, callbacks)
            adapter_cover_requests[#adapter_cover_requests + 1] = {
                record = record, callbacks = callbacks,
            }
            return { cancel = function() end }
        end,
    },
    loader = {
        identity = loader.identity,
        request_cover = function(_self, generation, image, callbacks)
            adapter_loader_requests[#adapter_loader_requests + 1] = {
                generation = generation, image = image, callbacks = callbacks,
            }
        end,
        cancel_cover_generation = function() end,
    },
    cache = {
        key_for = function(_self, _identity, path) return path end,
        lookup = function() return nil end,
    },
    connection_provider = function() return connection end,
}
adapter_list:show{
    title = "默认适配器",
    items = { { id = "adapter", manga = manga_a, text = "漫画 A", mandatory = "管理" } },
}
adapter_cover_requests[1].callbacks.on_ready{
    name = "adapter.jpg", path = "/漫画/A/adapter.jpg",
}
adapter_loader_requests[1].callbacks.on_ready("/cache/adapter.jpg")
local adapter_widget = fake_ui_manager.shown
local adapter_row = adapter_widget.cells.adapter
local last_dirty = fake_ui_manager.dirty[#fake_ui_manager.dirty]
expect(adapter_row.buffer and adapter_row.buffer.path == "/cache/adapter.jpg",
    "the default adapter should replace an asynchronously completed row cover")
expect(last_dirty.owner == adapter_widget and last_dirty.region == adapter_row.dimen,
    "an async row update should repaint through the shown top-level widget within the row region")

local sync_loader_calls = 0
fake_ui_manager.events = {}
local sync_adapter_list = CoverList:new{
    cover_service = {
        resolve = function(_self, _connection, _record, callbacks)
            fake_ui_manager.events[#fake_ui_manager.events + 1] = {
                kind = "visible", widget = fake_ui_manager.shown,
            }
            callbacks.on_ready{ name = "sync.jpg", path = "/漫画/A/sync.jpg" }
            return { cancel = function() end }
        end,
    },
    loader = {
        identity = loader.identity,
        request_cover = function() sync_loader_calls = sync_loader_calls + 1 end,
        cancel_cover_generation = function() end,
    },
    cache = {
        key_for = function(_self, _identity, path) return path end,
        lookup = function(_self, key)
            if key == "/漫画/A/sync.jpg" then return "/cache/sync.jpg" end
        end,
    },
    connection_provider = function() return connection end,
}
sync_adapter_list:show{
    title = "同步首屏",
    items = { { id = "sync", manga = manga_a, text = "漫画 A", mandatory = "管理" } },
}
local sync_widget = fake_ui_manager.shown
expect(fake_ui_manager.events[1].kind == "show"
    and fake_ui_manager.events[1].widget == sync_widget
    and fake_ui_manager.events[2].kind == "visible"
    and fake_ui_manager.events[2].widget == sync_widget,
    "the default adapter should show and retain its top-level widget before publishing first-page visibility")
expect(sync_widget.cells.sync.buffer
    and sync_widget.cells.sync.buffer.path == "/cache/sync.jpg"
    and sync_loader_calls == 0,
    "a synchronous first-page cache hit should update the adapter after its widget is shown")

local multi_items = {}
for index = 1, 7 do
    multi_items[#multi_items + 1] = {
        id = "p" .. tostring(index),
        manga = {
            name = "分页漫画 " .. tostring(index),
            path = "/漫画/page/" .. tostring(index),
            is_folder = true,
        },
        text = "分页漫画 " .. tostring(index),
        mandatory = "管理",
    }
end
fake_ui_manager.events = {}
local multi_widget
local multi_adapter_list = CoverList:new{
    cover_service = {
        resolve = function(_self, _connection, record, callbacks)
            local id = "p" .. tostring(record.manga.path:match("/(%d+)$"))
            local shown = fake_ui_manager.shown
            fake_ui_manager.events[#fake_ui_manager.events + 1] = {
                kind = "visible",
                id = id,
                widget = shown,
                replacement_live = shown == multi_widget
                    and shown[1] == shown.page_group
                    and shown.cells[id] ~= nil
                    and shown.cells.p1 == nil,
            }
            callbacks.on_ready{
                name = id .. ".jpg",
                path = record.manga.path .. "/" .. id .. ".jpg",
            }
            return { cancel = function() end }
        end,
    },
    loader = {
        identity = loader.identity,
        request_cover = function() error("synchronous indexed covers should hit cache") end,
        cancel_cover_generation = function() end,
    },
    cache = {
        key_for = function(_self, _identity, path) return path end,
        lookup = function(_self, key)
            local id = "p" .. tostring(key:match("/p(%d+)%.jpg$"))
            return "/cache/" .. id .. ".jpg"
        end,
    },
    connection_provider = function() return connection end,
}
multi_adapter_list:show{ title = "同步分页", items = multi_items }
multi_widget = fake_ui_manager.shown
expect(multi_widget:set_page(2),
    "the real default widget should navigate to its replacement page")
local second_page_event = fake_ui_manager.events[#fake_ui_manager.events]
expect(second_page_event.kind == "visible" and second_page_event.id == "p7"
    and second_page_event.widget == multi_widget and second_page_event.replacement_live,
    "the replacement page should be rebuilt and live before publishing its visible IDs")
expect(multi_widget.cells.p1 == nil and multi_widget.cells.p7.buffer
    and multi_widget.cells.p7.buffer.path == "/cache/p7.jpg",
    "a synchronous second-page cache hit should update the new row without writing the departed page")

local reshow_models = {}
local reshow_updates = {}
local reshow_close_reentered = false
local reshow_ui = {
    show_grid = function(self, model)
        self.current_model = model
        reshow_models[#reshow_models + 1] = model
    end,
    close_grid = function(self)
        if self.current_model and not reshow_close_reentered then
            reshow_close_reentered = true
            self.current_model.on_visible({ "shared" })
        end
        self.current_model = nil
    end,
    update_cover = function(self, id, path)
        reshow_updates[#reshow_updates + 1] = {
            model = self.current_model, id = id, path = path,
        }
    end,
}
local reshow_loader_requests = {}
local reshow_list = CoverList:new{
    cover_service = {
        resolve = function(_self, _connection, record, callbacks)
            callbacks.on_ready{
                name = "old.jpg", path = record.manga.path .. "/old.jpg",
            }
            return { cancel = function() end }
        end,
    },
    loader = {
        identity = loader.identity,
        request_cover = function(_self, generation, image, callbacks)
            reshow_loader_requests[#reshow_loader_requests + 1] = {
                generation = generation, image = image, callbacks = callbacks,
            }
        end,
        cancel_cover_generation = function() end,
    },
    cache = {
        key_for = function(_self, _identity, path) return path end,
        lookup = function() return nil end,
    },
    ui = reshow_ui,
    connection_provider = function() return connection end,
}
reshow_list:show{
    title = "旧列表",
    items = { {
        id = "shared",
        manga = { name = "旧漫画", path = "/漫画/old", is_folder = true },
        text = "旧漫画",
    } },
}
local old_reshow_model = reshow_ui.current_model
old_reshow_model.on_visible({ "shared" })
expect(#reshow_loader_requests == 1,
    "the old view should establish one loader waiter before replacement")
reshow_list:show{
    title = "新列表",
    items = { {
        id = "shared",
        manga = { name = "新漫画", path = "/漫画/new", is_folder = true },
        text = "新漫画",
    } },
}
local last_reshow_request = reshow_loader_requests[#reshow_loader_requests]
last_reshow_request.callbacks.on_ready("/cache/old-late.jpg")
expect(#reshow_loader_requests == 1 and #reshow_updates == 0
    and reshow_ui.current_model == reshow_models[2],
    "reentrant close work and late old loader callbacks must not pollute the replacement view")

print(("cover_list_spec: %d checks"):format(checks))
