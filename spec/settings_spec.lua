local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local values = {}
local flush_count = 0
local store = {
    readSetting = function(_self, key, default)
        local value = values[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_self, key, value)
        values[key] = value
    end,
    flush = function()
        flush_count = flush_count + 1
    end,
}

local Settings = require("webdavmanga.settings")
local settings = Settings:new{ store = store }

local reader = settings:get_reader()
expect(reader.direction == "normal", "normal direction should be default")
expect(reader.prefetch_count == 3, "three pages should be prefetched by default")
expect(reader.cache_limit_mb == 200, "cache should default to 200 MB")
expect(reader.fit_mode == "page", "page fit should be default")
expect(reader.show_page_number == nil and reader.show_progress_bar == true,
    "the committed top progress bar replaces the removed page-number title")
expect(reader.split_enabled == false, "wide-page splitting should default to disabled")
expect(reader.split_min_ratio == 1.20 and reader.split_max_ratio == 2.20,
    "wide-page aspect bounds should have exact defaults")
expect(reader.split_cut_percent == 50, "wide-page cut should default to the midpoint")
expect(reader.grid_columns == 5, "browser grids should default to five columns")
expect(reader.animation_enabled == false and reader.animation_steps == nil
    and reader.animation_delay_ms == nil,
    "native animation defaults off and discards removed software timing fields")
expect(reader.panel_zoom_enabled == false
    and reader.panel_show_adjacent == true
    and reader.panel_standard_margin_percent == 0
    and reader.panel_hold_margin_percent == 5
    and reader.panel_initial_zoom == 1.2
    and reader.panel_experimental_sort == false,
    "dynamic panel reading must have neutral safe defaults")

for _, values in ipairs({
    { panel_zoom_enabled = "yes" },
    { panel_show_adjacent = 1 },
    { panel_standard_margin_percent = 3 },
    { panel_hold_margin_percent = 0 },
    { panel_initial_zoom = 1.3 },
    { panel_experimental_sort = "false" },
}) do
    local saved_ok = settings:set_reader(values)
    expect(saved_ok == nil, "dynamic panel settings must reject non-whitelisted values")
end

expect(settings:set_reader{
    panel_zoom_enabled = true,
    panel_show_adjacent = false,
    panel_standard_margin_percent = 10,
    panel_hold_margin_percent = 20,
    panel_initial_zoom = 2.0,
    panel_experimental_sort = true,
}, "every documented dynamic panel value must persist")
reader = settings:get_reader()
expect(reader.panel_zoom_enabled == true
    and reader.panel_show_adjacent == false
    and reader.panel_standard_margin_percent == 10
    and reader.panel_hold_margin_percent == 20
    and reader.panel_initial_zoom == 2.0
    and reader.panel_experimental_sort == true,
    "dynamic panel values must survive the settings store round trip")

reader.prefetch_count = 9
expect(settings:get_reader().prefetch_count == 3, "reader defaults must be copied")

local ok, err = settings:set_reader{ prefetch_count = 11 }
expect(ok == nil and err == "invalid_prefetch_count", "prefetch above 10 must fail")
ok, err = settings:set_reader{ cache_limit_mb = 15 }
expect(ok == nil and err == "invalid_cache_limit", "cache below 16 MB must fail")
for _, limit in ipairs({ 16, 200, 4096 }) do
    expect(settings:set_reader{ cache_limit_mb = limit },
        "an integer cache limit inside the inclusive range must save")
end
for _, limit in ipairs({ 4097, 16.5, "200" }) do
    ok, err = settings:set_reader{ cache_limit_mb = limit }
    expect(ok == nil and err == "invalid_cache_limit",
        "out-of-range, fractional, and text cache limits must fail")
end
ok, err = settings:set_reader{ direction = "rtl" }
expect(ok == nil and err == "invalid_direction", "unknown direction must fail")
ok, err = settings:set_reader{ fit_mode = "stretch" }
expect(ok == nil and err == "invalid_fit_mode", "unknown fit mode must fail")
ok, err = settings:set_reader{ split_enabled = "true" }
expect(ok == nil and err == "invalid_split_enabled",
    "split enabled must reject non-boolean values")
for _, bounds in ipairs({
    { split_min_ratio = 1.00, split_max_ratio = 4.00 },
    { split_min_ratio = 1.20, split_max_ratio = 2.20 },
}) do
    expect(settings:set_reader(bounds),
        "aspect ratios inside the inclusive 1.00 to 4.00 range should save")
end
for _, values in ipairs({
    { split_min_ratio = 0.99 },
    { split_min_ratio = 4.01 },
    { split_min_ratio = "1.20" },
}) do
    ok, err = settings:set_reader(values)
    expect(ok == nil and err == "invalid_split_min_ratio",
        "minimum aspect ratio must be a number from 1.00 to 4.00")
end
for _, values in ipairs({
    { split_max_ratio = 0.99 },
    { split_max_ratio = 4.01 },
    { split_max_ratio = "2.20" },
}) do
    ok, err = settings:set_reader(values)
    expect(ok == nil and err == "invalid_split_max_ratio",
        "maximum aspect ratio must be a number from 1.00 to 4.00")
end
for _, values in ipairs({
    { split_min_ratio = 2.20, split_max_ratio = 2.20 },
    { split_min_ratio = 2.21, split_max_ratio = 2.20 },
}) do
    ok, err = settings:set_reader(values)
    expect(ok == nil and err == "invalid_split_ratio_range",
        "minimum aspect ratio must remain strictly below maximum")
end
for _, cut in ipairs({ 10, 50, 90 }) do
    expect(settings:set_reader{ split_cut_percent = cut },
        "integer split cuts inside the inclusive range should save")
end
for _, cut in ipairs({ 9, 91, 50.5, "50" }) do
    ok, err = settings:set_reader{ split_cut_percent = cut }
    expect(ok == nil and err == "invalid_split_cut_percent",
        "split cut must be an integer from 10 to 90")
end
for _, columns in ipairs({ 3, 5 }) do
    expect(settings:set_reader{ grid_columns = columns },
        "only supported browser grid column counts should save")
end
for _, columns in ipairs({ 2, 4, 6, 3.5, "5" }) do
    ok, err = settings:set_reader{ grid_columns = columns }
    expect(ok == nil and err == "invalid_grid_columns",
        "grid columns must be exactly the number three or five")
end
for _, steps in ipairs({ 0, 13, 2.5, "8" }) do
    ok, err = settings:set_reader{ animation_steps = steps }
    expect(ok and settings:get_reader().animation_steps == nil,
        "removed animation frame control must never reenter persisted reader settings")
end
for _, delay in ipairs({ 4, 101, 10.5, "24" }) do
    ok, err = settings:set_reader{ animation_delay_ms = delay }
    expect(ok and settings:get_reader().animation_delay_ms == nil,
        "removed animation delay control must never reenter persisted reader settings")
end
ok, err = settings:set_reader{ animation_enabled = "yes" }
expect(ok == nil and err == "invalid_animation_enabled",
    "animation enabled must reject non-boolean values")

expect(settings:set_reader{
    direction = "manga",
    prefetch_count = 5,
    cache_limit_mb = 512,
    fit_mode = "width",
    show_progress_bar = false,
    split_enabled = true,
    split_min_ratio = 1.25,
    split_max_ratio = 2.50,
    split_cut_percent = 45,
    grid_columns = 3,
    animation_enabled = false,
    animation_steps = 6,
    animation_delay_ms = 18,
}, "valid reader settings should save")
reader = settings:get_reader()
expect(reader.direction == "manga" and reader.prefetch_count == 5,
    "reader settings should persist")
expect(reader.cache_limit_mb == 512 and reader.fit_mode == "width"
    and reader.show_progress_bar == false and reader.show_page_number == nil, "all current reader fields should persist")
expect(reader.split_enabled == true and reader.split_min_ratio == 1.25
    and reader.split_max_ratio == 2.50 and reader.split_cut_percent == 45
    and reader.grid_columns == 3, "all split and grid fields should persist")
expect(reader.animation_enabled == false and reader.animation_steps == nil
    and reader.animation_delay_ms == nil,
    "native animation switch persists while removed software timing does not")

ok, err = settings:set_connection{
    server_url = "ftp://nas.example/dav",
    username = "reader",
    password = "secret-value",
    root_path = "/漫画",
}
expect(ok == nil and err == "invalid_server_url", "non-HTTP URL must fail")
expect(not tostring(err):find("secret%-value"), "errors must not expose passwords")

expect(settings:set_connection{
    server_url = "https://nas.example/dav/",
    username = "reader",
    password = "secret-value",
    root_path = "漫画/",
}, "valid connection should save")
local connection = settings:get_connection()
expect(connection.server_url == "https://nas.example/dav", "server slash should be trimmed")
expect(connection.root_path == "/漫画", "root should have one leading slash")
expect(connection.username == "reader" and connection.password == "secret-value",
    "credentials should persist locally")
expect(settings:is_configured(), "complete connection should be configured")

expect(settings:set_connection{
    server_url = "https://nas.example/dav/",
    username = "reader",
    password = "secret-value",
    root_path = " / ",
}, "the WebDAV collection root should be a valid manga root")
connection = settings:get_connection()
expect(connection.root_path == "/" and settings:is_configured(),
    "slash root should survive normalization and persisted configuration checks")

expect(settings:get_browser_path() == "/漫画",
    "changing the connection root to slash should preserve the previous manga location")
expect(settings:set_browser_path("sata11-reader/Books/A/"),
    "a bookshelf directory below the WebDAV root should be accepted")
expect(settings:get_browser_path() == "/sata11-reader/Books/A",
    "the last bookshelf directory should be normalized and remembered")

expect(settings:set_connection{
    server_url = "https://nas.example/dav/",
    username = "reader",
    password = "secret-value",
    root_path = "/",
}, "saving the same WebDAV root should succeed")
expect(settings:get_browser_path() == "/sata11-reader/Books/A",
    "editing connection details must not reset a still-valid bookshelf location")

expect(settings:set_connection{
    server_url = "https://nas.example/dav/",
    username = "reader",
    password = "secret-value",
    root_path = "/other-root",
}, "changing the WebDAV root should succeed")
expect(settings:get_browser_path() == "/other-root",
    "a bookshelf location outside a new WebDAV root should reset safely")
ok, err = settings:set_browser_path("/sata11-reader/Books/A")
expect(ok == nil and err == "browser_path_outside_root",
    "bookshelf navigation must not escape the configured WebDAV root")
ok, err = settings:set_browser_path("/other-root/../outside")
expect(ok == nil and err == "browser_path_outside_root",
    "dot segments must not bypass WebDAV root confinement")

expect(settings:set_browser_path("/other-root/private-books"),
    "a path under the current account root should save")
expect(settings:set_connection{
    server_url = "https://second-nas.example/dav",
    username = "reader",
    password = "other-secret",
    root_path = "/other-root",
}, "switching servers should save")
expect(settings:get_browser_path() == "/other-root",
    "switching servers must not carry a private bookshelf path to the new server")

expect(settings:set_browser_path("/other-root/account-a"),
    "the new server should remember its browsed child")
expect(settings:set_connection{
    server_url = "https://second-nas.example/dav",
    username = "reader-b",
    password = "other-secret",
    root_path = "/other-root",
}, "switching accounts should save")
expect(settings:get_browser_path() == "/other-root",
    "switching WebDAV accounts must reset the saved bookshelf location")

connection.username = "changed"
expect(settings:get_connection().username == "reader-b", "connection must be copied")

settings:flush()
expect(flush_count == 1, "flush should delegate once")

print(("settings_spec: %d checks"):format(checks))
