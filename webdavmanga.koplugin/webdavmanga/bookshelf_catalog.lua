local Path = require("webdavmanga.path")
local Cover = require("webdavmanga.cover")
local BookIndex = require("webdavmanga.book_index")
local Catalog = {}; Catalog.__index = Catalog

local function safe_image(image, root)
    local copy=Cover.copy_image(image,root)
    if not copy then return nil end
    -- DocumentCover uses Range for local and remote MOBI/archive files alike.
    -- These other routes belong to reader history, never a shelf selection.
    if copy.mobi_path or copy.archive_local_path then return nil end
    if copy.mobi_record and not copy.mobi_remote_path then return nil end
    if copy.archive_entry_name and not copy.archive_kind then return nil end
    if copy.source_path and not copy.mupdf_page then return nil end
    local adapters=0
    for _,enabled in ipairs({copy.archive_kind~=nil,copy.mobi_remote_path~=nil,
        copy.pdf_image==true,copy.mupdf_page~=nil}) do
        if enabled then adapters=adapters+1 end
    end
    if adapters>1 then return nil end
    for key,value in pairs(copy) do
        if type(value)=="string" and (#value>32768 or value:find("%z")) then return nil end
        if type(value)=="number" and (value<0 or value>4294967295 or value~=math.floor(value)) then return nil end
    end
    for _,key in ipairs({"archive_remote_path","mobi_remote_path","pdf_remote_path","mupdf_remote_path",
        "mupdf_source_path","source_path","mobi_path","archive_local_path"}) do
        if copy[key] and not Path.is_within_remote(copy[key],root) then return nil end
    end
    if copy.archive_kind then
        local entry={};for key,value in pairs(copy) do
            if key~="modified" and key~="is_folder" then entry[key]=value end
        end
        entry.is_file=true
        if not BookIndex.from_table{version=1,count=1,items={entry}} then return nil end
    elseif copy.mobi_remote_path then
        if not copy.mobi_source_size or copy.mobi_source_size<1 or not copy.mobi_record or copy.mobi_record<1
            or not copy.mobi_offset or not copy.mobi_size or copy.mobi_size<1
            or copy.mobi_offset+copy.mobi_size>copy.mobi_source_size
            or copy.path~=copy.mobi_remote_path.."#mobi/"..copy.mobi_record then return nil end
    elseif copy.pdf_image then
        if not copy.pdf_remote_path or not copy.pdf_source_size or copy.pdf_source_size<1
            or not copy.page or copy.page<1 or copy.path~=copy.pdf_remote_path.."#pdf/"..copy.page then return nil end
        if copy.pdf_image_offset or copy.pdf_image_length then
            if not copy.pdf_image_offset or not copy.pdf_image_length or copy.pdf_image_length<1
                or copy.pdf_image_offset+copy.pdf_image_length>copy.pdf_source_size then return nil end
        elseif not copy.pdf_page_object or copy.pdf_page_object<1 then return nil end
    elseif copy.mupdf_page then
        local source=copy.mupdf_remote_path or copy.mupdf_source_path
        if not source or copy.mupdf_page<1 or copy.path~=source.."#mupdf/"..copy.mupdf_page
            or not copy.mupdf_source_size or copy.mupdf_source_size<1 then return nil end
        if copy.source_path and copy.source_path~=copy.mupdf_source_path then return nil end
    end
    return copy
end
function Catalog:new(options)
    return setmetatable({cache=assert(options.cache),json=options.json or require("json"),
        identity_provider=assert(options.identity_provider),sequence=0},self)
end
function Catalog:_namespace(connection) return self.identity_provider(connection).."\0bookshelf-selection-v2" end
function Catalog:_key(connection,path) return self.cache:key_for(self:_namespace(connection),path) end
function Catalog:get_cover(connection,path)
    path=Path.normalize_remote(path or "")
    if path=="" or not Path.is_within_remote(path,connection.root_path) then return nil end
    local key=self:_key(connection,path)
    local file_path=self.cache:lookup(key)
    if not file_path then return nil end
    local file=self.cache.fs.open(file_path,"rb")
    if not file then self.cache:remove(key);return nil end
    local bytes=file:read(65537);file:close()
    local ok,record=pcall(self.json.decode,bytes or "")
    if not ok or not bytes or #bytes>65536 or type(record)~="table" or record.manga_path~=path then
        self.cache:remove(key);return nil
    end
    if record.none==true then return {manga_path=path,none=true} end
    local image=safe_image(record.image,connection.root_path)
    if not image then self.cache:remove(key);return nil end
    return {manga_path=path,image=image}
end
function Catalog:_save(connection,path,image,none)
    path=Path.normalize_remote(path or "")
    if path=="" or not Path.is_within_remote(path,connection.root_path) then return nil end
    image=image and safe_image(image,connection.root_path)
    if not none and not image then return nil end
    local ok,bytes=pcall(self.json.encode,{manga_path=path,image=image,none=none or nil})
    if not ok or type(bytes)~="string" or #bytes>65536 then return nil end
    local key=self:_key(connection,path)
    if self.cache.unified_quota and self.cache:write_budget(65536,#bytes)<#bytes then return nil end
    self.sequence=self.sequence+1;local token="selection"..self.sequence
    local _,part=self.cache:paths_for(key,"manifest",token)
    local file=self.cache.fs.open(part,"wb")
    if not file then return nil end
    local wrote,result=pcall(file.write,file,bytes)
    local closed,close_result=pcall(file.close,file)
    if not wrote or not result or not closed or not close_result then
        self.cache:discard_part(key,"manifest",token);return nil
    end
    local published=self.cache:publish({key=key,kind="manifest",extension="manifest",
        validated=true,remote_path=path,identity=self:_namespace(connection)},part)
    if not published then self.cache:discard_part(key,"manifest",token) end
    return published and true or nil
end
function Catalog:set_cover(connection,path,image) return self:_save(connection,path,image,false) end
function Catalog:set_no_cover(connection,path) return self:_save(connection,path,nil,true) end
function Catalog:invalidate(connection,path)
    local namespace=self:_namespace(connection)
    local keys={}
    for key,record in pairs(self.cache.entries) do
        if record.identity==namespace and Path.is_within_remote(record.remote_path,path) then keys[#keys+1]=key end
    end
    for _,key in ipairs(keys) do self.cache:remove(key) end
end

return Catalog
