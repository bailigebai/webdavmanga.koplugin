local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")
local Gray = require("webdavmanga.gray_enhance")
local original_find, original_apply, original_gray = Gray.first_image_in_directory, Gray.apply_lut, Gray.apply
Gray.first_image_in_directory = function() return "/fixture/001.png" end
Gray.apply_lut = function() return true end
Gray.apply = function() return true end
local checks, failures = 0, {}
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local function test(name, body)
    local ok, err = pcall(body)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local function fixture(kind)
    local f = {buffers = {}, views = {}, violations = {}}
    local function buffer()
        local b = {frees = 0, visible = false}
        function b:free()
            if self.visible then f.violations[#f.violations + 1] = "freed visible image" end
            self.frees = self.frees + 1
            if self.frees > 1 then f.violations[#f.violations + 1] = "double free" end
        end
        f.buffers[#f.buffers + 1] = b
        return b
    end
    local values = {}
    local settings = Settings:new{store = {
        readSetting = function(_, key, fallback) return values[key] or fallback end,
        saveSetting = function(_, key, value) values[key] = value end,
        flush = function() return true end,
    }}
    assert(settings:set_reader{gray_enhance_enabled = true, gray_enhance_sample_path = "/fixture",
        tone_adjust_enabled = true, tone_adjust_sample_path = "/fixture",
        kopt_filter_enabled = true, kopt_sample_path = "/fixture"})
    local adapter = {show_info = function() end}
    local function show(_, model)
        if f.reject == "throw" then error("fixture view construction failed") end
        if f.reject then return false end
        local view = {model = model, closed = false}
        model.before_buffer.visible, model.after_buffer.visible = true, true
        function view.close()
            if view.closed then return true end
            view.closed = true
            model.before_buffer.visible, model.after_buffer.visible = false, false
            model.on_close()
            return true
        end
        f.views[#f.views + 1] = view
        return view
    end
    adapter.show_tone_preview, adapter.show_kopt_preview, adapter.show_gray_preview = show, show, show
    function adapter:close_all()
        for _, view in ipairs(f.views) do view.close() end
        return true
    end
    f.controller = UiSettings:new{settings = settings, ui = adapter, cache = {}, async = {},
        client_factory = function() return {} end,
        sample_image_finder = function() return "/fixture/001.png" end,
        native_image_filter = {process = function() return buffer() end},
        render_image = {renderImageFile = function() return buffer() end}}
    function f:open()
        if kind == "kopt" then return self.controller:show_kopt_preview() end
        if kind == "gray" then return self.controller:_show_gray_preview() end
        return self.controller:_show_tone_preview()
    end
    function f:finish()
        self.controller:close_all()
        expect(#self.violations == 0, table.concat(self.violations, ", "))
        for _, b in ipairs(self.buffers) do expect(b.frees == 1, "each image freed once") end
    end
    return f
end
for _, kind in ipairs({"gray", "tone", "kopt"}) do
    test(kind .. " replacement closes old view before freeing", function()
        local f = fixture(kind)
        expect(f:open(), "open first preview")
        expect(f:open(), "open second preview")
        expect(f.views[1].closed, "old preview remains on screen")
        expect(f.views[1].model.before_buffer.frees == 1, "old image released")
        f.views[1].model.on_close()
        expect(f.views[2].model.before_buffer.frees == 0, "late old close freed new preview")
        f:finish()
    end)
    test(kind .. " close all hides before freeing", function()
        local f = fixture(kind)
        expect(f:open(), "open preview")
        f:finish()
    end)
    for _, rejection in ipairs({"throw", "reject"}) do
        test(kind .. " failed view releases both images: " .. rejection, function()
            local f = fixture(kind)
            f.reject = rejection
            local called, result = pcall(f.open, f)
            expect(called and result == false, "view failure must return false without escaping")
            for _, b in ipairs(f.buffers) do expect(b.frees == 1, "failed view leaked image") end
            f:finish()
        end)
    end
    test(kind .. " repeated previews and stale close events", function()
        local f = fixture(kind)
        for i = 1, 100 do
            expect(f:open(), "repeated preview opens")
            if i > 1 then f.views[i - 1].model.on_close() end
            expect(f.views[i].model.before_buffer.frees == 0, "active image stays alive")
        end
        f:finish()
    end)
    test(kind .. " failed close preserves visible buffer and blocks replacement", function()
        local f = fixture(kind)
        expect(f:open(), "open preview")
        local view, count = f.views[1], #f.buffers
        local close = view.close
        view.close = function() return false end
        expect(f:open() == false, "failed close blocks replacement")
        expect(#f.buffers == count and view.model.before_buffer.frees == 0,
            "cannot free visible image or decode another while close fails")
        view.close = close
        f:finish()
    end)
end
Gray.first_image_in_directory, Gray.apply_lut, Gray.apply = original_find, original_apply, original_gray
assert(#failures == 0, table.concat(failures, "\n"))
print(("settings_preview_lifecycle_spec: %d checks"):format(checks))
