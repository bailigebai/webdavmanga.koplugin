local PremiumAccess = require("webdavmanga.premium_access")
local Identity = require("webdavmanga.manga_identity")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local connection = {
    kind = "webdav", server_url = "https://nas/dav", username = "u", root_path = "/A",
}

local function manga(index)
    return { name = "M" .. index, path = "/A/M" .. index }
end

local function fixture(count)
    local history, library, offline, documents = {}, {}, {}, {}
    for index = 1, count do
        local item = manga(index)
        history[#history + 1] = { connection = connection, manga = item }
        -- The other sources intentionally repeat the same identities.
        if index <= math.min(2, count) then
            library[#library + 1] = {
                connection = connection, manga = { name = item.name, path = item.path },
            }
            offline[#offline + 1] = {
                identity = Identity.manga(connection, item.path), manga_path = item.path,
                manga_name = item.name, path = item.path,
            }
            documents[#documents + 1] = {
                identity = Identity.manga(connection, item.path),
                remote_path = item.path .. "/book.cbz", name = item.name,
            }
        end
    end
    return history, library, offline, documents
end

local function make_access(count, authorized)
    local history, library, offline, documents = fixture(count)
    return PremiumAccess:new{
        identity = Identity,
        license = { is_authorized = function() return authorized == true end },
        progress = { list_all_history = function() return history end },
        library = { list_all_mangas = function() return library end },
        offline_cache = { list_all_mangas = function() return offline end },
        document_cache = { list_all_documents = function() return documents end },
        connection_provider = function() return connection end,
    }
end

local empty = make_access(0, false)
expect(empty:count_tracked_mangas() == 0, "empty sources should count zero")
expect(empty:can_open({ path = "/A/new" }) == true, "a new manga is allowed below quota")

local one = make_access(1, false)
expect(one:count_tracked_mangas() == 1, "one identity should count once")
expect(one:can_open({ path = "/A/new" }) == true, "new manga is allowed below five")
expect(one:can_add({ path = "/A/new" }) == true, "add is allowed below five")
expect(one:can_cache({ path = "/A/new" }) == true, "cache is allowed below five")

local five = make_access(5, false)
local tracked = five:collect_tracked_mangas()
expect(#tracked == 5, "repeated history/library/cache identities must deduplicate")
expect(#tracked[1].sources >= 1, "tracked manga should retain source labels")
expect(five:can_open({ path = "/A/M1" }) == true,
    "existing manga remains readable at exactly five")
local allowed, reason = five:can_open({ path = "/A/M6" })
expect(allowed == false, "sixth manga must be blocked at exactly five")
expect(reason == "license_required", "blocked action must return the license reason")
allowed, reason = five:can_add({ path = "/A/M6" })
expect(allowed == false and reason == "license_required",
    "sixth manga cannot be added at exactly five")
allowed, reason = five:can_cache({ path = "/A/M6" })
expect(allowed == false and reason == "license_required",
    "sixth manga cannot be cached at exactly five")

local six = make_access(6, false)
expect(six:count_tracked_mangas() == 6, "legacy data over quota remains enumerable")
allowed, reason = six:can_open({ path = "/A/M1" })
expect(allowed == false and reason == "license_required",
    "over-quota data blocks existing manga until reduced")
allowed, reason = six:can_add({ path = "/A/new" })
expect(allowed == false and reason == "license_required",
    "over-quota data blocks additions")
allowed, reason = six:can_cache({ path = "/A/M1" })
expect(allowed == false and reason == "license_required",
    "over-quota data blocks caching")
expect(six:collect_tracked_mangas() ~= nil,
    "management enumeration remains available over quota")

local changing = make_access(6, false)
expect(changing:count_tracked_mangas() == 6, "pre-delete count should be six")
-- The strategy only reads indexes; a deletion in the business store is observed on refresh.
local history_after, library_after, offline_after, documents_after = fixture(5)
changing.progress.list_all_history = function() return history_after end
changing.library.list_all_mangas = function() return library_after end
changing.offline_cache.list_all_mangas = function() return offline_after end
changing.document_cache.list_all_documents = function() return documents_after end
expect(changing:refresh() == 5, "refresh should observe deletion without writing stores")
expect(changing:can_open({ path = "/A/M1" }) == true,
    "deleting back to five restores reading without restart")

local authorized = make_access(20, true)
expect(authorized:is_authorized() == true, "valid license should authorize all actions")
expect(authorized:can_open({ path = "/A/new" }) == true, "license bypasses quota for reading")
expect(authorized:can_add({ path = "/A/new" }) == true, "license bypasses quota for adding")
expect(authorized:can_cache({ path = "/A/new" }) == true, "license bypasses quota for caching")

local failing = PremiumAccess:new{
    identity = Identity,
    license = { is_authorized = function() return false end },
    progress = { list_all_history = function() error("corrupt history") end },
    library = { list_all_mangas = function() return {} end },
    offline_cache = { list_all_mangas = function() return {} end },
    document_cache = { list_all_documents = function() return {} end },
    connection_provider = function() return connection end,
}
allowed, reason = failing:can_open({ path = "/A/anything" })
expect(allowed == false,
    "enumeration failure must fail closed")
expect(reason == "license_required",
    "enumeration failure must use the license reason")
expect(failing:collect_tracked_mangas() ~= nil,
    "enumeration failure must not destroy management reads")

print(("premium_access_spec: %d checks"):format(checks))
