local Loader = require("webdavmanga.loader")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local calls = { download = 0, range = {} }
local client = {
    connection = { id = "archive" },
    read_range = function(_, path, first, last)
        calls.range[#calls.range + 1] = { path = path, first = first, last = last }
        return string.rep("x", last - first + 1), {
            ["content-range"] = ("bytes %d-%d/100"):format(first, last),
        }
    end,
    download = function() calls.download = calls.download + 1; return nil, "unexpected" end,
}
local published, ready
local cache = {
    limit_bytes = 1024 * 1024,
    key_for = function(_, identity, path) return identity .. "|" .. path end,
    lookup = function() end,
    paths_for = function() return "/cache/final", "/cache/part" end,
    publish = function(_, entry, path)
        published = { entry = entry, path = path }
        return "/cache/final"
    end,
    discard_part = function() end,
}
local archive_pages = {
    extract_remote = function(_, image, read_at, target)
        local header = read_at(image.archive_local_offset, 30)
        local data = read_at(image.archive_local_offset + 30 + #image.archive_entry_name,
            image.archive_compressed_size)
        expect(header and #header == 30 and data and #data == image.archive_compressed_size
            and target == "/cache/part",
            "Loader must provide the worker-local range reader")
        return { size = 3, format = "jpeg", width = 1, height = 1 }
    end,
}
local async = {
    run = function(work, callback)
        local ok, result = pcall(work)
        callback(ok, result, ok and nil or result, {})
        return { cancel = function() end }
    end,
}
local loader = Loader:new{
    client_factory = function() return client end,
    cache = cache,
    async = async,
    identity = "archive",
    archive_pages = archive_pages,
}
local image = {
    name = "001.jpg", path = "/book.cbz#zip/1", archive_entry_name = "001.jpg",
    archive_remote_path = "/book.cbz", archive_source_size = 100,
    archive_local_offset = 0, archive_method = 0, archive_compressed_size = 3,
    archive_size = 3, archive_crc32 = 0, archive_flags = 0,
}
assert(loader:request(1, image, {
    on_ready = function(path, cached, metadata) ready = { path, cached, metadata } end,
    on_error = function(err) error(tostring(err and err.code or err)) end,
}))
expect(calls.download == 0 and #calls.range == 2
    and calls.range[1].first == 0 and calls.range[1].last == 29
    and calls.range[2].first == 37 and calls.range[2].last == 39,
    "archive pages must use Range reads instead of normal download")
expect(published and published.path == "/cache/part" and ready and ready[1] == "/cache/final"
    and ready[3].format == "jpeg", "archive metadata must use existing cache publication")

local queued_work, queued_callback
local queued_async = {
    run = function(work, callback)
        queued_work, queued_callback = work, callback
        return { cancel = function() end }
    end,
}
local active_connection = { id = "queued-source" }
local factory_connections, range_connections = {}, {}
local queued_loader = Loader:new{
    client_factory = function(connection)
        local selected = connection or active_connection
        factory_connections[#factory_connections + 1] = selected.id
        return {
            connection = selected,
            read_range = function(_, _path, first, last)
                range_connections[#range_connections + 1] = selected.id
                return string.rep("x", last - first + 1), {
                    ["content-range"] = ("bytes %d-%d/100"):format(first, last),
                }
            end,
        }
    end,
    cache = cache,
    async = queued_async,
    identity = "queued-archive",
    archive_pages = archive_pages,
}
assert(queued_loader:request(2, image, {}))
active_connection = { id = "new-source" }
local work_ok, work_result = pcall(queued_work)
queued_callback(work_ok, work_result, work_ok and nil or work_result, {})
expect(factory_connections[1] == "queued-source" and factory_connections[2] == "queued-source"
    and range_connections[1] == "queued-source",
    "queued archive jobs must create their worker client from the bound connection")

local queued_tasks = {}
local serial_async = {
    run = function(work, callback)
        queued_tasks[#queued_tasks + 1] = { work = work, callback = callback }
        return { cancel = function() end }
    end,
}
local serial_connection = { id = "queued-source" }
local serial_factory, serial_ranges = {}, {}
local serial_pages = {
    extract_remote = function(_, _image, read_at)
        expect(read_at(0, 1) == "x", "queued archive must receive a live range reader")
        return { size = 1, format = "jpeg", width = 1, height = 1 }
    end,
}
local serial_loader = Loader:new{
    client_factory = function(connection)
        local selected = connection or serial_connection
        serial_factory[#serial_factory + 1] = selected.id
        return {
            connection = selected,
            download = function()
                return { size = 1, format = "jpeg", width = 1, height = 1 }
            end,
            read_range = function(_, _path, first, last)
                serial_ranges[#serial_ranges + 1] = selected.id
                return string.rep("x", last - first + 1), {
                    ["content-range"] = ("bytes %d-%d/100"):format(first, last),
                }
            end,
        }
    end,
    cache = cache,
    async = serial_async,
    identity = "serial-archive",
    prefetch_count = 1,
    archive_pages = serial_pages,
}
assert(serial_loader:request(3, { name = "active.jpg", path = "/active.jpg" }, {}))
serial_loader:prefetch(4, { image }, 0)
expect(#queued_tasks == 1, "archive prefetch must wait behind the active job")
serial_connection = { id = "new-source" }
local active_ok, active_result = pcall(queued_tasks[1].work)
queued_tasks[1].callback(active_ok, active_result, active_ok and nil or active_result, {})
expect(#queued_tasks == 2, "finishing the active job must start the queued archive")
local archive_ok, archive_result = pcall(queued_tasks[2].work)
queued_tasks[2].callback(archive_ok, archive_result, archive_ok and nil or archive_result, {})
expect(serial_factory[1] == "queued-source" and serial_factory[2] == "queued-source"
    and serial_factory[3] == "queued-source" and serial_ranges[1] == "queued-source",
    "queued archive jobs must retain the connection that existed when they were enqueued")

local retry_tasks = {}
local retry_async = {
    run = function(work, callback)
        retry_tasks[#retry_tasks + 1] = { work = work, callback = callback }
        return { cancel = function() end }
    end,
}
local retry_connection = { id = "queued-source" }
local retry_factory, retry_ranges, retry_publishes = {}, {}, 0
local retry_cache = {
    limit_bytes = 1000,
    key_for = function(_, identity, path) return identity .. "|" .. path end,
    lookup = function() end,
    paths_for = function() return "/cache/final", "/cache/retry-part" end,
    publish = function()
        retry_publishes = retry_publishes + 1
        if retry_publishes == 1 then return nil, "temporary_storage" end
        return "/cache/final"
    end,
    discard_part = function() end,
    total_size = function() return 0 end,
    evict = function(_, required) return required end,
}
local retry_pages = {
    extract_remote = function(_, _image, read_at)
        expect(read_at(0, 1) == "x", "retry archive must receive a live range reader")
        return { size = 1, format = "jpeg", width = 1, height = 1 }
    end,
}
local retry_loader = Loader:new{
    client_factory = function(connection)
        local selected = connection or retry_connection
        retry_factory[#retry_factory + 1] = selected.id
        return {
            connection = selected,
            read_range = function(_, _path, first, last)
                retry_ranges[#retry_ranges + 1] = selected.id
                return string.rep("x", last - first + 1), {
                    ["content-range"] = ("bytes %d-%d/100"):format(first, last),
                }
            end,
        }
    end,
    cache = retry_cache,
    async = retry_async,
    identity = "retry-archive",
    archive_pages = retry_pages,
}
assert(retry_loader:request(5, image, {}))
local first_ok, first_result = pcall(retry_tasks[1].work)
retry_tasks[1].callback(first_ok, first_result, first_ok and nil or first_result, {})
expect(retry_publishes == 1 and #retry_tasks == 2,
    "a retryable archive publish failure must schedule a second worker")
retry_connection = { id = "new-source" }
local second_ok, second_result = pcall(retry_tasks[2].work)
retry_tasks[2].callback(second_ok, second_result, second_ok and nil or second_result, {})
expect(retry_publishes == 2 and retry_factory[1] == "queued-source"
    and retry_factory[2] == "queued-source" and retry_factory[3] == "queued-source"
    and retry_ranges[1] == "queued-source" and retry_ranges[2] == "queued-source",
    "archive publish retries must retain the connection captured when the job was created")

local local_image = {}
for key, value in pairs(image) do local_image[key] = value end
local_image.archive_local_path = "/cache/full.cbz"
local local_reads, local_ready = 0, false
local local_loader = Loader:new{
    client_factory = function() error("complete archive cache must not need a network client") end,
    cache = cache, async = async, identity = "local-archive",
    archive_pages = { extract_local = function(_, page, target)
        local_reads = local_reads + 1
        expect(page.archive_local_path == "/cache/full.cbz" and target == "/cache/part",
            "local archive extraction must receive its complete source and owned part")
        return { size = 3, format = "jpeg", width = 1, height = 1 }
    end },
}
local_loader:request(1, local_image, { on_ready = function() local_ready = true end })
expect(local_reads == 1 and local_ready,
    "later pages and covers from complete archive caches must call extract_local without Range")

print(("rebuild_0374_archive_loader_spec: %d checks"):format(checks))
