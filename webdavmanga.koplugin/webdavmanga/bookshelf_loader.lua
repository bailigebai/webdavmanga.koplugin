local Errors = require("webdavmanga.errors")
local Processor = require("webdavmanga.page_processor")
local Loader = {}; Loader.__index = Loader
-- Worst-case RGBA pixels plus PNG scanline/compression framing overhead.
Loader.MAX_PNG_BYTES = 384*512*4+65536

function Loader:new(options)
    return setmetatable({cache=assert(options.cache), loader=assert(options.loader),
        identity=assert(options.identity), processor=options.processor or Processor,
        renderer=options.renderer, image_probe=options.image_probe or require("webdavmanga.image_probe"),
        generations={}, sequence=0}, self)
end

function Loader:cover_key(image)
    local version = table.concat({image.path, tostring(image.etag or ""),
        tostring(image.modified or ""), tostring(image.size or "")}, "\0")
    return self.cache:key_for(self.identity, version, "cover")
end

function Loader:protect_cover(generation, image)
    local state = self.generations[generation]
    if not state then state={keys={},canceled=false}; self.generations[generation]=state end
    local key=self:cover_key(image)
    if not state.keys[key] then state.keys[key]=true; self.cache:protect(key) end
    return state,key
end

function Loader:_release_source(identity, image, path)
    local key=self.cache:key_for(identity,image.path,"cover")
    local record=self.cache.entries[key]
    -- Ownership is checked against the generated cache record. Local source
    -- paths never enter this table and must never be removed by thumbnailing.
    if record and record.path==path then self.cache:remove(key) end
end

function Loader:request_cover(generation, image, callbacks)
    callbacks=callbacks or {}
    local state,key=self:protect_cover(generation,image)
    local path=self.cache:lookup(key)
    if path then if callbacks.on_ready then callbacks.on_ready(path,true) end; return true end
    if self.cache.unified_quota then
        local direct=self.loader._uses_direct_local and self.loader:_uses_direct_local()
        local required=not direct and (tonumber(image.size) or 0) or 0
        local available=self.cache:write_budget(Loader.MAX_PNG_BYTES,required)
        if available<1 or required>available then
            if callbacks.on_error then callbacks.on_error(Errors.storage("cache_limit")) end
            return nil
        end
        self.cache.cover_limit_bytes=available
    end
    local source_identity=self.loader.identity
    return self.loader:request_cover(generation,image,{
        on_ready=function(source_path,_cached,source_metadata)
            if state.canceled then self:_release_source(source_identity,image,source_path); return end
            local source_key=self.cache:key_for(source_identity,image.path,"cover")
            self.cache:protect(source_key)
            self.sequence=self.sequence+1
            local token="thumb"..self.sequence
            local _,part=self.cache:paths_for(key,"png",token)
            local source_info=source_metadata
            if not source_info or not source_info.width or not source_info.height then
                local ok,info=pcall(self.image_probe.inspect,source_path,nil)
                source_info=ok and info or nil
            end
            local width,height
            if source_info then width,height=Processor.target_size(source_info.width,source_info.height,
                {fit_mode="page",split_enabled=false},384,512) end
            local called,metadata,err
            if width and height and (not self.cache.unified_quota
                or self.cache:write_budget(65536,Loader.MAX_PNG_BYTES,part)>=Loader.MAX_PNG_BYTES) then
                called,metadata,err=pcall(self.processor.process,source_path,part,
                    {target_width=width,target_height=height},{renderer=self.renderer})
            else called=true;err="cache_limit" end
            self.cache:unprotect(source_key)
            self:_release_source(source_identity,image,source_path)
            if not called then err=metadata; metadata=nil end
            if state.canceled or not metadata then
                self.cache:discard_part(key,"png",token)
                if not state.canceled and callbacks.on_error then callbacks.on_error(Errors.storage(err)) end
                return
            end
            metadata.key=key;metadata.kind="cover";metadata.extension="png"
            metadata.remote_path=image.path;metadata.identity=self.identity
            metadata.etag=image.etag;metadata.modified=image.modified
            local published,publish_error=self.cache:publish(metadata,part)
            if not published then
                self.cache:discard_part(key,"png",token)
                if callbacks.on_error then callbacks.on_error(Errors.storage(publish_error)) end
                return
            end
            if callbacks.on_ready then callbacks.on_ready(published,false,metadata) end
        end,
        on_error=function(err) if not state.canceled and callbacks.on_error then callbacks.on_error(err) end end,
    })
end

function Loader:cancel_cover_generation(generation)
    local state=self.generations[generation]
    if state then
        state.canceled=true
        for key in pairs(state.keys) do self.cache:unprotect(key) end
        self.generations[generation]=nil
    end
    pcall(self.loader.cancel_cover_generation,self.loader,generation)
    if self.cache.cleanup_browse then pcall(self.cache.cleanup_browse,self.cache,true) end
end
function Loader:cancel_all()
    local generations={};for generation in pairs(self.generations) do generations[#generations+1]=generation end
    for _,generation in ipairs(generations) do self:cancel_cover_generation(generation) end
    self.loader:cancel_all()
end

return Loader
