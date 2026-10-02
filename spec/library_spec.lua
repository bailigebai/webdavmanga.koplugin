local Identity = require("webdavmanga.manga_identity")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local values = {
    library = {
        schema_version = 1,
        connections = {
            ["https://bad.example/dav\0reader\0/漫画"] = {
                connection = { server_url = "https://bad.example/dav", username = "reader", root_path = "/漫画" },
                categories = { broken = "not a category" },
                mangas = { broken = { manga = "not a resource" } },
                covers = { broken = { image = "not a resource" } },
            },
        },
    },
}
local flushes = 0
local store = {
    readSetting = function(_self, key, default)
        if values[key] == nil then return default end
        return values[key]
    end,
    saveSetting = function(_self, key, value) values[key] = value end,
    flush = function() flushes = flushes + 1 end,
}

local Library = require("webdavmanga.library")
local now = 1700000000
local library = Library:new{
    store = store,
    md5 = function(value) return value end,
    clock = function() return now end,
}

local connection = {
    server_url = "https://nas.example/dav",
    username = " reader ",
    password = "must-not-be-stored",
    root_path = "/漫画/",
}
local other_connection = {
    server_url = "https://nas.example/dav",
    username = "another-reader",
    password = "other-secret",
    root_path = "/漫画",
}
local manga = { name = "漫画 A", path = "/漫画/A", is_folder = true }
local chapter1 = { name = "第 1 话", path = "/漫画/A/第 1 话", is_folder = true }
local manga_b = { name = "漫画 2", path = "/漫画/B", is_folder = true }

expect(#library:list_categories({
    server_url = "https://bad.example/dav", username = "reader", root_path = "/漫画",
}) == 0, "malformed child records are filtered during initialization")

local favorites = assert(library:create_category(connection, " 收藏 "))
expect(favorites.name == "收藏", "category names are trimmed")
expect(library:create_category(connection, "收藏") == nil, "duplicate category rejected")
expect(library:create_category(connection, "   ") == nil, "empty category rejected")

local later = assert(library:create_category(connection, "第 10 类"))
local earlier = assert(library:create_category(connection, "第 2 类"))
local categories = library:list_categories(connection)
expect(categories[1].name == "收藏" and categories[2].name == "第 2 类"
    and categories[3].name == "第 10 类", "categories have stable natural ordering")
categories[1].name = "mutated"
expect(library:list_categories(connection)[1].name == "收藏", "category results are copies")

local renamed = assert(library:rename_category(connection, favorites.id, " 喜欢 "))
expect(renamed.id == favorites.id and renamed.name == "喜欢", "renaming keeps the stable category ID")
expect(library:rename_category(connection, favorites.id, "第 2 类") == nil,
    "rename rejects an existing category name")

local added = assert(library:add_manga(connection, manga, {
    category_ids = { favorites.id }, layout = "chapters",
    cover_hint = { chapter = chapter1 },
}))
expect(added.layout == "chapters" and added.cover_hint.chapter.path == chapter1.path,
    "manga stores classification metadata and sanitized cover hint")
expect(#library:list_mangas(connection, Library.ALL) == 1, "all view lists every manga")
expect(#library:list_mangas(connection, favorites.id) == 1, "category view lists membership")
expect(#library:list_mangas(connection, Library.UNCATEGORIZED) == 0,
    "categorized manga is not uncategorized")
expect(#library:list_mangas(other_connection, Library.ALL) == 0, "manga records are connection isolated")

local invalid_hint_category = assert(library:create_category(connection, "坏提示"))
expect(library:add_manga(connection, { name = "坏提示漫画", path = "/漫画/坏提示" }, {
    category_ids = {}, layout = "direct",
    cover_hint = { chapter = { name = "越界话", path = "/private/chapter" } },
}) == nil, "new manga rejects an out-of-root cover hint before persisting")
expect(library:add_manga(connection, manga, {
    category_ids = { invalid_hint_category.id }, layout = "direct",
    cover_hint = { chapter = { name = "越界话", path = "/private/chapter" } },
}) == nil, "existing manga rejects an out-of-root cover hint before updating")
expect(not library:list_mangas(connection, Library.ALL)[1].category_ids[invalid_hint_category.id],
    "rejected existing cover hint does not partially replace memberships")

local merged = assert(library:add_manga(connection, manga, {
    category_ids = { earlier.id }, layout = "direct",
}))
expect(merged.category_ids[favorites.id] and merged.category_ids[earlier.id]
    and merged.layout == "direct", "adding an existing manga merges categories and updates metadata")
expect(library:set_categories(connection, manga.path, { later.id }) ~= nil,
    "set_categories replaces membership after validating every category")
expect(library:set_categories(connection, manga.path, { "missing" }) == nil,
    "set_categories rejects missing categories atomically")
expect(#library:list_mangas(connection, later.id) == 1
    and #library:list_mangas(connection, favorites.id) == 0,
    "invalid category replacement leaves the prior membership unchanged")

assert(library:remove_from_category(connection, manga.path, later.id))
expect(#library:list_mangas(connection, Library.UNCATEGORIZED) == 1,
    "empty membership becomes uncategorized")
assert(library:add_manga(connection, manga_b, {
    category_ids = { earlier.id }, layout = "direct",
    cover_hint = { image = { name = "2.jpg", path = "/漫画/B/2.jpg" } },
    direct_cover_image = { name = "2.jpg", path = "/漫画/B/2.jpg", password = "discard-me" },
}))
expect(library:get_cover(connection, manga_b.path).image.path == "/漫画/B/2.jpg",
    "direct add persists its already-recognized cover in the same library mutation")
now = 1700000001
assert(library:remove_category(connection, earlier.id))
local after_category_removal = library:list_mangas(connection, Library.ALL)
expect(#after_category_removal == 2 and after_category_removal[1].updated_at == 1700000001,
    "removing a category retains mangas and updates their classification metadata")
expect(not library:remove_category(connection, Library.ALL)
    and not library:remove_category(connection, Library.UNCATEGORIZED),
    "virtual categories are immutable")

assert(library:add_manga(connection, manga_b, {
    category_ids = { later.id }, layout = "direct",
}))
local old_history_cover = assert(library:set_cover(connection, manga.path, {
    name = "old-history.jpg", path = "/漫画/A/old-history.jpg",
}))
local fresh_chapter = { name = "新第 1 话", path = "/漫画/B/新第 1 话", is_folder = true }
local relinked = assert(library:relink_manga(connection, manga.path, {
    manga = manga_b,
    layout = "chapters",
    cover_hint = { chapter = fresh_chapter },
}))
expect(relinked.manga.path == manga_b.path and relinked.category_ids[later.id],
    "relink merges old classification into an existing target")
expect(relinked.layout == "chapters" and relinked.cover_hint.chapter.path == fresh_chapter.path,
    "fresh recognition metadata wins when relink merges into an existing target")
expect(#library:list_mangas(connection, Library.ALL) == 1,
    "relink removes the old path after merging into its target")
expect(library:get_cover(connection, manga.path).image.path == old_history_cover.image.path,
    "relink retains the old shared cover index for history that stays on the old path")

now = 1700000002
local cover = assert(library:set_cover(connection, manga_b.path, {
    name = "001.jpg", path = "/漫画/B/001.jpg", size = 123,
    etag = "etag", last_modified = "yesterday", password = "not-kept",
}))
expect(cover.image.path == "/漫画/B/001.jpg" and cover.resolved_at == 1700000002,
    "cover index persists a sanitized image record")
expect(cover.image.password == nil, "cover return values exclude passwords")
cover.image.name = "mutated.jpg"
expect(library:get_cover(connection, manga_b.path).image.name == "001.jpg",
    "cover results are copies")
local identity = Identity.connection(connection)
expect(values.library.connections[identity].connection.password == nil,
    "persisted connection excludes passwords")
expect(values.library.connections[identity].covers[identity .. "\0/漫画/B"].image.password == nil,
    "persisted cover excludes passwords")
now = 1700000003
local none_cover = assert(library:set_no_cover(connection, manga_b.path))
expect(none_cover.none == true and none_cover.image == nil and none_cover.resolved_at == now,
    "library persists an explicit timestamped no-cover sentinel")
expect(library:get_cover(connection, manga_b.path).none == true,
    "no-cover sentinel is returned as an immutable cover-index record")
assert(library:set_cover(connection, manga_b.path, {
    name = "replacement.jpg", path = "/漫画/B/replacement.jpg",
}))
expect(library:get_cover(connection, manga_b.path).image.path == "/漫画/B/replacement.jpg"
    and library:get_cover(connection, manga_b.path).none == nil,
    "a positive cover atomically replaces a prior no-cover sentinel")
expect(library:clear_cover(connection, manga_b.path), "clear_cover removes only the cover association")
expect(library:get_cover(connection, manga_b.path) == nil, "cleared cover no longer resolves")

expect(library:add_manga(connection, { name = "越界", path = "/private/A" }, {
    category_ids = {}, layout = "direct",
}) == nil, "library rejects manga paths outside the configured root")
expect(library:set_cover(connection, "/漫画/A", {
    name = "bad.jpg", path = "/private/bad.jpg",
}) == nil, "library rejects cover paths outside the configured root")
expect(#library:list_mangas(connection, Library.ALL) == 1,
    "rejected out-of-root records never persist")

expect(library:remove_manga(connection, manga_b.path), "remove_manga only removes local metadata")
expect(#library:list_mangas(connection, Library.ALL) == 0, "removed manga leaves the library")

local malformed_connection = {
    server_url = "https://malformed.example/dav", username = "reader", root_path = "/漫画",
}
local malformed_identity = "https://malformed.example/dav\0reader\0/漫画"
local malformed_values = {
    library = {
        schema_version = 1,
        connections = {
            ["\0\0"] = {
                connection = "not-a-table", categories = {},
                mangas = {
                    ["\0\0\0/private/A"] = {
                        key = "\0\0\0/private/A",
                        manga = { name = "malformed root", path = "/private/A" },
                    },
                },
                covers = {},
            },
            [malformed_identity] = {
                connection = "not-a-table", categories = "not-a-table",
                mangas = "not-a-table", covers = "not-a-table",
            },
            ["https://legacy.example/dav\0reader\0/漫画"] = {
                connection = {
                    server_url = "https://legacy.example/dav", username = "reader", root_path = "/漫画",
                },
                categories = {},
                mangas = {
                    ["wrong-map-key"] = {
                        key = "https://legacy.example/dav\0reader\0/漫画\0/漫画/A",
                        manga = { name = "wrong key", path = "/漫画/A" },
                    },
                    ["https://legacy.example/dav\0reader\0/漫画\0/private/A"] = {
                        key = "https://legacy.example/dav\0reader\0/漫画\0/private/A",
                        manga = { name = "outside", path = "/private/A" },
                    },
                },
                covers = {
                    ["wrong-map-key"] = {
                        manga_path = "/漫画/A", image = { name = "a.jpg", path = "/漫画/A/a.jpg" },
                    },
                    ["https://legacy.example/dav\0reader\0/漫画\0/private/A"] = {
                        manga_path = "/private/A", image = { name = "bad.jpg", path = "/private/bad.jpg" },
                    },
                },
            },
        },
    },
}
local malformed_store = {
    readSetting = function(_self, key, default) return malformed_values[key] or default end,
    saveSetting = function(_self, key, value) malformed_values[key] = value end,
}
local malformed_library = Library:new{ store = malformed_store, md5 = function(value) return value end,
    clock = function() return 1 end }
expect(#malformed_library:list_categories(malformed_connection) == 0,
    "non-table persisted containers and connections load as empty")
expect(#malformed_library:list_mangas({ server_url = "", username = "", root_path = "" }, Library.ALL) == 0,
    "malformed connections cannot turn an empty root into an unconfined bucket")
local legacy_connection = {
    server_url = "https://legacy.example/dav", username = "reader", root_path = "/漫画",
}
expect(#malformed_library:list_mangas(legacy_connection, Library.ALL) == 1
    and malformed_library:get_cover(legacy_connection, "/漫画/A") ~= nil
    and malformed_library:get_cover(legacy_connection, "/private/A") == nil,
    "legacy records are rekeyed while root-escaping paths are discarded")

local ghost_connection = {
    server_url = "https://ghost.example/dav", username = "reader", root_path = "/漫画",
}
local ghost_identity = "https://ghost.example/dav\0reader\0/漫画"
local ghost_values = { library = { schema_version = 1, connections = {
    [ghost_identity] = {
        connection = ghost_connection,
        categories = {
            kept = { id = "kept", name = "保留分类", created_at = 1, updated_at = 1 },
        },
        mangas = {
            [ghost_identity .. "\0/漫画/有分类"] = {
                key = ghost_identity .. "\0/漫画/有分类",
                manga = { name = "有分类", path = "/漫画/有分类" },
                category_ids = { kept = true, missing = true },
            },
            [ghost_identity .. "\0/漫画/幽灵分类"] = {
                key = ghost_identity .. "\0/漫画/幽灵分类",
                manga = { name = "幽灵分类", path = "/漫画/幽灵分类" },
                category_ids = { missing = true },
            },
        },
        covers = {},
    },
} } }
local ghost_library = Library:new{
    store = { readSetting = function(_self, key, default) return ghost_values[key] or default end },
    md5 = function(value) return value end,
}
local ghost_records = ghost_library:list_mangas(ghost_connection, Library.ALL)
expect(#ghost_records == 2 and ghost_records[1].category_ids.missing == nil
    and ghost_records[2].category_ids.missing == nil,
    "startup sanitization removes memberships to missing category records")
expect(#ghost_library:list_mangas(ghost_connection, Library.UNCATEGORIZED) == 1,
    "a manga with only missing memberships recovers into uncategorized")

local failing_values = {}
local successful_flushes = 0
local fail_save = false
local fail_flush = false
local failing_store = {
    readSetting = function(_self, key, default) return failing_values[key] or default end,
    saveSetting = function(_self, key, value)
        if fail_save then error("save failed") end
        failing_values[key] = value
    end,
    flush = function()
        if fail_flush then error("flush failed") end
        successful_flushes = successful_flushes + 1
    end,
}
local failing_library = Library:new{ store = failing_store, md5 = function(value) return value end,
    clock = function() return 1 end }
local success_before = successful_flushes
fail_save = true
local failed_category, failed_error = failing_library:create_category(connection, "save failure")
expect(failed_category == nil and failed_error == "storage_failure"
    and #failing_library:list_categories(connection) == 0
    and successful_flushes == success_before, "save failure publishes no candidate and performs no flush")
fail_save = false
expect(failing_library:create_category(connection, "kept"), "a later save succeeds after save failure")
expect(successful_flushes == success_before + 1, "one successful mutation flushes exactly once")
success_before = successful_flushes
fail_flush = true
failed_category, failed_error = failing_library:create_category(connection, "flush failure")
expect(failed_category == nil and failed_error == "storage_failure"
    and #failing_library:list_categories(connection) == 1
    and successful_flushes == success_before, "flush failure rolls back the live candidate")
fail_flush = false
expect(failing_library:create_category(other_connection, "other kept"),
    "a later cross-connection save succeeds after flush failure")
expect(#failing_library:list_categories(connection) == 1
    and #failing_library:list_categories(other_connection) == 1,
    "read-only lookups and failed commits do not leak empty or failed buckets into later saves")
local flushes_before_success = flushes
expect(library:create_category(connection, "一次刷新"), "representative mutation succeeds")
expect(flushes == flushes_before_success + 1,
    "representative successful mutation flushes exactly once")

print(("library_spec: %d checks"):format(checks))
