local Errors = require("webdavmanga.errors")
local Processor = require("webdavmanga.page_processor")
local Reporter = require("webdavmanga.error_reporter")
local unpack_values=table.unpack or unpack
local Loader = {}; Loader.__index = Loader
-- Worst-case RGBA pixels plus PNG scanline/compression framing overhead.
Loader.MAX_PNG_BYTES = 384*512*4+65536

function Loader:new(options)
    return setmetatable({cache=assert(options.cache), loader=assert(options.loader),
        identity=assert(options.identity), processor=options.processor or Processor,
        renderer=options.renderer, image_probe=options.image_probe or require("webdavmanga.image_probe"),
        async=options.async,error_reporter=options.error_reporter or Reporter:new{},
        target_width=384,target_height=512,generations={},sequence=0,
        processing_jobs={},all_jobs={},source_users={}}, self)
end

function Loader:set_target_size(width,height)
    width,height=tonumber(width),tonumber(height)
    if not width or not height or width~=width or height~=height or width<1 or height<1 then return false end
    self.target_width=math.min(384,math.floor(width))
    self.target_height=math.min(512,math.floor(height))
    if self.loader.mupdf_pages then
        self.loader.mupdf_pages.max_pixels=self.target_width*self.target_height
    end
    return true
end
function Loader:png_budget()
    return self.target_width*self.target_height*4+65536
end
function Loader.source_size(image)
    if image.archive_size then
        -- ZIP fallback may need a compressed work file beside its output.
        return (tonumber(image.archive_size) or 0)+(tonumber(image.archive_compressed_size) or 0)+65536
    end
    if image.mobi_size then return tonumber(image.mobi_size) or 0 end
    if image.pdf_image then return tonumber(image.pdf_image_length) or 0 end
    if image.mupdf_page then return 0 end -- book size is not rendered page size
    return tonumber(image.size) or 0
end

function Loader:cover_key(image)
    local version = table.concat({image.path, tostring(image.etag or ""),
        tostring(image.modified or ""), tostring(image.size or ""),
        self.target_width.."x"..self.target_height}, "\0")
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
    if (self.source_users[key] or 0)>0 then return end
    local record=self.cache.entries[key]
    -- Ownership is checked against the generated cache record. Local source
    -- paths never enter this table and must never be removed by thumbnailing.
    if record and record.path==path then self.cache:remove(key) end
end

local function has_waiters(job)
    for _,waiter in ipairs(job.waiters) do if not waiter.state.canceled then return true end end
    return false
end

function Loader:_cleanup_job(job)
    if job.cleaned then return end
    job.cleaned=true
    self.all_jobs[job]=nil
    if self.processing_jobs[job.key]==job then self.processing_jobs[job.key]=nil end
    self.source_users[job.source_key]=(self.source_users[job.source_key] or 1)-1
    self.cache:unprotect(job.source_key)
    self:_release_source(job.source_identity,job.image,job.source_path)
    if self.source_users[job.source_key]==0 then self.source_users[job.source_key]=nil end
    if not job.published then self.cache:discard_part(job.key,"png",job.token) end
end

function Loader:_deliver_job(job,event,...)
    local args={...}
    for _,waiter in ipairs(job.waiters) do
        local callback=waiter.callbacks[event]
        if not waiter.state.canceled and callback then
            self.error_reporter:guard("load_cover",function() callback(unpack_values(args)) end,nil,nil,{silent=true})
        end
    end
end

function Loader:_process_source(state,key,image,callbacks,source_identity,source_path,source_info,width,height,png_budget)
    local existing=self.processing_jobs[key]
    if existing then
        existing.waiters[#existing.waiters+1]={state=state,callbacks=callbacks}
        return
    end
    self.sequence=self.sequence+1
    local token="thumb"..self.sequence
    local _,part=self.cache:paths_for(key,"png",token)
    local source_key=self.cache:key_for(source_identity,image.path,"cover")
    local job={key=key,token=token,part=part,image=image,source_identity=source_identity,
        source_key=source_key,source_path=source_path,waiters={{state=state,callbacks=callbacks}}}
    self.processing_jobs[key]=job;self.all_jobs[job]=true
    self.source_users[source_key]=(self.source_users[source_key] or 0)+1
    self.cache:protect(source_key)
    local function wake()
        if self.cache.wake_space_waiters then self.cache:wake_space_waiters() end
    end
    local function reaped() self:_cleanup_job(job);wake() end
    local function done(ok,result,err,async_state)
        if job.cleaned or job.settled then return end
        job.settled=true
        if self.processing_jobs[key]==job then self.processing_jobs[key]=nil end
        if job.canceled or not has_waiters(job) then
            -- Even a late result cannot release files while a child is alive.
            if not (async_state and async_state.reap_pending) then reaped() end
            return
        end
        local metadata=ok and type(result)=="table" and type(result.metadata)=="table" and result.metadata or nil
        err=err or (type(result)=="table" and result.error) or "thumbnail_failed"
        local published
        if metadata then
            metadata.key=key;metadata.kind="cover";metadata.extension="png"
            metadata.remote_path=image.path;metadata.identity=self.identity
            metadata.etag=image.etag;metadata.modified=image.modified
            local called,value,publish_error=pcall(self.cache.publish,self.cache,metadata,part)
            published=called and value or nil
            err=called and publish_error or value
            job.published=published~=nil
        end
        if not (async_state and async_state.reap_pending) then self:_cleanup_job(job) end
        if published then self:_deliver_job(job,"on_ready",published,false,metadata)
        else self:_deliver_job(job,"on_error",Errors.storage(err)) end
        wake()
    end
    if self.cache.unified_quota and self.cache:write_budget(65536,png_budget,part,png_budget)<png_budget then
        done(true,{error="cache_limit"});return
    end
    local function work()
        local info=source_info
        if not info or not info.width or not info.height then info=self.image_probe.inspect(source_path,nil) end
        if not info then return {error="invalid_source_image"} end
        local w,h=Processor.target_size(info.width,info.height,{fit_mode="page",split_enabled=false},width,height)
        local metadata,err=self.processor.process(source_path,part,{target_width=w,target_height=h},{renderer=self.renderer})
        return {metadata=metadata,error=err}
    end
    if self.async then
        local ok,handle=pcall(self.async.run,work,done,{timeout=120,on_cancelled=reaped,on_reaped=reaped})
        if not ok or not handle then done(false,nil,ok and "thumbnail_worker_unavailable" or handle)
        elseif not job.cleaned then job.handle=handle end
    else
        local ok,result=pcall(work);done(ok,ok and result or nil,not ok and result or nil)
    end
end

function Loader:request_cover(generation, image, callbacks)
    callbacks=callbacks or {}
    local state,key=self:protect_cover(generation,image)
    local target_width,target_height=self.target_width,self.target_height
    local png_budget=self:png_budget()
    local path=self.cache:lookup(key)
    if path then if callbacks.on_ready then callbacks.on_ready(path,true) end; return true end
    -- The source loader admits work when capacity is available. A busy cache
    -- is transient; rejecting here would leave a card blank after page flips.
    if self.cache.unified_quota then
        local direct=self.loader._uses_direct_local and self.loader:_uses_direct_local()
        local required=not direct and Loader.source_size(image) or 0
        local available=self.cache:write_budget(png_budget,required)
        if (available<1 or required>available) and not
            (self.cache.has_pending_writes and self.cache:has_pending_writes()) then
            if callbacks.on_error then callbacks.on_error(Errors.storage("cache_limit")) end
            return nil
        end
    end
    local source_identity=self.loader.identity
    local source_finished=false
    local source_request=self.loader:request_cover(generation,image,{
        on_ready=function(source_path,_cached,source_metadata)
            source_finished=true
            if state.canceled then self:_release_source(source_identity,image,source_path); return end
            -- Source Loader merges equal images. Its first waiter generates
            -- and removes the original; later cards use that same thumbnail.
            local shared=self.cache:lookup(key)
            if shared then
                if callbacks.on_ready then callbacks.on_ready(shared,true) end
                return
            end
            self:_process_source(state,key,image,callbacks,source_identity,source_path,source_metadata,
                target_width,target_height,png_budget)
        end,
        on_error=function(err)
            source_finished=true
            if not state.canceled and callbacks.on_error then callbacks.on_error(err) end
        end,
    })
    -- A source-cache hit returns nil synchronously, but its PNG child may
    -- still be running. Keep the complete grid lane until on_ready/on_error.
    return source_request or (source_finished and true or nil)
end

function Loader:cancel_cover_generation(generation)
    local state=self.generations[generation]
    if state then
        state.canceled=true
        for key in pairs(state.keys) do self.cache:unprotect(key) end
        self.generations[generation]=nil
    end
    local canceled={}
    for job in pairs(self.all_jobs) do
        if not job.canceled and not has_waiters(job) then canceled[#canceled+1]=job end
    end
    for _,job in ipairs(canceled) do
        job.canceled=true
        if self.processing_jobs[job.key]==job then self.processing_jobs[job.key]=nil end
        if job.handle then pcall(job.handle.cancel,job.handle) end
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
