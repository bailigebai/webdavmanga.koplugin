local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end
local AutoCrop = require("webdavmanga.auto_crop")
local PageProcessor = require("webdavmanga.page_processor")
local PreparedPages = require("webdavmanga.prepared_pages")
local Cache = require("webdavmanga.cache")
local Reader = require("webdavmanga.ui_reader")
local State = require("webdavmanga.state")
-- Catch a Reader gate that never forwards crop-only settings to either path.
for _, case in ipairs({
    {name="crop only", settings={auto_crop_enabled=true}, enabled=true},
    {name="gray only", settings={gray_enhance_enabled=true}, enabled=true},
    {name="tone only", settings={tone_adjust_enabled=true}, enabled=true},
    {name="all disabled", settings={}, enabled=false},
}) do
    local reader = setmetatable({reader_settings=case.settings, page_processor=PageProcessor,
        shell={get_content_size=function() return 320,480 end}}, {__index=Reader})
    local image = {width=320,height=480}
    local enabled, profile, processor = reader:_processing_enabled(),
        reader:_processing_profile(image), reader:_memory_processor(image)
    expect(enabled == case.enabled and (profile ~= nil) == case.enabled
        and (processor ~= nil) == case.enabled,
        case.name .. ": processing_enabled=" .. tostring(enabled)
            .. ", profile=" .. tostring(profile) .. ", memory_processor=" .. tostring(processor))
end
local budget = 160 * 160 + 4 * 160 * 20
local function buffer(w, h, pixel)
    local result = { calls = 0 }
    result.getWidth = function() return w end
    result.getHeight = function() return h end
    result.getPixel = function(self, x, y)
        self.calls = self.calls + 1
        -- Returning nil makes runaway implementations fail without a long scan.
        if self.calls > budget then return nil end
        if not (x >= 0 and x < w and y >= 0 and y < h) then error("samples stay in source") end
        return pixel(x, y)
    end
    result.writePNG = function() return true end
    result.free = function() end
    return result
end
local function rectangle(w, h, left, top, right, bottom, paper, ink, dust)
    return buffer(w, h, function(x, y)
        if x >= left and x < right and y >= top and y < bottom then return ink end
        if dust and (x * 19 + y * 31) % 137 == 0 then return 80 end
        return paper
    end)
end
local function precise(page, edges, options)
    local crop, reason = AutoCrop.detect(page, options or { max_percent = 30 })
    expect(crop ~= nil, "expected crop, got " .. tostring(reason))
    for i, value in ipairs({ crop.x, crop.y, crop.x + crop.w, crop.y + crop.h }) do
        expect(math.abs(value - edges[i]) <= 2, "refined edge " .. i .. " must be within two source pixels")
    end
    expect(page.calls <= budget, "bounded coarse and native refinement sampling")
    return crop
end
local function rejected(page, expected, options)
    local crop, reason = AutoCrop.detect(page, options or { max_percent = 30 })
    expect(crop == nil and reason == expected,
        "expected " .. expected .. ", got " .. tostring(reason) .. "/" .. tostring(crop))
    expect(page.calls <= budget, "refusals also obey sampling budget")
end

precise(rectangle(401, 603, 37, 53, 361, 551, 255, 20), {37, 53, 361, 551})
precise(rectangle(401, 603, 37, 53, 361, 551, 218, 35, true), {37, 53, 361, 551})
local large = rectangle(4000, 6000, 437, 853, 3671, 5417, 250, 20)
precise(large, {437, 853, 3671, 5417})
local huge = rectangle(12000, 18000, 1237, 2053, 10961, 16517, 250, 20)
precise(huge, {1237, 2053, 10961, 16517})
print(("Auto-crop samples: 4000x6000=%d, 12000x18000=%d, limit=%d")
    :format(large.calls, huge.calls, budget))
local corner = rectangle(400, 600, 37, 53, 361, 551, 245, 20)
local corner_pixel = corner.getPixel
corner.getPixel = function(self, x, y)
    if x < 2 and y < 2 then self.calls = self.calls + 1; return 0 end
    return corner_pixel(self, x, y)
end
precise(corner, {37, 53, 361, 551})
local shaded_corner = buffer(400, 600, function(x, y)
    if x < 20 and y < 30 then return 30 end
    if x >= 37 and x < 361 and y >= 53 and y < 551 then return 20 end
    return 245
end)
precise(shaded_corner, {0, 0, 361, 551})
rejected(buffer(320, 480, function(x, y)
    if x < 20 or y < 20 or x >= 300 or y >= 460 then return 30 end
    return 245
end), "dark_edge")
rejected(buffer(320, 480, function(x) return x < 160 and 255 or 40 end), "full_bleed")
rejected(buffer(320, 480, function() return 0 end), "dark_edge")
rejected(buffer(320, 480, function() return 255 end), "near_blank")
rejected(rectangle(100, 100, 0, 49, 100, 50, 255, 0), "near_blank")
rejected(rectangle(400, 600, 160, 80, 240, 520, 255, 0), "unsafe_box")
rejected(rectangle(400, 600, 125, 80, 361, 520, 255, 0), "unsafe_box", {max_percent = 99})
rejected(rectangle(160, 160, 1, 1, 159, 159, 255, 0), "no_margin")
local faint = rectangle(400, 600, 37, 53, 361, 551, 250, 225)
precise(faint, {37, 53, 361, 551}, { threshold = 250, max_percent = 30 })
faint.calls = 0
rejected(faint, "near_blank", { threshold = 210, max_percent = 30 })
-- Rec.601 gives green a luminance near 150; arithmetic RGB average gives 85.
precise(rectangle(400, 600, 37, 53, 361, 551, 190, {r=0,g=255,b=0}),
    {37, 53, 361, 551}, { threshold = 230, max_percent = 30 })
rejected(rectangle(400, 600, 37, 53, 361, 551, 190, {r=0,g=255,b=0}),
    "near_blank", { threshold = 210, max_percent = 30 })

local function crop_profile(threshold)
    return assert(PageProcessor.profile({auto_crop_enabled=true,
        auto_crop_threshold=threshold, auto_crop_max_percent=30},
        {width=320,height=480}, 320, 480))
end
local profile = crop_profile(250)
for _, accepted in ipairs({true, false}) do
    local page = accepted and rectangle(320, 480, 30, 40, 290, 440, 250, 225)
        or buffer(320, 480, function() return 255 end)
    local expected_reason = accepted and "cropped" or "near_blank"
    local memory_reader = setmetatable({reader_settings={auto_crop_enabled=true,
        auto_crop_threshold=250,auto_crop_max_percent=30},page_processor=PageProcessor,
        shell={get_content_size=function() return 320,480 end}}, {__index=Reader})
    local memory_processor = assert(memory_reader:_memory_processor({width=320,height=480}))
    local _, memory_metadata = memory_processor(page, {width=320,height=480})
    expect(memory_metadata.crop_checked == true and memory_metadata.crop_reason == expected_reason,
        "in-memory preprocessing records both accepted and rejected decisions")
    local detector_calls, decode_calls = 0, 0
    local original_detect = AutoCrop.detect
    AutoCrop.detect = function(source, options)
        detector_calls = detector_calls + 1
        return original_detect(source, options)
    end
    local files, stored = {}, {}
    local cache_options = {
        root="/cache/crop", limit_bytes=10000,
        md5=function(value) return (value:gsub("[^%w]", "_")) end,
        store={readSetting=function(_, key, default) return stored[key] or default end,
            saveSetting=function(_, key, value) stored[key]=value end, flush=function() end},
        fs={make_path=function() return true end,
            exists=function(path) return files[path] ~= nil end,
            size=function(path) return files[path] end,
            rename=function(source, target)
                if not files[source] then return nil end
                files[target],files[source] = files[source],nil
                return true
            end,
            remove=function(path) files[path]=nil; return true end,
            list=function() return {} end},
    }
    local cache = Cache:new(cache_options)
    cache:migrate(3)
    page.writePNG = function(_, path) files[path]=100; return true end
    local prepared = PreparedPages:new{
        cache=cache,
        loader={identity="server",
            request=function(_, _, _, callbacks) callbacks.on_ready("/raw.png", false, {}) end,
            prefetch=function(_, _, images, _, callback)
                callback(images[1], "/raw.png", false, {})
            end},
        async={run=function(work, done) done(true, work()); return {} end},
        page_processor={process=function(source, part, requested)
            page.calls = 0
            return PageProcessor.process(source, part, requested, {
                renderer={renderImageFile=function() decode_calls=decode_calls+1; return page end},
                image_probe={inspect=function() return {width=320,height=480,size=100} end},
            })
        end},
    }
    local image = {name="page.png",path="/page.png",width=320,height=480}
    local display_decodes, displays, display_errors = 0, 0, 0
    local reader_settings = {auto_crop_enabled=true,auto_crop_threshold=250,
        auto_crop_max_percent=30,prefetch_count=1,fit_mode="page"}
    local shell = {get_content_size=function() return 320,480 end,
        show_loading=function() return true end,
        show_page=function() displays=displays+1; return true end,
        show_error=function() display_errors=display_errors+1; return true end}
    local reader = Reader:new{
        loader=prepared.loader, prepared_pages=prepared, cache=cache, state=State:new(),
        settings={get_reader=function() return reader_settings end,
            get_connection=function() return {} end},
        progress={save=function() return true end}, ui={}, open_chapter=function() end,
        render_image={renderImageFile=function(_, path)
            expect(path:match("^/cache/crop/"), "Reader decodes the published prepared PNG")
            display_decodes=display_decodes+1
            local decoded = buffer(320,480,function() return 255 end)
            decoded.viewport=function(_, _, _, w, h) return buffer(w,h,function() return 255 end) end
            return decoded
        end},
    }
    -- Enter the live request/prefetch boundary with an already selected chapter.
    reader.context = {manga={name="manga"},chapter={name="chapter"},chapter_index={
        count=function() return 1 end, get=function() return image end,
        window=function() return {image} end}}
    reader.generation=reader.state:begin_chapter(reader.context)
    reader.reader_settings,reader.shell,reader.fit_mode=reader_settings,shell,"page"
    reader:_prefetch(1)
    expect(detector_calls == 1 and decode_calls == 1 and display_decodes == 0,
        "Reader preload routes crop-only pages through PageProcessor once")
    -- A fresh cache object reads the persisted record, not just job metadata.
    prepared.cache = Cache:new(cache_options)
    for visit=1,2 do
        expect(reader:request_page(1, "whole"), "real Reader request must display prepared page")
        local metadata = reader.page_metadata or {}
        expect(metadata.crop_checked == true and metadata.crop_reason == expected_reason,
            "published cache retains acceptance/refusal metadata through _render_ready")
        expect((reader.page_crop ~= nil) == accepted and displays == visit * 2 - 1,
            "real display reuses the persisted crop decision")
        local current_buffer = reader.page_buffer
        expect(reader:_display_segment("whole", false) and reader.page_buffer == current_buffer,
            "redrawing the current page retains its decoded buffer")
        expect(display_decodes == visit and detector_calls == 1 and decode_calls == 1,
            "each file request decodes one PNG; redraw never decodes or analyzes")
    end
    expect(detector_calls == 1 and decode_calls == 1 and displays == 4 and display_errors == 0,
        "preload plus two real displays and redraws preprocess and analyze once")
    reader_settings.auto_crop_threshold=210
    local changed_profile = reader:_processing_profile(image)
    expect(prepared:cache_key(image, profile) ~= prepared:cache_key(image, changed_profile),
        "threshold changes invalidate the prepared-page key")
    for visit=1,2 do
        expect(reader:request_page(1, "whole"), "new threshold must still display")
        local metadata = reader.page_metadata or {}
        expect(metadata.crop_checked == true and metadata.crop_reason == "near_blank"
            and reader.page_crop == nil, "new threshold changes faint-ink crop to a cached refusal")
    end
    expect(detector_calls == 2 and decode_calls == 2 and display_decodes == 4
        and displays == 6 and display_errors == 0,
        "changed threshold recomputes once, then reuses its own cache entry")
    AutoCrop.detect = original_detect
end
local compatibility_reader = setmetatable({reader_settings={auto_crop_enabled=true},
    _silent=function(_, _, callback) return callback() end}, {__index=Reader})
local original_detect = AutoCrop.detect
local compatibility_calls = 0
AutoCrop.detect = function() compatibility_calls=compatibility_calls+1; return nil, "near_blank" end
compatibility_reader:_detect_crop({}, {crop_processed=true})
compatibility_reader:_detect_crop({}, {crop_checked=true, crop_processed=false})
expect(compatibility_calls == 0, "legacy refusal works, and crop_checked is authoritative")
compatibility_reader:_detect_crop({}, {crop_checked=false, crop_processed=true})
compatibility_reader:_detect_crop({}, {})
expect(compatibility_calls == 2, "unchecked metadata must not suppress needed analysis")
AutoCrop.detect = original_detect
local _, failed = PageProcessor.process_buffer(buffer(20, 30, function() return 255 end), profile,
    {auto_crop={detect=function() error("decoder unavailable") end}})
expect(failed.crop_checked == true and failed.crop_processed == true
    and failed.crop_reason == "detection_failed" and failed.crop == nil,
    "failed detection is a cached refusal, not a retry loop")
print(("rebuild_0405_auto_crop_edges_spec: %d checks passed"):format(checks))
