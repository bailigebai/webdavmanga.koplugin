local Loader = require("webdavmanga.loader")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local target = os.tmpname()
local image = { name = "00001.png", path = "/Books/comic.pdf#mupdf/1", mupdf_page = 1,
    page = 1, format = "pdf", size = 100, mupdf_source_size = 100,
    mupdf_remote_path = "/Books/comic.pdf", mupdf_connection = { id = "clicked" } }
local ready, published, rendered, selected_connection = false, false, false, nil
local loader = Loader:new{
    client_factory = function(connection)
        selected_connection = connection
        return { read_range = function(_, _, first, last)
            return string.rep("x", last - first + 1), { ["Content-Range"] = ("bytes %d-%d/100"):format(first, last) }
        end }
    end,
    cache = {
        key_for = function(_, _, path) return path end,
        paths_for = function() return "/cache/page.png", target end,
        publish = function(_, record, part)
            published = record.mupdf_page == 1 and record.format == "png"
            os.remove(part); return "/cache/page.png"
        end,
        lookup = function() return nil end, discard_part = function() os.remove(target) end,
        total_size = function() return 0 end, evict = function() return 0 end,
    },
    async = { run = function(work, done)
        local ok, result = pcall(work); done(ok, result, ok and nil or result, {})
        return { cancel = function() end }
    end },
    mupdf_pages = {
        render_remote = function(_, item, read_at, output)
            rendered = read_at(0, 1) ~= nil; local file = assert(io.open(output, "wb")); file:write("png"); file:close()
            return { format = "png", width = 1, height = 1, size = 3 }
        end,
    },
    error_reporter = { guard = function(_, _, callback) return callback() end },
}
loader:request("reader", image, { on_ready = function() ready = true end,
    on_error = function(error) error("unexpected loader error: " .. tostring(error)) end })
expect(ready and rendered and published, "MuPDF page must render remotely and publish normal metadata")
expect(selected_connection and selected_connection.id == "clicked",
    "MuPDF worker must use the click-time connection snapshot")
os.remove(target)
local function local_loader(validate,client,item)
    local selected,failed,ready
    local instance=Loader:new{validate_local_documents=validate,client_factory=function() return client end,
        cache=loader.cache,async=loader.async,error_reporter=loader.error_reporter,
        mupdf_pages={render_local=function(_,page,output)
            selected=page.local_path or page.source_path or page.path:match("^(.-)#mupdf/")
            local file=assert(io.open(output,"wb"));file:write("png");file:close()
            return {format="png",width=1,height=1,size=3}
        end}}
    instance:request("local",item,{on_ready=function() ready=true end,on_error=function(err) failed=err end})
    return selected,failed,ready
end
local local_page={name="00001.png",path="/Books/local.pdf#mupdf/1",mupdf_page=1,size=100,
    mupdf_source_path="/Books/local.pdf",source_path="/Books/other.pdf",local_path="/outside.pdf"}
local selected,failed,local_ready=local_loader(true,{direct=true,resolve_document=function(_,path) return path end},local_page)
expect(local_ready and selected=="/Books/local.pdf","shelf rendering uses only the revalidated local source")
selected,failed=local_loader(true,{direct=true,resolve_document=function() return nil end},local_page)
expect(not selected and failed and failed.code=="local_path","changed or unavailable shelf source cannot reach native IO")
local cached_page={name="00001.png",path="/Books/remote.pdf#mupdf/1",mupdf_page=1,size=100,
    mupdf_source_path="/cache/remote.pdf",local_path="/cache/remote.pdf"}
selected,failed,local_ready=local_loader(false,{direct=false,connection={kind="webdav"}},cached_page)
expect(local_ready and selected=="/cache/remote.pdf" and not failed,
    "normal reader can still render its already staged remote PDF")
print(("rebuild_0375_mupdf_loader_spec: %d checks"):format(checks))
