local Options=require('webdavmanga.panel_options')
local Shell=require('webdavmanga.ui_reader_shell')
local Reader=require('webdavmanga.ui_reader')
local Session=require('webdavmanga.panel_session')
local motion={}
for _,f in ipairs(Options.fields) do if f.group=='motion' then motion[#motion+1]=f end end
assert(#motion==1 and motion[1].choices[2]=='native','panel motion settings must only select classic or host animation')
local armed,directions=0,{}
local screen={_swipe_animation_core_patch_applied=true,
    setSwipeAnimations=function(_,v) if v then armed=armed+1 end;return true end,
    setSwipeDirection=function(_,v) directions[#directions+1]=v;return true end}
_G.SwipeAnimation={runSwipeAnimation=function() end}
local shell=Shell:new{owner={},screen=screen,device={canDoSwipeAnimation=function() return false end},
    ui_manager={swipe_animation_defaults={},show=function() end,close=function() end},
    widget_factory=function() return {set_model=function() end} end}
assert(shell:_arm_native_animation(false) and directions[1]==false,'complete installed Swipe Animation must work on a non-MTK screen')
_G.SwipeAnimation=nil
assert(not shell:_arm_native_animation(true),'incomplete software patch must degrade to classic')
local shown
local reader=setmetatable({position={index=1},generation=1,reader_settings={panel_transition_mode='native'},
    shell={show_page=function(_,_,_,_,change) shown=change;return true end,show_status=function() end}},Reader)
reader._count=function() return 1 end
reader._reading_token=function() return {} end
assert(reader:_show_panel({}, {}, 2, 3,{animate=true,forward=false}))
assert(shown.animate==true and shown.forward==false,'panel publication must pass only the final image and host direction')
local handle={detection_raster=function() return {} end,close=function() end,
    render=function() return {free=function() end} end}
local session=Session:new{screen_width=600,screen_height=800,
    source={open=function(_,_,_,callbacks) callbacks.on_ready(handle);return {} end},
    detector={detect=function() return {{x=.6,y=0,w=.4,h=1},{x=0,y=0,w=.4,h=1}} end}}
local change
assert(session:start({direction='manga',transition_mode='native'},
    {on_panel=function(_,_,_,_,options) change=options;return true end}))
assert(session:move(1) and change.animate and change.forward==false,'next manga panel must animate in the same RTL direction as a manga page')
assert(session:move(-1) and change.forward==true,'previous manga panel must reverse the animation direction')
session:close()
assert(session:start({direction='normal',transition_mode='native'},
    {on_panel=function(_,_,_,_,options) change=options;return true end}))
assert(session:move(1) and change.forward==true,'next comic panel must animate forward')
assert(session:move(-1) and change.forward==false,'previous comic panel must animate backward')
session:close()
print('panel_native_animation_spec: host-only option, software capability and panel direction passed')
