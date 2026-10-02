local Progress = require("webdavmanga.progress")
local Library = require("webdavmanga.library")
local OfflineCache = require("webdavmanga.offline_cache")
local Cache = require("webdavmanga.cache")
local Identity = require("webdavmanga.manga_identity")
local DocumentBridge = require("webdavmanga.document_bridge")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function store(values)
    local object = { values = values or {}, flushes = 0 }
    function object:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function object:saveSetting(key, value) self.values[key] = value end
    function object:flush() self.flushes = self.flushes + 1; return true end
    return object
end

local webdav = { kind = "webdav", server_url = "https://nas/dav", username = "u", root_path = "/A" }
local local_dir = { kind = "local", server_url = "local://", root_path = "/mnt/us/Comics", local_path = "/mnt/us/Comics" }
local manga = { name = "Book", path = "/A/Book" }

local progress_store = store({ history = {
    legacy = { connection = { server_url = webdav.server_url, username = webdav.username,
        root_path = webdav.root_path }, manga = manga,
        chapter = { name = "c1", path = "/A/Book/c1" }, image_path = "/A/Book/c1/1.jpg" },
} })
local progress = Progress:new{ store = progress_store, md5 = function(value) return value end }
local history = progress:list_all_history()
expect(#history == 1 and history[1].connection.kind == "webdav",
    "old history without kind must read as WebDAV")
expect(type(history[1].identity) == "string", "history enumeration must expose identity")

local library_store = store({ library = { schema_version = 2, connections = {
    legacy = { connection = { server_url = webdav.server_url, username = "u", root_path = "/A" },
        categories = {}, mangas = {
            old = { key = "old", manga = manga, category_ids = {}, is_read = true },
        }, covers = {} },
} } })
local library = Library:new{ store = library_store, md5 = function(value) return value end }
local all_library = library:list_all_mangas()
expect(#all_library == 1 and all_library[1].connection.kind == "webdav",
    "library enumeration must preserve old WebDAV records")
expect(all_library[1].identity == Identity.manga(webdav, manga.path),
    "library enumeration must expose normalized identity")

local collision_store = store({ library = { schema_version = 2, connections = {
    first = { connection = { server_url = "https://nas/dav", username = "u", root_path = "/A" },
        categories = { c1 = { id = "c1", name = "分类一" } }, mangas = {
            m1 = { key = "m1", manga = { name = "Book 1", path = "/A/Book1" }, category_ids = { c1 = true } },
        }, covers = {
            m1 = { manga_path = "/A/Book1", image = { name = "cover1.jpg", path = "/A/Book1/cover1.jpg" } },
        } },
    second = { connection = { server_url = "https://nas/dav/", username = " u ", root_path = "/A/" },
        categories = { c2 = { id = "c2", name = "分类二" } }, mangas = {
            m2 = { key = "m2", manga = { name = "Book 2", path = "/A/Book2" }, category_ids = { c2 = true } },
        }, covers = {
            m2 = { manga_path = "/A/Book2", image = { name = "cover2.jpg", path = "/A/Book2/cover2.jpg" } },
        } },
} } })
local collision_library = Library:new{ store = collision_store, md5 = function(value) return value end }
local collision_mangas = collision_library:list_all_mangas()
expect(#collision_mangas == 2, "library migration must merge colliding buckets without losing mangas")
expect(collision_mangas[1].connection ~= collision_mangas[2].connection,
    "library enumeration records must own independent connection copies")
expect(#collision_library:list_categories(webdav) == 2,
    "library migration must merge colliding categories")
expect(collision_library:get_cover(webdav, "/A/Book1") ~= nil
    and collision_library:get_cover(webdav, "/A/Book2") ~= nil,
    "library migration must merge colliding covers")

local offline_store = store({ entries = {}, jobs = {
    job = { schema_version = 2, key = "job", identity = Identity.connection(webdav),
        manga_path = "/A/Book", manga_name = "Book", status = "queued", total_pages = 2 },
} })
local offline = OfflineCache:new{
    store = offline_store, root_provider = function() return "/mnt/us/Offline" end,
    fs = { make_path = function() return true end, exists = function() return true end },
    md5 = function(value) return value end,
}
local all_offline = offline:list_all_mangas()
expect(#all_offline == 1 and all_offline[1].identity == Identity.manga(webdav, "/A/Book"),
    "offline enumeration must expose manga identity")
expect(all_offline[1].cached_pages == 0 and all_offline[1].total_pages == 2,
    "offline enumeration must include page totals")

local cache_store = store({ schema_version = 3, entries = {
    doc = { key = "doc", kind = "document", remote_path = "/A/Book.cbz",
        path = "/cache/doc.cbz", size = 1, extension = "cbz", validated = true, atime = 1,
        identity = Identity.connection(webdav) },
    legacy_doc = { key = "legacy_doc", kind = "document", remote_path = "/A/Book.cbz",
        path = "/cache/legacy_doc.cbz", size = 1, extension = "cbz", validated = true, atime = 1 },
} })
local cache = Cache:new{
    root = "/cache", limit_bytes = 100,
    store = cache_store,
    fs = { make_path = function() return true end, exists = function() return true end,
        size = function() return 1 end, remove = function() return true end,
        list = function() return {} end },
    md5 = function(value) return value end,
}
local documents = cache:list_all_documents()
expect(#documents == 2, "cache enumeration must include legacy and current documents")
expect(documents[1].identity ~= documents[2].identity,
    "legacy cache identity must not deduplicate with a real connection")
expect((documents[1].identity == Identity.manga(webdav, "/A/Book.cbz")
    or documents[2].identity == Identity.manga(webdav, "/A/Book.cbz")),
    "cache enumeration must expose document identity")
for _, document in ipairs(documents) do
    if document.identity ~= Identity.manga(webdav, "/A/Book.cbz") then
        expect(document.identity:sub(1, 1) ~= "\0",
            "legacy cache identity must use an opaque namespace, not an empty prefix")
    end
end
local real_document
for _, document in ipairs(documents) do
    if document.identity == Identity.manga(webdav, "/A/Book.cbz") then real_document = document end
end
expect(real_document and real_document.remote_path == "/A/Book.cbz"
    and real_document.local_path == "/cache/doc.cbz",
    "cache enumeration must include remote and local paths")

local published_identity
local bridge = DocumentBridge:new{
    cache = {
        key_for = function() return "doc-key" end,
        paths_for = function() return "/cache/doc.cbz", "/cache/doc.part" end,
        lookup_record = function() return nil end,
        discard_part = function() return true end,
        publish = function(_, record) published_identity = record.identity; return "/cache/doc.cbz" end,
    },
    client_factory = function()
        return { download_document = function() return {
            size = 1, format = "cbz", etag = "e", modified = "m",
        } end }
    end,
    identity_provider = function() return Identity.connection(webdav) end,
    connection_provider = function() return webdav end,
    async = { run = function(worker, callback) callback(true, worker()); return { cancel = function() end } end },
    file_size = function() return 1 end,
}
bridge:cache_document({ name = "Book.cbz", path = "/A/Book.cbz", connection = webdav }, {})
expect(published_identity == Identity.connection(webdav),
    "document publish must persist the identity-provider result")

local chapter = { path = "/A/Book/ch1" }
local identity_progress = Progress:new{ store = store(), md5 = function(value) return value end }
local local_chapter_id = identity_progress:chapter_id(local_dir,
    { path = "/mnt/us/Comics/Book" }, { path = "/mnt/us/Comics/Book/ch1" })
local webdav_chapter_id = identity_progress:chapter_id(webdav, manga, chapter)
expect(local_chapter_id ~= webdav_chapter_id,
    "chapter progress identity must distinguish local and WebDAV connections")
expect(local_chapter_id == Identity.manga(local_dir, "/mnt/us/Comics/Book")
    .. "\0/mnt/us/Comics/Book/ch1",
    "chapter progress key must use the unified kind/local identity")
local legacy_input = table.concat({ webdav.server_url, webdav.username, webdav.root_path,
    manga.path, chapter.path }, "\0")
local legacy_progress = Progress:new{ store = store({ progress = {
    [legacy_input] = { image_path = "/A/Book/ch1/1.jpg", index = 2 },
} }), md5 = function(value) return value end }
local migrated_id = legacy_progress:chapter_id(webdav, manga, chapter)
local resolved = legacy_progress:resolve(migrated_id, { count = function() return 3 end,
    find = function() return 2 end })
expect(resolved and resolved.index == 2,
    "old WebDAV progress keys must remain readable after identity migration")

local local_legacy_input = table.concat({ local_dir.server_url, "", local_dir.root_path,
    "/mnt/us/Comics/Book", "/mnt/us/Comics/Book/ch1" }, "\0")
local local_progress_store = store({ progress = {
    [local_legacy_input] = { image_path = "/mnt/us/Comics/Book/ch1/1.jpg", index = 2 },
} })
local local_progress = Progress:new{ store = local_progress_store, md5 = function(value) return value end }
local local_migrated_id = local_progress:chapter_id(local_dir,
    { path = "/mnt/us/Comics/Book" }, { path = "/mnt/us/Comics/Book/ch1" })
expect(local_progress.records[local_legacy_input] ~= nil,
    "local progress must retain opaque legacy data")
expect(local_progress.records[local_migrated_id] == nil,
    "legacy WebDAV compatibility must not migrate local progress keys")

print(("rebuild_0396_identity_spec: %d checks"):format(checks))
