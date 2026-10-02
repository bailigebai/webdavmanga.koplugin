local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local files = {}
local close_order = {}
local opened_pages = {}

local function fake_document(page_count)
    local document = {}
    function document:getPages() return page_count end
    function document:openPage(number)
        opened_pages[#opened_pages + 1] = number
        return {
            getSize = function(_, draw_context)
                expect(draw_context ~= nil, "MuPDF size must use a draw context")
                if number == 1 then return 6000, 3000 end
                return 1200, 1600
            end,
            draw_new = function(_, _, width, height)
                return {
                    width = width, height = height,
                    writePNG = function(_, path)
                        files[path] = "PNG" .. tostring(width) .. "x" .. tostring(height)
                        return true
                    end,
                    close = function() close_order[#close_order + 1] = "buffer" end,
                    free = function() close_order[#close_order + 1] = "buffer" end,
                }
            end,
            close = function() close_order[#close_order + 1] = "page" end,
        }
    end
    function document:close() close_order[#close_order + 1] = "document" end
    return document
end

local fake_mupdf = {
    openRemoteDocument = function(descriptor)
        expect(descriptor and descriptor.read_at, "remote descriptor must be passed through")
        return fake_document(3)
    end,
    openDocument = function(path)
        expect(path == "/tmp/comic.pdf", "local path must be passed without reading whole file")
        return fake_document(3)
    end,
}

local fake_probe = {
    inspect = function(path, format)
        expect(files[path] ~= nil, "probe must receive rendered PNG path")
        expect(format == "png", "rendered output must be probed as PNG")
        return { format = "png", width = 100, height = 100, size = #files[path] }
    end,
}

local fake_file = {
    seek = function(_, where) return where == "end" and 54321 or 0 end,
    close = function() end,
}

local pages = require("webdavmanga.mupdf_pages"):new({
    mupdf = fake_mupdf,
    image_probe = fake_probe,
    draw_context = { name = "test" },
    max_pixels = 12000000,
    open_file = function(path)
        expect(path == "/tmp/comic.pdf", "local file must be opened only for size")
        return fake_file
    end,
})

local remote = {
    size = 12345,
    format = "pdf",
    name = "comic.pdf",
    read_at = function() return "range" end,
}
local book, inspect_error = pages:inspect_remote(remote, "/comic.pdf", {
    page = 1, path = "/tmp/first.png",
})
expect(inspect_error == nil and book and book.layout == "mupdf_pages",
    "remote inspection must return the MuPDF page layout")
expect(book.index:count() == 3, "remote page count expected")
expect(book.index:get(2).path == "/comic.pdf#mupdf/2"
    and book.index:get(2).mupdf_page == 2
    and book.index:get(2).size == 12345
    and book.index:get(2).format == "pdf",
    "page items must contain serializable source fields")
expect(book.first_metadata.format == "png", "first rendered page must be validated")
expect(files["/tmp/first.png"]:find("4898x2449", 1, true) ~= nil,
    "large pages must be scaled below the pixel cap")

local rendered, render_error = pages:render_remote(book.index:get(1),
    remote.read_at, "/tmp/page.png")
expect(render_error == nil and rendered.format == "png", "remote page must render")
expect(#close_order >= 6 and close_order[#close_order] == "document",
    "render resources must close in reverse order")

local local_book, local_error = pages:inspect_local("/tmp/comic.pdf", "pdf", {
    page = 1, path = "/tmp/local-first.png",
})
expect(local_error == nil and local_book.index:count() == 3,
    "local inspection must use the same adapter")

local bad, bad_error = pages:inspect_remote({ size = 1 }, "/bad.pdf", 1)
expect(bad == nil and bad_error == "invalid_remote_descriptor",
    "invalid remote descriptors need typed errors")

local encrypted_mupdf = {
    openRemoteDocument = function() return nil, "encrypted" end,
}
local encrypted, encrypted_error = require("webdavmanga.mupdf_pages"):new({ mupdf = encrypted_mupdf }):inspect_remote(
    remote, "/encrypted.pdf", 1)
expect(encrypted == nil and encrypted_error == "encrypted_document",
    "encrypted documents need a typed error")

print(("rebuild_0375_mupdf_pages_spec: %d checks"):format(checks))
