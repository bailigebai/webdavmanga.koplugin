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
local document_images={
    {name="cover.jpg",path="/m/a.epub#zip/1/spine/1",size=12,
        archive_kind="zip",archive_format="epub",archive_remote_path="/m/a.epub",archive_source_size=123,
        archive_entry_name="cover.jpg",archive_entry_ordinal=1,archive_spine_position=1,archive_local_offset=0,
        archive_method=0,archive_flags=0,archive_crc32=0,archive_compressed_size=12,archive_size=12},
    {name="00002.jpg",path="/m/a.mobi#mobi/2",size=12,mobi_remote_path="/m/a.mobi",
        mobi_source_size=123,mobi_record=2,mobi_offset=50,mobi_size=12},
    {name="00001.jpg",path="/m/a.pdf#pdf/1",size=12,page=1,pdf_image=true,
        pdf_remote_path="/m/a.pdf",pdf_source_size=123,pdf_image_offset=50,pdf_image_length=12},
    {name="001.jpg",path="/m/a.cbt#tar/2",size=5,archive_kind="tar",archive_format="cbt",
        archive_remote_path="/m/a.cbt",archive_source_size=3072,archive_entry_name="001.jpg",
        archive_size=5,archive_method=0,archive_entry_offset=1536},
    {name="00001.png",path="/m/a.pdf#mupdf/1",size=123,mupdf_page=1,
        mupdf_source_size=123,mupdf_source_path="/m/a.pdf",source_path="/m/a.pdf"},
}
for i,descriptor in ipairs(document_images) do
    descriptor.remote_read_at=function() error("functions cannot be cached") end
    descriptor.password="never-store"
    expect(catalog:set_cover(c,"/m/book"..i,descriptor),"persist typed first-page descriptors")
    local restored=service():get_cover(c,"/m/book"..i).image
    expect(restored.path==descriptor.path and not restored.remote_read_at and not restored.password,
        "roundtrip drops callbacks/credentials while keeping descriptor identity")
    expect(restored.archive_spine_position==descriptor.archive_spine_position and restored.mobi_offset==descriptor.mobi_offset
        and restored.pdf_image_offset==descriptor.pdf_image_offset,"roundtrip keeps page extraction fields")
end
local bad=document_images[3];bad.pdf_image_offset=120
expect(not catalog:set_cover(c,"/m/bad",bad),"range outside source rejected before persistence")
bad.pdf_image_offset=50;bad.pdf_remote_path="/outside/a.pdf"
expect(not catalog:set_cover(c,"/m/bad",bad),"embedded document cannot escape configured root")
document_images[5].source_path="/m/other.pdf"
expect(not catalog:set_cover(c,"/m/bad",document_images[5]),"native rendering source must match the validated book")
expect(not catalog:set_cover(c,"/m/bad",{name="001.jpg",path="/m/a.mobi#mobi/1",mobi_path="/m/other.mobi",
    mobi_record=1,mobi_offset=0,mobi_size=16}),"shelf cannot cache local MOBI extraction routes")
local local_archive={};for k,v in pairs(document_images[1]) do local_archive[k]=v end
local_archive.archive_local_path="/m/other.epub"
expect(not catalog:set_cover(c,"/m/bad",local_archive),"shelf cannot cache local archive extraction routes")
local mixed={};for k,v in pairs(document_images[2]) do mixed[k]=v end
mixed.pdf_image=true
expect(not catalog:set_cover(c,"/m/bad",mixed),"contradictory extraction adapters rejected")
cache.unified_quota=true;cache.write_budget=function() return 0 end
local count=#snapshots;local opened_count=0;local open=cache.fs.open
cache.fs.open=function(...) opened_count=opened_count+1;return open(...) end
expect(not catalog:set_cover(c,"/m/C",image) and opened_count==0,
 "selection index checks capacity before opening any output")


print(("bookshelf_catalog_spec: %d checks"):format(checks))
