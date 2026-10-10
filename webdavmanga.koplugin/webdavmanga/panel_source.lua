local PanelSource = {}
PanelSource.__index = PanelSource
local Handle = {}
Handle.__index = Handle
local View = require("webdavmanga.panel_view")

local function finite(value)
    value = tonumber(value)
    if value and value == value and math.abs(value) < math.huge then return value end
end

local function positive(value)
    value = finite(value)
    if value and value > 0 then return value end
end

local function release(value, method)
    if value then pcall(function() value[method](value) end) end
end

local function dependency(value, module)
    if value ~= nil then return value end
    local ok, loaded = pcall(require, module)
    if ok then return loaded end
end

local function clipped(box)
    if type(box) ~= "table" then return nil end
    local x, y, w, h = finite(box.x), finite(box.y), positive(box.w), positive(box.h)
    if not x or not y or not w or not h then return nil end
    local right, bottom = math.min(1, x + w), math.min(1, y + h)
    x, y = math.max(0, x), math.max(0, y)
    if right <= x or bottom <= y then return nil end
    return { x = x, y = y, w = right - x, h = bottom - y }
end

local function fit(width, height, target_w, target_h, max_pixels)
    -- A subpixel side rounds up to one: limit the other side with the same zoom.
    local zoom = math.min(target_w / width, target_h / height,
        math.sqrt(max_pixels / width / height), max_pixels / width, max_pixels / height)
    if not positive(zoom) then return nil end
    local w = math.max(1, math.floor(width * zoom))
    local h = math.max(1, math.floor(height * zoom))
    return w, h, zoom
end

function Handle:close()
    if self.closed then return end
    self.closed = true
    local page, document = self.page, self.document
    self.page, self.document = nil, nil
    release(page, "close")
    release(document, "close")
    self.path, self.buffer, self.draw_context = nil, nil, nil
end

function Handle:detection_raster()
    if self.closed then return nil, "panel_source_unavailable" end
    return {
        path = self.path, buffer = self.buffer, crop = self.crop_normalized,
        width = self.detection_width, height = self.detection_height,
        max_width = self.screen_width, max_height = self.screen_height,
    }
end

function Handle:render(panel, options)
    if self.closed then return nil, "panel_source_unavailable" end
    options = options or {}
    local camera,reason=self:camera(panel,options)
    if not camera then return nil,reason end
    local box=camera.box
    local target_w,target_h=camera.target_width,camera.target_height
    local requested_pixels = positive(options.max_pixels)
    if options.max_pixels ~= nil and not requested_pixels then return nil, "invalid_pixel_budget" end
    local max_pixels = math.floor(math.min(self.screen_width * self.screen_height * 1.5,
        requested_pixels or math.huge))
    if max_pixels < 1 then return nil, "invalid_pixel_budget" end
    local function render(kind, full_width, full_height)
        local x, y = box.x * full_width, box.y * full_height
        local width, height = box.w * full_width, box.h * full_height
        local viewport
        local ok, result = pcall(function()
            if kind == "buffer" then
                local right = math.min(full_width, math.ceil(x + width))
                local bottom = math.min(full_height, math.ceil(y + height))
                x, y = math.floor(x), math.floor(y)
                width, height = right - x, bottom - y
            end
            local w, h, zoom = fit(width, height, target_w, target_h, max_pixels)
            if not w then return nil end
            if kind == "buffer" then
                viewport = self.buffer:viewport(x, y, width, height)
                return viewport:scale(w, h)
            end
            return self.page:draw_new(self.draw_context.new(0, zoom), w, h, x * zoom, y * zoom)
        end)
        release(viewport, "free")
        if ok then return result end
    end
    local result = render(self.kind, self.width, self.height)
    if not result and self.kind ~= "buffer" and self.buffer_width and self.buffer_height then
        result = render("buffer", self.buffer_width, self.buffer_height)
    end
    if not result then return nil, "panel_render_failed" end
    if camera.rotation~=0 then
        local ok,rotated=pcall(function() return result:rotatedCopy(-camera.rotation) end)
        release(result,"free")
        if not ok or not rotated then return nil,"panel_rotation_failed" end
        result=rotated
    end
    -- The returned allocation belongs to the caller, never to this handle.
    return result
end

function Handle:camera(panel,options)
    local values={}
    for k,v in pairs(options or {}) do values[k]=v end
    values.screen_width=positive(values.screen_width) or self.screen_width
    values.screen_height=positive(values.screen_height) or self.screen_height
    local camera,reason=View.compute(panel,self.crop_normalized,self.width,self.height,values)
    if camera and values.transition_box then
        local box=clipped(values.transition_box)
        if not box or box.x<self.crop_normalized.x or box.y<self.crop_normalized.y
            or box.x+box.w>self.crop_normalized.x+self.crop_normalized.w+.000001
            or box.y+box.h>self.crop_normalized.y+self.crop_normalized.h+.000001 then
            return nil,"invalid_panel_camera"
        end
        camera.box=box
    end
    return camera,reason
end

function Handle:pan_options(panel,options,dx,dy)
    local camera=self:camera(panel,options)
    if not camera then return nil end
    return View.pan(camera,self.crop_normalized,options,dx,dy)
end

function PanelSource:new(options)
    options = options or {}
    return setmetatable({
        mupdf = options.mupdf,
        draw_context = options.draw_context,
    }, self)
end

function PanelSource:_handle(request)
    local handle = setmetatable({
        path = request.page_path, buffer = request.page_buffer,
        screen_width = positive(request.screen_width),
        screen_height = positive(request.screen_height),
    }, Handle)
    if not handle.screen_width or not handle.screen_height
        or handle.screen_width < 1 or handle.screen_height < 1 then handle:close(); return nil end
    handle.screen_width, handle.screen_height = math.floor(handle.screen_width), math.floor(handle.screen_height)
    local buffer_w, buffer_h
    if handle.buffer then
        local ok, w, h = pcall(function()
            return handle.buffer:getWidth(), handle.buffer:getHeight()
        end)
        if ok then buffer_w, buffer_h = positive(w), positive(h) end
    end
    handle.buffer_width, handle.buffer_height = buffer_w, buffer_h
    local native_ok = pcall(function()
        local mupdf = assert(dependency(self.mupdf, "ffi/mupdf"))
        handle.draw_context = assert(dependency(self.draw_context, "ffi/drawcontext"))
        if type(handle.path) == "string" and handle.path ~= "" then
            handle.document = assert(mupdf.openDocument(handle.path))
        else
            return
        end
        handle.page = assert(handle.document:openPage(1))
        local w, h = handle.page:getSize(handle.draw_context.new(0, 1))
        handle.width, handle.height = assert(positive(w)), assert(positive(h))
        handle.kind = "mupdf"
    end)
    if not native_ok or not handle.kind then
        release(handle.page, "close"); release(handle.document, "close")
        handle.page, handle.document, handle.draw_context = nil, nil, nil
        if not buffer_w or not buffer_h then handle:close(); return nil end
        handle.kind, handle.width, handle.height = "buffer", buffer_w, buffer_h
    end
    local crop = request.page_crop
    if crop then
        if type(crop) ~= "table" then handle:close(); return nil end
        local w, h = buffer_w or handle.width, buffer_h or handle.height
        local x, y, cw, ch = finite(crop.x), finite(crop.y), positive(crop.w), positive(crop.h)
        if x and y and cw and ch then
            handle.crop_normalized = clipped({ x = x / w, y = y / h, w = cw / w, h = ch / h })
        end
        if not handle.crop_normalized then handle:close(); return nil end
    else
        handle.crop_normalized = { x = 0, y = 0, w = 1, h = 1 }
    end
    local zoom = math.min(1, handle.screen_width / handle.width, handle.screen_height / handle.height)
    handle.detection_width = math.max(1, math.floor(handle.width * zoom * handle.crop_normalized.w))
    handle.detection_height = math.max(1, math.floor(handle.height * zoom * handle.crop_normalized.h))
    return handle
end

function PanelSource:open(generation, request, callbacks)
    request, callbacks = request or {}, callbacks or {}
    self.generation = generation
    self.token = (self.token or 0) + 1
    local token = self.token
    local operation = {}
    function operation:cancel()
        if self.cancelled then return end
        self.cancelled = true
        if self.handle then self.handle:close() end
    end
    local function complete()
        if operation.finished then return end
        operation.finished = true
        if operation.cancelled or self.token ~= token or self.generation ~= generation then
            return
        end
        local handle = self:_handle(request)
        if handle then
            operation.handle = handle
            if operation.cancelled or self.token ~= token or self.generation ~= generation then
                handle:close()
            elseif type(callbacks.on_ready) ~= "function"
                or not pcall(callbacks.on_ready, handle) then
                handle:close()
            end
        else
            if not operation.cancelled and self.token == token
                and self.generation == generation and callbacks.on_error then
                pcall(callbacks.on_error, "panel_source_unavailable")
            end
        end
    end
    if request.engine == "memory" then
        operation.finished = true
        if callbacks.on_error then pcall(callbacks.on_error, "panel_engine_unsupported") end
        return operation
    end
    complete()
    return operation
end

return PanelSource
