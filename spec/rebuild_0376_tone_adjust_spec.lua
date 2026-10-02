local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local ToneAdjust = require("webdavmanga.tone_adjust")
local GrayEnhance = require("webdavmanga.gray_enhance")

local original = ToneAdjust.find("original", {})
expect(original and original.brightness == 0 and original.contrast == 100,
    "the immutable original tone preset must be neutral")

local identity = ToneAdjust.build_lut(original)
expect(#identity == 255 and identity[0] == 0 and identity[64] == 64
    and identity[128] == 128 and identity[255] == 255,
    "neutral tone must build a literal identity LUT")

local brighter = ToneAdjust.build_lut{ brightness = 10, contrast = 100 }
expect(brighter[0] == 26 and brighter[128] == 154 and brighter[255] == 255,
    "brightness must be folded into the LUT and clamped")

local contrast = ToneAdjust.build_lut{ brightness = 0, contrast = 150 }
expect(contrast[64] == 32 and contrast[128] == 128 and contrast[192] == 224,
    "contrast must pivot around the grayscale midpoint")

local gray = GrayEnhance.build_lut{
    id = "gray", black = 40, white = 238, gamma = 1.20,
}
local combined = ToneAdjust.combine_lut(gray, brighter)
expect(combined[40] == 26 and combined[238] == 255,
    "gray and tone transforms must compose into one lookup")
expect(combined[128] == 122,
    "the combined middle tone must match the hand-derived mapping")

local custom, custom_error = ToneAdjust.normalize_custom({
    id = "custom-1", name = "夜间", brightness = -12, contrast = 135,
})
expect(custom_error == nil and custom and custom.id == "custom-1"
    and custom.brightness == -12 and custom.contrast == 135,
    "valid custom presets must retain bounded integer values")

for _, invalid in ipairs({
    { id = "bad", name = "无效", brightness = 0, contrast = 100 },
    { id = "custom-1", name = "", brightness = 0, contrast = 100 },
    { id = "custom-1", name = "无效", brightness = -101, contrast = 100 },
    { id = "custom-1", name = "无效", brightness = 0, contrast = 201 },
    { id = "custom-1", name = "无效", brightness = 0.5, contrast = 100 },
}) do
    local value, reason = ToneAdjust.normalize_custom(invalid)
    expect(value == nil and reason == "invalid_tone_preset",
        "malformed custom tone presets must be rejected")
end

local presets = ToneAdjust.all_presets({ custom, custom, { name = "broken" } })
expect(#presets == 2 and presets[1].id == "original" and presets[2].id == "custom-1",
    "preset lists must sanitize and deduplicate custom entries")
expect(ToneAdjust.next_custom_id({ custom }) == "custom-2",
    "new custom preset ids must not replace existing presets")

local first = ToneAdjust.fingerprint(gray, custom)
local same = ToneAdjust.fingerprint(gray, {
    id = "renamed", name = "另一个名称", brightness = -12, contrast = 135,
})
local changed = ToneAdjust.fingerprint(gray, {
    id = "custom-1", name = "夜间", brightness = -11, contrast = 135,
})
expect(first == same and first ~= changed,
    "cache fingerprints must follow pixel parameters rather than display names")

local applied, apply_error = GrayEnhance.apply_lut(nil, identity, true)
expect(applied == false and apply_error ~= nil,
    "missing native buffers must fail without throwing")

print(("rebuild_0376_tone_adjust_spec: %d checks"):format(checks))
