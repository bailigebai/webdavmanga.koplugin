local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Probe = require("webdavmanga.image_probe")

for _, case in ipairs({
    { "baseline.jpg", "jpg", "jpeg" },
    { "progressive.jpeg", "jpeg", "jpeg" },
    { "grayscale.png", "png", "png" },
    { "lossy.webp", "webp", "webp" },
    { "lossless.WEBP", "WEBP", "webp" },
    { "static.gif", "gif", "gif" },
    { "sample.tif", "tif", "tiff" },
    { "sample.TIFF", "TIFF", "tiff" },
    { "vector.svg", "svg", "svg" },
}) do
    local info, err = Probe.inspect(
        "webdavmanga.koplugin/resources/format_samples/" .. case[1], case[2])
    expect(info and not err and info.format == case[3]
        and info.width == 8 and info.height == 12,
        case[1] .. " should expose its hand-checked format and dimensions")
end

local function be16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function be32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256)
end

local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

local function le32(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256)
end

local function tiff_fixture(endian, width, height)
    local little = endian == "II"
    local u16 = little and le16 or be16
    local u32 = little and le32 or be32
    local magic = little and string.char(0x2A, 0) or string.char(0, 0x2A)
    local function entry(tag, value)
        return u16(tag) .. u16(4) .. u32(1) .. u32(value)
    end
    return endian .. magic .. u32(8) .. u16(2)
        .. entry(256, width) .. entry(257, height) .. u32(0)
end

local png_signature
local function png_fixture(width, height, bit_depth, color_type,
        compression, filter, interlace, crc)
    return png_signature .. be32(13) .. "IHDR"
        .. be32(width) .. be32(height)
        .. string.char(bit_depth, color_type, compression, filter, interlace)
        .. be32(crc)
end

local jpeg = string.char(0xFF, 0xD8, 0xFF, 0xC0)
    .. be16(11) .. string.char(8) .. be16(9) .. be16(7)
    .. string.char(1, 1, 0x11, 0) .. string.char(0xFF, 0xD9)
png_signature = string.char(137) .. "PNG\r\n" .. string.char(26) .. "\n"

local vp8x_payload = string.char(0, 0, 0, 0, 7, 0, 0, 11, 0, 0)

local fixtures = {
    empty = "",
    truncated_png = png_signature .. be32(13) .. "IHDR" .. be32(8) .. be32(12),
    html = "<!DOCTYPE html><html><body>Sign in</body></html>",
    jpeg = jpeg,
    svg_xml = string.char(0xEF, 0xBB, 0xBF)
        .. "  \r\n<?xml version=\"1.0\"?>\n"
        .. "<svg viewBox=\"0 0 19 23\" xmlns=\"http://www.w3.org/2000/svg\"></svg>",
    tiff_le = tiff_fixture("II", 17, 29),
    tiff_be = tiff_fixture("MM", 31, 37),
    jpeg_bad_components = jpeg:sub(1, 11) .. string.char(2) .. jpeg:sub(13),
    gif_truncated_lsd = "GIF89a" .. le16(8) .. le16(12),
    webp_bad_riff_size = "RIFF" .. le32(10) .. "WEBPVP8X" .. le32(10)
        .. vp8x_payload,
    webp_bad_vp8x_size = "RIFF" .. le32(22) .. "WEBPVP8X" .. le32(9)
        .. vp8x_payload,
    webp_vp8x = "RIFF" .. le32(22) .. "WEBPVP8X" .. le32(10)
        .. vp8x_payload,
    webp_exact_limit_truncated = ("RIFF" .. le32(69992)
        .. "WEBPVP8X" .. le32(10) .. vp8x_payload)
        .. string.rep("\0", 65536 - 30),
    webp_no_seek_ambiguous = ("RIFF" .. le32(65528)
        .. "WEBPVP8X" .. le32(10) .. vp8x_payload)
        .. string.rep("\0", 65536 - 30),
    webp_failed_seek_shift = "XRIFF" .. le32(22)
        .. "WEBPVP8X" .. le32(10) .. vp8x_payload,
    webp_no_seek_short = "RIFF" .. le32(22)
        .. "WEBPVP8X" .. le32(10) .. vp8x_payload,
    webp_file_size_exact = "RIFF" .. le32(65528)
        .. "WEBPVP8 " .. le32(65516)
        .. string.char(0, 0, 0, 0x9D, 0x01, 0x2A, 8, 0, 12, 0)
        .. string.rep("\0", 65516 - 10),
    tiff_missing_next_ifd = tiff_fixture("II", 17, 29):sub(1, -5),
    png_bad_compression = png_fixture(1, 1, 8, 6, 1, 0, 0, 0x1ED7AEBE),
    png_bad_bit_depth = png_fixture(1, 1, 3, 2, 0, 0, 0, 0xE7A762CF),
    png_bad_crc = png_fixture(1, 1, 8, 6, 0, 0, 0, 0x1F15C488),
    png_oversize = png_fixture(0x80000000, 1, 8, 6, 0, 0, 0, 0x50BD8AA0),
    svg_infinite = "<svg width=\"1e309\" height=\"10\"></svg>",
    svg_unsafe = "<svg width=\"9007199254740992\" height=\"10\"></svg>",
    svg_evil_prefix = "<evil:svg width=\"8\" height=\"12\"></evil:svg>",
    svg_duplicate_prefix = "<art:svg xmlns:art=\"http://www.w3.org/2000/svg\""
        .. " xmlns:art=\"https://evil.example/svg\""
        .. " width=\"8\" height=\"12\"></art:svg>",
    svg_bound_prefix = "<art:svg xmlns:art=\"http://www.w3.org/2000/svg\""
        .. " width=\"8\" height=\"12\"></art:svg>",
}

local largest_read = 0
local seek_count = 0
local read_counts = {}
local function fixture_open(path, mode)
    expect(mode == "rb", "probe fixtures should be opened read-only in binary mode")
    local content = fixtures[path]
    if content == nil then return nil, "missing fixture" end
    local closed = false
    local position = 0
    local handle = {
        read = function(_self, count)
            read_counts[path] = (read_counts[path] or 0) + 1
            largest_read = math.max(largest_read, tonumber(count) or 0)
            local result = content:sub(position + 1, position + count)
            position = position + #result
            return result
        end,
        close = function() closed = true; return true end,
        was_closed = function() return closed end,
    }
    if path == "webp_failed_seek_shift" then
        handle.seek = function(_self, whence)
            seek_count = seek_count + 1
            if whence == "end" then
                position = 1
                return nil, "injected end-seek failure"
            end
            return nil, "unexpected seek"
        end
    elseif path ~= "webp_no_seek_ambiguous" and path ~= "webp_no_seek_short"
        and path ~= "webp_file_size_exact" then
        handle.seek = function(_self, whence, offset)
            seek_count = seek_count + 1
            offset = tonumber(offset) or 0
            if whence == "set" then position = offset
            elseif whence == "cur" then position = position + offset
            elseif whence == "end" then position = #content + offset
            else return nil, "invalid whence" end
            return position
        end
    end
    return handle
end

local deps = { open_file = fixture_open }
for _, case in ipairs({
    { "empty", "png" }, { "truncated_png", "png" }, { "html", "svg" },
    { "jpeg_bad_components", "jpg" }, { "gif_truncated_lsd", "gif" },
    { "webp_bad_riff_size", "webp" }, { "webp_bad_vp8x_size", "webp" },
    { "webp_exact_limit_truncated", "webp" },
    { "webp_no_seek_ambiguous", "webp" },
    { "webp_failed_seek_shift", "webp" },
    { "tiff_missing_next_ifd", "tif" },
    { "png_bad_compression", "png" }, { "png_bad_bit_depth", "png" },
    { "png_bad_crc", "png" }, { "png_oversize", "png" },
    { "svg_infinite", "svg" },
    { "svg_unsafe", "svg" }, { "svg_evil_prefix", "svg" },
    { "svg_duplicate_prefix", "svg" },
}) do
    local name, extension = case[1], case[2]
    local info, err = Probe.inspect(name, extension, deps)
    expect(info == nil and err == "unknown_image_signature",
        name .. " should be rejected as an unknown image signature")
end

local mismatch, mismatch_err = Probe.inspect("jpeg", "png", deps)
expect(mismatch == nil and mismatch_err == "extension_signature_mismatch",
    "JPEG bytes named PNG should be rejected")

local svg = assert(Probe.inspect("svg_xml", "SVG", deps))
expect(svg.format == "svg" and svg.width == 19 and svg.height == 23,
    "SVG should allow BOM, whitespace, an XML declaration, and viewBox dimensions")
local bound_svg = assert(Probe.inspect("svg_bound_prefix", "svg", deps))
expect(bound_svg.width == 8 and bound_svg.height == 12,
    "a prefixed SVG root should require the official namespace binding")
local extended_webp = assert(Probe.inspect("webp_vp8x", "webp", deps))
expect(extended_webp.width == 8 and extended_webp.height == 12,
    "VP8X should use its fixed ten-byte canvas header layout")
local no_seek_short = assert(Probe.inspect("webp_no_seek_short", "webp", deps))
expect(no_seek_short.width == 8 and no_seek_short.height == 12,
    "a no-seek short file should retain EOF-size compatibility")
local file_size_calls = 0
local file_size_webp = assert(Probe.inspect("webp_file_size_exact", "webp", {
    open_file = fixture_open,
    file_size = function(path)
        file_size_calls = file_size_calls + 1
        return #fixtures[path]
    end,
}))
expect(file_size_calls == 1 and file_size_webp.width == 8
    and file_size_webp.height == 12,
    "an injected exact file-size provider should work without seek or extra reads")

local little = assert(Probe.inspect("tiff_le", "tif", deps))
local big = assert(Probe.inspect("tiff_be", "TIFF", deps))
expect(little.width == 17 and little.height == 29
    and big.width == 31 and big.height == 37,
    "both TIFF byte orders should expose width and height")

expect(Probe.matches_extension("jpeg", "JPG")
    and Probe.matches_extension("jpeg", ".jpeg")
    and Probe.matches_extension("tiff", "TIF")
    and Probe.matches_extension("tiff", ".tiff")
    and not Probe.matches_extension("png", "jpg"),
    "extension matching should be case-insensitive and allow only documented aliases")
expect(Probe.valid_metadata("jpeg", 65535, 1, "jpg")
    and not Probe.valid_metadata("jpeg", 65536, 1, "jpg")
    and not Probe.valid_metadata("jpeg", 8, 12, "png"),
    "shared JPEG metadata validation should enforce its bound and extension aliases")
expect(Probe.valid_metadata("png", 2147483647, 1, "png")
    and not Probe.valid_metadata("png", 2147483648, 1, "png")
    and Probe.valid_metadata("webp", 16777216, 1, "webp")
    and not Probe.valid_metadata("webp", 16777217, 1, "webp"),
    "shared raster metadata validation should enforce format-specific bounds")
expect(Probe.valid_metadata("svg", 8.5, 12.25, "svg")
    and not Probe.valid_metadata("svg", 9007199254740992, 1, "svg")
    and not Probe.valid_metadata("svg", 0 / 0, 1, "svg")
    and not Probe.valid_metadata("JPEG", 8, 12, "jpg"),
    "shared SVG metadata validation should allow safe finite fractions only")
expect(largest_read <= 65536, "header probing must remain bounded to 64 KiB")
expect(seek_count > 0, "probe fixtures should expose exact size without extra reads")
expect(read_counts.webp_failed_seek_shift == nil,
    "a failed end-seek should reject before reading from an unknown cursor")

print(("image_probe_spec: %d checks"):format(checks))
