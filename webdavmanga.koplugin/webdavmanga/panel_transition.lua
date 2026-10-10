-- A bounded transition plan. Scheduling and pixel ownership stay in PanelSession.
local Transition={}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function Transition.has_headroom(width,height)
    local ok,available=pcall(function()
        local file=io.open("/proc/meminfo","r")
        if not file then return nil end
        local text=file:read(4096);file:close()
        return tonumber(text:match("MemAvailable:%s*(%d+)") or text:match("MemFree:%s*(%d+)"))
    end)
    -- No Linux memory telemetry on a host: retain the hard pixel/frame budgets.
    return not ok or not available or available*1024>=16*1024*1024+width*height*24
end
function Transition.plan(options,from,to)
    local mode=options.transition_mode
    if mode~="smooth" and mode~="animated" then return nil end
    local frames,duration=options.transition_frames or 5,options.transition_duration or .3
    if not finite(frames) or not finite(duration) or frames<3 or frames>12 or frames%1~=0
        or duration<=0 or duration>.8 then return nil end
    if mode=="smooth" and (not from or not to or from.rotation~=to.rotation) then return nil end
    return {mode=mode,frames=frames,delay=duration/frames,from=from,to=to}
end
function Transition.frame(plan,step)
    local t=step/plan.frames
    if plan.mode=="animated" then
        return {use_target=plan.fade_in or t>=.5,white=plan.fade_in and 1-t or 1-math.abs(2*t-1)}
    end
    local ease=t*t*(3-2*t)
    local box={}
    for _,k in ipairs({"x","y","w","h"}) do
        box[k]=plan.from.box[k]+(plan.to.box[k]-plan.from.box[k])*ease
    end
    return {box=box}
end
return Transition
