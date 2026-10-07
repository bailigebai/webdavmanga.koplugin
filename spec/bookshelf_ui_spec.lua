local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local loaded,Ui=pcall(require,"webdavmanga.ui_bookshelf_cache")
expect(loaded,"bookshelf cache must have independent controls")
local Settings=require("webdavmanga.settings")
local saved={};local settings=Settings:new{store={readSetting=function(_,k,d) return saved[k] or d end,
    saveSetting=function(_,k,v) saved[k]=v end,flush=function() end}}
local cleared,cleaned,changed=0,0,0
local cache={root="/shelf",entries={},total_size=function() return 120*1024*1024 end,
    kind_size=function(_,kind) return kind=="manifest" and 3*1024*1024 or 117*1024*1024 end,
    kind_count=function() return 12 end,store={cache_index_size=function() return 1024 end},
    protected_size=function() return 10*1024*1024 end,
    set_browse_policy=function(_,policy) expect(policy.total_bytes==250*1024*1024,"apply independent byte policy");return true end,
    cleanup_browse=function() cleaned=cleaned+1;return 0,false,"below_trigger" end,
    clear=function() cleared=cleared+1;return true,10*1024*1024 end}
local adapter={show=function(self,m) self.model=m end,show_info=function(self,m) self.info=m end,
    confirm=function(self,m) self.confirmation=m end,close_all=function() end}
local ui=Ui:new{settings=settings,cache=cache,ui=adapter,on_changed=function() changed=changed+1 end}
ui:show()
expect(adapter.model.title=="漫画书架封面缓存" and adapter.model.cover_count==12,"dedicated cache name and count")
expect(adapter.model.index_bytes==3*1024*1024+1024,"selection/directory and registration bytes shown")
expect(not adapter.model.on_save{total_mb=50,trigger_mb=150},"invalid edit rejected")
expect(settings:get_bookshelf_cache().total_mb==200 and changed==0,"invalid edit preserves policy")
expect(adapter.model.on_save{total_mb=250} and changed==1,"valid edit applied and persisted")
adapter.model.on_cleanup();expect(cleaned>=1,"manual cleanup obeys policy")
adapter.model.on_clear();expect(cleared==0 and adapter.confirmation,"clear requires explicit cache confirmation")
adapter.confirmation.on_confirm();expect(cleared==1 and adapter.info:find("10"),"clear reports protected bytes retained")
ui:close_all()
print(("bookshelf_ui_spec: %d checks"):format(checks))
