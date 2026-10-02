local Pages = require("webdavmanga.opds_pages")

local freed = 0
local requests = {}
local transport = {
    get_bytes = function(_self, url, _auth, _maximum)
        requests[#requests + 1] = url
        return 200, {}, "OK", "jpeg-bytes-" .. url:match("(%d+)$")
    end,
}
local transfer = {
    run = function(work, done)
        local handle = { canceled = false }
        local ok, body = pcall(work)
        done(ok, body, ok and nil or body)
        function handle:cancel() self.canceled = true end
        return handle
    end,
}
local renderer = {
    renderImageData = function(_self, body)
        return {
            body = body,
            free = function(self) self.freed = true; freed = freed + 1 end,
            getSize = function() return 100, 100 end,
        }
    end,
}
local image_probe = {
    inspect_bytes = function() return { format = "jpeg", width = 100, height = 100 } end,
}
local pages = Pages:new{
    transport = transport,
    transfer = transfer,
    renderer = renderer,
    image_probe = image_probe,
    auth_provider = function() return { username = "u", password = "p" } end,
}
local processed = 0
local process_buffer = function(buffer)
    processed = processed + 1
    return buffer, { memory_processed = true }
end
local image = function(index)
    return { opds_page = true, path = "opds://page/" .. index,
        image_url = "https://example.test/page/" .. index, name = index .. ".jpg" }
end
local ready
assert(pages:request(1, image(1), function() return 600, 800 end, {
    on_ready = function(buffer) ready = buffer end,
}, process_buffer))
assert(ready and ready.body == "jpeg-bytes-1")
pages:prefetch(1, { image(2), image(3), image(4), image(5), image(6), image(7) },
    function() return 600, 800 end, process_buffer)
assert(pages:buffer_count() == 5)
assert(#requests == 6)
assert(processed == 6)
pages:cancel_all()
assert(pages:buffer_count() == 0 and freed == 5)

print("opds_pages_spec: passed")
