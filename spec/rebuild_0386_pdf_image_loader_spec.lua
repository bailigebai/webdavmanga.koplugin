local Loader = require("webdavmanga.loader")

local checks, range_call, downloaded = 0, nil, false
local range_count = 0
local target = os.tmpname()
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local image = {
    name = "00001.jpg", path = "/Books/comic.pdf#pdf/1", is_file = true,
    size = 4, format = "jpg", page = 1, pdf_image = true,
    pdf_remote_path = "/Books/comic.pdf", pdf_source_size = 100,
    pdf_image_offset = 42, pdf_image_length = 4,
    pdf_connection = { id = "test" },
}
local ready, published = false, false
local loader = Loader:new{
    client_factory = function(connection)
        expect(connection and connection.id == "test" and connection ~= image.pdf_connection,
            "PDF loader must use a copied page connection in its worker")
        return { connection = { id = "test" },
            read_range = function(_, path, first, last)
                range_count = range_count + 1
                range_call = { path = path, first = first, last = last }
                return "DATA", { ["Content-Range"] = "bytes 42-45/100" }
            end,
            download = function() downloaded = true end,
        }
    end,
    cache = {
        key_for = function(_, _, path) return path end,
        paths_for = function() return "/cache/page.jpg", target end,
        publish = function(_, record, part)
            published = record.remote_path == image.path and record.format == "jpeg"
            os.remove(part)
            return "/cache/page.jpg"
        end,
        lookup = function() return nil end,
        discard_part = function() os.remove(target) end,
        total_size = function() return 0 end,
        evict = function() return 0 end,
    },
    image_probe = {
        inspect = function(path, extension)
            local file = assert(io.open(path, "rb"))
            local bytes = file:read("*a")
            file:close()
            expect(bytes == "DATA" and extension == "jpg", "PDF bytes must be probed after exact Range")
            return { format = "jpeg", width = 1, height = 1, size = #bytes }
        end,
    },
    async = { run = function(work, done)
        local ok, result = pcall(work)
        done(ok, result, ok and nil or result, {})
        return { cancel = function() end }
    end },
    error_reporter = { guard = function(_, _, callback) return callback() end },
}
loader:request("reader", image, {
    on_ready = function() ready = true end,
    on_error = function(value) assert(false, "unexpected loader error: " .. tostring(value and value.detail or value)) end,
})
expect(ready and published, "PDF image page must publish through normal loader")
expect(range_count == 1 and range_call and range_call.path == "/Books/comic.pdf"
    and range_call.first == 42 and range_call.last == 45,
    "PDF page must request its exact source range")
expect(not downloaded, "PDF image page must not call ordinary document download")

local lazy_image = {
    name = "00002.jpg", path = "/Books/comic.pdf#pdf/2", is_file = true,
    size = 0, format = "jpg", page = 2, pdf_image = true,
    pdf_remote_path = "/Books/comic.pdf", pdf_source_size = 100,
    pdf_page_object = 12, pdf_connection = { id = "test" },
}
local lazy_ready, lazy_resolved = false, false
local lazy_loader = Loader:new{
    client_factory = function()
        return { connection = { id = "test" },
            read_range = function(_, _, first, last)
                return string.rep("X", last - first + 1),
                    { ["Content-Range"] = ("bytes %d-%d/100"):format(first, last) }
            end }
    end,
    cache = loader.cache,
    image_probe = loader.image_probe,
    pdf_image_stream = {
        extract_remote = function(_, current, read_at, output)
            lazy_resolved = current.pdf_page_object == 12 and type(read_at) == "function"
            local file = assert(io.open(output, "wb")); file:write("DATA"); file:close()
            return { format = "jpeg", width = 1, height = 1, size = 4 }
        end,
    },
    async = loader.async,
    error_reporter = loader.error_reporter,
}
lazy_loader:request("reader", lazy_image, {
    on_ready = function() lazy_ready = true end,
    on_error = function(value)
        assert(false, "unexpected lazy PDF loader error: " .. tostring(value and value.detail or value))
    end,
})
expect(lazy_ready and lazy_resolved,
    "an unresolved PDF page must be resolved only when the loader requests it")
-- A lazy parser write failure must enter Loader's existing bounded storage
-- recovery, retry once, and retain storage classification if the retry fails.
for _, recover in ipairs({ true, false }) do
    local attempts, evictions, ready_count, error_count = 0, 0, 0, 0
    local final_error, tokens, discarded = nil, {}, {}
    local retry_cache = {}
    for key, value in pairs(loader.cache) do retry_cache[key] = value end
    retry_cache.limit_bytes = 100
    retry_cache.protected_keys = { visible = true }
    retry_cache.total_size = function() return 100 end
    retry_cache.paths_for = function(_, _, _, token)
        tokens[#tokens + 1] = token
        return "/cache/page.jpg", target
    end
    retry_cache.evict = function(_, required, protected)
        evictions = evictions + 1
        expect(required == 5 and protected == retry_cache.protected_keys,
            "lazy PDF storage recovery must preserve the existing bounded eviction policy")
        return 5
    end
    retry_cache.discard_part = function(_, _, _, token)
        discarded[#discarded + 1] = token
        os.remove(target)
    end
    local retry_loader = Loader:new{
        client_factory = lazy_loader.client_factory,
        cache = retry_cache, async = loader.async, error_reporter = loader.error_reporter,
        pdf_image_stream = { extract_remote = function(_, _, _, output)
            attempts = attempts + 1
            local file = assert(io.open(output, "wb")); file:write("DATA"); file:close()
            if attempts == 1 or not recover then return nil, "pdf_image_write_failed" end
            return { format = "jpeg", width = 1, height = 1, size = 4 }
        end },
    }
    retry_loader:request("retry", lazy_image, {
        on_ready = function() ready_count = ready_count + 1 end,
        on_error = function(err) error_count = error_count + 1; final_error = err end,
    })
    expect(attempts == 2 and evictions == 1,
        "lazy PDF write failure must evict and retry exactly once")
    expect(tokens[1] ~= tokens[2] and discarded[1] == tokens[1],
        "lazy PDF retry must replace its transfer token and release the failed part")
    if recover then
        expect(ready_count == 1 and error_count == 0,
            "lazy PDF must publish successfully after storage recovery")
    else
        expect(ready_count == 0 and error_count == 1 and final_error.code == "storage",
            "repeated lazy PDF write failure must terminate with a storage error")
        expect(discarded[2] == tokens[2], "terminal storage failure must release the retry part")
    end
end

os.remove(target)
print(("rebuild_0386_pdf_image_loader_spec: %d checks"):format(checks))
