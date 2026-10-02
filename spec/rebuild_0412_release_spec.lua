local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local root = assert(TEST_PLUGIN_ROOT)
local function read(path)
    local file = assert(io.open(root .. "/" .. path, "rb"))
    local body = file:read("*a"); file:close(); return body
end

package.preload.gettext = function() return function(text) return text end end
local metadata = assert(loadfile(root .. "/_meta.lua"))()
expect(metadata.version == "0.4.12", "release metadata must identify 0.4.12")
expect(read("main.lua"):match('local%s+VERSION%s*=%s*"([^"]+)"') == metadata.version,
    "runtime and installed metadata versions must agree")

local readme, notice = read("README.md"), read("NOTICE")
for _, marker in ipairs({
    "版本：0.4.12", "前 3 页", "第 4～20 页", "完整目录",
    "目录完成前禁用跳页", "重试流式加载 / 完整下载 / 返回",
    "明确确认", "保留周边 / 独立格 / 自由视图", "智能分格阅读重构", "最长边480", "并非任意 PDF 或 7Z",
}) do
    expect(readme:find(marker, 1, true), "release instructions must describe " .. marker)
end
for _, marker in ipairs({
    "version 0.4.12", "three validated opening pages", "pages 4 through 20",
    "full catalog", "jump navigation", "explicit confirmation",
    "retry streaming, explicit complete download, or return",
    "not universal pdf or 7z support",
}) do
    expect(notice:lower():find(marker, 1, true), "release notice must describe " .. marker)
end

print("rebuild_0412_release_spec: " .. checks .. " checks")
