local Cover=require("webdavmanga.cover")
local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local function index(items) return {count=function() return #items end,get=function(_,i) return items[i] end} end
local function dir(images,documents,folders)
    return {images=index(images or {}),documents=index(documents or {}),folders=index(folders or {}),close=function() end}
end
local book={name="001.epub",path="/m/A/001.epub",size=123,is_file=true,etag="book-v1"}
local image={name="cover.jpg",path=book.path.."#zip/1",size=12,
    archive_kind="zip",archive_format="epub",archive_source_size=123,archive_remote_path=book.path,
    archive_entry_name="cover.jpg",archive_entry_ordinal=1,archive_spine_position=1,
    archive_local_offset=0,archive_method=0,archive_flags=0,archive_crc32=0,archive_compressed_size=12,archive_size=12}
local dirs={["/m/A"]=dir({}, {book}),["/m"]=dir({}, {},{{name="A",path="/m/A",is_folder=true}})}
local selected,stored,loads,queue={}, {},0,{}
local document_cover={supports=function(_,v) return v.name:match("%.epub$")~=nil end,
    resolve=function(_,c,d,cb) selected[#selected+1]=d.path;expect(d.size==123,"document bytes retained for bounded Range")
        cb.on_ready(image);return {cancel=function() end} end}
local service=Cover:new{library={get_cover=function(_,_,p) return stored[p] end,
    set_cover=function(_,_,p,i) stored[p]={manga_path=p,image=i};return true end,set_no_cover=function() return true end},
    directory_store={load=function(_,p,cb) loads=loads+1;cb.on_ready(assert(dirs[p]));return {cancel=function() end} end},
    search_all_children=true,document_cover=document_cover,scheduler={scheduleIn=function(_,_,cb) queue[#queue+1]=cb end}}
local function drain() while #queue>0 do table.remove(queue,1)() end end
local c={root_path="/m"};local result
service:resolve(c,{manga={name="A",path="/m/A",is_folder=true}},{on_ready=function(i) result=i end});drain()
expect(result and result.archive_spine_position==1,"document-only folders get first reading-page cover")
service:resolve(c,{manga={name="m",path="/m",is_folder=true}},{on_ready=function(i) result=i end});drain()
expect(result and #selected==2,"parent shelf searches document in next layer")
local before=loads
service:resolve(c,{manga=book},{on_ready=function(i) result=i end});drain()
expect(result and loads==before,"book cards inspect the file without treating it as a directory")
local direct={name="001.jpg",path="/m/A/001.jpg"};stored={};dirs["/m/A"]=dir({direct},{book})
before=#selected;service:resolve(c,{manga={path="/m/A",name="A"}},{on_ready=function(i) result=i end});drain()
expect(result.path==direct.path and #selected==before,"loose images have priority over documents")
stored={};dirs["/m/A"]=dir({}, {book});local delayed,canceled
document_cover.resolve=function(_,_,_,cb) delayed=cb;return {cancel=function() canceled=true end} end
local handle=service:resolve(c,{manga={path="/m/A",name="A"}},{on_ready=function(i) result=i end})
result=nil;handle:cancel();delayed.on_ready(image)
expect(canceled and not result and not stored["/m/A"],"cancel prevents late cover publication")
print(("bookshelf_document_cover_spec: %d checks"):format(checks))
