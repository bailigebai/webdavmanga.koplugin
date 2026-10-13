-- One policy for global defaults, sparse book overrides and reader routing.
local Modes={}
local order={'web','dynamic','intelligent'}
Modes.keys={intelligent='panel_zoom_enabled',dynamic='dynamic_panel_zoom_enabled',web='web_panel_zoom_enabled'}
function Modes.active(values)
    for _,mode in ipairs(order) do
        if values and values[Modes.keys[mode]]==true then return mode end
    end
end
function Modes.enabled(values)return Modes.active(values)~=nil end
function Modes.resolve(values,previous,changed)
    local selected
    for _,mode in ipairs(order) do
        local key=Modes.keys[mode]
        if changed==key and values[key]==true then selected=mode;break end
    end
    if not selected and previous then
        local count=0
        for _,mode in ipairs(order) do
            local key=Modes.keys[mode]
            if values[key]==true and previous[key]~=true then selected=mode;count=count+1 end
        end
        if count~=1 then selected=nil end
    end
    selected=selected or Modes.active(values)
    for mode,key in pairs(Modes.keys) do values[key]=mode==selected end
    return values
end
function Modes.override(patch)
    local selected=Modes.active(patch)
    if selected then for mode,key in pairs(Modes.keys) do patch[key]=mode==selected end end
    return patch
end
return Modes
