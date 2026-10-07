local Cover = require("webdavmanga.cover")
local Sort = require("webdavmanga.natural_sort")
local checks=0; local function expect(v,m) checks=checks+1; assert(v,m) end
local function index(items) return {count=function() return #items end,get=function(_,i) return items[i] end} end
local function directory(images,folders)
    Sort.sort(images, function(i) return i.name end)
    return {images=function() return index(images) end,folders=function() return index(folders or {}) end,
        close=function() end}
end
local a={name="1",path="/m/A/1",is_folder=true}
local b={name="2",path="/m/A/2",is_folder=true}
local img={name="001.jpg",path=b.path.."/001.jpg",size=20,etag="v1",modified="today"}
local dirs={
    ["/m/A"]=directory({},{a,b}), [a.path]=directory({},{{path=a.path.."/deep"}}),
    [b.path]=directory({{name="10.jpg",path=b.path.."/10.jpg"},img,{name="2.jpg",path=b.path.."/2.jpg"}}),
}
local loaded,queue,stored={}, {},{}
local ds={load=function(_,path,cb) loaded[#loaded+1]=path
    if dirs[path] then cb.on_ready(dirs[path]) else cb.on_error({code="transport"}) end
    return {cancel=function() end} end}
local library={get_cover=function(_,_,p) return stored[p] end,
    set_cover=function(_,_,p,i) stored[p]={manga_path=p,image=i}; return true end,
    set_no_cover=function(_,_,p) stored[p]={manga_path=p,none=true}; return true end}
local service=Cover:new{library=library,directory_store=ds,search_all_children=true,
    scheduler={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}}
local function drain() while #queue>0 do table.remove(queue,1)() end end
local connection={root_path="/m",server_url="http://nas",username="u",password="secret"}
local record={manga={name="A",path="/m/A",is_folder=true}}
local result; service:resolve(connection,record,{on_ready=function(i) result=i end}); drain()
expect(result and result.path==img.path, "empty first child must not hide the next child's first image")
expect(result.modified=="today", "source change metadata retained")
expect(#loaded==3, "no recursion into grandchildren")
stored={}; loaded={}; dirs["/m/A"]=directory({{name="2.jpg",path="/m/A/2.jpg"},
    {name="001.jpg",path="/m/A/001.jpg"},{name="10.jpg",path="/m/A/10.jpg"}},{a,b})
service:resolve(connection,record,{on_ready=function(i) result=i end});drain()
expect(result.path=="/m/A/001.jpg" and #loaded==1, "direct numeric first image wins")
stored={}; dirs["/m/A"]=directory({},{a,b}); dirs[b.path]=nil
service:resolve(connection,record,{});drain()
expect(stored["/m/A"]==nil, "transport failure must not be cached as permanent absence")
dirs[b.path]=directory({img});service:resolve(connection,record,{on_ready=function(i) result=i end});drain()
expect(result.path==img.path, "failed selection can retry")
stored={}; loaded={}; result=nil
local handle=service:resolve(connection,record,{on_ready=function(i) result=i end})
handle:cancel();drain()
expect(result==nil and #loaded==2, "cancel stops sibling search")
local gets,closed=0,0
local folders={count=function() return 10000 end,get=function(_,i)
    gets=gets+1;return {path="/m/L/"..i,name=tostring(i),is_folder=true} end}
dirs["/m/L"]={images=function() return index({}) end,folders=function() return folders end,
    close=function() closed=closed+1 end}
dirs["/m/L/1"]=directory({})
local large=service:resolve(connection,{manga={path="/m/L",name="L"}},{})
expect(gets<=2 and closed==0,"large child index is read incrementally and kept open")
large:cancel();drain()
expect(closed==1 and gets<=2,"cancel releases parent index without scanning remaining children")
print(("bookshelf_cover_spec: %d checks"):format(checks))
