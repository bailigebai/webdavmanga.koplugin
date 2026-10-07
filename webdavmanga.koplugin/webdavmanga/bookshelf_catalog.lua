local Path = require("webdavmanga.path")
local Formats = require("webdavmanga.image_formats")
local Catalog = {}; Catalog.__index = Catalog

local function safe_image(image, root)
    if type(image) ~= "table" or not Formats.is_supported(image.name) then return nil end
    local path=Path.normalize_remote(image.path or "")
    if path=="" or not Path.is_within_remote(path,root) then return nil end
    return {name=tostring(image.name),path=path,size=tonumber(image.size),
        etag=image.etag and tostring(image.etag),modified=image.modified and tostring(image.modified)}
end
function Catalog:new(options)
    return setmetatable({cache=assert(options.cache),json=options.json or require("json"),
        identity_provider=assert(options.identity_provider),sequence=0},self)
end
function Catalog:_namespace(connection) return self.identity_provider(connection).."\0bookshelf-selection-v1" end
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
