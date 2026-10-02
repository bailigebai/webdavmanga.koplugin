local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local PageProcessor = require("webdavmanga.page_processor")

local page_w, page_h = PageProcessor.target_size(3000, 4000, {
    fit_mode = "page", split_enabled = false,
}, 1272, 1696)
expect(page_w == 1272 and page_h == 1696,
    "full-page scaling must use the real KPW6 content bounds without stretching")

local width_w, width_h = PageProcessor.target_size(2000, 6000, {
    fit_mode = "width", split_enabled = false,
}, 1272, 1696)
expect(width_w == 1199 and width_h == 3597,
    "fit-width scaling must retain its ratio under the two-screen pixel ceiling")

local split_w, split_h = PageProcessor.target_size(3000, 2000, {
    fit_mode = "page", split_enabled = true, split_min_ratio = 1.20,
    split_max_ratio = 2.20, split_cut_percent = 50,
}, 1272, 1696)
expect(split_w == 2544 and split_h == 1696,
    "a split spread must retain one screen of resolution for each half")

expect(PageProcessor.profile({
    gray_enhance_enabled = false, tone_adjust_enabled = false,
}, { width = 3000, height = 4000 }, 1272, 1696) == nil,
    "two disabled switches must bypass prepared-page processing")

local profile = PageProcessor.profile({
    fit_mode = "page", split_enabled = false,
    gray_enhance_enabled = true, gray_enhance_preset = "clear",
    gray_enhance_custom_presets = {},
    tone_adjust_enabled = true, tone_adjust_preset = "custom-1",
    tone_adjust_custom_presets = {{
        id = "custom-1", name = "提亮", brightness = 10, contrast = 120,
    }},
}, { width = 3000, height = 4000 }, 1272, 1696)
expect(profile and profile.target_width == 1272 and profile.target_height == 1696,
    "active processing must snapshot target dimensions")
expect(type(profile.id) == "string" and profile.id:find("1272x1696", 1, true),
    "the derivative id must include the actual render size")
expect(profile.lut[0] == 0 and profile.lut[128] == 115 and profile.lut[255] == 255,
    "the profile must carry the already-composed LUT")

local writes, frees, probes = {}, 0, 0
local fake_buffer = {
    getWidth = function() return 1272 end,
    getHeight = function() return 1696 end,
    writePNG = function(_, path) writes[#writes + 1] = path; return true end,
    free = function() frees = frees + 1 end,
}
local metadata, process_error = PageProcessor.process("/raw.jpg", "/part.png", profile, {
    renderer = {
        renderImageFile = function(_, path, frames, width, height)
            expect(path == "/raw.jpg" and frames == false,
                "the processor must decode the raw page once")
            expect(width == 1272 and height == 1696,
                "the native renderer must receive the bounded dimensions")
            return fake_buffer
        end,
    },
    gray_enhance = {
        apply_lut = function(buffer, lut, disposable)
            expect(buffer == fake_buffer and lut == profile.lut and disposable == true,
                "temporary render buffers must use the disposable one-pass LUT path")
            return true
        end,
    },
    image_probe = {
        inspect = function(path, format)
            probes = probes + 1
            expect(path == "/part.png" and format == "png",
                "the completed derivative must be validated as PNG")
            return { format = "png", width = 1272, height = 1696, size = 1234 }
        end,
    },
})
expect(process_error == nil and metadata and metadata.format == "png",
    "successful processing must return validated PNG metadata")
expect(#writes == 1 and frees == 1 and probes == 1,
    "successful processing must write once, validate once and free once")

local failed, failed_error = PageProcessor.process("/raw.jpg", "/bad.png", profile, {
    renderer = { renderImageFile = function() return fake_buffer end },
    gray_enhance = { apply_lut = function() return false, "lut_failed" end },
    image_probe = { inspect = function() error("failed output must not be probed") end },
})
expect(failed == nil and failed_error == "lut_failed" and frees == 2,
    "processing errors must free the temporary buffer and return a typed reason")

print(("rebuild_0376_page_processor_spec: %d checks"):format(checks))
