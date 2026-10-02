local NativeImageFilter = {}

local function dependency(dependencies, key, module)
    if dependencies and dependencies[key] then return dependencies[key] end
    local ok, loaded = pcall(require, module)
    if ok then return loaded end
end

local function close(value, method)
    if value and type(value[method]) == "function" then
        pcall(value[method], value)
    end
end

function NativeImageFilter.process(path, profile, dependencies)
    profile = profile or {}
    local mupdf = dependency(dependencies, "mupdf", "ffi/mupdf")
    local draw_context = dependency(dependencies, "draw_context", "ffi/drawcontext")
    local optimized = profile.dewatermark == true
        or profile.white_threshold_enabled == true
    local kopt = optimized
        and dependency(dependencies, "kopt", "ffi/koptcontext") or nil
    if not mupdf or type(mupdf.openDocument) ~= "function"
        or not draw_context or type(draw_context.new) ~= "function"
        or (optimized and (not kopt or type(kopt.new) ~= "function")) then
        return nil, "native_image_processing_unavailable"
    end

    local document, page, context
    local ok, result = pcall(function()
        document = assert(mupdf.openDocument(path))
        if type(document.setColorRendering) == "function" then
            document:setColorRendering(false)
        end
        page = assert(document:openPage(1))
        local width, height = page:getSize(draw_context.new(0, 1))
        width, height = tonumber(width), tonumber(height)
        assert(width and height and width > 0 and height > 0)

        local zoom = math.min(
            (tonumber(profile.target_width) or width) / width,
            (tonumber(profile.target_height) or height) / height)
        if not optimized then
            return assert(page:draw_new(
                draw_context.new(0, zoom, 0, 0,
                    tonumber(profile.contrast) or 1,
                    profile.background_cleanup == true),
                math.max(1, math.floor(tonumber(profile.target_width) or width)),
                math.max(1, math.floor(tonumber(profile.target_height) or height)),
                0, 0))
        end

        context = assert(kopt.new())
        context:setBBox(0, 0, width, height)
        context:setZoom(zoom)
        context:setContrast(1 / (tonumber(profile.contrast) or 1))
        if profile.white_threshold_enabled == true then
            context:setWhiteThreshold(tonumber(profile.white_threshold) or 224)
            context:setPaintWhiteThreshold(1)
        end
        page:getPagePix(context, 0, profile.background_cleanup == true and 1 or 0)
        context:optimizePage()
        return assert(context:dstToBlitBuffer())
    end)

    close(context, "free")
    close(page, "close")
    close(document, "close")
    if not ok then return nil, "native_image_processing_failed" end
    return result
end

return NativeImageFilter
