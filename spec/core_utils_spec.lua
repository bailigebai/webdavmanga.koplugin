local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local NaturalSort = require("webdavmanga.natural_sort")
local Formats = require("webdavmanga.image_formats")
local Path = require("webdavmanga.path")
local Errors = require("webdavmanga.errors")

local ordered = NaturalSort.sort({ "10.jpg", "2.jpg", "01.jpg", "1.jpg" })
expect(table.concat(ordered, "|") == "1.jpg|01.jpg|2.jpg|10.jpg",
    "numbers should use natural order and shorter equal numbers first")

local items = {
    { name = "第10话" },
    { name = "第2话" },
    { name = "第1话" },
}
NaturalSort.sort(items, function(item) return item.name end)
expect(items[1].name == "第1话" and items[2].name == "第2话"
    and items[3].name == "第10话", "table items should sort by selected name")

local mixed = NaturalSort.sort({ "pageA.jpg", "Pagea.jpg", "pageB.jpg" })
expect(table.concat(mixed, "|") == "Pagea.jpg|pageA.jpg|pageB.jpg",
    "case-insensitive ties should have deterministic original-text order")

for _, name in ipairs({
    "1.jpg", "1.JPEG", "1.png", "1.WEBP", "1.gif",
}) do
    expect(Formats.is_supported(name), name .. " should be supported")
end
expect(table.concat(Formats.list(), ",") == "jpg,jpeg,png,webp,gif,tif,tiff,svg",
    "the public format order must match diagnostics")
for _, name in ipairs({ "a.JPG", "b.jpeg", "c.PNG", "d.webp", "e.GIF", "f.tif", "g.TIFF", "h.svg" }) do
    expect(Formats.is_supported(name), "approved format should be discovered: " .. name)
end
for _, name in ipairs({ "a.bmp", "b.avif", "c.heic", "d.cbz", "no-extension" }) do
    expect(not Formats.is_supported(name), "unsupported format should be hidden: " .. name)
end
expect(not Formats.is_supported("archive.cbz"), "CBZ should not be treated as an image")
expect(not Formats.is_supported("no-extension"), "extensionless file should be rejected")
expect(Formats.extension("a.photo.JPEG") == "jpeg", "last extension should be lowercased")

expect(Path.normalize_remote("\\漫画\\海贼王//") == "/漫画/海贼王",
    "remote separators and duplicate slashes should normalize")
expect(Path.join_remote("/漫画/", "/海 贼王/") == "/漫画/海 贼王",
    "remote path should join with one slash")
expect(Path.join_remote("", "海贼王") == "/海贼王", "empty base should produce root path")
expect(Path.normalize_remote("/root/./manga/../outside") == "/root/outside",
    "remote dot segments should be resolved before root checks or URL construction")
expect(Path.join_remote("/root/manga", "..") == "/root",
    "joining a parent segment should canonicalize instead of forwarding traversal syntax")
expect(Path.is_within_remote("/root/manga", "/root"),
    "a canonical child should remain inside its WebDAV root")
expect(not Path.is_within_remote("/root/..", "/root")
    and not Path.is_within_remote("/rootish", "/root"),
    "root confinement should reject canonical escapes and prefix lookalikes")

local encoded = {
    ["漫画"] = "%E6%BC%AB%E7%94%BB",
    ["A #1"] = "A%20%231",
}
local encode_calls = {}
local function encode_segment(segment)
    encode_calls[#encode_calls + 1] = segment
    return encoded[segment] or segment
end
expect(Path.build_url("https://nas/dav/", "/漫画/A #1", encode_segment)
    == "https://nas/dav/%E6%BC%AB%E7%94%BB/A%20%231", "segments should encode separately")
expect(table.concat(encode_calls, "|") == "漫画|A #1", "slash must not be encoded")
expect(Path.build_url("https://nas/dav", "", encode_segment) == "https://nas/dav/",
    "empty remote path should address collection root")
expect(Path.build_url("https://nas/dav", "/root/../outside", encode_segment)
    == "https://nas/dav/outside",
    "WebDAV URLs must never forward dot-segment traversal")

expect(Errors.message(Errors.http(401)):find("用户名或密码", 1, true),
    "401 should explain credentials")
expect(Errors.message(Errors.http(403)):find("权限", 1, true),
    "403 should explain permissions")
expect(Errors.message(Errors.http(404)):find("不存在", 1, true),
    "404 should explain missing path")
expect(Errors.message(Errors.http(503, "secret body")):find("503", 1, true),
    "server failures should include status code")
expect(not Errors.message(Errors.http(503, "secret body")):find("secret body", 1, true),
    "response detail must not be exposed")
expect(Errors.message(Errors.transport("password=hunter2")):find("网络", 1, true),
    "transport failures should explain network")
expect(not Errors.message(Errors.transport("password=hunter2")):find("hunter2", 1, true),
    "transport detail must not be exposed")
expect(Errors.message(Errors.transport("TLS certificate rejected")):find("证书", 1, true),
    "TLS failures should explain certificate or device time")
expect(Errors.message(Errors.decode("raw XML")):find("目录响应", 1, true),
    "decode failures should explain incompatibility")
expect(Errors.message(Errors.storage("page_exceeds_cache_limit")):find("大于缓存上限", 1, true),
    "an oversized page should tell the user to raise the cache limit")

local SafeCallback = require("webdavmanga.safe_callback")
local safe_ui = {
    show_info = function(self, message) self.message = message end,
}
local protected_result = SafeCallback.wrap(safe_ui, "test callback", function()
    error("password=hunter2")
end, false)()
expect(protected_result == false and safe_ui.message:find("test callback失败", 1, true)
    and safe_ui.message:find("错误编号：", 1, true),
    "top-level UI callback guard should swallow failures and show a safe traceable message")
expect(not safe_ui.message:find("hunter2", 1, true),
    "top-level callback failures must not expose internal details")
local first, second = SafeCallback.wrap(safe_ui, "multi return", function()
    return "one", "two"
end)()
expect(first == "one" and second == "two", "callback guard should preserve successful return values")

print(("core_utils_spec: %d checks"):format(checks))
