local Settings = require("webdavmanga.settings")
local Catalog = require("webdavmanga.opds_catalog")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function memory_store(initial)
    local values = initial or {}
    local flushes = 0
    return {
        values = values,
        readSetting = function(_, key, default)
            if values[key] == nil then return default end
            return values[key]
        end,
        saveSetting = function(_, key, value) values[key] = value end,
        flush = function() flushes = flushes + 1 end,
        flushes = function() return flushes end,
    }
end

local store = memory_store()
local settings = Settings:new{ store = store }
local ok, id = settings:add_source{
    kind = "opds", name = "家庭 Komga", server_url = " https://komga.example/opds/ ",
    username = "reader", password = "secret", server_kind = "komga",
}
expect(ok and id, "OPDS source must be accepted")
local source = settings:get_source(id)
expect(source.kind == "opds" and source.server_url == "https://komga.example/opds"
    and source.server_kind == "komga" and source.root_path == "/",
    "OPDS source must normalize URL and retain its driver")
expect(settings:get_connection().server_kind == "komga",
    "active OPDS connection must retain its driver")
expect(not source.name:find("secret", 1, true), "source display name must omit password")
expect(Settings:new{ store = store }:get_source(id).server_kind == "komga",
    "OPDS driver must survive restart")
expect(settings:set_source(id, { kind = "opds", name = "新名称",
    server_url = "https://komga.example/other", username = "reader",
    password = "new-secret", server_kind = "kavita" }), "OPDS source must be editable")
expect(settings:get_source(id).server_kind == "kavita"
    and settings:get_connection().server_kind == "kavita", "editing active OPDS source must update connection")
local ok_second, second_id = settings:add_source{ kind = "opds",
    server_url = "https://second.example/opds", server_kind = "suwayomi" }
expect(ok_second and settings:select_source(id), "OPDS sources must be selectable")
expect(settings:get_active_source_id() == id and settings:get_connection().kind == "opds",
    "selection must activate the OPDS source")
expect(settings:remove_source(second_id), "OPDS source must be removable")
expect(settings:remove_source(id) == nil, "last-source protection must apply to OPDS")
local invalid, reason = settings:add_source{ kind = "opds", server_url = "file:///secret" }
expect(invalid == nil and reason == "invalid_opds_url", "OPDS URL must be HTTP(S)")

local public_settings = Settings:new{ store = memory_store() }
local public_ok = public_settings:add_source{ kind = "opds",
    server_url = "https://public.example/opds" }
expect(public_ok and public_settings:is_configured(),
    "anonymous public OPDS source must count as configured")
local key_ok = public_settings:add_source{ kind = "opds",
    server_url = "https://key.example/opds?api_key=stored-in-settings" }
expect(key_ok and public_settings:is_configured(),
    "URL API-key OPDS source must not require a username")
local no_host, no_host_error = public_settings:add_source{ kind = "opds",
    server_url = "https://?api_key=not-a-host" }
expect(no_host == nil and no_host_error == "invalid_opds_url",
    "OPDS configuration must still require a real URL authority")

local legacy = memory_store{
    catalogs = {
        { id = "old-a", name = "甲", url = "https://example.test/a/", username = "u", password = "p" },
        { id = "old-b", name = "乙", url = "https://example.test/b", username = "v", password = "q" },
    },
    active_catalog_id = "old-b",
}
local unified = memory_store{ sources = {
    { id = "source-1", name = "已有", kind = "opds", server_url = "https://example.test/a",
        username = "u", password = "p", root_path = "/", server_kind = "auto" },
} }
local migrated_settings = Settings:new{ store = unified }
local catalog = Catalog:new{ settings = migrated_settings, legacy_store = legacy,
    client_factory = function() return { fetch = function() return { title = "根目录", entries = {} } end } end }
expect(catalog:migrate_legacy_once(), "legacy catalogs must import")
expect(#catalog:list() == 2, "normalized URL and username must deduplicate legacy catalogs")
expect(legacy.values.migrated_to_sources_v1 == true and legacy.flushes() > 0,
    "successful migration must persist a marker")
expect(catalog:active() and catalog:active().server_url == "https://example.test/b",
    "legacy active catalog must select its imported source")
expect(catalog:migrate_legacy_once() and #catalog:list() == 2,
    "running legacy migration twice must not duplicate sources")
local new_catalog = Catalog:new{ settings = migrated_settings, legacy_store = legacy,
    client_factory = function() return { fetch = function() return { title = "根目录", entries = {} } end } end }
local saved = assert(new_catalog:save{ name = "丙", url = "https://example.test/c", password = "secret" })
expect(saved.kind == "opds" and #new_catalog:list() == 3,
    "catalog facade must save to unified sources")
expect(#legacy.values.catalogs == 2, "runtime catalog save must never write legacy rows")

local preserve_store = memory_store()
local preserve_settings = Settings:new{ store = preserve_store }
local webdav_ok, webdav_id = preserve_settings:add_source{
    name = "NAS", server_url = "https://nas.example", root_path = "/Books",
}
expect(webdav_ok and webdav_id, "migration fixture must have an active WebDAV source")
local preserve_legacy = memory_store{ catalogs = {
    { id = "old-only", name = "旧目录", url = "https://legacy.example/opds" },
} }
local preserve_catalog = Catalog:new{ settings = preserve_settings,
    legacy_store = preserve_legacy, client_factory = function() return {} end }
expect(preserve_catalog:migrate_legacy_once()
    and preserve_settings:get_active_source_id() == webdav_id,
    "import without a legacy active catalog must preserve the user's selected source")

local UiSettings = require("webdavmanga.ui_settings")
local shown, messages, fetches = {}, {}, {}
local shelf_opens = 0
local feed_response = { title = "根目录", entries = {{ name = "卷一" }},
    is_atom_feed = true, server_kind = "komga" }
local ui = {
    show_sources = function(_, model) shown.sources = model end,
    show_opds_connection = function(_, model) shown.opds = model end,
    show_info = function(_, message) messages[#messages + 1] = message end,
    show_busy = function() return { close = function() end } end,
}
local controller = UiSettings:new{
    settings = settings,
    client_factory = function() return {} end,
    opds_client_factory = function()
        return { fetch = function(_, url, auth)
            fetches[#fetches + 1] = { url = url, auth = auth }
            return feed_response
        end }
    end,
    async = { run = function(work, done) done(true, work()) end },
    cache = {}, ui = ui,
    open_category_shelf = function() shelf_opens = shelf_opens + 1; return true end,
    open_opds = function() error("standalone OPDS bookshelf must not open") end,
}
controller:show_connection()
expect(shown.sources and type(shown.sources.on_add_opds) == "function"
    and shown.sources.on_open_opds == nil,
    "unified source menu must offer OPDS add without standalone shelf")
expect(shown.sources.on_add_opds(), "OPDS add must open its connection form")
expect(shown.opds and shown.opds.values.kind == "opds",
    "OPDS form must be a regular source form")
local input = { kind = "opds", name = "新 OPDS", server_url = "https://new.example/opds",
    username = "reader", password = "private", server_kind = "auto" }
expect(shown.opds.on_test(input), "OPDS form must test its feed")
expect(fetches[1] and fetches[1].url == input.server_url
    and fetches[1].auth.username == "reader" and fetches[1].auth.password == "private",
    "connection test must fetch the OPDS feed with source credentials")
feed_response = { title = "伪目录", entries = {{ name = "卷一" }}, is_atom_feed = false }
expect(shown.opds.on_test(input), "non-Atom response must finish the connection test")
expect(tostring(messages[#messages]):find("Atom", 1, true),
    "non-Atom XML with entries must be rejected by the settings test")
feed_response = { title = "根目录", entries = {{ name = "卷一" }},
    is_atom_feed = true, server_kind = "komga" }
expect(shown.opds.on_test(input), "a successful retest must replace the failed test")
expect(shown.opds.on_save(input), "OPDS form must save through unified settings")
local added = settings:get_source(settings:get_active_source_id())
expect(added.kind == "opds" and added.server_kind == "komga",
    "successful test must persist detected server kind")
controller:show_connection()
expect(shown.sources.on_select(added.id) and shelf_opens == 1,
    "selecting OPDS source must return to the unified manga bookshelf")
expect(not tostring(messages[#messages]):find("private", 1, true),
    "connection feedback must not expose password")

local widgets = {}
local function widget_type(kind)
    return { new = function(_, options)
        options._kind = kind
        return options
    end }
end
for _, name in ipairs({ "buttondialog", "confirmbox", "infomessage", "multiinputdialog" }) do
    local current = name
    package.preload["ui/widget/" .. name] = function() return widget_type(current) end
end
package.preload["ui/uimanager"] = function()
    return { _window_stack = {}, show = function(_, widget)
        widgets[#widgets + 1] = widget
    end, close = function() end }
end
local rendered = UiSettings:new{ settings = settings, client_factory = function() return {} end,
    opds_client_factory = function() return {} end, async = {}, cache = {} }
rendered:show_connection()
local source_dialog = widgets[#widgets]
local all_text = {}
for _, row in ipairs(source_dialog.buttons or {}) do
    for _, button in ipairs(row) do all_text[#all_text + 1] = button.text or "" end
end
local menu_text = table.concat(all_text, "\n")
expect(menu_text:find("新增 OPDS 连接", 1, true)
    and menu_text:find("OPDS 目录", 1, true),
    "rendered source menu must display OPDS rows and add action")
expect(not menu_text:find("OPDS 书架", 1, true)
    and not menu_text:find("private", 1, true),
    "rendered source menu must omit standalone shelf and credentials")
local url_ok, url_id = settings:add_source{ kind = "opds",
    server_url = "https://reader:embedded-secret@safe.example/opds?apiKey=query-secret" }
expect(url_ok and url_id, "OPDS URLs with server credentials must be retained for requests")
expect(not settings:get_source(url_id).name:find("secret", 1, true),
    "fallback OPDS source name must not expose URL credentials")
rendered:show_connection()
local private_dialog = widgets[#widgets]
for _, row in ipairs(private_dialog.buttons or {}) do
    for _, button in ipairs(row) do
        expect(not tostring(button.text):find("secret", 1, true),
            "source rows must conceal URL credentials and API keys")
    end
end

print(("rebuild_0405_opds_sources_spec: %d checks"):format(checks))
