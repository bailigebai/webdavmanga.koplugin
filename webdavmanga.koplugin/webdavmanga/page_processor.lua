local AutoCrop = require("webdavmanga.auto_crop")
local GrayEnhance = require("webdavmanga.gray_enhance")
local PageSequence = require("webdavmanga.page_sequence")
local ToneAdjust = require("webdavmanga.tone_adjust")

local PageProcessor = {}

local function positive(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or value <= 0 then return nil end
    return value
end

function PageProcessor.target_size(width, height, settings, content_w, content_h)
    width, height = positive(width), positive(height)
    content_w, content_h = positive(content_w), positive(content_h)
    if not width or not height or not content_w or not content_h then return nil end
    settings = settings or {}
    local webtoon = settings.fit_mode == "webtoon"
    local split = not webtoon and #PageSequence.segments(width, height, settings) == 2
    local scale
    if split then
        local cut = math.max(0.1, math.min(0.9,
            (tonumber(settings.split_cut_percent) or 50) / 100))
        scale = math.min(content_w / math.max(width * cut, width * (1 - cut)),
            content_h / height)
    elseif settings.fit_mode == "width" or webtoon then
        scale = content_w / width
    else
        scale = math.min(content_w / width, content_h / height)
    end
    -- At most 8 MiB per target even with four-byte pixels. This bounds the
    -- target, not the native decoder's temporary full-source allocation.
    local max_pixels = webtoon and math.min(4 * content_w * content_h, 2 * 1024 * 1024)
        or 2 * content_w * content_h
    scale = math.min(scale, math.sqrt(max_pixels / (width * height)))
    local target_w = math.max(1, math.floor(width * scale))
    local target_h = math.max(1, math.floor(height * scale))
    max_pixels = math.floor(max_pixels)
    while target_w * target_h > max_pixels do
        if target_w >= target_h then target_w = target_w - 1
        else target_h = target_h - 1 end
    end
    return target_w, target_h
end

function PageProcessor.profile(settings, image, content_w, content_h)
    settings, image = settings or {}, image or {}
    local gray_enabled = settings.gray_enhance_enabled == true
    local tone_enabled = settings.tone_adjust_enabled == true
    local crop_enabled = settings.auto_crop_enabled == true
    if not gray_enabled and not tone_enabled and not crop_enabled then return nil end
    local width, height = positive(image.width), positive(image.height)
    local target_w, target_h = PageProcessor.target_size(width, height,
        settings, content_w, content_h)
    if not target_w then return nil end

    local gray = gray_enabled and GrayEnhance.find(
        settings.gray_enhance_preset or "original",
        settings.gray_enhance_custom_presets) or nil
    local tone = tone_enabled and ToneAdjust.find(
        settings.tone_adjust_preset or "original",
        settings.tone_adjust_custom_presets) or nil
    if gray_enabled and not gray then gray = GrayEnhance.find("original", {}) end
    if tone_enabled and not tone then tone = ToneAdjust.find("original", {}) end
    local lut = ToneAdjust.combine_lut(
        gray_enabled and GrayEnhance.build_lut(gray) or nil,
        tone_enabled and ToneAdjust.build_lut(tone) or nil)
    local split = #PageSequence.segments(width, height, settings) == 2
    local id = table.concat({
        target_w .. "x" .. target_h,
        tostring(settings.fit_mode or "page"),
        split and "split" or "whole",
        tostring(settings.split_cut_percent or 50),
        ToneAdjust.fingerprint(gray, tone),
        crop_enabled and ("crop/" .. tostring(settings.auto_crop_threshold or 242)
            .. "/" .. tostring(settings.auto_crop_max_percent or 15)
            .. (settings.auto_crop_enhance_enabled == true and ("/enhanced-v1/"
                .. tostring(settings.auto_crop_border_width or 2) .. "/"
                .. tostring(settings.auto_crop_min_area or 4) .. "/"
                .. tostring(settings.auto_crop_padding_percent or 1)) or "")) or "no-crop",
    }, ":")
    return {
        id = id, target_width = target_w, target_height = target_h, lut = lut,
        crop = crop_enabled and AutoCrop.options(settings) or nil,
    }
end

local function close_buffer(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end

function PageProcessor.process_buffer(buffer, profile, dependencies)
    dependencies = dependencies or {}
    if not buffer then return nil, "image_buffer_missing" end
    profile = profile or {}
    local metadata = { memory_processed = true }
    if profile.native then
        metadata.processing_error = "native_image_processing_unavailable"
        return buffer, metadata
    end
    local enhancer = dependencies.gray_enhance or GrayEnhance
    if profile.lut and type(enhancer.apply_lut) == "function" then
        local ok, reason = enhancer.apply_lut(buffer, profile.lut, true, {
            dithering = profile.gray_dithering == true,
        })
        if ok == false then metadata.processing_error = reason end
    end
    local cropper = dependencies.auto_crop or AutoCrop
    if profile.crop and type(cropper.detect) == "function" then
        local called, crop, reason = pcall(cropper.detect, buffer, profile.crop)
        metadata.crop_checked = true
        metadata.crop_processed = true -- Legacy alias of crop_checked.
        metadata.crop = called and crop or nil
        metadata.crop_reason = called and (reason or (crop and "cropped" or "no_margin"))
            or "detection_failed"
    end
    if profile.page_number_crop and type(cropper.detect_page_number) == "function" then
        local called, page_number_crop = pcall(cropper.detect_page_number,
            buffer, profile.page_number_crop)
        if called then metadata.page_number_crop = page_number_crop end
    end
    if metadata.page_number_crop and type(cropper.remove_page_number) == "function" then
        local width = type(buffer.getWidth) == "function" and buffer:getWidth() or nil
        local height = type(buffer.getHeight) == "function" and buffer:getHeight() or nil
        local called, crop = pcall(cropper.remove_page_number,
            metadata.crop, metadata.page_number_crop, width, height)
        if called then metadata.crop = crop end
    end
    if type(buffer.getWidth) == "function" then metadata.width = buffer:getWidth() end
    if type(buffer.getHeight) == "function" then metadata.height = buffer:getHeight() end
    return buffer, metadata
end

function PageProcessor.process(source_path, part_path, profile, dependencies)
    dependencies = dependencies or {}
    local renderer = dependencies.renderer
    if not renderer then
        local ok, loaded = pcall(require, "ui/renderimage")
        if ok then renderer = loaded end
    end
    local enhancer = dependencies.gray_enhance or GrayEnhance
    local cropper = dependencies.auto_crop or AutoCrop
    local probe = dependencies.image_probe or require("webdavmanga.image_probe")
    if not renderer or type(renderer.renderImageFile) ~= "function" then
        return nil, "image_renderer_unavailable"
    end
    local decoded, buffer = pcall(renderer.renderImageFile, renderer,
        source_path, false, profile.target_width, profile.target_height)
    if not decoded or not buffer then return nil, "image_decode_failed" end
    if profile.lut then
        local applied, reason = enhancer.apply_lut(buffer, profile.lut, true)
        if applied == false then close_buffer(buffer); return nil, reason end
    end
    local crop, crop_checked, crop_reason
    if profile.crop and type(cropper.detect) == "function" then
        local ok, value, reason = pcall(cropper.detect, buffer, profile.crop)
        crop_checked = true
        crop = ok and value or nil
        crop_reason = ok and (reason or (crop and "cropped" or "no_margin"))
            or "detection_failed"
    end
    local wrote, result = pcall(buffer.writePNG, buffer, part_path)
    close_buffer(buffer)
    if not wrote or result == false then return nil, "png_write_failed" end
    local inspected, metadata, inspect_error = pcall(probe.inspect, part_path, "png")
    if not inspected or not metadata then
        return nil, inspect_error or "png_validation_failed"
    end
    metadata.format = "png"
    metadata.validated = true
    metadata.crop = crop
    metadata.crop_checked = crop_checked
    metadata.crop_processed = crop_checked -- Legacy alias of crop_checked.
    metadata.crop_reason = crop_reason
    return metadata
end

return PageProcessor
