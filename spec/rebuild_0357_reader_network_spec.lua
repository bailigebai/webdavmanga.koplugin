local Settings = require("webdavmanga.settings")
local UiSettings = require("webdavmanga.ui_settings")
local Reader = require("webdavmanga.ui_reader")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local store = { values = {}, flushes = 0 }
function store:readSetting(key, fallback)
    local value = self.values[key]
    return value == nil and fallback or value
end
function store:saveSetting(key, value) self.values[key] = value end
function store:flush() self.flushes = self.flushes + 1; return true end

local settings = Settings:new{ store = store }
local opened_section, saved_values
local settings_ui = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    async = {},
    cache = {},
    ui = {
        show_reader = function(_self, model)
            opened_section = model.initial_section
            local values = {}
            for key, value in pairs(model.values or {}) do values[key] = value end
            values.range_streaming_enabled = false
            values.image_prefetch_enabled = true
            values.prefetch_first_pages = 10
            values.prefetch_near_count = 4
            values.prefetch_far_count = 2
            values.prefetch_concurrency = 3
            model.on_save(values)
        end,
        show_info = function() end,
    },
    on_reader_saved = function(values) saved_values = values end,
}
expect(settings_ui:show_reader("network") == nil,
    "settings adapter should be invoked")
expect(opened_section == "network",
    "reader settings must pass the requested initial section")
expect(saved_values and saved_values.prefetch_concurrency == 3
    and saved_values.prefetch_first_pages == 10
    and saved_values.range_streaming_enabled == false,
    "reader network settings must use the existing save callback")

local controls
local network_opens = 0
local reader = Reader:new{
    loader = {}, progress = {}, state = {}, settings = settings, cache = {},
    open_chapter = function() end,
    ui = { show_controls = function(_self, model) controls = model; return true end },
    show_network_settings = function() network_opens = network_opens + 1; return true end,
}
reader.reader_settings = settings:get_reader()
reader.context = { chapter_index = {
    count = function() return 1 end,
    get = function() return { path = "/page.jpg" } end,
} }
expect(reader:toggle_controls("root") == true,
    "reader settings root should open")
local network_action
for _, action in ipairs(controls.actions or {}) do
    if action.text == "网络加载" then network_action = action; break end
end
expect(type(network_action) == "table" and type(network_action.callback) == "function",
    "reader settings root must expose network loading")
expect(network_action.callback() == true and network_opens == 1,
    "network loading action must call the injected settings entry")

print(("rebuild_0357_reader_network_spec: %d checks"):format(checks))
