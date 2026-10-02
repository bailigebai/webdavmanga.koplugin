local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end
local Reader = require("webdavmanga.ui_reader")
local MemoryPages = require("webdavmanga.memory_pages")
local PanelSource = require("webdavmanga.panel_source")
local State = require("webdavmanga.state")
local reads, transfers, loader_requests, file_opens, cache_writes = {}, {}, {}, {}, {}
local jpeg = string.char(255,216,255,192,0,17,8,0,10,0,20,3,
    1,17,0,2,17,0,3,17,0,255,217)
local function buffer()
    return {getWidth=function() return 20 end, getHeight=function() return 10 end,
        free=function(self) self.frees=(self.frees or 0)+1 end}
end
local transfer = {run=function(work, done)
    local call = {work=work, done=done, cancels=0}
    transfers[#transfers+1] = call
    return {cancel=function() call.cancels=call.cancels+1 end}
end}
local connection = {kind="webdav",root_path="/books"}
local function connection_provider() return connection end
local function client_factory()
    return {read_image=function(_, path)
        reads[#reads+1]=path
        return jpeg
    end}
end
local source = PanelSource:new{transfer=transfer,client_factory=client_factory,
    connection_provider=connection_provider,draw_context={new=function() return {} end}}
local native_pages, native_documents, outputs = {}, {}, {}
source.mupdf = {openDocumentFromText=function(bytes, extension)
    expect(bytes == jpeg and extension == "jpg", "MuPDF must receive session-owned encoded bytes")
    local page = {getSize=function() return 20,10 end,
        draw_new=function() local result=buffer(); outputs[#outputs+1]=result; return result end,
        close=function(self) self.closes=(self.closes or 0)+1 end}
    local document = {openPage=function() return page end,
        close=function(self) self.closes=(self.closes or 0)+1 end}
    native_pages[#native_pages+1],native_documents[#native_documents+1]=page,document
    return document
end}
local current, statuses, cleanup = nil, {}, {}
local shell = {get_content_size=function() return 600,800 end,
    show_loading=function() end,
    show_page=function(_, value) current=value; return true end,
    show_status=function(_, value) statuses[#statuses+1]=value end,
    free_buffer_later=function(_, value) value:free(); return true end,
    close_now=function() current=nil; return true end}
local settings = {get_connection=connection_provider,
    get_reader=function() return {image_engine="memory",image_prefetch_enabled=false,
        panel_zoom_enabled=true,direction="normal",fit_mode="page",split_enabled=false} end}
local previous_open, previous_tmpname = io.open, os.tmpname
io.open=function(...) file_opens[#file_opens+1]={...}; error("unexpected body file") end
os.tmpname=function() file_opens[#file_opens+1]={}; error("unexpected temporary body file") end
local reader = Reader:new{loader={identity="panel-memory",request=function(...)
        loader_requests[#loader_requests+1]={...}
    end,cancel_generation=function() end},
    memory_pages=MemoryPages:new{transfer=transfer,client_factory=client_factory,
        connection_provider=connection_provider,renderer={renderImageData=function() return buffer() end}},
    panel_source=source,panel_detector={detect=function(raster)
        expect(raster.bytes==jpeg and raster.path==nil, "detection must use encoded bytes without a disk path")
        return {{id="one",x=0,y=0,w=1,h=1}}
    end},state=State:new(),settings=settings,
    progress={chapter_id=function() return "chapter" end,
        resolve=function() return {index=1,segment="whole"} end,save=function() end},
    cache={key_for=function(_,identity,path) return identity..path end,set_protected=function() end,
        put=function(...) cache_writes[#cache_writes+1]={...} end},
    ui={create_shell=function() return shell end,show_shell=function() end,close_shell=function() end,
        schedule=function(_,callback) cleanup[#cleanup+1]=callback end},open_chapter=function() end}
local image = {path="/books/001.jpg",name="001.jpg",width=20,height=10}
local index = {count=function() return 1 end,get=function() return image end,
    window=function() return {image} end}
local ok, err = pcall(function()
    local probe_ok = pcall(reader.memory_pages.open_file, "/__webdavmanga_panel_probe__", "rb")
    expect(not probe_ok and #file_opens == 1,
        "file monitor must intercept the opener captured by MemoryPages")
    file_opens[1] = nil -- Discard only the deliberate monitor calibration probe.
    expect(reader:open{manga={path="/books"},chapter={path="/books"},chapter_index=index}, "open memory image")
    transfers[1].done(true,transfers[1].work())
    local full_page = reader.page_buffer
    -- The saved selection is authoritative even if an existing page still
    -- carries an older effective-engine field until it is reloaded.
    reader.session_image_engine = "default"
    expect(current==full_page and not reader:enter_panel_mode(),
        "selected no-trace engine must reject dynamic panel entry")
    expect(#transfers==1 and #reads==1 and #loader_requests==0,
        "rejected panel entry must not start a second image transfer")
    expect(reader.panel_session==nil and reader.panel_entry==nil and current==full_page,
        "rejected panel entry must retain the ordinary memory page")
    expect(statuses[#statuses]=="无痕引擎不支持智能分格，请切换默认引擎。",
        "rejected panel entry must explain how to enable panel reading")
    expect(#native_pages==0 and #native_documents==0 and #outputs==0,
        "no-trace panel rejection must not create native panel resources")
    expect(#file_opens==0 and #cache_writes==0,
        "ordinary no-trace reading must remain free of body-page cache files")
    reader:force_close("back")
    for _, callback in ipairs(cleanup) do callback() end
    expect(full_page.frees==1 and #file_opens==0 and #cache_writes==0,
        "reader shutdown releases the body allocation without disk writes")
end)
io.open, os.tmpname = previous_open, previous_tmpname
if not ok then error(err) end
print(("panel_memory_spec: %d checks"):format(checks))
