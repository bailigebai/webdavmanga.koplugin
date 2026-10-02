local OfflineCache = require("webdavmanga.offline_cache")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local function memory_store(initial)
    local store = { values = initial or {}, flushes = 0 }
    function store:readSetting(key, fallback)
        local value = self.values[key]
        return value == nil and fallback or value
    end
    function store:saveSetting(key, value) self.values[key] = value end
    function store:flush() self.flushes = self.flushes + 1 end
    return store
end

local files, directories, removed = {}, {}, {}
local fs = {}
function fs.make_path(path) directories[path] = true; return true end
function fs.exists(path) return files[path] ~= nil end
function fs.size(path) return files[path] end
function fs.rename(source, target)
    if not files[source] then return nil, "missing" end
    files[target], files[source] = files[source], nil
    return true
end
function fs.remove(path)
    removed[#removed + 1] = path
    files[path] = nil
    return true
end

local available = 6 * 1024 * 1024 * 1024
local store = memory_store()
local cache = OfflineCache:new{
    store = store,
    root_provider = function() return "/mnt/us/ComicsCache" end,
    fs = fs,
    disk_usage = function()
        return { total = 12 * 1024 * 1024 * 1024,
            used = 6 * 1024 * 1024 * 1024, available = available }
    end,
    md5 = function(value)
        local sum = #value
        for index = 1, #value do sum = (sum * 33 + value:byte(index)) % 0xffffffff end
        return ("%032x"):format(sum)
    end,
}

local manga = { name = "../漫画:一", path = "/Books/漫画一" }
local chapter = { name = "第一/话", path = "/Books/漫画一/第一话" }
local image = { name = "001?.JPG", path = "/Books/漫画一/第一话/001?.JPG" }
local plan = assert(cache:plan("source-a", manga, chapter, image, true, "task1"))
expect(plan.final_path:sub(1, #cache:root()) == cache:root()
    and not plan.final_path:find("..", 1, true)
    and not plan.final_path:find("\\", 1, true),
    "offline paths must stay inside the selected Kindle directory")
expect(plan.final_path:match("%.denoise%.png$") ~= nil
    and plan.part_path:match("%.part$") ~= nil,
    "denoised pages must use a separate PNG filename and owned part file")

local GB = 1024 * 1024 * 1024
available = 5 * GB + 100
expect(cache:can_store(100) == true,
    "a download that leaves exactly 5 GB free should be accepted")
local enough, space_error = cache:can_store(101)
expect(enough == false and space_error == "reserve_space",
    "downloads must stop before crossing the 5 GB reserve")

local fresh_root = "/mnt/us/NewOfflineRoot"
directories[fresh_root] = nil
local fresh_cache = OfflineCache:new{
    store = memory_store(), root_provider = function() return fresh_root end,
    fs = fs,
    disk_usage = function(path)
        if not directories[path] then
            return { total = nil, used = nil, available = nil }
        end
        return { total = 12 * GB, used = 6 * GB, available = 6 * GB }
    end,
    md5 = cache.md5,
}
expect(fresh_cache:can_store(1) == true and directories[fresh_root] == true,
    "the first space check must create a new configured offline root")

available = 6 * GB
files[plan.part_path] = 12345
local published = assert(cache:publish(plan, plan.part_path, {
    size = 12345, format = "png", width = 1200, height = 1600,
}, true))
expect(published == plan.final_path and files[plan.final_path] == 12345,
    "a validated offline part must be atomically published")
local found, metadata = cache:lookup("source-a", image.path)
expect(found == plan.final_path and metadata.denoised == true
    and metadata.width == 1200 and metadata.height == 1600,
    "published pages must be found by source identity and remote path")

local stats = cache:stats()
expect(stats.offline_bytes == 12345 and stats.total_bytes == 12 * GB
    and stats.available_bytes == 6 * GB and stats.reserve_bytes == 5 * GB,
    "cache statistics must include owned offline bytes and Kindle disk space")
local manga_stats = cache:stats("source-a", manga.path)
expect(manga_stats.manga_bytes == 12345,
    "cache statistics must report the selected manga separately")

local raw_plan = assert(cache:plan("source-a", manga, chapter, image, false, "task2"))
files[raw_plan.part_path] = 23456
assert(cache:publish(raw_plan, raw_plan.part_path, {
    size = 23456, format = "jpeg", width = 1200, height = 1600,
}, false))
found, metadata = cache:lookup("source-a", image.path)
expect(found == raw_plan.final_path and metadata.denoised == false
    and files[plan.final_path] == 12345,
    "re-caching switches the index but preserves the prior offline file")

local mismatch_image = { name = "wrong.png",
    path = "/Books/漫画一/第一话/wrong.png" }
local mismatch_plan = assert(cache:plan(
    "source-a", manga, chapter, mismatch_image, false, "task3"))
files[mismatch_plan.part_path] = 34567
local mismatch_path = assert(cache:publish(mismatch_plan,
    mismatch_plan.part_path, { size = 34567, format = "jpeg",
        width = 1200, height = 1600, extension_mismatch = true }, false))
expect(mismatch_path:match("%.jpg$") ~= nil
    and cache:lookup("source-a", mismatch_image.path) == mismatch_path,
    "validated extension-mismatch images must use their canonical local extension")

local outside = OfflineCache:new{
    store = memory_store(), root_provider = function() return "/var/tmp" end,
    fs = fs, disk_usage = function() return {} end,
    md5 = function() return string.rep("a", 32) end,
}
local outside_plan, outside_error = outside:plan(
    "source-a", manga, chapter, image, false, "task")
expect(outside_plan == nil and outside_error == "invalid_offline_root",
    "production offline cache roots must be restricted to /mnt/us")

local forged_key = string.rep("a", 32)
local user_photo = "/mnt/us/ComicsCache/family-photo.jpg"
files[user_photo] = 45678
local forged = OfflineCache:new{
    store = memory_store({ entries = { [forged_key] = {
        namespace = "webdavmanga-offline-v1", owned = true,
        key = forged_key, identity = "source-forged",
        remote_path = "/Books/forged.jpg", manga_path = "/Books",
        manga_name = "Books", root = "/mnt/us/ComicsCache",
        local_path = user_photo, size = 45678, extension = "jpg",
        format = "jpeg", width = 1200, height = 1600,
    } } }),
    root_provider = function() return "/mnt/us/ComicsCache" end,
    fs = fs, disk_usage = function() return { available = 2 * GB } end,
    md5 = function() return forged_key end,
}
expect(forged:lookup("source-forged", "/Books/forged.jpg") == nil
    and files[user_photo] == 45678,
    "a forged index must not claim or remove a normal user image")

local corrupt_path = "/mnt/us/personal/do-not-delete.jpg"
files[corrupt_path] = 99
store.values.entries["corrupt"] = {
    key = "corrupt", identity = "source-a", remote_path = "/bad.jpg",
    local_path = corrupt_path, root = "/mnt/us/ComicsCache", size = 99,
    format = "jpeg", width = 10, height = 10, extension = "jpg",
}
expect(cache:lookup("source-a", "/bad.jpg") == nil
    and files[corrupt_path] == 99,
    "invalid index records must never delete unrelated Kindle files")

print(("offline_cache_spec: %d checks"):format(checks))
