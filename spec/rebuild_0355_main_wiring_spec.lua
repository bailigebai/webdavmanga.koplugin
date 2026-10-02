local dispatcher_actions = {}
local WidgetContainer = {}
function WidgetContainer:new(values)
    values = values or {}
    setmetatable(values, self)
    if values.init then values:init() end
    return values
end
function WidgetContainer:extend(definition)
    definition = definition or {}
    definition.__index = definition
    setmetatable(definition, { __index = self })
    return definition
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/settings" end,
        getDataDir = function() return "." end,
        getFullDataDir = function() return "/data" end,
    }
end
package.preload["dispatcher"] = function()
    return { registerAction = function(_self, name, model)
        dispatcher_actions[name] = model
    end }
end
package.preload["luasettings"] = function()
    return { open = function() error("all phase-two stores must be injected") end }
end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["logger"] = function()
    return { err = function() end, warn = function() end,
        info = function() end, dbg = function() end }
end
package.preload["json"] = function()
    return { encode = function() return "{}" end, decode = function() return {} end }
end

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end
local function memory_store()
    local store = { values = {}, flushes = 0 }
    function store:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:saveSetting(key, value) self.values[key] = value end
    function store:flush() self.flushes = self.flushes + 1; return true end
    return store
end

local settings_store, cache_store = memory_store(), memory_store()
local license_settings_store = memory_store()
local progress_store, catalog_store, opds_store = memory_store(), memory_store(), memory_store()
opds_store.values.catalogs = {
    { id = "legacy-opds", name = "旧 OPDS", url = "https://legacy.example/opds",
        username = "legacy-user", password = "legacy-secret" },
}
local library_store, offline_store = memory_store(), memory_store()
local connection = { kind = "webdav", server_url = "http://nas:5005",
    username = "reader", root_path = "/Books", local_path = "" }
local settings = {
    sources = {},
    get_sources = function(self) return self.sources end,
    get_source = function(self, id)
        for _, source in ipairs(self.sources) do
            if source.id == id then return source end
        end
    end,
    get_active_source_id = function() return "nas" end,
    add_source = function(self, values)
        local id = "opds-" .. tostring(#self.sources + 1)
        values.id = id
        self.sources[#self.sources + 1] = values
        return true, id
    end,
    select_source = function() return true end,
    get_connection = function() return connection end,
    get_browser_path = function() return connection.root_path end,
    get_reader = function()
        return { cache_limit_mb = 200, cover_cache_limit_mb = 200,
            prefetch_count = 3, prefetch_first_pages = 10,
            prefetch_near_count = 5, prefetch_far_count = 2,
            prefetch_concurrency = 2 }
    end,
    get_browse_cache = function()
        return { total_mb = 5120, trigger_mb = 3072, retain_mb = 1024,
            interval_minutes = 10 }
    end,
    get_offline_root = function() return "/mnt/us/OfflineManga" end,
    set_browser_path = function() return true end,
    is_configured = function() return true end,
    flush = function() return true end,
}
local reporter = { failures = {} }
function reporter:guard(label, callback, fallback)
    local ok, result = pcall(callback)
    if ok then return result end
    self.failures[#self.failures + 1] = { label = label, error = result }
    return fallback
end
function reporter:wrap(label, callback, fallback)
    return function(...)
        local arguments = { n = select("#", ...), ... }
        return self:guard(label, function()
            return callback(unpack(arguments, 1, arguments.n))
        end, fallback)
    end
end

local cache = {
    limit_bytes = 200 * 1024 * 1024,
    cover_limit_bytes = 200 * 1024 * 1024,
    migrate = function() end, cleanup_parts = function() end,
    cleanup_browse = function() end,
    browse_policy = function() return { check_interval_seconds = 600 } end,
    total_size = function() return 0 end, protected_size = function() return 0 end,
    kind_size = function() return 0 end, kind_count = function() return 0 end,
}
local lifecycle = { offline_cancels = 0, directory_cancels = 0,
    loader_cancels = 0, reader_closes = 0 }
local offline_cache = {
    root = function() return "/mnt/us/OfflineManga" end,
    stats = function()
        return { root = "/mnt/us/OfflineManga", offline_bytes = 0,
            manga_bytes = 0, total_bytes = 10, used_bytes = 2,
            available_bytes = 8, reserve_bytes = 1 }
    end,
    list_mangas = function()
        return {{ manga = { name = "离线测试", path = "/Books/Offline" }, progress = 1 }}
    end,
    reader_model = function()
        return { manga = { name = "离线测试", path = "/Books/Offline" }, chapters = {{
            name = "离线测试", path = "/Books/Offline", images = {{ name = "001.jpg",
                path = "/Books/Offline/001.jpg", local_path = "/offline/001.jpg",
                offline_owned = true }},
        }} }
    end,
}
local offline_manager = {
    status = function()
        return { running = false, status = "idle", total = 0,
            downloaded = 0, cached = 0, failed = 0 }
    end,
    start = function() return { cancel = function() end } end,
    cancel = function() return true end,
    cancel_all = function()
        lifecycle.offline_cancels = lifecycle.offline_cancels + 1
        return true
    end,
}
local directory_store = { identity = "before",
    cancel_all = function() lifecycle.directory_cancels = lifecycle.directory_cancels + 1 end }
local loader = { identity = "before", cancel_all = function()
    lifecycle.loader_cancels = lifecycle.loader_cancels + 1
end }
local reader_opened
local reader = { open = function(_self, context) reader_opened = context end, force_close = function()
    lifecycle.reader_closes = lifecycle.reader_closes + 1
end }
local captured_offline
local settings_ui_adapter = {
    show_offline_cache = function(_self, model) captured_offline = model end,
    show_info = function() end,
    close_all = function() end,
}
local browser_ui_adapter = { show_menu = function() end, show_info = function() end,
    close_menu = function() end }
local library_ui_adapter = { show_menu = function(_self, model) _self.last_menu = model end,
    show_info = function() end, close_all = function() end }
local scheduler = { scheduleIn = function() return true end,
    unschedule = function() return true end }
local opds_home_opens = 0

local Plugin = require("main")
local plugin = Plugin:new{
    path = "/plugin",
    ui = { menu = { registerToMainMenu = function() end } },
    webdavmanga_deps = {
        settings_store = settings_store, cache_store = cache_store,
        license_settings_store = license_settings_store,
        progress_store = progress_store, catalog_store = catalog_store,
        opds_store = opds_store,
        library_store = library_store, offline_store = offline_store,
        settings = settings, error_reporter = reporter, cache = cache,
        license = { is_authorized = function() return true end },
        progress = { list_history = function() return {} end, flush = function() return true end },
        library = { ALL = "all", UNCATEGORIZED = "uncategorized" },
        state = {}, client_factory = function(current) return { connection = current } end,
        transport = {},
        directory_store = directory_store, loader = loader, reader = reader,
        document_bridge = { cancel_all = function() end },
        cover_service = { cancel_all = function() end },
        cover_grid = { cancel = function() end,
            show = function(_self, model) _self.last_grid = model; return true end },
        local_archive = {},
        diagnostics = {}, async = { run = function() return { cancel = function() end } end },
        lighting = {}, nodeshare = {}, scheduler = scheduler,
        network_manager = { willRerunWhenConnected = function() return false end },
        settings_ui_adapter = settings_ui_adapter,
        browser_ui_adapter = browser_ui_adapter,
        library_ui_adapter = library_ui_adapter,
        offline_cache = offline_cache, offline_manager = offline_manager,
        opds_ui = { show_home = function() opds_home_opens = opds_home_opens + 1; return true end },
        device = {}, global_settings = memory_store(),
    },
}

expect(plugin.offline_cache == offline_cache and plugin.offline_manager == offline_manager,
    "main must retain the independent whole-manga cache components")
expect(plugin.opds_cover == plugin.browser.opds_cover
    and plugin.opds_cover == plugin.library_ui.opds_cover,
    "main must share one OPDS cover service across history and every shelf")
expect(#settings.sources == 1 and settings.sources[1].kind == "opds"
    and opds_store.values.migrated_to_sources_v1 == true,
    "startup must import legacy OPDS catalogs into unified sources exactly once")
local source_auth = plugin.opds_pages.auth_provider(settings.sources[1].id)
expect(plugin.opds_pages.progress.store == plugin.progress,
    "OPDS server high-water must use the existing persistent progress service")
expect(source_auth.username == "legacy-user" and source_auth.password == "legacy-secret",
    "OPDS page auth must use its source id, not the active connection")
expect(plugin.settings_ui.open_opds == nil
    and type(plugin.settings_ui.opds_client_factory) == "function"
    and opds_home_opens == 0,
    "main must test OPDS through unified connection settings without a standalone shelf")
local menu_items = {}
plugin:addToMainMenu(menu_items)
local plugin_menu = menu_items.webdavmanga.sub_item_table_func()
for _, item in ipairs(plugin_menu) do
    expect(item.text ~= "OPDS 书架",
        "OPDS must not remain as a separate KOReader top-menu item")
end
expect(plugin.library_ui:show_offline_shelf()
    and plugin.cover_grid.last_grid.title == "缓存漫画"
    and plugin.library_ui.offline_cache == offline_cache
    and plugin.library_ui.offline_manager == offline_manager,
    "main must inject offline shelf dependencies into the real library UI")
plugin.cover_grid.last_grid.items[1].on_open()
expect(reader_opened and reader_opened.chapter_index:get(1).local_path == "/offline/001.jpg",
    "main-wired cache shelf must open the trusted local reader")
plugin.browser.cache_manga({ name = "测试", path = "/Books/Test", is_folder = true })
expect(captured_offline and captured_offline.manga_name == "测试",
    "the bookshelf cache action must reach the whole-manga task panel")

plugin.settings_ui.on_connection_saved()
expect(lifecycle.offline_cancels == 1,
    "switching connections must cancel an active whole-manga task first")
expect(plugin:onFlushSettings() == true and offline_store.flushes == 1,
    "the independent whole-manga index must flush with plugin settings")
expect(opds_store.flushes == 1,
    "normal settings flush must not write the legacy OPDS catalog store")
local exit_form, exit_job, late_messages
late_messages = 0
settings_ui_adapter.show_opds_connection = function(_, model) exit_form = model end
settings_ui_adapter.show_busy = function()
    return { close = function() end }
end
settings_ui_adapter.show_info = function() late_messages = late_messages + 1 end
plugin.settings_ui.async.run = function(_work, done)
    exit_job = { canceled = false, done = done }
    return { cancel = function() exit_job.canceled = true end }
end
expect(plugin.settings_ui:_show_opds_connection_dialog(nil, nil, true)
    and exit_form.on_test{ server_url = "https://exit.example/opds" },
    "the plugin exit probe must start a real OPDS settings test")
expect(plugin:onExit() == true and lifecycle.offline_cancels == 2,
    "plugin teardown must cancel whole-manga work without touching saved files")
expect(exit_job.canceled,
    "plugin exit must cancel the pending OPDS settings test")
exit_job.done(true, { ok = true, server_kind = "kavita" })
expect(late_messages == 0,
    "plugin exit must suppress the pending OPDS test's late message")
expect(#reporter.failures == 0 and dispatcher_actions.show_webdav_manga,
    "phase-two wiring must not hide initialization or lifecycle failures")

-- Keep the production settings/cache/manager/grid chain; only platform I/O is replaced.
local root_deps = {}
for key, value in pairs(plugin.webdavmanga_deps) do root_deps[key] = value end
for _, key in ipairs({ "settings", "offline_cache", "offline_manager", "cover_grid", "library" }) do
    root_deps[key] = nil
end
root_deps.settings_store, root_deps.offline_store = memory_store(), memory_store()
root_deps.settings_store.values.connection = connection
root_deps.settings_store.values.offline_root = "/mnt/us/ShelfA"
local root_files, root_events, root_summaries = {}, {}, {}
root_deps.offline_fs = {
    make_path = function() return true end,
    exists = function(path) return root_files[path] ~= nil end,
    size = function(path) return root_files[path] end,
    rename = function(source, target)
        root_files[target], root_files[source] = root_files[source], nil
        return true
    end,
    remove = function(path) root_files[path] = nil; return true end,
}
-- The 0.3.57 cache policy reserves 5 GB, so the lifecycle fixture needs
-- enough free space to exercise a successful download.
root_deps.offline_disk_usage = function() return { available = 8 * 1024 * 1024 * 1024 } end
root_deps.md5 = function(value)
    local sum = #value
    for position = 1, #value do sum = (sum * 33 + value:byte(position)) % 0xffffffff end
    return ("%032x"):format(sum)
end
local function root_schedule(callback) root_events[#root_events + 1] = callback; return true end
root_deps.scheduler = { scheduleIn = function(_self, _delay, callback)
    return root_schedule(callback)
end, unschedule = function() end }
local root_manga = { name = "Root lifecycle", path = "/Books/RootLifecycle" }
root_deps.progress = { list_history = function()
    return {{ manga = root_manga, chapter = root_manga, index = 1, total = 2, updated_at = 1 }}
end, flush = function() return true end }
local function root_index(entries)
    return { count = function() return #entries end,
        get = function(_self, position) return entries[position] end }
end
root_deps.directory_store = { load = function(_self, path, callbacks)
    assert(path == root_manga.path)
    root_schedule(function() callbacks.on_ready({ folders = root_index({}), images = root_index({
        { name = "001.jpg", path = root_manga.path .. "/001.jpg", size = 40 },
        { name = "002.jpg", path = root_manga.path .. "/002.jpg", size = 40 },
    }) }) end)
    return { cancel = function() end }
end }
root_deps.client_factory = function() return { download = function(_self, _remote, part)
    root_files[part] = 40
    return { size = 40, format = "jpeg", width = 100, height = 200 }
end } end
root_deps.async = { run = function(work, callback)
    root_schedule(function() callback(true, work()) end)
    return { cancel = function() end }
end }
local root_grid_ui = {
    show_grid = function(self, model) self.model = model end,
    close_grid = function(self) self.model = nil end,
    free_visible = function() end,
    set_progress = function(self, id, progress)
        self.last_progress = { id = id, progress = progress }
        return true
    end,
}
root_deps.cover_grid_ui_adapter = root_grid_ui
local root_plugin = Plugin:new{ path = "/plugin", webdavmanga_deps = root_deps }
local root_library, root_manager = root_plugin.library_ui, root_plugin.offline_manager
local root_identity = root_library:_offline_identity()
local root_on_status = root_manager.on_status
root_manager.on_status = function(summary)
    root_summaries[#root_summaries + 1] = summary
    root_on_status(summary)
end
assert(root_plugin.offline_cache:save_job(root_identity, root_manga,
    { status = "canceled", total_pages = 2, cached_pages = 0 }))
assert(root_library:show_offline_shelf())
local root_a_grid, root_a_epoch = root_grid_ui.model, root_library.view_epoch
root_a_grid.items[1].on_hold()
expect(captured_offline.manga_name == root_manga.name and root_plugin.cover_grid.is_open,
    "long-press must open real cache details while the A shelf remains visible")
expect(captured_offline.on_set_root("/mnt/us//ShelfA/")
    and root_grid_ui.model == root_a_grid and root_library.view_epoch == root_a_epoch,
    "saving the same normalized destination must keep the current shelf")
expect(captured_offline.on_set_root("/tmp/Invalid") == false
    and root_grid_ui.model == root_a_grid and root_library.view_epoch == root_a_epoch
    and root_plugin.settings:get_offline_root() == "/mnt/us/ShelfA",
    "an invalid destination must not change settings or invalidate the shelf")
local root_writer = root_deps.settings_store.saveSetting
root_deps.settings_store.saveSetting = function() error("destination write failed") end
local root_write_failed = captured_offline.on_set_root("/mnt/us/Unwritable")
root_deps.settings_store.saveSetting = root_writer
expect(root_write_failed == false and root_grid_ui.model == root_a_grid
    and root_library.view_epoch == root_a_epoch
    and root_plugin.settings:get_offline_root() == "/mnt/us/ShelfA",
    "a failed settings write must leave the current shelf and destination unchanged")
local root_flush = root_deps.settings_store.flush
for _, throws in ipairs({ false, true }) do
    root_deps.settings_store.flush = function()
        if throws then error("destination flush failed") end
        return false
    end
    local saved_root = captured_offline.on_set_root("/mnt/us/Unflushed")
    root_deps.settings_store.flush = root_flush
    expect(saved_root == false and root_grid_ui.model == root_a_grid
        and root_library.view_epoch == root_a_epoch
        and root_plugin.settings:get_offline_root() == "/mnt/us/ShelfA",
        "a failed destination flush must restore the original root and keep its shelf")
end
expect(captured_offline.on_set_root("/mnt/us//ShelfB/") == true
    and not root_plugin.cover_grid.is_open and root_grid_ui.model == nil
    and root_library.view_epoch > root_a_epoch,
    "saving destination B from long-press details must immediately close the old A shelf")
assert(root_library:show_offline_shelf())
expect(#root_grid_ui.model.items == 0,
    "reopening destination B must not display the retained A job")
assert(root_plugin.settings_ui:show_offline_cache(root_manga))
assert(captured_offline.on_start())
local root_b_scanning = root_summaries[#root_summaries]
assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfA"))
assert(root_library:show_offline_shelf())
root_a_grid, root_a_epoch = root_grid_ui.model, root_library.view_epoch
root_grid_ui.last_progress = nil
assert(root_plugin.settings:set_offline_root("/mnt/us//ShelfB/"))
local function root_drain_until(predicate)
    for _ = 1, 50 do
        if predicate() then return end
        assert(#root_events > 0, "root lifecycle stopped before its expected state")
        table.remove(root_events, 1)()
    end
    error("root lifecycle did not reach its expected state")
end
root_drain_until(function() return root_manager:status().downloaded == 1 end)
local root_b_progress = root_summaries[#root_summaries]
expect(root_a_grid.items[1].cache_progress == 0 and root_grid_ui.last_progress == nil
    and root_grid_ui.model == root_a_grid and root_library.view_epoch == root_a_epoch,
    "a real B task must not update the still-open A shelf even without a UI invalidation callback")
expect(root_b_scanning.root == "/mnt/us/ShelfB" and root_b_progress.root == "/mnt/us/ShelfB"
    and root_b_progress.downloaded == 1 and root_b_progress.total == 2,
    "manager summaries must carry the captured normalized task destination")
assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfA"))
expect(root_library:update_offline_progress(root_b_progress) == false
    and root_a_grid.items[1].cache_progress == 0,
    "a B summary must be rejected when both the current destination and shelf are A")
assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfB"))
assert(root_library:show_offline_shelf())
local root_b_grid = root_grid_ui.model
expect(root_b_grid.items[1].cache_progress == 0.5
    and root_library:update_offline_progress(root_b_progress) == true
    and root_grid_ui.last_progress.progress == 0.5,
    "the reopened B shelf must display and accept only B's real task progress")
assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfA"))
root_grid_ui.last_progress = nil
expect(root_library:update_offline_progress(root_b_progress) == false
    and root_grid_ui.last_progress == nil,
    "matching summary and shelf roots are insufficient when the current destination changed")
root_drain_until(function() return not root_manager:status().running end)
local root_b_canceled = root_summaries[#root_summaries]
expect(root_b_canceled.status == "canceled" and root_b_canceled.root == "/mnt/us/ShelfB",
    "cancellation after a destination switch must still report the original B task root")
assert(root_plugin.settings_ui:show_offline_cache(root_manga))
assert(captured_offline.on_start())
root_drain_until(function() return root_manager:status().downloaded == 1 end)
local root_a_progress = root_summaries[#root_summaries]
assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfB"))
assert(root_library:show_offline_shelf())
root_grid_ui.last_progress = nil
expect(root_library:update_offline_progress(root_a_progress) == false
    and root_grid_ui.last_progress == nil and root_grid_ui.model.items[1].cache_progress == 0.5,
    "a late A summary must never repaint a reopened B shelf for the same manga")
root_manager:cancel()
for _, ordinary_view in ipairs({ "category", "rating", "history" }) do
    assert(root_library:show_offline_shelf())
    if ordinary_view == "category" then root_library:show_category(root_plugin.library.ALL)
    elseif ordinary_view == "rating" then root_library:show_rating_category(1)
    else root_plugin.browser:show_history() end
    local ordinary_grid, ordinary_epoch = root_grid_ui.model, root_library.view_epoch
    root_grid_ui.last_progress = nil
    expect(root_library:update_offline_progress(root_b_progress) == false
        and root_grid_ui.last_progress == nil,
        "offline summaries must not repaint an ordinary " .. ordinary_view .. " view")
    assert(root_plugin.settings_ui:show_offline_cache(root_manga))
    assert(captured_offline.on_set_root("/mnt/us/" .. ordinary_view))
    expect(root_grid_ui.model == ordinary_grid and root_plugin.cover_grid.is_open
        and root_library.view_epoch == ordinary_epoch,
        "saving a destination must not close or invalidate an ordinary " .. ordinary_view .. " view")
    assert(root_plugin.settings:set_offline_root("/mnt/us/ShelfB"))
end
expect(#reporter.failures == 1
    and tostring(reporter.failures[1].error):find("destination write failed", 1, true),
    "the root lifecycle must not hide errors other than the deliberately failed settings write")

local auth_deps = {}
for key, value in pairs(plugin.webdavmanga_deps) do auth_deps[key] = value end
auth_deps.license = nil
auth_deps.license_transport = nil
auth_deps.ca_file = "/settings/webdavmanga-ca.crt"
auth_deps.license_settings_store = memory_store()
auth_deps.license_get_serial = function() return "runtime-license-device" end
auth_deps.sha256 = function(value)
    local byte = value == "runtime-license-device" and "a" or "b"
    return string.rep(byte, 64)
end
local auth_plugin = Plugin:new{
    path = "/plugin",
    ui = { menu = { registerToMainMenu = function() end } },
    webdavmanga_deps = auth_deps,
}
expect(type(auth_plugin.license.transport) == "table"
    and type(auth_plugin.license.transport.activate) == "function",
    "normal plugin startup must construct the production license transport")
expect(auth_plugin.license.endpoint == auth_plugin.license.transport.endpoint
    and type(auth_plugin.license.endpoint) == "string"
    and auth_plugin.license.endpoint:match("^https://"),
    "normal plugin startup must wire one HTTPS activation endpoint")
expect(auth_plugin.license.transport.ca_file == "./data/ca-bundle.crt",
    "a private WebDAV CA override must not replace the public activation CA bundle")
expect(auth_plugin.license_settings_store ~= plugin.settings_store
    and auth_plugin.license_settings_store ~= plugin.cache_store,
    "license receipt storage must remain independent from plugin and cache settings")

print(("rebuild_0355_main_wiring_spec: %d checks"):format(checks))
