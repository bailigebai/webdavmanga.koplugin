local checks=0; local function expect(v,m) checks=checks+1;assert(v,m) end
local loaded,Catalog=pcall(require,"webdavmanga.bookshelf_catalog")
expect(loaded,"bookshelf selection index must persist separately from reading history")
local files,entries,snapshots={}, {},{}
local json={encode=function(value) local bytes="json"..tostring(#snapshots+1)
    snapshots[#snapshots+1]=value;return bytes end,
    decode=function(bytes) return snapshots[tonumber(bytes:sub(5))] end}
local cache={entries=entries,root="/shelf",key_for=function(_,id,path) return id..path end,
    lookup=function(_,k) return entries[k] and entries[k].path end,
    paths_for=function(_,k) return k..".manifest",k..".part" end,
    fs={open=function(path,mode)
        if mode=="rb" then if not files[path] then return nil end
            return {read=function() return files[path] end,close=function() end} end
        return {write=function(_,bytes) files[path]=bytes;return true end,close=function() return true end}
    end},
    remove=function(_,k) if entries[k] then files[entries[k].path]=nil end;entries[k]=nil end,
    publish=function(_,r,part) r.path=r.key..".manifest";files[r.path]=files[part];files[part]=nil;entries[r.key]=r;return r.path end,
    discard_part=function(_,k) files[k..".part"]=nil end}
local function service() return Catalog:new{cache=cache,json=json,
    identity_provider=function(c) return c.username.."@"..c.root_path end} end
local catalog=service();local c={username="u",root_path="/m",password="never-store"}
local image={name="001.jpg",path="/m/A/001.jpg",etag="v1",modified="today",size=99}
expect(catalog:set_cover(c,"/m/A",image),"selection is persisted")
expect(service():get_cover(c,"/m/A").image.etag=="v1","new instance uses persisted selection")
expect(not catalog:get_cover({username="other",root_path="/m"},"/m/A"),"users isolated")
expect(not catalog:get_cover({username="u",root_path="/other"},"/m/A"),"root boundary enforced")
expect(not catalog:set_cover(c,"/m/A",{path="/elsewhere/001.jpg",name="001.jpg"}),"out-of-root image rejected")
expect(catalog:set_no_cover(c,"/m/B") and catalog:get_cover(c,"/m/B").none,"successful absence can be cached")
expect(snapshots[1].password==nil and snapshots[1].image.password==nil,"selection excludes credentials")
catalog:invalidate(c,"/m/A")
expect(not catalog:get_cover(c,"/m/A") and catalog:get_cover(c,"/m/B").none,"refresh only invalidates matching subtree")
print(("bookshelf_catalog_spec: %d checks"):format(checks))
