local Async = require("webdavmanga.async")
local Browser = require("webdavmanga.ui_browser")
local Cache = require("webdavmanga.cache")
local Client = require("webdavmanga.client")
local Cover = require("webdavmanga.cover")
local CoverGrid = require("webdavmanga.ui_cover_grid")
local DataStorage = require("datastorage")
local Diagnostics = require("webdavmanga.format_diagnostics")
local DirectoryStore = require("webdavmanga.directory_store")
local DocumentBridge = require("webdavmanga.document_bridge")
local Dispatcher = require("dispatcher")
local ErrorReporter = require("webdavmanga.error_reporter")
local Library = require("webdavmanga.library")
local KeyboardCompat = require("webdavmanga.keyboard_compat")
local License = require("webdavmanga.license")
local LicenseConfig = require("webdavmanga.license_config")
local LicenseCrypto = require("webdavmanga.license_crypto")
local LicenseDevice = require("webdavmanga.license_device")
local LicenseRsa = require("webdavmanga.license_rsa")
local LicenseStore = require("webdavmanga.license_store")
local LicenseTransport = require("webdavmanga.license_transport")
local Lighting = require("webdavmanga.lighting")
local LocalClient = require("webdavmanga.local_client")
local Loader = require("webdavmanga.loader")
local MemoryPages = require("webdavmanga.memory_pages")
local MeguruPointer = require("webdavmanga.meguru_pointer")
local MeguruAssociation = require("webdavmanga.meguru_association")
local OpdsCatalog = require("webdavmanga.opds_catalog")
local OpdsClient = require("webdavmanga.opds_client")
local OpdsCover = require("webdavmanga.opds_cover")
local OpdsPages = require("webdavmanga.opds_pages")
local SeriesNavigation = require("webdavmanga.series_navigation")
local OpdsUi = require("webdavmanga.ui_opds")
local LocalArchive = require("webdavmanga.local_archive")
local LuaSettings = require("luasettings")
local MangaIdentity = require("webdavmanga.manga_identity")
local Progress = require("webdavmanga.progress")
local PremiumAccess = require("webdavmanga.premium_access")
local Reader = require("webdavmanga.ui_reader")
local PreparedPages = require("webdavmanga.prepared_pages")
local Settings = require("webdavmanga.settings")
local State = require("webdavmanga.state")
local Nodeshare = require("webdavmanga.nodeshare")
local OfflineCache = require("webdavmanga.offline_cache")
local OfflineManager = require("webdavmanga.offline_manager")
local Transport = require("webdavmanga.transport")
local UiLibrary = require("webdavmanga.ui_library")
local UiSettings = require("webdavmanga.ui_settings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local MB = 1024 * 1024
local VERSION = "0.4.11"
local CATALOG_MIGRATION_VERSION = 3

local WebDavManga = WidgetContainer:extend{
    name = "webdavmanga",
    is_doc_only = false,
}

local function connection_identity(connection)
    connection = connection or {}
    local kind = tostring(connection.kind or "webdav")
    local username = tostring(connection.username or ""):match("^%s*(.-)%s*$")
    return table.concat({ kind, tostring(connection.server_url or ""), username,
        tostring(connection.root_path or ""), tostring(connection.local_path or "") }, "\0")
end

local function file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

local function migrate_catalog_store(store)
    if not store or not store.readSetting or not store.saveSetting then return false end
    if store:readSetting("migration_version") == CATALOG_MIGRATION_VERSION then
        return false
    end
    store:saveSetting("catalogs", {})
    if store.flush then store:flush() end
    store:saveSetting("migration_version", CATALOG_MIGRATION_VERSION)
    if store.flush then store:flush() end
    return true
end

function WebDavManga:_guard(label, callback)
    if self.switching_connection or self.tearing_down or self.stopped then return nil end
    return self.error_reporter:guard(label, callback)
end

function WebDavManga:_report_silent(stage, error_value)
    local reporter = self.error_reporter
    if reporter and type(reporter.report) == "function" then
        pcall(reporter.report, reporter, stage, error_value, { silent = true })
    end
end

function WebDavManga:init()
    if self.initialized then return end
    self.initialized = true
    local deps = self.webdavmanga_deps or {}
    local settings_dir = DataStorage:getSettingsDir()
    local custom_ca_file = settings_dir .. "/webdavmanga-ca.crt"
    local default_ca_file = DataStorage:getDataDir() .. "/data/ca-bundle.crt"
    local ca_file = deps.ca_file
        or (file_exists(custom_ca_file) and custom_ca_file or default_ca_file)

    self.settings_store = deps.settings_store
        or LuaSettings:open(settings_dir .. "/webdavmanga.lua")
    self.cache_store = deps.cache_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-cache.lua")
    self.progress_store = deps.progress_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-progress.lua")
    self.opds_store = deps.opds_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-opds.lua")
    self.offline_store = deps.offline_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-offline.lua")
    self.license_settings_store = deps.license_settings_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-license.lua")
    self.license_store = deps.license_store or LicenseStore:new{
        settings = self.license_settings_store,
    }
    self.catalog_store = deps.catalog_store
    if not self.catalog_store then
        local catalog_path = settings_dir .. "/webdavmanga-catalog.lua"
        local catalog_backup_path = catalog_path .. ".old"
        local catalog_version = self.settings_store:readSetting("catalog_migration_version")
        local exists = deps.catalog_file_exists or file_exists
        local remove = deps.catalog_file_remove or os.remove
        local paths_to_remove = { catalog_backup_path }
        if catalog_version ~= CATALOG_MIGRATION_VERSION then
            paths_to_remove[#paths_to_remove + 1] = catalog_path
        end
        local removal_failed = false
        for _, path in ipairs(paths_to_remove) do
            if exists(path) then remove(path) end
            if exists(path) then removal_failed = true end
        end
        if removal_failed then
            error("WebDavManga legacy catalog migration could not remove catalog store")
        end
        self.catalog_store = LuaSettings:open(catalog_path)
        if catalog_version ~= CATALOG_MIGRATION_VERSION then
            self.catalog_store:saveSetting("catalogs", {})
            if self.catalog_store.flush then self.catalog_store:flush() end
            self.settings_store:saveSetting(
                "catalog_migration_version", CATALOG_MIGRATION_VERSION)
            if self.settings_store.flush then self.settings_store:flush() end
        end
    end
    self.library_store = deps.library_store
        or LuaSettings:open(settings_dir .. "/webdavmanga-library.lua")
    local pointer_root = DataStorage:getDataDir() .. "/webdavmanga-streams"
    self.settings = deps.settings or Settings:new{
        store = self.settings_store, default_opds_pointer_root = pointer_root,
    }

    local compat_device = deps.device
    if not compat_device then
        local ok, loaded_device = pcall(require, "device")
        if ok then compat_device = loaded_device end
    end
    self.license_device = deps.license_device or LicenseDevice:new{
        device = compat_device,
        store = self.license_settings_store,
        hash = deps.sha256,
        get_serial = deps.license_get_serial,
        random_bytes = deps.license_random_bytes,
    }
    local license_endpoint = deps.license_endpoint or LicenseConfig.endpoint
    local license_transport = deps.license_transport
    if not license_transport and not deps.license then
        license_transport = LicenseTransport:new{
            endpoint = license_endpoint,
            -- The WebDAV override may contain only a private NAS root. Public
            -- activation must keep KOReader's public trust bundle unless a
            -- dedicated license CA was explicitly injected for testing.
            ca_file = deps.license_ca_file or default_ca_file,
            request = deps.license_request,
        }
    end
    self.license = deps.license or License:new{
        store = self.license_store,
        crypto = deps.license_crypto or LicenseCrypto,
        device = self.license_device,
        transport = license_transport,
        product = deps.license_product or LicenseConfig.product,
        endpoint = license_endpoint,
        public_key = deps.license_public_key or {
            value = LicenseConfig.public_key,
            verifier = LicenseRsa,
        },
    }
    local compat_settings = deps.global_settings or rawget(_G, "G_reader_settings")
    local compat = deps.keyboard_compat or KeyboardCompat
    if compat and type(compat.ensure) == "function" then
        local ok, changed, reason = pcall(compat.ensure, {
            device = compat_device,
            global_settings = compat_settings,
            plugin_store = self.settings_store,
        })
        if not ok then
            if type(logger.warn) == "function" then
                logger.warn("WebDavManga: virtual keyboard compatibility repair failed:", changed)
            end
        elseif changed then
            if type(logger.info) == "function" then
                logger.info("WebDavManga: restored KOReader virtual keyboard for KPW6")
            end
        elseif type(logger.dbg) == "function" then
            logger.dbg("WebDavManga: virtual keyboard compatibility:", reason)
        end
    end
    self.lighting = deps.lighting or Lighting:new{ device = deps.device,
        powerd = deps.powerd }
    self.error_reporter = deps.error_reporter or ErrorReporter:new{
        logger = logger,
        ui = deps.settings_ui_adapter,
    }

    if deps.catalog_store then migrate_catalog_store(self.catalog_store) end

    local reader_settings = self.settings:get_reader()
    self.meguru_pointer = deps.meguru_pointer or MeguruPointer:new{
        root = reader_settings.opds_pointer_root or pointer_root,
        per_server = reader_settings.opds_pointer_per_server,
    }
    local browse_settings = type(self.settings.get_browse_cache) == "function"
        and self.settings:get_browse_cache() or {
            total_mb = 5120, trigger_mb = 3072, retain_mb = 1024,
            interval_minutes = 10,
        }
    local browse_total_bytes = (tonumber(browse_settings.total_mb) or 5120) * MB
    local browse_trigger_bytes = (tonumber(browse_settings.trigger_mb) or 3072) * MB
    local browse_retain_bytes = (tonumber(browse_settings.retain_mb) or 1024) * MB
    local browse_interval_seconds = (tonumber(browse_settings.interval_minutes) or 10) * 60
    local cover_limit_bytes = (tonumber(reader_settings.cover_cache_limit_mb) or 200) * MB
    self.cache = deps.cache or Cache:new{
        root = DataStorage:getDataDir() .. "/cache/webdavmanga",
        limit_bytes = browse_total_bytes,
        cover_limit_bytes = cover_limit_bytes,
        browse_total_bytes = browse_total_bytes,
        browse_trigger_bytes = browse_trigger_bytes,
        browse_retain_bytes = browse_retain_bytes,
        browse_check_interval_seconds = browse_interval_seconds,
        document_limit_bytes_provider = function()
            return self.settings:get_offline_limit_gb() * 1024 * 1024 * 1024
        end,
        store = self.cache_store,
        fs = deps.cache_fs,
        md5 = deps.md5,
        clock = deps.clock,
    }
    self.opds_cover = deps.opds_cover or OpdsCover:new{ cache = self.cache }
    if deps.cache and type(self.cache.set_browse_policy) == "function" then
        pcall(self.cache.set_browse_policy, self.cache, {
            total_bytes = browse_total_bytes,
            trigger_bytes = browse_trigger_bytes,
            retain_bytes = browse_retain_bytes,
            check_interval_seconds = browse_interval_seconds,
        })
    end
    if deps.cache and type(self.cache.set_cover_limit_bytes) == "function" then
        pcall(self.cache.set_cover_limit_bytes, self.cache, cover_limit_bytes)
    end
    if self.cache.migrate then
        self.cache:migrate(3)
    end
    self.cache:cleanup_parts(24 * 60 * 60)
    if type(self.cache.cleanup_stream) == "function" then
        pcall(self.cache.cleanup_stream, self.cache, false)
    elseif type(self.cache.cleanup_browse) == "function" then
        pcall(self.cache.cleanup_browse, self.cache, false)
    end

    local progress_scheduler = deps.scheduler
    if not progress_scheduler then
        local scheduler_ok, scheduler_module = pcall(require, "ui/uimanager")
        progress_scheduler = scheduler_ok and scheduler_module or nil
    end
    self.browse_cleanup_scheduler = progress_scheduler
    local function schedule_browse_cleanup()
        if not self.browse_cleanup_scheduler
            or type(self.browse_cleanup_scheduler.scheduleIn) ~= "function"
            or self.stopped or self.tearing_down then
            return false
        end
        local policy = type(self.cache.browse_policy) == "function"
            and self.cache:browse_policy() or {}
        local delay = tonumber(policy.check_interval_seconds)
            or browse_interval_seconds
        local task
        task = function()
            if self.browse_cleanup_task ~= task then return end
            self.browse_cleanup_task = nil
            if self.stopped or self.tearing_down then return end
            if type(self.cache.cleanup_stream) == "function" then
                pcall(self.cache.cleanup_stream, self.cache, false)
            elseif type(self.cache.cleanup_browse) == "function" then
                pcall(self.cache.cleanup_browse, self.cache, false)
            end
            schedule_browse_cleanup()
        end
        self.browse_cleanup_task = task
        local ok, result = pcall(self.browse_cleanup_scheduler.scheduleIn,
            self.browse_cleanup_scheduler, delay, task)
        if not ok or result == false then
            self.browse_cleanup_task = nil
            self:_report_silent("schedule browse cache maintenance", result)
            return false
        end
        return true
    end
    self.schedule_browse_cleanup = schedule_browse_cleanup
    schedule_browse_cleanup()
    self.progress = deps.progress or Progress:new{
        store = self.progress_store,
        md5 = deps.md5,
        scheduler = progress_scheduler,
    }
    self.library = deps.library or Library:new{
        store = self.library_store,
        md5 = deps.md5,
        clock = deps.clock,
    }
    local archive_data_root = DataStorage:getDataDir()
    if tostring(archive_data_root):sub(1, 1) ~= "/"
        and type(DataStorage.getFullDataDir) == "function" then
        archive_data_root = DataStorage:getFullDataDir()
    end
    self.local_archive = deps.local_archive or LocalArchive:new{
        root = tostring(archive_data_root) .. "/webdavmanga-archive/covers",
        library = self.library,
        lfs = deps.local_archive_lfs,
        make_path = deps.local_archive_make_path,
        open_file = deps.local_archive_open_file,
        remove_file = deps.local_archive_remove_file,
        rename_file = deps.local_archive_rename_file,
        file_size = deps.local_archive_file_size,
        image_probe = deps.local_archive_image_probe,
        md5 = deps.md5,
    }
    self.state = deps.state or State:new()
    self.transport = deps.transport
    if not self.transport and not deps.client_factory then
        self.transport = Transport:new{
            ca_file = ca_file,
        }
    end
    self.opds_catalog = deps.opds_catalog
    if not self.opds_catalog and self.transport then
        self.opds_catalog = OpdsCatalog:new{
            settings = self.settings,
            legacy_store = self.opds_store,
            client_factory = function()
                return OpdsClient:new{ transport = self.transport }
            end,
        }
        local migrated, migration_error = self.opds_catalog:migrate_legacy_once()
        if not migrated then error("OPDS source migration failed: " .. tostring(migration_error)) end
    end
    self.opds_pages = deps.opds_pages
    if not self.opds_pages and self.transport and self.opds_catalog then
        self.opds_pages = OpdsPages:new{
            transport = self.transport,
            transfer = deps.opds_memory_transfer or deps.memory_transfer,
            renderer = deps.render_image,
            scheduler = progress_scheduler,
            cover_store = self.opds_cover,
            progress_store = self.progress,
            cover_enabled = function() return self.settings:get_reader().opds_cover_enabled ~= false end,
            source_provider = function(source_id) return self.opds_catalog:get(source_id) end,
            auth_provider = function(source_id)
                local source = source_id and self.opds_catalog:get(source_id)
                return source and {
                    username = source.username, password = source.password,
                } or {}
            end,
        }
    end
    -- NodeShare supplies only a TCP reachability check. WebDAV requests still
    -- use the normal client and transport without modifying their payloads.
    self.nodeshare = deps.nodeshare
    if not self.nodeshare and self.transport then
        self.nodeshare = Nodeshare:new{ socket = self.transport.socket }
    end

    local function create_client(connection)
        if deps.client_factory then return deps.client_factory(connection) end
        connection = connection or self.settings:get_connection()
        if connection.kind == "local" then
            return LocalClient:new{ connection = connection, md5 = deps.md5 }
        end
        return Client:new{
            connection = connection,
            transport = self.transport,
            range_download = self.settings:get_reader().range_streaming_enabled ~= false,
        }
    end
    self.client_factory = create_client

    -- Declare these before constructing callbacks that close over them.  Lua
    -- resolves locals lexically, so declaring them later would make the
    -- earlier callbacks read accidental globals instead of the initialized UI.
    local browser
    local library_ui

    local active_identity = connection_identity(self.settings:get_connection())
    self.directory_store = deps.directory_store or DirectoryStore:new{
        client_factory = function()
            return create_client(self.settings:get_connection())
        end,
        cache = self.cache,
        async = deps.async or Async,
        identity = active_identity,
        md5 = deps.md5,
        error_reporter = self.error_reporter,
    }

    self.offline_cache = deps.offline_cache or OfflineCache:new{
        store = self.offline_store,
        root_provider = function() return self.settings:get_offline_root() end,
        limit_bytes_provider = function()
            return self.settings:get_offline_limit_gb() * 1024 * 1024 * 1024
        end,
        external_bytes_provider = function()
            if self.cache and type(self.cache.kind_size) == "function" then
                return self.cache:kind_size("document")
            end
            return 0
        end,
        fs = deps.offline_fs,
        disk_usage = deps.offline_disk_usage,
        md5 = deps.md5,
        reserve_bytes = deps.offline_reserve_bytes,
    }
    self.premium_access = deps.premium_access or PremiumAccess:new{
        identity = deps.manga_identity or MangaIdentity,
        license = self.license,
        progress = self.progress,
        library = self.library,
        offline_cache = self.offline_cache,
        document_cache = self.cache,
        connection_provider = function() return self.settings:get_connection() end,
    }
    self.offline_manager = deps.offline_manager or OfflineManager:new{
        directory_store = self.directory_store,
        offline_cache = self.offline_cache,
        client_factory = function(connection) return create_client(connection) end,
        connection_provider = function() return self.settings:get_connection() end,
        identity_provider = function()
            return connection_identity(self.settings:get_connection())
        end,
        denoise_enabled_provider = function() return false end,
        async = deps.async or Async,
        scheduler = progress_scheduler,
        on_status = function(summary)
            if library_ui then library_ui.offline_latest_summary = summary end
        end,
    }

    self.loader = deps.loader or Loader:new{
        archive_pages = deps.archive_pages,
        mupdf_pages = deps.mupdf_pages,
        client_factory = function(connection)
            return create_client(connection or self.settings:get_connection())
        end,
        cache = self.cache,
        async = deps.async or Async,
        identity = active_identity,
        source_kind_provider = function()
            local connection = self.settings:get_connection()
            return connection and connection.kind
        end,
        prefetch_count = reader_settings.prefetch_count,
        prefetch_first_pages = reader_settings.prefetch_first_pages,
        prefetch_near_count = reader_settings.prefetch_near_count,
        prefetch_far_count = reader_settings.prefetch_far_count,
        prefetch_concurrency = reader_settings.prefetch_concurrency,
        error_reporter = self.error_reporter,
        offline_path_validator = function(image)
            return self.offline_cache:owns_local_path(
                connection_identity(self.settings:get_connection()), image.path, image.local_path)
        end,
    }
    self.prepared_pages = deps.prepared_pages or PreparedPages:new{
        loader = self.loader,
        cache = self.cache,
        async = deps.async or Async,
    }
    self.memory_pages = deps.memory_pages or MemoryPages:new{
        client_factory = create_client,
        connection_provider = function() return self.settings:get_connection() end,
        renderer = deps.render_image,
        scheduler = progress_scheduler,
        transfer = deps.memory_transfer,
    }

    self.document_bridge = deps.document_bridge or DocumentBridge:new{
        cache = self.cache,
        archive_pages = deps.archive_pages,
        mupdf_pages = deps.mupdf_pages,
        pdf_image_stream = deps.pdf_image_stream,
        async = deps.async or Async,
        ui_manager = deps.document_ui_manager,
        scheduler = progress_scheduler,
        error_reporter = self.error_reporter,
        logger = logger,
        identity_provider = function(entry)
            return connection_identity(entry and entry.connection
                or self.settings:get_connection())
        end,
        connection_provider = function() return self.settings:get_connection() end,
        streaming_enabled_provider = function()
            return self.settings:get_reader().range_streaming_enabled ~= false
        end,
        can_store_document = function(bytes)
            if self.offline_cache and type(self.offline_cache.can_store) == "function" then
                return self.offline_cache:can_store(bytes)
            end
            return true
        end,
        open_reader = function(context)
            local connection = context.connection or self.settings:get_connection()
            SeriesNavigation.local_context(context, connection, function(directory)
                local client = create_client(connection)
                local entries = {}
                if type(client._produce_entries) ~= "function" then return entries end
                client:_produce_entries(directory, function(entry)
                    entry.path = entry.path or entry.full_path
                    entries[#entries + 1] = entry
                    return true
                end)
                return entries
            end, function(entry)
                entry.connection = connection
                local opened = self.document_bridge:open(entry, {
                    on_closed = context.source_context and context.source_context.on_return,
                })
                return opened ~= false and opened ~= nil
            end)
            return self.reader:open(context)
        end,
        client_factory = function(connection) return create_client(connection) end,
    }

    self.cover = deps.cover_service or deps.cover or Cover:new{
        library = self.library,
        directory_store = self.directory_store,
        error_reporter = self.error_reporter,
    }
    self.cover_service = self.cover
    self.cover_grid = deps.cover_grid or CoverGrid:new{
        cover_service = self.cover,
        loader = self.loader,
        cache = self.cache,
        connection_provider = function() return self.settings:get_connection() end,
        settings = self.settings,
        render_image = deps.render_image,
        open_history = function()
            if browser and type(browser.show_history) == "function" then
                return browser:show_history()
            end
            return false
        end,
        open_category_shelf = function()
            if library_ui and type(library_ui.show_home) == "function" then
                return library_ui:show_home()
            end
            return false
        end,
        scheduler = deps.scheduler,
        ui = deps.cover_grid_ui_adapter,
        error_reporter = self.error_reporter,
        render_document_cover = deps.render_document_cover,
    }
    self.diagnostics = deps.diagnostics or Diagnostics:new{
        sample_root = self.path .. "/resources/format_samples",
        samples = deps.diagnostics_samples,
        decoder = deps.diagnostics_decoder,
    }

    self.settings_ui = deps.settings_ui or UiSettings:new{
        settings = self.settings,
        open_source_shelf = function() return self:onShowWebDavManga() end,
        license = self.license,
        client_factory = create_client,
        opds_client_factory = function()
            return OpdsClient:new{ transport = self.transport }
        end,
        async = deps.async or Async,
        ui = deps.settings_ui_adapter,
        cache = self.cache,
        offline_cache = self.offline_cache,
        offline_manager = self.offline_manager,
        on_offline_root_saved = function()
            if library_ui then library_ui:invalidate_offline_shelf() end
        end,
        identity_provider = function()
            return connection_identity(self.settings:get_connection())
        end,
        lighting = self.lighting,
        nodeshare = self.nodeshare,
        scheduler = deps.scheduler,
        network_manager = deps.network_manager,
        error_reporter = self.error_reporter,
        render_image = deps.render_image,
        open_history = function()
            if browser and type(browser.show_history) == "function" then
                return browser:show_history()
            end
            return false
        end,
        open_category_shelf = function()
            if library_ui and type(library_ui.show_home) == "function" then
                return library_ui:show_home()
            end
            return false
        end,
        close_reader_controls = function()
            -- Reader controls and filter dialogs live in separate UI stacks.
            -- Close the plugin-owned stack first so the emergency X button
            -- cannot leave a settings window covering the manga page.
            if self.settings_ui and type(self.settings_ui.close_all) == "function" then
                self.settings_ui:close_all()
            end
            if self.reader and type(self.reader.close_controls) == "function" then
                return self.reader:close_controls()
            end
            return false
        end,
        on_connection_saved = function()
            if self.switching_connection or self.tearing_down or self.stopped then return end
            self.switching_connection = true
            local failures = {}
            local function cancel(label, callback)
                local ok = self.error_reporter:guard("connection switch " .. label, function()
                    callback()
                    return true
                end, false, nil, { silent = true })
                if ok then return end
                failures[#failures + 1] = label
            end
            cancel("browser", function()
                if browser then browser:cancel() end
            end)
            cancel("opds", function() if self.opds_ui and self.opds_ui.cancel then self.opds_ui:cancel() end end)
            cancel("library ui", function()
                if library_ui and library_ui.cancel then library_ui:cancel(false) end
            end)
            cancel("cover", function() self.cover:cancel_all() end)
            cancel("cover grid", function() self.cover_grid:cancel() end)
            cancel("reader", function() self.reader:force_close("connection_switch") end)
            cancel("offline manager", function() self.offline_manager:cancel_all() end)
            cancel("loader", function() self.loader:cancel_all() end)
            cancel("document bridge", function() self.document_bridge:cancel_all() end)
            cancel("directory store", function() self.directory_store:cancel_all() end)
            cancel("browser reset", function()
                if browser and browser.reset_session then browser:reset_session() end
            end)
            if #failures > 0 then
                self:_teardown(true, "connection switch failure")
                error("WebDavManga connection switch failed: " .. table.concat(failures, ","))
            end
            local new_identity = connection_identity(self.settings:get_connection())
            self.loader.identity = new_identity
            self.directory_store.identity = new_identity
            self.switching_connection = false
        end,
        on_reader_saved = function(values)
            if self.switching_connection or self.tearing_down or self.stopped then return end
            self.meguru_pointer.root = values.opds_pointer_root or self.meguru_pointer.root
            self.meguru_pointer.per_server = values.opds_pointer_per_server ~= false
            self.loader.prefetch_count = values.prefetch_count
            self.loader.prefetch_first_pages = values.prefetch_first_pages
            self.loader.prefetch_near_count = values.prefetch_near_count
            self.loader.prefetch_far_count = values.prefetch_far_count
            self.loader.prefetch_concurrency = math.max(1, math.min(3,
                math.floor(tonumber(values.prefetch_concurrency) or 2)))
            if self.cache and type(self.cache.set_cover_limit_bytes) == "function" then
                pcall(self.cache.set_cover_limit_bytes, self.cache,
                    (tonumber(values.cover_cache_limit_mb) or 200) * MB)
            end
            if self.reader and type(self.reader.reload_settings) == "function" then
                self.reader:reload_settings(values)
            end
        end,
    }
    local function request_license(continuation)
        local resumed = false
        return self.settings_ui:show_license{
            on_result = function(ok, result)
                if ok and not resumed then
                    resumed = true
                    if continuation then return continuation() end
                end
                return ok, result
            end,
        }
    end

    self.reader = deps.reader or Reader:new{
        loader = self.loader,
        prepared_pages = self.prepared_pages,
        memory_pages = self.memory_pages,
        opds_pages = self.opds_pages,
        panel_source = deps.panel_source or {
            open = function(source, generation, request, callbacks)
                if not source.impl then
                    source.impl = require("webdavmanga.panel_source"):new{}
                end
                return source.impl:open(generation, request, callbacks)
            end,
        },
        panel_detector = deps.panel_detector or {
            detect = function(...) return require("webdavmanga.panel_detector").detect(...) end,
            sort = function(...) return require("webdavmanga.panel_detector").sort(...) end,
        },
        panel_session_factory = deps.panel_session_factory,
        progress = self.progress,
        state = self.state,
        settings = self.settings,
        cache = self.cache,
        ui = deps.reader_ui_adapter,
        error_reporter = self.error_reporter,
        show_gray_settings = function()
            return self.settings_ui:show_gray_settings()
        end,
        show_tone_settings = function()
            return self.settings_ui:show_tone_settings()
        end,
        show_kopt_sample_path = function(on_saved)
            return self.settings_ui:show_kopt_sample_path(on_saved)
        end,
        show_kopt_preview = function()
            return self.settings_ui:show_kopt_preview()
        end,
        open_chapter = function(manga, chapter) browser:open_chapter(manga, chapter) end,
        return_to_root = function()
            if browser and browser.show_library then return browser:show_library() end
            return true
        end,
        show_light_settings = function()
            return self.settings_ui:show_light()
        end,
        show_network_settings = function()
            return self.settings_ui:show_reader("network")
        end,
        show_koreader_menu = function()
            local host_menu = self.ui and self.ui.menu
            if host_menu and type(host_menu.onShowMenu) == "function" then
                return host_menu:onShowMenu()
            end
            return false
        end,
        open_history = function()
            if browser and type(browser.show_history) == "function" then
                return browser:show_history()
            end
            return false
        end,
        open_category_shelf = function()
            if library_ui and type(library_ui.show_home) == "function" then
                return library_ui:show_home()
            end
            return false
        end,
    }
    if self.opds_catalog and not deps.opds_ui then
        self.opds_ui = OpdsUi:new{
            catalog = self.opds_catalog,
            network_manager = deps.network_manager,
            logger = logger,
            async = deps.async or Async,
            client_factory = function(entry)
                return OpdsClient:new{ transport = self.transport }
            end,
            reader = self.reader,
            ui = deps.opds_ui_adapter,
            pointer = self.meguru_pointer,
            library = self.library,
            progress = self.progress,
            pages = self.opds_pages,
            open_category_shelf = function(options)
                if library_ui and type(library_ui.show_home) == "function" then
                    return library_ui:show_home(options)
                end
                return false
            end,
        }
    else
        self.opds_ui = deps.opds_ui
    end
    local cache_manga = function(manga)
        return self.settings_ui:show_offline_cache(manga)
    end
    local cache_document = function(entry, callbacks)
        return self.document_bridge:cache_document(entry, callbacks)
    end
    browser = deps.browser or Browser:new{
        settings = self.settings,
        settings_ui = self.settings_ui,
        directory_store = self.directory_store,
        ui = deps.browser_ui_adapter,
        network_manager = deps.network_manager,
        catalog_store = self.catalog_store,
        progress = self.progress,
        library = self.library,
        cover_grid = self.cover_grid,
        document_cache = self.cache,
        opds_cover = self.opds_cover,
        open_category_shelf = function()
            return library_ui:show_home{ reset_source = true }
        end,
        open_rating_shelf = function()
            return library_ui:show_rating_home{ reset_source = true }
        end,
        open_offline_shelf = function(options)
            options = options or {}
            options.reset_source = true
            return library_ui:show_offline_shelf(options)
        end,
        manage_history = function(record) return library_ui:show_history_manage(record) end,
        manage_history_batch = function(records) return library_ui:show_history_batch(records) end,
        cache_manga = cache_manga,
        open_opds_record = function(record, on_return)
            if self.opds_ui and type(self.opds_ui.open_record) == "function" then
                return self.opds_ui:open_record(record, on_return)
            end
            return false
        end,
        cache_document = cache_document,
        premium_access = self.premium_access,
        request_license = request_license,
        open_reader = function(context) self.reader:open(context) end,
        open_document = function(entry, callbacks)
            return self.document_bridge:open(entry, callbacks)
        end,
        error_reporter = self.error_reporter,
    }
    self.browser = browser
    library_ui = deps.library_ui or UiLibrary:new{
        settings = self.settings,
        library = self.library,
        progress = self.progress,
        cover_service = self.cover,
        cover_grid = self.cover_grid,
        browser = self.browser,
        ui = deps.library_ui_adapter,
        error_reporter = self.error_reporter,
        local_archive = self.local_archive,
        cache_manga = cache_manga,
        opds_cover = self.opds_cover,
        offline_cache = self.offline_cache,
        offline_manager = self.offline_manager,
        scheduler = progress_scheduler,
        identity_provider = function()
            return connection_identity(self.settings:get_connection())
        end,
        show_offline_cache = cache_manga,
        open_cached_reader = function(context) self.reader:open(context) end,
        document_cache = self.cache,
        premium_access = self.premium_access,
        request_license = request_license,
        document_bridge = self.document_bridge,
        open_cached_document = function(entry, callbacks)
            return self.document_bridge:open(entry, callbacks)
        end,
        open_opds_record = function(record, on_return)
            if self.opds_ui and type(self.opds_ui.open_record) == "function" then
                return self.opds_ui:open_record(record, on_return)
            end
            return false
        end,
    }
    self.library_ui = library_ui
    if not self.error_reporter.ui and self.settings_ui and self.settings_ui.ui then
        self.error_reporter.ui = self.settings_ui.ui
    end

    Dispatcher:registerAction("show_webdav_manga", {
        category = "none",
        event = "ShowWebDavManga",
        title = "WebDAV 漫画",
        general = true,
    })
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    local installed, result = pcall(MeguruAssociation.install, {
        open_pointer = function(path, on_first_page) return self:open_pointer(path, on_first_page) end,
        document_registry = deps.document_registry,
        reader_ui = deps.reader_ui,
        read_history = deps.read_history,
    })
    if not installed or not result then
        logger.warn("WebDAV Manga: pointer association unavailable")
    end
end

function WebDavManga:open_pointer(path, on_first_page)
    local descriptor, err = self.meguru_pointer:load(path)
    if not descriptor then return nil, err end
    local source = self.settings:get_source(descriptor.source_id)
    if not source or source.kind ~= "opds" then
        if self.opds_ui and type(self.opds_ui.show_missing_source) == "function" then
            self.opds_ui:show_missing_source(descriptor, { pointer_path = path })
        end
        return nil, "missing_source"
    end
    if not self.opds_ui or type(self.opds_ui.open_descriptor) ~= "function" then
        return nil, "reader_unavailable"
    end
    -- The existing OPDS UI owns source credential restoration and the one Reader.
    return self.opds_ui:open_descriptor(descriptor, source, { pointer_path = path, on_first_page = on_first_page })
end

function WebDavManga:onShowWebDavManga()
    return self:_guard("show library", function()
        if self.opds_ui and self.settings:get_connection().kind == "opds" then
            if self.browser.cancel then self.browser:cancel() end
            return self.opds_ui:show_home()
        end
        if self.opds_ui and self.opds_ui.cancel then self.opds_ui:cancel() end
        return self.browser:show_library()
    end)
end

function WebDavManga:addToMainMenu(menu_items)
    menu_items.webdavmanga = {
        text = "WebDAV 漫画",
        sub_item_table_func = function()
            return self:_guard("build main menu", function() return {
                {
                    text = "漫画书架",
                    callback = function() self:onShowWebDavManga() end,
                },
                {
                    text = "阅读历史",
                    callback = function()
                        self:_guard("reading history", function()
                            self.browser:show_history()
                        end)
                    end,
                },
                {
                    text = "缓存漫画",
                    callback = function()
                        self:_guard("offline manga shelf", function()
                            self.library_ui:show_offline_shelf()
                        end)
                    end,
                },
                {
                    text = "漫画分类架",
                    callback = function()
                        self:_guard("category shelf", function()
                            self.library_ui:show_home()
                        end)
                    end,
                },
                {
                    text = "漫画评分架",
                    callback = function()
                        self:_guard("rating shelf", function()
                            self.library_ui:show_rating_home()
                        end)
                    end,
                },
                {
                    text = "连接设置",
                    callback = function()
                        self:_guard("connection settings", function()
                            self.settings_ui:show_connection()
                        end)
                    end,
                },
                {
                    text = "阅读设置",
                    callback = function()
                        self:_guard("reader settings", function() self.settings_ui:show_reader() end)
                    end,
                },
                {
                    text = "前光与色温",
                    callback = function()
                        self:_guard("frontlight settings", function() self.settings_ui:show_light() end)
                    end,
                },
                {
                    text = "缓存管理",
                    callback = function()
                        self:_guard("cache settings", function() self.settings_ui:show_cache() end)
                    end,
                },
                {
                    text = "关于",
                    callback = function()
                        self:_guard("about", function()
                            self.settings_ui:show_about(VERSION, self.diagnostics)
                        end)
                    end,
                },
            } end) or {}
        end,
    }
end

function WebDavManga:_flush_stores()
    local failures = {}
    local flushers = {
        { "settings", function()
            if self.settings and self.settings.flush then self.settings:flush() end
        end },
        { "cache", function()
            if self.cache_store and self.cache_store.flush then self.cache_store:flush() end
        end },
        { "progress", function()
            if self.progress and type(self.progress.flush) == "function" then
                local ok, err = self.progress:flush()
                if ok == false then error(err or "progress flush failed") end
            elseif self.progress_store and self.progress_store.flush then
                self.progress_store:flush()
            end
        end },
        { "offline", function()
            if self.offline_store and self.offline_store.flush then
                self.offline_store:flush()
            end
        end },
        { "license", function()
            if self.license_settings_store and self.license_settings_store.flush then
                self.license_settings_store:flush()
            end
        end },
        { "catalog", function()
            if self.catalog_store and self.catalog_store.flush then self.catalog_store:flush() end
        end },
        { "library", function()
            if self.library_store and self.library_store.flush then self.library_store:flush() end
        end },
    }
    for _, entry in ipairs(flushers) do
        local label, flush = entry[1], entry[2]
        local ok = self.error_reporter:guard("flush " .. label, function()
            flush()
            return true
        end, false, nil, { silent = true })
        if not ok then
            failures[#failures + 1] = label
        end
    end
    return #failures == 0, failures
end

function WebDavManga:onFlushSettings()
    local called, ok, failures = pcall(self._flush_stores, self)
    if called and ok then return true end
    local detail = called and table.concat(failures or {}, ",") or ok
    self:_report_silent("flush settings", detail)
    return true
end

function WebDavManga:_teardown(force, source)
    if self.stopped then return true end
    if self.teardown_running then return false end
    if self.tearing_down and not force then return false end
    self.tearing_down = true
    self.teardown_running = true
    local failures = {}
    local function stop(label, callback)
        local called = self.error_reporter:guard("teardown " .. label, function()
            callback()
            return true
        end, false, nil, { silent = true })
        if called then return end
        failures[#failures + 1] = label
    end
    stop("cancel browse cache maintenance", function()
        local scheduler = self.browse_cleanup_scheduler
        local task = self.browse_cleanup_task
        self.browse_cleanup_task = nil
        if scheduler and task and type(scheduler.unschedule) == "function" then
            scheduler:unschedule(task)
        end
    end)
    stop("close settings dialogs", function()
        if self.settings_ui and self.settings_ui.close_all then self.settings_ui:close_all() end
    end)
    stop("close reader", function()
        if self.reader then self.reader:force_close("plugin_teardown") end
    end)
    stop("cancel browser", function()
        if self.browser then self.browser:cancel() end
    end)
    stop("close browser menu", function()
        if self.browser and self.browser.close_menu then self.browser:close_menu() end
    end)
    stop("cancel library ui", function()
        if self.library_ui and self.library_ui.cancel then self.library_ui:cancel(false) end
    end)
    stop("cancel cover service", function()
        if self.cover then self.cover:cancel_all() end
    end)
    stop("cancel cover grid", function()
        if self.cover_grid then self.cover_grid:cancel() end
    end)
    stop("cancel loader", function()
        if self.loader then self.loader:cancel_all() end
    end)
    stop("cancel memory pages", function()
        if self.memory_pages then self.memory_pages:cancel_all() end
    end)
    stop("cancel OPDS pages", function()
        if self.opds_pages then self.opds_pages:cancel_all() end
    end)
    stop("cancel OPDS catalog", function()
        if self.opds_ui and self.opds_ui.cancel then self.opds_ui:cancel() end
    end)
    stop("cancel offline manager", function()
        if self.offline_manager then self.offline_manager:cancel_all() end
    end)
    stop("cancel directory store", function()
        if self.directory_store then self.directory_store:cancel_all() end
    end)
    stop("cancel document bridge", function()
        if self.document_bridge then self.document_bridge:cancel_all() end
    end)
    local stores_called, stores_ok, store_failures = pcall(self._flush_stores, self)
    if not stores_called then
        failures[#failures + 1] = "flush stores"
    elseif not stores_ok then
        for _, label in ipairs(store_failures) do failures[#failures + 1] = "flush " .. label end
    end
    self.teardown_running = false
    self.stopped = true
    self.tearing_down = false
    if #failures > 0 then
        self:_report_silent("plugin teardown", table.concat(failures, ","))
        return false
    end
    return true
end

function WebDavManga:stopPlugin(force)
    local called, result = pcall(self._teardown, self, force == true, "stopPlugin")
    if not called then
        self.teardown_running = false
        self.tearing_down = false
        self.stopped = true
        self:_report_silent("plugin teardown", result)
    end
    return true
end

function WebDavManga:onShowingReader()
    return self:stopPlugin(true)
end

function WebDavManga:onCloseDocument()
    return self:stopPlugin(true)
end

function WebDavManga:onExit()
    return self:stopPlugin(true)
end

return WebDavManga
