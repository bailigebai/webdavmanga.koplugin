local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local Bridge = require("webdavmanga.document_bridge")
local BookIndex = require("webdavmanga.book_index")

local function document_entry(extension)
    return {
        name = "comic." .. extension, path = "/comic." .. extension,
        size = 4096, file_kind = "document", connection = {},
    }
end

local function mobi_page(path)
    return { name = "page.jpg", path = path .. "#mobi/1", is_file = true }
end

local function immediate_async()
    return {
        run = function(worker, done)
            local ok, result = pcall(worker)
            done(ok, result, ok and nil or result)
            return { cancel = function() end }
        end,
    }
end

local function cache_fixture(record_path)
    return {
        key_for = function() return "comic-key" end,
        lookup_record = function() return record_path, record_path and { kind = "document" } end,
    }
end

for _, extension in ipairs({ "azw", "azw3" }) do
    local opened, downloaded = nil, 0
    local bridge = Bridge:new{
        cache = cache_fixture(),
        client_factory = function()
            return {
                connection = {},
                read_range = function() return "BOOKMOBI" end,
                download_document = function() downloaded = downloaded + 1 end,
            }
        end,
        async = immediate_async(),
        mobi_pages = {
            inspect_remote = function(_, descriptor, path)
                expect(descriptor.size == 4096 and path == "/comic." .. extension,
                    extension .. " inspection must receive the remote descriptor")
                return { index = BookIndex.from_items({ mobi_page(path) }) }
            end,
            index_from_items = function(_, items) return BookIndex.from_items(items) end,
        },
        open_reader = function(context) opened = context; return true end,
    }
    local capability = bridge:stream_capability{ name = "comic." .. extension }
    expect(capability.supported and capability.kind == "mobi_images",
        extension .. " must advertise the MOBI page adapter")
    expect(bridge:open(document_entry(extension), {}) == true
        and opened and opened.layout == "mobi_images" and downloaded == 0,
        extension .. " must enter the plugin reader without a complete download")
end

local Client = require("webdavmanga.client")
local rejected_part = nil
local client = Client:new{
    connection = { server_url = "https://example.invalid", root_path = "/" },
    transport = {
        get_to_file = function() return 200, { ["Content-Length"] = "4096" }, "OK" end,
    },
    encode_segment = function(value) return value end,
    decode_url = function(value) return value end,
    html_decode = function(value) return value end,
    file_size = function() return 4096 end,
    read_file_prefix = function() return string.rep("X", 1024) end,
    remove_file = function(path) rejected_part = path; return true end,
}
local metadata, signature_error = client:download_document("/comic.azw3", "/cache/comic.part")
expect(metadata == nil and signature_error and signature_error.detail == "invalid_document_signature"
    and rejected_part == "/cache/comic.part",
    "a downloaded AZW3 without BOOKMOBI must be rejected before caching")

local cached_opened, lazy_path, lazy_remote = nil, nil, nil
local cached_bridge = Bridge:new{
    cache = cache_fixture("/cache/comic.azw3"),
    client_factory = function() return {} end,
    mobi_pages = {
        inspect_lazy = function(_, path, remote_path)
            lazy_path, lazy_remote = path, remote_path
            return { index = BookIndex.from_items({ mobi_page(remote_path) }) }
        end,
    },
    open_reader = function(context) cached_opened = context; return true end,
}
expect(cached_bridge:open(document_entry("azw3"), {}) == true
    and lazy_path == "/cache/comic.azw3" and lazy_remote == "/comic.azw3"
    and cached_opened and cached_opened.layout == "mobi_images",
    "a cached AZW3 must use lazy MOBI inspection and the plugin reader")

local rejected_opened = false
local rejected_bridge = Bridge:new{
    cache = cache_fixture("/cache/text.azw3"),
    client_factory = function() return {} end,
    mobi_pages = {
        inspect_lazy = function() return nil, "not_mobi" end,
    },
    open_reader = function() rejected_opened = true; return true end,
}
expect(rejected_bridge:_try_open_mobi_images("/cache/text.azw3",
    document_entry("azw3"), {}) == nil and not rejected_opened,
    "a non-BOOKMOBI AZW3 must not unlock the manga reader")

print(("rebuild_0404_azw_stream_spec: %d checks"):format(checks))
