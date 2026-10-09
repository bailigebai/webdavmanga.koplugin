-- Inspect one reading page, without opening a reader or downloading a book.
local Errors=require("webdavmanga.errors")
local Formats=require("webdavmanga.image_formats")
local Path=require("webdavmanga.path")
local RemoteStream=require("webdavmanga.remote_stream")
local Cover=require("webdavmanga.cover")
local Service={};Service.__index=Service
local archives={zip=true,cbz=true,epub=true,rar=true,cbr=true,["7z"]=true,cb7=true,tar=true,cbt=true}
local mobi={mobi=true,azw=true,azw3=true,prc=true}
function Service:new(options)
    return setmetatable({client_factory=assert(options.client_factory),async=options.async or require("webdavmanga.async"),
        archive_pages=options.archive_pages or require("webdavmanga.archive_pages"):new(),
        mobi_pages=options.mobi_pages or require("webdavmanga.mobi_pages"):new(),
        pdf_pages=options.pdf_pages or require("webdavmanga.pdf_image_stream"):new(),
        mupdf_pages=options.mupdf_pages or require("webdavmanga.mupdf_pages"):new(),
        temp_name=options.temp_name or os.tmpname,remove_file=options.remove_file or os.remove},self)
end
function Service:supports(document)
    local kind=Formats.extension(document and (document.name or document.path))
    return archives[kind]==true or mobi[kind]==true or kind=="pdf"
end
function Service:resolve(connection,document,callbacks)
    callbacks=callbacks or {}
    local path=Path.normalize_remote(document and document.path or "")
    local function fail(reason)
        if callbacks.on_error then callbacks.on_error(Errors.image_decode(reason,"remote")) end
    end
    if not self:supports(document) or path=="" or not Path.is_within_remote(path,connection.root_path) then
        fail("invalid_document_cover_path");return {cancel=function() end}
    end
    local snapshot={};for k,v in pairs(connection) do
        if type(v)=="string" or type(v)=="number" or type(v)=="boolean" then snapshot[k]=v end
    end
    local kind=Formats.extension(document.name or path)
    local native_target,cleaned
    if kind=="pdf" then
        local ok,target=pcall(self.temp_name)
        if not ok or type(target)~="string" or target=="" then
            fail("document_cover_target_unavailable");return {cancel=function() end}
        end
        native_target={page=1,path=target}
    end
    local function cleanup()
        if native_target and not cleaned then
            cleaned=true;pcall(self.remove_file,native_target.path)
        end
    end
    local size,etag,modified=tonumber(document.size),document.etag,document.modified
    local canceled=false
    local handle=self.async.run(function()
        local client=self.client_factory(snapshot)
        local local_path,local_metadata
        if client.direct and client.resolve_document then
            local_path,local_metadata=client:resolve_document(path)
            if not local_path then return {error="local_document_cover_unavailable"} end
        end
        local source_size=local_metadata and local_metadata.size or size
        if not source_size or source_size<1 then return {error="document_cover_size_missing"} end
        local book,err
        if local_path and kind=="pdf" then
            book,err=self.mupdf_pages:inspect_local(local_path,kind,native_target)
        else
            local stream=RemoteStream:new{size=source_size,exact_reads=archives[kind]==true,
                read_range=function(first,last) return client:read_range(path,first,last) end}
            if not stream then return {error="invalid_document_cover_size"} end
            local descriptor={size=source_size,format=kind,name=document.name,
                read_at=function(offset,count) return stream:read_at(offset,count) end}
            if archives[kind] then
                local sequential=kind=="rar" or kind=="cbr" or kind=="7z" or kind=="cb7"
                book,err=self.archive_pages:inspect_remote(descriptor,kind,path,
                    {page_limit=(sequential or kind=="epub") and 1 or nil,preserve_archive_order=sequential})
            elseif mobi[kind] then book,err=self.mobi_pages:inspect_remote(descriptor,path)
            else
                book,err=self.pdf_pages:inspect_remote(descriptor,path)
                if not book and self.mupdf_pages:remote_capability() then
                    book,err=self.mupdf_pages:inspect_remote(descriptor,path,native_target)
                end
            end
            if stream.failure then return {error=stream.failure} end
        end
        if not book or not book.index then return {error=err or "document_cover_unavailable"} end
        local first=book.index:get(1)
        if not first then return {error="document_cover_empty"} end
        if first.mupdf_page then
            first.path=path.."#mupdf/1";first.mupdf_source_size=source_size
            if local_path then first.mupdf_source_path=local_path;first.source_path=local_path
            else first.mupdf_remote_path=path end
        end
        first.etag=etag;first.modified=tostring(modified or (local_metadata and local_metadata.modified) or "")
        local image=Cover.copy_image(first,connection.root_path)
        return image and {image=image} or {error="document_cover_descriptor_invalid"}
    end,function(ok,result,err,state)
        if not (state and state.reap_pending) then cleanup() end
        if canceled then return end
        if not ok or type(result)~="table" or result.error or not result.image then
            return fail(type(result)=="table" and result.error or err or "document_cover_failed")
        end
        if callbacks.on_ready then callbacks.on_ready(result.image) end
    end,{max_payload_bytes=65536,on_cancelled=cleanup,on_reaped=cleanup})
    return {cancel=function()
        canceled=true
        if handle and handle.cancel then handle:cancel() end
    end}
end
return Service
