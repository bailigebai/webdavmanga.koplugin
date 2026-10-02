local BookIndex = require("webdavmanga.book_index")

local MupdfPages = {}
MupdfPages.__index = MupdfPages

local DEFAULT_MAX_PIXELS = 12000000

local function protected_method(object, name, ...)
    local found, method = pcall(function() return object[name] end)
    if not found then return false, "missing_object" end
    if type(method) ~= "function" then return false, "missing_" .. name end
    return pcall(method, object, ...)
end

local function finite_positive(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or value <= 0 then return nil end
    return value
end

local function page_size(page, draw_context)
    local ok, a, b = protected_method(page, "getSize", draw_context)
    if not ok then return nil, "corrupt_document" end
    return finite_positive(a), finite_positive(b)
end

local function render_size(width, height, max_pixels)
    local area = width * height
    if area ~= area or area <= 0 or not max_pixels or max_pixels < 1 then
        return nil, nil, "pixel_limit_exceeded"
    end
    local scale = area > max_pixels and math.sqrt(max_pixels / area) or 1
    local output_width = math.max(1, math.floor(width * scale))
    local output_height = math.max(1, math.floor(height * scale))
    while output_width * output_height > max_pixels do
        if output_width >= output_height then output_width = output_width - 1
        else output_height = output_height - 1 end
    end
    return output_width, output_height
end

local function target_info(target)
    if type(target) == "table" then
        local page = tonumber(target.page or target.target_page or 1)
        local path = target.path or target.output_path
        return page, path
    end
    return tonumber(target) or 1, nil
end

local function close_safely(object, name)
    if object then pcall(protected_method, object, name) end
end

function MupdfPages:new(options)
    options = options or {}
    return setmetatable({
        mupdf = options.mupdf,
        draw_context = options.draw_context,
        image_probe = options.image_probe or require("webdavmanga.image_probe"),
        open_file = options.open_file or io.open,
        remove_file = options.remove_file or os.remove,
        max_pixels = tonumber(options.max_pixels) or DEFAULT_MAX_PIXELS,
        temp_name = options.temp_name or os.tmpname,
    }, self)
end

function MupdfPages:_mupdf()
    if not self.mupdf then self.mupdf = require("ffi/mupdf") end
    return self.mupdf
end

function MupdfPages:remote_capability()
    local loaded, mupdf = pcall(function() return self:_mupdf() end)
    return loaded and type(mupdf) == "table"
        and type(mupdf.openRemoteDocument) == "function"
end

function MupdfPages:_draw_context()
    if self.draw_context then return self.draw_context end
    local ok, DrawContext = pcall(require, "ffi/drawcontext")
    if not ok or type(DrawContext) ~= "table" or type(DrawContext.new) ~= "function" then
        return nil
    end
    local created, context = pcall(DrawContext.new)
    if not created then return nil end
    self.draw_context = context
    return context
end

local function set_zoom(draw_context, zoom)
    if type(draw_context) ~= "table" and type(draw_context) ~= "userdata" then
        local ok = pcall(function() draw_context.zoom = zoom end)
        if ok then return true end
    end
    local ok = pcall(function()
        if type(draw_context.setZoom) == "function" then draw_context:setZoom(zoom)
        else draw_context.zoom = zoom end
    end)
    return ok
end

function MupdfPages:_open_remote(descriptor)
    if type(descriptor) ~= "table" or type(descriptor.read_at) ~= "function"
        or type(descriptor.name) ~= "string" or descriptor.name == ""
        or type(descriptor.format) ~= "string" or descriptor.format == ""
        or not finite_positive(descriptor.size)
        or descriptor.size ~= math.floor(descriptor.size) then
        return nil, "invalid_remote_descriptor"
    end
    local mupdf = self:_mupdf()
    if type(mupdf.openRemoteDocument) ~= "function" then
        return nil, "range_unavailable"
    end
    local ok, document, error_message = pcall(mupdf.openRemoteDocument, descriptor)
    if not ok or not document then
        if tostring(error_message):lower():find("encrypt", 1, true) then
            return nil, "encrypted_document"
        end
        return nil, "corrupt_document"
    end
    return document
end

function MupdfPages:_open_local(path)
    if type(path) ~= "string" or path == "" then return nil, "invalid_local_path" end
    local mupdf = self:_mupdf()
    if type(mupdf.openDocument) ~= "function" then return nil, "corrupt_document" end
    local ok, document, error_message = pcall(mupdf.openDocument, path)
    if not ok or not document then
        if tostring(error_message):lower():find("encrypt", 1, true) then
            return nil, "encrypted_document"
        end
        return nil, "corrupt_document"
    end
    return document
end

function MupdfPages:_page_count(document)
    local ok, count, error_message = protected_method(document, "getPages")
    if not ok or type(count) ~= "number" or count < 1 or count ~= math.floor(count) then
        return nil, "corrupt_document"
    end
    return count
end

function MupdfPages:_render_document(document, page_number, target)
    local count, count_error = self:_page_count(document)
    if not count then return nil, count_error end
    if page_number < 1 or page_number > count or page_number ~= math.floor(page_number) then
        return nil, "render_failed"
    end
    local ok, page = protected_method(document, "openPage", page_number)
    if not ok or not page then return nil, "render_failed" end
    local metadata, error_code
    local draw_context = self:_draw_context()
    local width, height
    if draw_context then width, height = page_size(page, draw_context) end
    if not width or not height then
        error_code = "corrupt_document"
    else
        local output_width, output_height, size_error = render_size(width, height, self.max_pixels)
        if not output_width then
            error_code = size_error
        elseif type(target) ~= "string" or target == "" then
            error_code = "render_failed"
        elseif not set_zoom(draw_context, output_width / width) then
            error_code = "render_failed"
        else
            local draw_ok, buffer = protected_method(page, "draw_new", draw_context,
                output_width, output_height, 0, 0)
            if not draw_ok or not buffer then
                error_code = "render_failed"
            else
                local write_ok, written = protected_method(buffer, "writePNG", target)
                if not write_ok or written == false then error_code = "render_failed" end
                close_safely(buffer, "close")
                close_safely(buffer, "free")
            end
        end
    end
    close_safely(page, "close")
    if error_code then return nil, error_code end
    local probe_ok, probed, probe_error = pcall(self.image_probe.inspect, target, "png")
    if not probe_ok or not probed then return nil, "render_failed" end
    probed.format = "png"
    return probed
end

function MupdfPages:_render(descriptor_or_path, is_remote, page_number, target)
    local document, open_error
    if is_remote then document, open_error = self:_open_remote(descriptor_or_path)
    else document, open_error = self:_open_local(descriptor_or_path) end
    if not document then return nil, open_error end
    local ok, metadata, render_error = pcall(self._render_document, self, document,
        page_number, target)
    close_safely(document, "close")
    if not ok then return nil, "render_failed" end
    return metadata, render_error
end

function MupdfPages:_inspect(descriptor_or_path, is_remote, remote_path, format, first_target, size)
    local page_number, output_path = target_info(first_target)
    local temporary = false
    if not output_path then output_path, temporary = self.temp_name(), true end
    local document, open_error
    if is_remote then document, open_error = self:_open_remote(descriptor_or_path)
    else document, open_error = self:_open_local(descriptor_or_path) end
    if not document then
        if temporary then pcall(self.remove_file, output_path) end
        return nil, open_error
    end
    local count, count_error = self:_page_count(document)
    local metadata, render_error
    if count then metadata, render_error = self:_render_document(document, page_number, output_path)
    else render_error = count_error end
    close_safely(document, "close")
    if temporary then pcall(self.remove_file, output_path) end
    if not metadata then return nil, render_error end
    local source_path = is_remote and tostring(remote_path or "document") or descriptor_or_path
    local items = {}
    for number = 1, count do
        items[number] = {
            name = ("%05d.png"):format(number),
            path = source_path .. "#mupdf/" .. tostring(number),
            size = tonumber(size) or (is_remote and descriptor_or_path.size or 0),
            format = tostring(format or (is_remote and descriptor_or_path.format or "pdf")),
            page = number,
            mupdf_page = number,
            is_file = true,
        }
    end
    return {
        index = BookIndex.from_items(items),
        layout = "mupdf_pages",
        first_metadata = metadata,
    }
end

function MupdfPages:inspect_remote(descriptor, remote_path, first_target)
    if type(descriptor) ~= "table" then return nil, "invalid_remote_descriptor" end
    return self:_inspect(descriptor, true, remote_path, descriptor.format,
        first_target, descriptor.size)
end

function MupdfPages:inspect_local(path, format, first_target)
    local handle = type(path) == "string" and self.open_file(path, "rb") or nil
    if not handle then return nil, "invalid_local_path" end
    local size = handle:seek("end") or 0
    pcall(handle.close, handle)
    return self:_inspect(path, false, nil, format, first_target, size)
end

function MupdfPages:render_remote(image, read_at, target)
    if type(image) ~= "table" or type(read_at) ~= "function" then
        return nil, "invalid_remote_page"
    end
    local descriptor = {
        size = image.size,
        format = image.format,
        name = image.name,
        read_at = read_at,
    }
    return self:_render(descriptor, true, tonumber(image.mupdf_page or image.page), target)
end

function MupdfPages:render_local(image, target)
    if type(image) ~= "table" or type(image.path) ~= "string" then
        return nil, "invalid_local_page"
    end
    local path = image.local_path or image.source_path or image.path:match("^(.-)#mupdf/")
    if not path then return nil, "invalid_local_page" end
    return self:_render(path, false, tonumber(image.mupdf_page or image.page), target)
end

return MupdfPages
