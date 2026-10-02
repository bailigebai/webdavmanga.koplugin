local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local now = 1000
local files = {}
local failed_remove_path
local function put(path, size, modified)
    files[path] = { size = size, modified = modified or now }
end

local fake_fs = {
    make_path = function(path)
        expect(path == "/cache/webdavmanga", "cache root should be created")
        return true
    end,
    exists = function(path) return files[path] ~= nil end,
    size = function(path) return files[path] and files[path].size or nil end,
    rename = function(source, target)
        if not files[source] then return nil, "source missing" end
        files[target] = files[source]
        files[source] = nil
        return true
    end,
    remove = function(path)
        if path == failed_remove_path then return nil, "disk error" end
        files[path] = nil
        return true
    end,
    list = function(root)
        local result = {}
        for path, attributes in pairs(files) do
            if path:sub(1, #root + 1) == root .. "/" then
                result[#result + 1] = {
                    path = path,
                    name = path:match("([^/]+)$"),
                    size = attributes.size,
                    modified = attributes.modified,
                }
            end
        end
        return result
    end,
}

local stored = {}
local flush_count = 0
local store = {
    readSetting = function(_self, key, default)
        if stored[key] == nil then return default end
        return stored[key]
    end,
    saveSetting = function(_self, key, value) stored[key] = value end,
    flush = function() flush_count = flush_count + 1 end,
}

local hashes = {
    ["id\0/漫画/A/1.jpg"] = "aaa",
    ["id\0/漫画/A/2.jpg"] = "bbb",
    ["id\0/漫画/A/3.jpg"] = "ccc",
}
local function fake_md5(value) return hashes[value] or "fallback" end

local Cache = require("webdavmanga.cache")
local cache = Cache:new{
    root = "/cache/webdavmanga",
    limit_bytes = 250,
    store = store,
    fs = fake_fs,
    md5 = fake_md5,
    clock = function() return now end,
}
local migration = cache:migrate(3)
expect(stored.schema_version == 3 and migration.invalidated == 0,
    "a fresh cache should persist schema v3 separately from entries")

expect(cache:key_for("id", "/漫画/A/1.jpg") == "aaa", "cache key should include identity and path")
local final, part = cache:paths_for("aaa", "JPG")
expect(final == "/cache/webdavmanga/aaa.jpg", "extension should be normalized")
expect(part == "/cache/webdavmanga/aaa.jpg.part", "part file should share final directory")
local _unique_final, unique_part = cache:paths_for("aaa", "jpg", "session1")
expect(unique_part == "/cache/webdavmanga/aaa.jpg.session1.part",
    "concurrent generations should use unique part paths for the same cache key")
put(unique_part, 12)
expect(cache:discard_part("aaa", "jpg", "session1") and files[unique_part] == nil,
    "discarding a canceled unique part should not touch another generation")

put(part, 100)
local published = assert(cache:publish({
    key = "aaa", remote_path = "/漫画/A/1.jpg", size = 100, extension = "jpg",
    kind = "page", format = "jpeg", width = 800, height = 1200,
    etag = '"page-etag"', modified = "today",
}, part))
expect(published == final and files[part] == nil and files[final] ~= nil,
    "publish should atomically rename part file")
expect(stored.entries.aaa.path == final and stored.entries.aaa.size == 100,
    "published record should persist")

now = 1010
local hit_path, hit_record = cache:lookup_record("aaa")
expect(hit_path == final and hit_record.kind == "page" and hit_record.validated
    and hit_record.format == "jpeg" and hit_record.width == 800
    and hit_record.etag == '"page-etag"' and hit_record.modified == "today",
    "a v3 hit should return trusted validation metadata")
hit_record.kind = "manifest"
expect(cache.entries.aaa.kind == "page", "lookup metadata must be an immutable copy")
expect(stored.entries.aaa.atime == 1010, "lookup should touch the v3 access time")

local final_b, part_b = cache:paths_for("bbb", "jpg")
put(part_b, 100)
now = 1020
assert(cache:publish({
    key = "bbb", remote_path = "/漫画/A/2.jpg", size = 100, extension = "jpg",
    kind = "page", validated = true, format = "jpeg", width = 200, height = 300,
}, part_b))
cache:set_protected({ aaa = true })

put(part, 100)
now = 1025
assert(cache:publish({
    key = "aaa", remote_path = "/漫画/A/1.jpg", size = 100, extension = "jpg",
    kind = "page", validated = true, format = "jpeg", width = 800, height = 1200,
}, part))
expect(files[final_b] ~= nil,
    "replacing a protected cache key should account only for size difference")

local final_c, part_c = cache:paths_for("ccc", "manifest")
put(part_c, 100)
now = 1030
assert(cache:publish({
    key = "ccc", remote_path = "/漫画/A", size = 100, extension = "manifest",
    kind = "manifest", validated = true,
}, part_c))
expect(files[final] ~= nil, "protected oldest page should remain")
expect(files[final_b] == nil and stored.entries.bbb == nil,
    "oldest unprotected page should be evicted")
expect(files[final_c] ~= nil, "new page should publish")

cache:set_protected({})
local resize_ok, resize_freed = cache:set_limit_bytes(100)
expect(resize_ok and resize_freed == 100 and cache:total_size() <= 100,
    "shrinking should report bytes freed by shared-kind LRU eviction")
local limit_before_invalid = cache.limit_bytes
local invalid_limit_ok, invalid_limit_error = cache:set_limit_bytes(math.huge)
expect(invalid_limit_ok == nil and invalid_limit_error == "invalid_limit"
    and cache.limit_bytes == limit_before_invalid,
    "a non-finite byte count must not replace the active cache limit")
expect(cache:remove("ccc"), "explicit removal should delete a corrupt cached page")
expect(files[final_c] == nil and cache:total_size() == 0,
    "explicit removal should update file and index")

stored.entries.missing = {
    key = "missing", path = "/cache/webdavmanga/missing.jpg", size = 50,
    atime = 900, extension = "jpg", kind = "page", validated = true,
    format = "jpeg", width = 8, height = 12,
}
expect(cache:lookup_record("missing") == nil and stored.entries.missing == nil,
    "missing indexed file should be forgotten")

put("/cache/webdavmanga/stale.jpg.part", 30, 800)
put("/cache/webdavmanga/fresh.jpg.part", 30, 1040)
now = 1050
local removed_parts = cache:cleanup_parts(100)
expect(removed_parts == 1 and files["/cache/webdavmanga/stale.jpg.part"] == nil,
    "stale part should be removed")
expect(files["/cache/webdavmanga/fresh.jpg.part"] ~= nil, "fresh part should remain")

cache:clear()
expect(cache:total_size() == 0, "clear should remove indexed shared cache entries")
expect(files["/cache/webdavmanga/fresh.jpg.part"] == nil, "clear should remove part files")

stored.schema_version = 3
stored.entries = {
    orphan = {
        key = "orphan", kind = "page", remote_path = "/old.jpg",
        path = "/cache/webdavmanga/orphan.jpg", size = 77, extension = "jpg",
        validated = true, format = "jpeg", width = 8, height = 12, atime = 700,
    },
}
put("/cache/webdavmanga/orphan.jpg", 77, 700)
local rebuilt_missing = Cache:new{
    root = "/cache/webdavmanga",
    limit_bytes = 250,
    store = store,
    fs = fake_fs,
    md5 = fake_md5,
    clock = function() return now end,
}
expect(rebuilt_missing:lookup_record("orphan") == "/cache/webdavmanga/orphan.jpg",
    "a valid v3 index should restore a trusted cache hit")
failed_remove_path = "/cache/webdavmanga/orphan.jpg"
expect(not rebuilt_missing:remove("orphan") and rebuilt_missing:total_size() == 77,
    "failed file deletion must keep its cache record and byte accounting")
local clear_ok, _retained, clear_failures = rebuilt_missing:clear()
expect(not clear_ok and clear_failures == 1 and rebuilt_missing.entries.orphan ~= nil,
    "cache clear should report files that could not be deleted")
failed_remove_path = nil

put("/outside/user.txt", 999, 500)
stored.entries = {
    evil = {
        key = "evil", kind = "page", remote_path = "/user.txt",
        path = "/outside/user.txt", size = 999, extension = "txt",
        validated = true, format = "jpeg", width = 8, height = 12, atime = 1,
    },
}
local path_safe = Cache:new{
    root = "/cache/webdavmanga",
    limit_bytes = 250,
    store = store,
    fs = fake_fs,
    md5 = fake_md5,
    clock = function() return now end,
}
path_safe:clear()
expect(files["/outside/user.txt"] ~= nil,
    "a corrupted index must never delete files outside the cache root")

stored.entries = {}
local bounded = Cache:new{
    root = "/cache/webdavmanga",
    limit_bytes = 100,
    store = store,
    fs = fake_fs,
    md5 = fake_md5,
    clock = function() return now end,
}
local bounded_a, bounded_a_part = bounded:paths_for("aaa", "jpg")
put(bounded_a_part, 80)
assert(bounded:publish({
    key = "aaa", kind = "page", remote_path = "/a.jpg", extension = "jpg",
    validated = true, format = "jpeg", width = 8, height = 12,
},
    bounded_a_part))
bounded:set_protected({ aaa = true })
local _bounded_b, bounded_b_part = bounded:paths_for("bbb", "jpg")
put(bounded_b_part, 50)
local protected_publish, protected_error = bounded:publish({
    key = "bbb", kind = "page", remote_path = "/b.jpg", extension = "jpg",
    validated = true, format = "jpeg", width = 8, height = 12,
}, bounded_b_part)
expect(protected_publish == nil and protected_error == "cache_limit"
    and bounded:total_size() == 80 and files[bounded_a] ~= nil,
    "publishing must not exceed the cache limit by evicting protected pages")
expect(files[bounded_b_part] == nil,
    "a page rejected by the cache limit should not leave a part file")

bounded:set_protected({})
local _oversize, oversize_part = bounded:paths_for("ccc", "jpg")
put(oversize_part, 120)
local oversize_publish, oversize_error = bounded:publish({
    key = "ccc", kind = "page", remote_path = "/oversize.jpg", extension = "jpg",
    validated = true, format = "jpeg", width = 8, height = 12,
}, oversize_part)
expect(oversize_publish == nil and oversize_error == "cache_limit"
    and bounded:total_size() <= bounded.limit_bytes,
    "a single oversized page should fail with an actionable cache-limit error")
expect(files[oversize_part] == nil,
    "an oversized rejected page should not leave a part file")

stored.schema_version = 3
stored.entries = {}
local protected_clear = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local protected_path, protected_part = protected_clear:paths_for("aaa", "jpg")
put(protected_part, 80)
assert(protected_clear:publish({
    key = "aaa", kind = "page", remote_path = "/current.jpg", extension = "jpg",
    validated = true, format = "jpeg", width = 8, height = 12,
}, protected_part))
local unprotected_path, unprotected_part = protected_clear:paths_for("bbb", "jpg")
put(unprotected_part, 60)
assert(protected_clear:publish({
    key = "bbb", kind = "manifest", remote_path = "/active", extension = "manifest",
    validated = true,
}, unprotected_part))
protected_clear:set_protected({ aaa = true })
local protected_resize_ok, protected_resize_freed = protected_clear:set_limit_bytes(50)
expect(protected_resize_ok and protected_resize_freed == 60
    and protected_clear:total_size() == 80 and files[protected_path] ~= nil
    and files[unprotected_path] == nil,
    "shrinking below the protected working set should evict every unprotected kind")
assert(protected_clear:set_limit_bytes(250))
local _republished_path
_republished_path, unprotected_part = protected_clear:paths_for("bbb", "manifest")
put(unprotected_part, 60)
assert(protected_clear:publish({
    key = "bbb", kind = "manifest", remote_path = "/active", extension = "manifest",
    validated = true,
}, unprotected_part))
local _active_final, active_part = protected_clear:paths_for("active", "jpg", "transfer")
put(active_part, 20, 100)
expect(protected_clear:cleanup_parts(0) == 0 and files[active_part] ~= nil,
    "stale cleanup must retain a partial file until its transfer releases ownership")
local clear_ok, retained_bytes = protected_clear:clear()
expect(clear_ok and retained_bytes == 80 and files[protected_path] ~= nil
    and files[unprotected_path] == nil,
    "clear should retain and report the protected working set")
expect(files[active_part] ~= nil,
    "clear must not remove a partial download still owned by an active transfer")
expect(protected_clear:discard_part("active", "jpg", "transfer")
    and files[active_part] == nil,
    "releasing an active transfer should allow its partial file to be removed")

local stores_snapshot = { progress = "keep", history = "keep", library = "keep" }
protected_clear:clear()
expect(stores_snapshot.progress == "keep" and stores_snapshot.history == "keep"
    and stores_snapshot.library == "keep",
    "cache clear must not touch progress, history, or library stores")

put("/cache/webdavmanga/legacy.jpg", 70, 600)
put("/cache/webdavmanga/orphan.jpg.part", 10, 600)
put("/outside/keep.jpg", 90, 600)
stored.schema_version = 2
stored.entries = {
    legacy = {
        key = "legacy", path = "/cache/webdavmanga/legacy.jpg", size = 70,
        extension = "jpg", accessed_at = 600,
    },
    unsafe = {
        key = "unsafe", path = "/outside/keep.jpg", size = 90, extension = "jpg",
    },
}
local legacy_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local migration_result = legacy_cache:migrate(3)
expect(migration_result.invalidated == 2 and migration_result.parts_removed == 1
    and files["/cache/webdavmanga/legacy.jpg"] == nil
    and files["/cache/webdavmanga/orphan.jpg.part"] == nil
    and files["/outside/keep.jpg"] ~= nil,
    "schema-2 migration should invalidate only cache-root artifacts and orphan parts")
expect(stored.schema_version == 3 and next(stored.entries) == nil,
    "migration should atomically reset the index to schema v3")

local function forged_record(key, overrides)
    local record = {
        key = key, kind = "page", remote_path = "/" .. key .. ".jpg",
        path = "/cache/webdavmanga/" .. key .. ".jpg", size = 20,
        extension = "jpg", validated = true, format = "jpeg",
        width = 8, height = 12, atime = 100,
    }
    for field, value in pairs(overrides or {}) do record[field] = value end
    return record
end

for _, case in ipairs({
    { name = "unsupported-format", overrides = { format = "bmp" } },
    { name = "extension-format-mismatch", overrides = { format = "png" } },
    { name = "jpeg-width-overflow", overrides = { width = 65536 } },
    { name = "fractional-width", overrides = { width = 8.5 } },
    { name = "infinite-height", overrides = { height = math.huge } },
    { name = "infinite-atime", overrides = { atime = math.huge } },
    { name = "nan-atime", overrides = { atime = 0 / 0 } },
}) do
    local key = "forged-" .. case.name
    local record = forged_record(key, case.overrides)
    stored.schema_version = 3
    stored.entries = { [key] = record }
    put(record.path, record.size, 100)
    local forged_cache = Cache:new{
        root = "/cache/webdavmanga", limit_bytes = 250, store = store,
        fs = fake_fs, md5 = fake_md5, clock = function() return now end,
    }
    expect(forged_cache:lookup_record(key) == nil,
        case.name .. " schema-v3 metadata must not forge a trusted image hit")
end

local valid_fractional_svg = forged_record("valid-fractional-svg", {
    remote_path = "/valid-fractional-svg.svg",
    path = "/cache/webdavmanga/valid-fractional-svg.svg",
    extension = "svg", format = "svg", width = 8.5, height = 12.25,
})
stored.schema_version = 3
stored.entries = { [valid_fractional_svg.key] = valid_fractional_svg }
put(valid_fractional_svg.path, valid_fractional_svg.size, 100)
local fractional_svg_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
expect(fractional_svg_cache:lookup_record(valid_fractional_svg.key)
        == valid_fractional_svg.path,
    "a validated SVG with positive safe fractional dimensions should be a trusted hit")

stored.schema_version = 3
stored.entries = {}
local canonical_publish_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local _, mismatch_part = canonical_publish_cache:paths_for("mismatch-publish", "jpg")
put(mismatch_part, 20, 100)
local mismatch_publish, mismatch_error = canonical_publish_cache:publish({
    key = "mismatch-publish", kind = "cover", remote_path = "/cover.jpg",
    extension = "jpg", validated = true, format = "png", width = 8, height = 12,
}, mismatch_part)
expect(mismatch_publish == nil and mismatch_error == "unvalidated",
    "publish should reject validated metadata whose format does not match its extension")
local _, svg_part = canonical_publish_cache:paths_for("svg-publish", "svg")
put(svg_part, 20, 100)
expect(canonical_publish_cache:publish({
    key = "svg-publish", kind = "page", remote_path = "/page.svg",
    extension = "svg", validated = true, format = "svg", width = 8.5, height = 12.25,
}, svg_part) ~= nil,
    "publish should accept canonical positive fractional SVG metadata")

local false_manifest = forged_record("false-manifest", {
    kind = "manifest", extension = "manifest",
    path = "/cache/webdavmanga/false-manifest.manifest",
    validated = false, format = nil, width = nil, height = nil,
})
stored.schema_version = 3
stored.entries = { [false_manifest.key] = false_manifest }
put(false_manifest.path, false_manifest.size, 100)
local false_manifest_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
expect(false_manifest_cache:lookup_record(false_manifest.key) == nil,
    "a manifest must follow its own validated-record rule")

local valid_manifest = forged_record("valid-manifest", {
    kind = "manifest", extension = "manifest",
    path = "/cache/webdavmanga/valid-manifest.manifest",
    format = nil, width = nil, height = nil,
})
stored.schema_version = 3
stored.entries = { [valid_manifest.key] = valid_manifest }
put(valid_manifest.path, valid_manifest.size, 100)
local valid_manifest_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
expect(valid_manifest_cache:lookup_record(valid_manifest.key)
        == valid_manifest.path,
    "a validated manifest should not require image dimensions")

local finite_atime = forged_record("finite-atime")
stored.schema_version = 3
stored.entries = { [finite_atime.key] = finite_atime }
put(finite_atime.path, finite_atime.size, 100)
local invalid_clock_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return math.huge end,
}
local invalid_clock_path, invalid_clock_record =
    invalid_clock_cache:lookup_record(finite_atime.key)
expect(invalid_clock_path == finite_atime.path and invalid_clock_record.atime == 100
    and stored.entries[finite_atime.key].atime == 100,
    "a non-finite clock result must never enter persisted LRU metadata")

stored.schema_version = 3
stored.entries = {}
local replacement_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local replacement_jpg, replacement_jpg_part = replacement_cache:paths_for("replace", "jpg")
put(replacement_jpg_part, 40)
assert(replacement_cache:publish({
    key = "replace", kind = "page", remote_path = "/replace.jpg", extension = "jpg",
    validated = true, format = "jpeg", width = 8, height = 12,
}, replacement_jpg_part))
local replacement_png, replacement_png_part = replacement_cache:paths_for("replace", "png")
put(replacement_png_part, 45)
failed_remove_path = replacement_jpg
local replacement_ok, replacement_error = replacement_cache:publish({
    key = "replace", kind = "page", remote_path = "/replace.png", extension = "png",
    validated = true, format = "png", width = 8, height = 12,
}, replacement_png_part)
expect(replacement_ok == nil and replacement_error == "replace_remove_failed"
    and replacement_cache.entries.replace.path == replacement_jpg
    and files[replacement_jpg] ~= nil and files[replacement_png] == nil,
    "extension replacement must roll back when the superseded file cannot be deleted")
failed_remove_path = nil

stored.schema_version = 3
stored.entries = {}
local orphan_page = "/cache/webdavmanga/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png"
local orphan_manifest = "/cache/webdavmanga/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.manifest"
put(orphan_page, 30, 100)
put(orphan_manifest, 31, 100)
put("/cache/webdavmanga/notes.jpg", 32, 100)
put("/cache/webdavmanga/placeholder.svg", 33, 100)
put("/cache/webdavmanga/nested/keep.jpg", 32, 100)
put("/outside/orphan-keep.jpg", 33, 100)
local orphan_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local orphan_clear_ok = orphan_cache:clear()
expect(orphan_clear_ok and files[orphan_page] == nil
    and files[orphan_manifest] == nil
    and files["/cache/webdavmanga/notes.jpg"] ~= nil
    and files["/cache/webdavmanga/placeholder.svg"] ~= nil
    and files["/cache/webdavmanga/nested/keep.jpg"] ~= nil
    and files["/outside/orphan-keep.jpg"] ~= nil,
    "clear should remove only canonical cache-owned orphan finals without recursion or root escape")

local damaged_orphan = "/cache/webdavmanga/cccccccccccccccccccccccccccccccc.webp"
put(damaged_orphan, 35, 100)
stored.schema_version = 3
stored.migration_pending = nil
stored.entries = { damaged = "not-a-record" }
local damaged_index_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
local damaged_index_migration = damaged_index_cache:migrate(3)
expect(damaged_index_migration.migrated
    and files[damaged_orphan] == nil,
    "migration should remove recognizable orphan finals after an index is damaged")

put("/cache/webdavmanga/retry.jpg", 34, 100)
put("/cache/webdavmanga/retry.part", 10, 100)
stored.schema_version = 2
stored.migration_pending = nil
stored.entries = {
    retry = {
        key = "retry", path = "/cache/webdavmanga/retry.jpg",
        size = 34, extension = "jpg", accessed_at = 100,
    },
}
local retry_cache = Cache:new{
    root = "/cache/webdavmanga", limit_bytes = 250, store = store,
    fs = fake_fs, md5 = fake_md5, clock = function() return now end,
}
failed_remove_path = "/cache/webdavmanga/retry.jpg"
local failed_migration = retry_cache:migrate(3)
expect(not failed_migration.migrated and failed_migration.pending
    and failed_migration.failed == 1 and stored.schema_version == 2
    and stored.migration_pending == true and files[failed_remove_path] ~= nil,
    "a failed cache deletion must leave a durable, retryable migration state")
failed_remove_path = nil
local retried_migration = retry_cache:migrate(3)
expect(retried_migration.migrated and not retried_migration.pending
    and retried_migration.failed == 0 and stored.schema_version == 3
    and stored.migration_pending == false
    and files["/cache/webdavmanga/retry.jpg"] == nil
    and files["/cache/webdavmanga/retry.part"] == nil,
    "the next migration attempt should finish prior failed deletions")
expect(flush_count > 0, "mutations should flush the cache index")

print(("cache_spec: %d checks"):format(checks))
