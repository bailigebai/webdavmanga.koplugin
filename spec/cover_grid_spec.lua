local CoverGrid = require("webdavmanga.ui_cover_grid")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local items = {}
for index = 1, 7 do
    items[#items + 1] = {
        id = "manga-" .. index,
        name = "漫画 " .. index,
        manga = { name = "漫画 " .. index, path = "/漫画/" .. index, is_folder = true },
    }
end

local buffers = {}
local renderer = {
    calls = {},
    renderImageFile = function(self, path, animated, width, height)
        self.calls[#self.calls + 1] = { path = path, animated = animated, width = width, height = height }
        local buffer = { path = path, width = width, height = height, freed = false }
        function buffer:free() self.freed = true end
        buffers[#buffers + 1] = buffer
        return buffer
    end,
}
local cache = {
    key_for = function(_, identity, path) return identity .. "|" .. path end,
    lookup = function(self, key) return self[key] end,
}
local loader = { identity = "account", requests = {}, canceled = {} }
function loader:request_cover(generation, image, callbacks)
    local request = { generation = generation, image = image, callbacks = callbacks, canceled = false }
    self.requests[#self.requests + 1] = request
    callbacks.on_ready(image.path == "/cover/cached.jpg" and "/cache/cached.jpg" or image.path)
    return { cancel = function() request.canceled = true; self.canceled[#self.canceled + 1] = request end }
end
function loader:cancel_cover_generation(generation) self.canceled[#self.canceled + 1] = generation end

local cover_service = { requests = {} }
function cover_service:resolve(_connection, record, callbacks)
    self.requests[#self.requests + 1] = { record = record, callbacks = callbacks }
    local image = { name = "001.jpg", path = "/cover/" .. record.manga.path:match("%d+$") .. ".jpg" }
    callbacks.on_ready(image)
    return { cancel = function() end }
end

local ui = { updates = {}, freed = 0, closed = 0 }
function ui:show_grid(model)
    self.model = model
    model.rows = 1
    model.visible_ids = { "manga-1", "manga-2", "manga-3", "manga-4", "manga-5" }
    model.on_visible(model.visible_ids)
end
function ui:get_cover_size() return 100, 140 end
function ui:update_cover(id, buffer)
    self.updates[#self.updates + 1] = { id = id, buffer = buffer }
    return true
end
function ui:free_visible() self.freed = self.freed + 1 end
function ui:close_grid() self.closed = self.closed + 1 end
local reporter = { failures = {} }
function reporter:guard(_, callback, fallback)
    local ok, result = pcall(callback)
    if ok then return result end
    self.failures[#self.failures + 1] = result
    return fallback
end
function reporter:wrap(_, callback, fallback)
    return function(...)
        local arguments = { ... }
        return self:guard("", function() return callback(unpack(arguments)) end, fallback)
    end
end

local settings = { get_reader = function() return { grid_columns = 5 } end }
local scheduler = { callbacks = {} }
function scheduler:scheduleIn(_, callback) self.callbacks[#self.callbacks + 1] = callback end
function scheduler:flush()
    local callbacks = self.callbacks
    self.callbacks = {}
    for _, callback in ipairs(callbacks) do callback() end
end

local opened = 0
local grid = CoverGrid:new{
    cover_service = cover_service,
    loader = loader,
    cache = cache,
    connection_provider = function() return { root_path = "/漫画" } end,
    settings = settings,
    render_image = renderer,
    scheduler = scheduler,
    ui = ui,
    error_reporter = reporter,
}
grid:show{ title = "阅读历史", items = items, on_back = function() opened = opened + 1 end }
expect(ui.model.columns == 5 and ui.model.fullscreen and ui.model.cells[1].name == "漫画 1",
    "grid model uses fullscreen five-column cells with one-line names")
expect(#ui.model.visible_ids == 5 and #ui.updates == 5,
    "only the visible first page requests and renders covers (visible=" .. tostring(#ui.model.visible_ids) .. ", updates=" .. tostring(#ui.updates) .. ", resolves=" .. tostring(#cover_service.requests) .. ", loads=" .. tostring(#loader.requests) .. ", renders=" .. tostring(#renderer.calls) .. ", errors=" .. tostring(reporter.failures[1]) .. ")")
expect(renderer.calls[1].width == 100 and renderer.calls[1].height == 140,
    "covers render directly to the target cell dimensions")
local before_leave_freed = ui.freed
grid:leave_for(function() opened = opened + 1 end)
expect(ui.freed == before_leave_freed + 1 and ui.closed == 1,
    "leaving invalidates work, frees visible buffers, then closes the grid")
expect(opened == 0 and #scheduler.callbacks == 1, "reader opening waits for the scheduled close tick")
scheduler:flush()
expect(opened == 1, "leave_for opens the reader exactly once")

settings.get_reader = function() return { grid_columns = 3 } end
grid:show{ title = "分类", items = items }
expect(ui.model.columns == 3, "grid honors the three-column setting")
expect(ui.model.cover_width == nil or ui.model.cover_width > 0, "grid exposes a positive cover width when supplied by the adapter")

print(("cover_grid_spec: %d checks"):format(checks))
