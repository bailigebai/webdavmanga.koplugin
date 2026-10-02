local Pointer=require("webdavmanga.meguru_pointer")
local failures={}
local function test(name,run) local ok,err=pcall(run); if not ok then failures[#failures+1]=name..": "..tostring(err) end end
local function copy(t) local r={}; for k,v in pairs(t) do r[k]=v end; return r end
local function hash(s) local n=0; for i=1,#s do n=(n*31+s:byte(i))%4294967296 end; return ("%032x"):format(n) end
package.loaded["ffi/sha2"]={md5=hash}
local encoded={}
local json={encode=function(t) local keys={}; for k,v in pairs(t) do keys[#keys+1]=k.."="..tostring(v) end; table.sort(keys); local s=table.concat(keys,"\n"); encoded[s]=copy(t); return s end,
    decode=function(s) return encoded[s] and copy(encoded[s]) end}
local function fixture()
    local fs={files={},dirs={},writes={},removed={}}
    fs.exists=function(p) return fs.files[p]~=nil or fs.dirs[p] end
    fs.make_path=function(p) fs.dirs[p]=true; return true end
    fs.mkdir=function(p) if fs.dirs[p] then return nil end; fs.dirs[p]=true; return true end
    fs.rmdir=function(p) fs.dirs[p]=nil; return true end
    fs.list=function(p) local found={}; for d in pairs(fs.dirs) do if d:match("^(.*)/[^/]+$")==p then found[#found+1]=d:match("([^/]+)$") end end; local i=0; return function() i=i+1; return found[i] end end
    fs.open=function(p,mode)
        if mode=="rb" then if not fs.files[p] then return nil end; return {read=function() return fs.files[p] end,close=function() return true end} end
        fs.writes[#fs.writes+1]=p
        return {write=function(_,s) fs.files[p]=s; return true end,flush=function() if fs.interleave then local f=fs.interleave; fs.interleave=nil; f() end; return true end,close=function() return true end}
    end
    fs.rename=function(a,b) fs.files[b],fs.files[a]=fs.files[a],nil; return true end
    fs.remove=function(p) fs.removed[#fs.removed+1]=p; fs.files[p]=nil; return true end
    return fs, Pointer:new{root="/books",per_server=false,fs=fs,json=json,md5=hash}
end
local desc={source_id="source-1",server_kind="komga",series_id="series-1",series_name="Series",
    chapter_id="chapter-1",chapter_name="Book",page_count=27,server_last_read=2,
    stream_template="https://srv/api/v1/books/chapter-1/pages/{pageNumber}"}
test("#4 reuse refreshes metadata and merges progress",function()
    local fs,p=fixture(); local path=assert(p:save(desc))
    local fresh=copy(desc); fresh.page_count=30; fresh.server_last_read=20
    fresh.stream_template=desc.stream_template.."?width={width}"; fresh.cover_url="https://srv/cover"
    assert(p:save(fresh)==path,"stable file path changed")
    local loaded=assert(p:load(path))
    assert(loaded.page_count==30 and loaded.server_last_read==20 and loaded.stream_template==fresh.stream_template and loaded.cover_url==fresh.cover_url,
        "existing pointer discarded newly observed routing/progress")
    fresh.server_last_read=5; assert(p:save(fresh)==path)
    assert(p:load(path).server_last_read==20,"stale feed lowered server high-water")
end)
test("#6 interleaved same identity writers converge",function()
    local fs,a=fixture(); local b=Pointer:new{root="/books",per_server=false,fs=fs,json=json,md5=hash}
    local second=copy(desc); second.server_last_read=20
    local b_path,b_reason
    fs.interleave=function() b_path,b_reason=b:save(second) end
    local a_path=assert(a:save(desc))
    if not b_path then assert(b_reason=="pointer_busy","contention is a classified retry"); b_path=assert(b:save(second)) end
    assert(a_path==b_path and a:load(a_path).server_last_read==20,"writers lost the newer observation")
    assert(fs.writes[1]~=fs.writes[2],"writers shared one temporary file")
    for path in pairs(fs.files) do assert(path==a_path,"owned temporary file leaked") end
end)
test("#6 conflicting identity retains both verified finals",function()
    local fs,a=fixture(); local b=Pointer:new{root="/books",per_server=false,fs=fs,json=json,md5=hash}
    local other=copy(desc); other.chapter_id="chapter-2"; other.stream_template="https://srv/api/v1/books/chapter-2/pages/{pageNumber}"
    local path2,why
    fs.interleave=function() path2,why=b:save(other) end
    local path1=assert(a:save(desc)); if not path2 then assert(why=="pointer_busy"); path2=assert(b:save(other)) end
    assert(path1~=path2 and a:load(path1).chapter_id=="chapter-1" and b:load(path2).chapter_id=="chapter-2","same title writers overwrote another identity")
end)
test("#6 rename failure never deletes another final",function()
    local fs,p=fixture(); local target=assert(p:path_for(desc))
    fs.rename=function(a,b) fs.files[b]="other writer final"; return false end
    assert(not p:save(desc)); assert(fs.files[target]=="other writer final","failure cleanup removed somebody else's final")
    for _,path in ipairs(fs.removed) do assert(path~=target,"final deletion is never cleanup-owned") end
    for path in pairs(fs.dirs) do assert(not path:match("%.meguru%-publish%.lock$"),"normal failure leaked the owned lock") end
end)
test("#7 directories isolate series and sources, reuse rename",function()
    local fs,p=fixture(); local path=assert(p:save(desc)); local directory=path:match("^(.*)/")
    local other=copy(desc); other.series_id="series-2"
    assert(p:path_for(other):match("^(.*)/")~=directory,"same-title series share cover directory")
    other=copy(desc); other.source_id="source-2"
    assert(p:path_for(other):match("^(.*)/")~=directory,"cross-source series share cover directory")
    other=copy(desc); other.series_name="Renamed"; other.chapter_id="chapter-2"
    assert(p:path_for(other):match("^(.*)/")==directory,"renamed series lost its canonical cover directory")
    assert(p:load(path).chapter_id=="chapter-1","existing exact path is no longer readable")
end)
test("#12 reserved Windows names",function()
    local fs,p=fixture()
    for _,name in ipairs({"CON","NUL.txt","aux.jpg","PRN","com1","COM9.txt","lpt1","LPT9.zip"}) do
        local d=copy(desc); d.chapter_name=name
        assert(p:path_for(d):match("/([^/]+)%.meguru$"):sub(1,1)=="_","reserved basename not prefixed: "..name)
    end
end)
assert(#failures==0,table.concat(failures,"\n"))
print("rebuild_0405_final_pointer_spec: refresh, races, series paths and reserved names passed")
