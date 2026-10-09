local Service=require("webdavmanga.document_cover")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local function le(n,count) local s="";for _=1,count do s=s..string.char(n%256);n=math.floor(n/256) end;return s end
-- Physical ZIP order differs from reading order. Exercise the actual parser.
local parts,central,offset={}, {},0
for _,name in ipairs({"10.jpg","001.jpg"}) do
    local body="image";local header="PK\003\004"..le(20,2)..le(0,8)..le(0,4)..le(#body,4)..le(#body,4)
        ..le(#name,2)..le(0,2)..name..body
    central[#central+1]="PK\001\002"..le(20,2)..le(20,2)..le(0,8)..le(0,4)..le(#body,4)..le(#body,4)
        ..le(#name,2)..le(0,12)..le(offset,4)..name
    parts[#parts+1]=header;offset=offset+#header
end
local cd=table.concat(central)
local bytes=table.concat(parts)..cd.."PK\005\006"..le(0,4)..le(2,2)..le(2,2)..le(#cd,4)..le(offset,4)..le(0,2)
local tasks,clients={},0
local async={run=function(work,done,options) tasks[#tasks+1]={work=work,done=done,options=options};return {cancel=function() end} end}
local service=Service:new{async=async,client_factory=function(c)
    clients=clients+1;expect(c.root_path=="/m","worker connection snapshot bounded to root")
    return {read_range=function(_,path,first,last)
        expect(path=="/m/book.cbz","parser uses book path rather than synthetic page URL")
        return bytes:sub(first+1,last+1),{["Content-Range"]=("bytes %d-%d/%d"):format(first,last,#bytes)}
    end,download=function() error("cover cannot download a whole book") end}
end}
local c={root_path="/m",password="never-return"}
for _,ext in ipairs({"zip","cbz","rar","cbr","7z","cb7","tar","cbt","epub","mobi","azw","azw3","prc","pdf"}) do
    expect(service:supports{name="a."..ext},"common comic extension supported: "..ext)
end
expect(not service:supports{name="a.txt"},"text books do not trigger comic parsing")
local document={name="book.cbz",path="/m/book.cbz",size=#bytes,is_file=true,etag="v1"}
local result,failed
local handle=service:resolve(c,document,{on_ready=function(i) result=i end,on_error=function(e) failed=e end})
local task=table.remove(tasks,1);local value=task.work();task.done(true,value)
expect(result and not failed and result.name=="001.jpg" and result.archive_entry_ordinal==2,
    "ZIP cover follows natural reading order, not the first physical entry")
expect(result.etag=="v1" and not result.password and not result.connection and not result.remote_read_at,
    "serialized first-page descriptor excludes credentials and callbacks")
result=nil;handle=service:resolve(c,document,{on_ready=function(i) result=i end})
task=table.remove(tasks,1);handle:cancel();task.done(true,value)
expect(not result,"late worker result after cancellation is ignored")
local before=clients
service:resolve(c,{name="book.cbz",path="/outside/book.cbz",size=#bytes},{on_error=function(e) failed=e end})
expect(clients==before and #tasks==0 and failed,"outside-root book rejected before network IO")
-- Unsorted TAR files also need their natural first page and persisted offset.
local function tar_item(name)
    local header=name..string.rep("\0",100-#name)..string.rep("\0",24)..("%011o\0"):format(5)
        ..string.rep("\0",12)..string.rep(" ",8).."0"..string.rep("\0",355)
    local sum=0;for i=1,#header do sum=sum+header:byte(i) end
    header=header:sub(1,148)..("%06o\0 "):format(sum)..header:sub(157)
    return header.."image"..string.rep("\0",507)
end
local tar=tar_item("10.jpg")..tar_item("001.jpg")..string.rep("\0",1024)
local tar_service=Service:new{async=async,client_factory=function()
    return {read_range=function(_,_,first,last) return tar:sub(first+1,last+1),
        {["Content-Range"]=("bytes %d-%d/%d"):format(first,last,#tar)} end}
end}
result=nil;tar_service:resolve(c,{name="book.cbt",path="/m/book.cbt",size=#tar},
    {on_ready=function(i) result=i end,on_error=function(e) failed=e end})
task=table.remove(tasks,1);task.done(true,task.work())
expect(result and result.name=="001.jpg" and result.archive_entry_offset==1536,
    "TAR cover natural order preserves the offset needed by the page loader")
local temporary,removals={},0
local local_pdf=Service:new{async=async,temp_name=function() return "/owned-cover.png" end,
    remove_file=function(path) temporary[path]=nil;removals=removals+1 end,
    client_factory=function() return {direct=true,resolve_document=function(_,path) return path,{size=100} end} end,
    mupdf_pages={inspect_local=function(_,path,_,target)
        expect(target and target.path=="/owned-cover.png","native cover target is owned by parent before worker starts")
        temporary[target.path]="png"
        return {index={get=function() return {name="00001.png",path=path.."#mupdf/1",mupdf_page=1,size=100} end}}
    end}}
local_pdf:resolve(c,{name="local.pdf",path="/m/local.pdf",size=100},{})
task=table.remove(tasks,1);value=task.work()
task.done(false,nil,"timeout",{reap_pending=true})
expect(temporary["/owned-cover.png"] and removals==0,"timeout does not unlink a target while native worker can still write")
task.options.on_reaped()
expect(not temporary["/owned-cover.png"] and removals==1,"reaped native worker leaves no owned temporary cover")
handle=local_pdf:resolve(c,{name="local.pdf",path="/m/local.pdf",size=100},{on_ready=function() error("cancelled result") end})
task=table.remove(tasks,1);value=task.work();handle:cancel();task.options.on_reaped()
task.done(true,value)
expect(not temporary["/owned-cover.png"],"cancelled native cover cleans its target and never publishes")
print(("document_cover_spec: %d checks"):format(checks))
