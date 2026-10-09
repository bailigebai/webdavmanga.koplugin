-- Original books stay on read-only mounts. Real ARM Bridge, Cache, Loader and
-- native parsers run; HTTP delivery, the scheduler and the reader window are
-- test boundaries. Results do not claim real touch/e-ink or live server tests.
local ffi = require("ffi")
assert(ffi.abi("32bit") and ffi.arch == "arm", "ARM32 runtime required")
assert(os.setlocale("C.UTF-8", "all"))
ffi.loadlib = function(name)
    if name == "archive" then return ffi.load("/device/libarchive.so.13") end
    if name == "z" then return ffi.load("libz.so.1") end
    error("unexpected native library: " .. tostring(name))
end
package.preload["libs/libkoreader-lfs"] = function()
    return assert(package.loadlib("/device/libkoreader-lfs.so", "luaopen_lfs"))()
end
local lfs = require("libs/libkoreader-lfs")
package.preload.util = function() return { makePath = function(path) return lfs.mkdir(path) end } end
package.preload.device = function() return { isKindle = function() return true end } end
local Cache = require("webdavmanga.cache")
local Bridge = require("webdavmanga.document_bridge")
local Loader = require("webdavmanga.loader")
local json = require("json")
local serialize
for index = 1, 30 do
    local name, value = debug.getupvalue(require("webdavmanga.async").run, index)
    if name == "serialize" then serialize = value; break end
end
assert(serialize, "production process serializer required")
local configuration = assert(loadfile("/output/inputs.lua"))()
local results = {}

for _, sample in ipairs(configuration) do
    local file = assert(io.open("/samples/" .. sample.filename, "rb"))
    local size = assert(file:seek("end"))
    local requests, bytes, maximum = 0, 0, 0
    local source = {
        connection = {},
        read_range = function(_, _, first, last)
            assert(first >= 0 and last < size and last >= first, "invalid Range")
            local length = last - first + 1
            assert(length < size, "full-file request forbidden")
            assert(file:seek("set", first))
            local data = assert(file:read(length)); assert(#data == length, "truncated Range")
            requests, bytes, maximum = requests + 1, bytes + length, math.max(maximum, length)
            return data, { ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, size) }
        end,
        download = function() error("full download forbidden") end,
    }
    local entry = { name = "original." .. sample.kind, path = "/original." .. sample.kind,
        size = size, connection = {}, etag = "offline-etag", modified = "offline-time" }
    local store = { readSetting = function(_, _, default) return default end,
        saveSetting = function() end, flush = function() end }
    local ids, serial = {}, 0
    local function new_cache(suffix)
        local cache = Cache:new{ root = "/tmp/stream-" .. sample.label .. suffix,
            limit_bytes = 100 * 1024 * 1024, store = store, md5 = function(value)
                if not ids[value] then serial = serial + 1; ids[value] = ("%032x"):format(serial) end
                return ids[value]
            end }
        cache.schema_version = 3
        return cache
    end
    local cache = new_cache("")
    local result = { label = sample.label, kind = sample.kind, source_bytes = size, rounds = {}, full_file_requests = 0 }
    local modes = sample.kind == "epub" and {"cold", "warm", "legacy"} or {"cold", "warm"}
    for _, mode in ipairs(modes) do
        if mode == "legacy" then cache = new_cache("-legacy") end
        local tasks, cursor, context, failure, prompt = {}, 0, nil, nil, nil
        local asynchronous = { run = function(work, done, options)
            tasks[#tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end }
        local bridge = Bridge:new{ cache = cache, client_factory = function() return source end,
            archive_pages = require("webdavmanga.archive_pages"):new{ archiver = require("ffi/archiver") },
            async = asynchronous, open_reader = function(value) context = value; return true end,
            mupdf_pages = { remote_capability = function() return false end } }
        if mode == "legacy" then
            local parsed = assert(bridge.archive_pages:inspect_remote({size = size,
                read_at = function(first, length) return source:read_range(entry.path, first, first + length - 1) end},
                "epub", entry.path))
            local catalog = parsed.index:to_table()
            local version = size .. ":" .. #entry.etag .. ":" .. entry.etag .. ":" .. entry.modified
            for _, page in ipairs(catalog.items) do
                page.archive_spine_position = nil
                page.path = entry.path .. "#zip/" .. page.archive_entry_ordinal
                page.etag, page.archive_version = entry.etag, version
            end
            assert(catalog.items[1].path == catalog.items[2].path, "original EPUB repeated cover fixture")
            local key = cache:key_for("\0book-index", entry.path .. "\0" .. version)
            local _, part = cache:paths_for(key, "manifest", "legacy")
            local output = assert(io.open(part, "wb")); local body = json.encode(catalog)
            assert(output:write(body)); assert(output:close())
            assert(cache:publish({key = key, kind = "manifest", identity = "", size = #body,
                remote_path = entry.path, extension = "manifest", validated = true, etag = entry.etag}, part))
        end
        local start_requests, start_bytes = requests, bytes
        local function drain(stop_on_open)
            while cursor < #tasks do
                cursor = cursor + 1; assert(cursor < 5000, "worker queue did not settle")
                local task = tasks[cursor]
                local ok, value = pcall(task.work)
                assert(ok, tostring(value))
                local encoded = serialize({ok = true, result = value})
                local limit = task.options and task.options.max_payload_bytes or 8192
                assert(#encoded <= limit, "process payload limit")
                local envelope = assert(loadstring("return " .. encoded))()
                assert(envelope.ok)
                task.done(true, envelope.result)
                if task.options and task.options.on_reaped then task.options.on_reaped() end
                assert(not failure and not prompt, "open failed/fallback: " .. tostring(failure or prompt))
                if stop_on_open and context then break end
            end
        end
        bridge:open(entry, {on_error = function(value) failure = value end,
            on_document_fallback_prompt = function(value) prompt = value end})
        drain(true)
        assert(context and context.chapter_index, "reader did not open: " .. sample.label)
        local opening_requests, opening_bytes = requests - start_requests, bytes - start_bytes
        if context.stream_state and sample.kind ~= "zip" then
            assert(context.stream_state.available_pages >= 3, "opening pages missing")
        end
        drain()
        if context.stream_state then assert(context.stream_state.complete, "catalog unfinished") end
        local index = context.chapter_index
        local count = index:count(); assert(count > 0, "empty catalog")
        result.page_count = result.page_count or count; assert(result.page_count == count, "catalog changed on reopening")
        local loader = Loader:new{cache = cache, client_factory = function() return source end,
            async = asynchronous, archive_pages = bridge.archive_pages,
            mobi_pages = bridge.mobi_pages, pdf_image_stream = bridge.pdf_image_stream}
        local positions = {}
        for position = 1, math.min(20, count) do positions[#positions + 1] = position end
        if count > 20 then positions[#positions + 1] = count end
        local images, paths = {}, {}
        for _, position in ipairs(positions) do
            local ready, err
            loader:request(1, assert(index:get(position)), { on_ready = function(path) ready = path end,
                on_error = function(value) err = value end })
            drain()
            assert(ready and not err, "page failed: " .. sample.label .. "/" .. mode .. "/" .. position)
            assert(not paths[ready], "logical pages share a physical cache file")
            paths[ready] = true
            local input = assert(io.open(ready, "rb")); local body = assert(input:read("*a")); input:close()
            local name = sample.label .. "-" .. mode .. "-" .. position .. ".image"
            local output = assert(io.open("/output/" .. name, "wb")); assert(output:write(body)); assert(output:close())
            images[#images + 1] = name
        end
        loader:cancel_all()
        result.rounds[mode] = { positions = positions, images = images,
            opening_range_requests = opening_requests, opening_transferred_bytes = opening_bytes,
            range_requests = requests - start_requests, transferred_bytes = bytes - start_bytes }
        print(("STREAM %s/%s catalog=%d readable=%d requests=%d bytes=%d"):format(
            sample.label, mode, count, #positions, requests - start_requests, bytes - start_bytes))
    end
    result.maximum_range_bytes = maximum
    results[#results + 1] = result
    file:close()
end
local output = assert(io.open("/output/native-results.json", "wb"))
assert(output:write(json.encode(results))); assert(output:close())
