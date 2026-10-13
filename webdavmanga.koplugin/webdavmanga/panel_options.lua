-- Shared schema for global defaults, per-book profiles and in-view controls.
local Options={}
Options.fields={
    {key="panel_transition_mode",default="classic",title="分格翻页动画",group="motion",choices={"classic","native"},labels={"经典（无动画）","原生 / Swipe Animation"}},
    {key="panel_entry_gesture",default="hold",title="进入分格手势",group="navigation",choices={"hold","two_finger_tap","both"},labels={"长按","两指轻敲","两种都启用"}},
    {key="panel_tap_enabled",default=true,title="边缘点按切格",group="navigation",choices={false,true}},
    {key="panel_swipe_enabled",default=true,title="滑动切格",group="navigation",choices={false,true}},
    {key="panel_edge_percent",default=33,title="两侧点按区域",group="navigation",choices={15,25,33},suffix="%"},
    {key="panel_protect_text",default=true,title="对白保护范围",group="detection",choices={false,true},labels={"严格原框裁切","保护对白（推荐）"}},
    {key="panel_detection_threshold",default=40,title="分格识别阈值",group="detection",minimum=1,maximum=254,
        description="请输入1到254的整数；越小越容易识别淡线，也越容易识别纸张噪点。默认40。"},
    {key='panel_auto_detection_enabled',default=false,title='高级分格识别 · 自动匹配强度',group='detection',choices={false,true}},
    {key="panel_background_detection",default="auto",title="页面背景识别",group="detection",choices={"auto","light","dark"},labels={"自动（含深色页）","浅色背景","深色背景"}},
}
function Options.index(field,value)
    for i,v in ipairs(field.choices or {}) do if v==value then return i end end
end
function Options.valid(field,value)
    if field.minimum then
        return type(value)=="number" and value==value and (field.integer==false or value%1==0)
            and value>=field.minimum and value<=field.maximum
    end
    return Options.index(field,value)~=nil
end
function Options.normalize(values)
    for _,f in ipairs(Options.fields) do if not Options.valid(f,values[f.key]) then values[f.key]=f.default end end
end
function Options.validate(values)
    for _,f in ipairs(Options.fields) do if not Options.valid(f,values[f.key]) then return false end end
    return true
end
function Options.label(field,value)
    local i=Options.index(field,value) or Options.index(field,field.default)
    return field.labels and field.labels[i] or type(value)=="boolean" and (value and "开" or "关")
        or tostring(value)..(field.suffix or "")
end
function Options.items()
    local items={}
    for _,f in ipairs(Options.fields) do
        local choices={}
        for _,v in ipairs(f.choices or {}) do choices[#choices+1]={value=v,text=Options.label(f,v)} end
        items[#items+1]={key=f.key,title=f.title,choices=f.choices and choices or nil,description=f.description}
    end
    return items
end
return Options
