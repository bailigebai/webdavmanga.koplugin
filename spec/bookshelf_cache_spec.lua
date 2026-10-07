local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local Settings = require("webdavmanga.settings")
local values = {}
local settings_store = {
    readSetting = function(_, k, d) if values[k] == nil then return d end; return values[k] end,
    saveSetting = function(_, k, v) values[k] = v end, flush = function() end,
}
local settings = Settings:new{store=settings_store}
expect(type(settings.get_bookshelf_cache) == "function", "bookshelf must have its own cache policy")
local policy = settings:get_bookshelf_cache()
expect(policy.total_mb == 200 and policy.trigger_mb == 150 and policy.retain_mb == 100
    and policy.interval_minutes == 10, "approved bookshelf defaults")
expect(settings:get_bookshelf_view() == "list", "first launch uses list")
expect(settings:set_bookshelf_view("covers") == true, "save cover mode")
expect(Settings:new{store=settings_store}:get_bookshelf_view() == "covers", "mode survives restart")
expect(not settings:set_bookshelf_view("invalid"), "unknown mode rejected")
expect(not settings:set_bookshelf_cache{retain_mb=150}, "retain must be below trigger")
expect(not settings:set_bookshelf_cache{trigger_mb=201}, "trigger must be below max")
expect(not settings:set_bookshelf_cache{total_mb=0}, "zero max rejected")
expect(settings:set_bookshelf_cache{total_mb=16, trigger_mb=12, retain_mb=0,
    interval_minutes=1} == true, "small valid policy and zero retention allowed")
expect(settings:get_browse_cache().total_mb == 5120, "old browsing quota isolated")

-- File-system and codec boundaries are injected; quota/LRU/index logic is real.
local files, snapshots, now, failed_rename = {}, {}, 100, false
local function clone(value)
    if type(value) ~= "table" then return value end
    local copy = {}; for k,v in pairs(value) do copy[k] = clone(v) end; return copy
end
local function serialize(value)
    if type(value) ~= "table" then return string.format("%q", tostring(value)) end
    local keys, parts = {}, {}; for k in pairs(value) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
    for _,k in ipairs(keys) do parts[#parts+1] = serialize(k)..":"..serialize(value[k]) end
    return "{"..table.concat(parts, ",").."}"
end
local json = {
    encode = function(value) local bytes=serialize(value); snapshots[bytes]=clone(value); return bytes end,
    decode = function(bytes) assert(snapshots[bytes], "invalid JSON"); return clone(snapshots[bytes]) end,
}
local fs = {
    make_path=function() return true end,
    exists=function(path) return files[path] ~= nil end,
    size=function(path) return files[path] and #files[path] end,
    list=function() return {} end,
    remove=function(path) files[path]=nil; return true end,
    rename=function(from,to) if failed_rename or not files[from] then return nil end
        files[to]=files[from]; files[from]=nil; return true end,
    open=function(path,mode)
        if mode=="rb" then if not files[path] then return nil end
            return {read=function() return files[path] end, close=function() return true end} end
        return {write=function(_,bytes) files[path]=bytes; return true end,
            close=function() return true end}
    end,
}
local Store = require("webdavmanga.bookshelf_store")
local function store() return Store:new{path="/shelf/index.json", fs=fs, json=json} end
local Cache = require("webdavmanga.cache")
local registry = store()
local cache = Cache:new{root="/shelf", limit_bytes=2400, cover_limit_bytes=2400,
    browse_total_bytes=2400,browse_trigger_bytes=1800,browse_retain_bytes=700,
    browse_check_interval_seconds=60, unified_quota=true, store=registry, fs=fs,
    clock=function() return now end}
local function publish(n,kind,size)
    local key=string.rep(tostring(n),32); files["/shelf/part"]=string.rep("x",size)
    return cache:publish({key=key,kind=kind,extension=kind=="manifest" and "manifest" or "png",
        size=size,validated=true,format="png",width=40,height=60,remote_path="/m/"..n},"/shelf/part"),key
end
local p1,k1=publish(1,"cover",500); now=101
local p2,k2=publish(2,"manifest",500)
expect(p1 and p2, "mixed entries fit shared quota")
expect(cache:total_size() == 1000 + #files["/shelf/index.json"], "registration bytes count")
expect(cache:browse_size() == cache:total_size(), "all shelf kinds count toward policy")
cache:protect(k2); now=102
local p3,k3=publish(3,"cover",700)
expect(p3 and not files[p1] and files[p2], "hard max evicts oldest cover but protects directory")
expect(cache:total_size() <= 2400, "hard max includes generated registry")
local restored=Cache:new{root="/shelf",limit_bytes=2400,store=store(),fs=fs,unified_quota=true}
expect(restored:lookup(k3)==p3, "persisted entry survives restart")
local _freed,_changed,status=cache:cleanup_browse(true)
expect(status=="cleaned" and files[p2] and not files[p3], "periodic cleanup reaches retain or protected floor")
expect(cache:total_size() >= 500, "protected usage remains accurately reported")
expect(select(3,cache:cleanup_browse(false))=="not_due", "cleanup interval honored")
local too_big=publish(4,"cover",2390)
expect(not too_big and not files["/shelf/part"], "index overhead rejects oversized addition without leftover")
local outside="/original/001.jpg"; files[outside]="original"
cache.entries.bad={path=outside,size=8,kind="cover",atime=0}
cache:clear()
expect(files[outside]=="original" and files[p2], "clear protects originals and active directory")
registry:saveSetting("example",1); local before=files["/shelf/index.json"]
failed_rename=true
expect(registry:flush()==false and files["/shelf/index.json"]==before
    and not files["/shelf/index.json.part"], "failed atomic save keeps previous registry")
failed_rename=false; files["/shelf/index.json"]="broken"
expect(next(store():readSetting("entries",{}))==nil, "corrupt registry cannot resurrect unsafe paths")
print(("bookshelf_cache_spec: %d checks"):format(checks))
