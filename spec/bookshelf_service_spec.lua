local checks=0;local function expect(v,m) checks=checks+1;assert(v,m) end
local loaded,Shelf=pcall(require,"webdavmanga.bookshelf")
expect(loaded,"bookshelf resources must have a single lifecycle owner")
local connection={root_path="/m",username="u"}
local timers,cleanups,cancels={},0,{grid=0,cover=0,loader=0,dirs=0,ui=0}
local scheduler={scheduleIn=function(_,seconds,fn) timers[fn]=seconds end,
    unschedule=function(_,fn) timers[fn]=nil end}
local settings={get_connection=function() return connection end,get_bookshelf_cache=function()
    return {total_mb=200,trigger_mb=150,retain_mb=100,interval_minutes=10} end}
local cache={store={flush=function() return true end},entries={},
    cleanup_browse=function() cleanups=cleanups+1 end,browse_policy=function() return {check_interval_seconds=600} end,
    clear_matching_cache=function() end}
local dirs={identity="old",cancel_all=function() cancels.dirs=cancels.dirs+1 end}
local source={identity="old-source"}
local thumb={identity="old-thumb",cancel_all=function() cancels.loader=cancels.loader+1 end}
local cover={cancel_all=function() cancels.cover=cancels.cover+1 end}
local grid={cancel=function() cancels.grid=cancels.grid+1 end}
local ui={close_all=function() cancels.ui=cancels.ui+1 end}
local shelf=Shelf:new{root="/shelf",settings=settings,cache=cache,directory_store=dirs,
    source_loader=source,thumbnail_loader=thumb,cover=cover,grid=grid,settings_ui=ui,
    catalog={invalidate=function() end},scheduler=scheduler,identity_provider=function(c) return "hashed-"..c.username end,
    client_factory=function() return {} end}
expect(cleanups==1,"opening plugin checks overdue bookshelf maintenance")
local first_timer=next(timers);expect(first_timer and timers[first_timer]==600,"dedicated ten-minute maintenance")
timers[first_timer]=nil;first_timer();expect(cleanups==2 and not timers[first_timer],"timer checks and reschedules once")
connection.username="other";shelf:change_connection()
expect(dirs.identity=="hashed-other" and source.identity~=thumb.identity,"all workers change isolated connection identity")
expect(cancels.grid==1 and cancels.cover==1 and cancels.loader==1 and cancels.dirs==1,"switch cancels complete old graph")
shelf:stop();expect(next(timers)==nil and cancels.ui==1,"teardown removes timer and dialogs")
local before=cleanups;first_timer();expect(cleanups==before,"stale timer cannot restart closed plugin")
print(("bookshelf_service_spec: %d checks"):format(checks))
