-- Own the independent shelf resource graph; main.lua only wires its boundary.
local Cache=require("webdavmanga.cache")
local Store=require("webdavmanga.bookshelf_store")
local Catalog=require("webdavmanga.bookshelf_catalog")
local Cover=require("webdavmanga.cover")
local DirectoryStore=require("webdavmanga.directory_store")
local SourceLoader=require("webdavmanga.loader")
local ThumbnailLoader=require("webdavmanga.bookshelf_loader")
local Grid=require("webdavmanga.ui_cover_grid")
local SettingsUi=require("webdavmanga.ui_bookshelf_cache")
local Path=require("webdavmanga.path")
local MB=1024*1024
local Shelf={};Shelf.__index=Shelf

function Shelf:new(options)
    local o=setmetatable({settings=assert(options.settings),scheduler=options.scheduler,
        identity_provider=assert(options.identity_provider),stopped=false},self)
    local policy=o.settings:get_bookshelf_cache()
    o.cache=options.cache or Cache:new{root=assert(options.root),unified_quota=true,
        limit_bytes=policy.total_mb*MB,cover_limit_bytes=policy.total_mb*MB,
        browse_total_bytes=policy.total_mb*MB,browse_trigger_bytes=policy.trigger_mb*MB,
        browse_retain_bytes=policy.retain_mb*MB,browse_check_interval_seconds=policy.interval_minutes*60,
        store=Store:new{path=options.root.."/index.json",fs=options.fs,json=options.json},
        fs=options.fs,md5=options.md5,clock=options.clock}
    if o.cache.migrate then o.cache:migrate(3) end
    if o.cache.cleanup_parts then o.cache:cleanup_parts(0) end
    local id=o.identity_provider(o.settings:get_connection())
    local function client() return options.client_factory(o.settings:get_connection()) end
    o.directory_store=options.directory_store or DirectoryStore:new{cache=o.cache,
        identity=id,client_factory=client,async=options.async,scheduler=options.scheduler,
        md5=options.md5,error_reporter=options.error_reporter}
    o.catalog=options.catalog or Catalog:new{cache=o.cache,identity_provider=o.identity_provider,json=options.json}
    o.cover=options.cover or Cover:new{library=o.catalog,directory_store=o.directory_store,
        search_all_children=true,scheduler=options.scheduler,error_reporter=options.error_reporter}
    o.source_loader=options.source_loader or SourceLoader:new{cache=o.cache,
        client_factory=client,identity=id.."\0bookshelf-source-v1",async=options.async,
        prefetch_concurrency=1,error_reporter=options.error_reporter,
        download_limit_provider=function(image,part)
            return o.cache:write_budget(ThumbnailLoader.MAX_PNG_BYTES,tonumber(image.size) or 0,part)
        end,
        source_kind_provider=function() return o.settings:get_connection().kind or "webdav" end}
    o.loader=options.thumbnail_loader or ThumbnailLoader:new{cache=o.cache,
        loader=o.source_loader,identity=id.."\0bookshelf-thumbnail-v1",renderer=options.render_image}
    o.grid=options.grid or Grid:new{cover_service=o.cover,cache=o.cache,loader=o.loader,
        settings=o.settings,connection_provider=function() return o.settings:get_connection() end,
        scheduler=options.scheduler,render_image=options.render_image,ui=options.grid_ui,defer_ui=true,
        fit_whole_image=true,
        error_reporter=options.error_reporter}
    o.settings_ui=options.settings_ui or SettingsUi:new{cache=o.cache,settings=o.settings,
        ui=options.settings_ui_adapter,error_reporter=options.error_reporter,
        on_changed=function() o:reschedule() end}
    o.cache:cleanup_browse(false)
    o:_schedule()
    return o
end

function Shelf:_schedule()
    if self.stopped or not self.scheduler or not self.scheduler.scheduleIn then return end
    local task
    task=function()
        if self.stopped or self.cleanup_task~=task then return end
        self.cleanup_task=nil
        self.cache:cleanup_browse(false)
        self:_schedule()
    end
    self.cleanup_task=task
    local ok,result=pcall(self.scheduler.scheduleIn,self.scheduler,
        self.cache:browse_policy().check_interval_seconds,task)
    if not ok or result==false then self.cleanup_task=nil end
end
function Shelf:reschedule()
    if self.cleanup_task and self.scheduler and self.scheduler.unschedule then
        self.scheduler:unschedule(self.cleanup_task)
    end
    self.cleanup_task=nil;self:_schedule()
end
function Shelf:cancel_all()
    local failed={}
    for _,entry in ipairs({{self.grid,"cancel"},{self.cover,"cancel_all"},
        {self.loader,"cancel_all"},{self.directory_store,"cancel_all"}}) do
        local ok=pcall(entry[1][entry[2]],entry[1])
        if not ok then failed[#failed+1]=entry[2] end
    end
    if #failed>0 then error("bookshelf cancellation failed: "..table.concat(failed,",")) end
end
function Shelf:change_connection()
    self:cancel_all()
    local id=self.identity_provider(self.settings:get_connection())
    self.directory_store.identity=id
    self.source_loader.identity=id.."\0bookshelf-source-v1"
    self.loader.identity=id.."\0bookshelf-thumbnail-v1"
end
function Shelf:refresh(path)
    self:cancel_all()
    local connection=self.settings:get_connection()
    self.catalog:invalidate(connection,path)
    local identity=self.loader.identity
    self.cache:clear_matching_cache(function(record)
        if not Path.is_within_remote(record.remote_path,path) then return false end
        return record.identity==identity
            or record.key==self.directory_store:_cache_key(record.remote_path)
    end)
end
function Shelf:stop()
    if self.stopped then return end
    self.stopped=true
    if self.cleanup_task and self.scheduler and self.scheduler.unschedule then
        self.scheduler:unschedule(self.cleanup_task)
    end
    self.cleanup_task=nil
    self.settings_ui:close_all()
    self:cancel_all()
    if self.cache.store:flush()==false then error("bookshelf index flush failed") end
end
return Shelf
