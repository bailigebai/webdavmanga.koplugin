-- Independent mode policy. Display buffers and prefetch remain owned by the
-- existing panel session; detection always uses KOReader's native Leptonica.
local Dynamic={}
Dynamic.fields={
    {key='dynamic_panel_zoom_enabled',default=false,title='动态面板变焦',choices={false,true}},
    {key='dynamic_panel_order',default='follow',title='动态阅读顺序',choices={'follow','normal','manga'},
        labels={'跟随翻页方向','左到右','右到左'}},
    {key='dynamic_panel_margin_percent',default=0,title='动态聚焦边距',choices={0,2,5,10}},
    {key='dynamic_panel_hold_margin_percent',default=10,title='动态长按原图扩展',choices={2,5,10,15,20}},
    {key='dynamic_panel_initial_zoom',default=1.2,title='动态自由缩放倍率',choices={1,1.2,1.5,2}},
}
local function member(v,choices)
    for _,choice in ipairs(choices) do if v==choice then return true end end
    return false
end
function Dynamic.normalize(values)
    for _,f in ipairs(Dynamic.fields) do
        if not member(values[f.key],f.choices) then values[f.key]=f.default end
    end
    return Dynamic.resolve(values)
end
function Dynamic.validate(values)
    for _,f in ipairs(Dynamic.fields) do
        if not member(values[f.key],f.choices) then return false end
    end
    return true
end
function Dynamic.resolve(values,previous,changed)
    if values.dynamic_panel_zoom_enabled==true and values.panel_zoom_enabled==true then
        if changed=='panel_zoom_enabled' or (previous and previous.dynamic_panel_zoom_enabled==true
            and previous.panel_zoom_enabled~=true) then
            values.dynamic_panel_zoom_enabled=false
        else values.panel_zoom_enabled=false end
    end
    return values
end
function Dynamic.override(values)
    -- Explicit book enable must also override the opposing global default.
    if values.dynamic_panel_zoom_enabled==true then values.panel_zoom_enabled=false
    elseif values.panel_zoom_enabled==true then values.dynamic_panel_zoom_enabled=false end
    return values
end
function Dynamic.enabled(values)
    return values and (values.dynamic_panel_zoom_enabled==true or values.panel_zoom_enabled==true)
end
function Dynamic.detect(raster,options)
    return require('webdavmanga.panel_detector').detect_native(raster,options)
end
function Dynamic.sort(panels,direction)
    return require('webdavmanga.panel_detector').sort(panels,direction)
end
function Dynamic.label(field,value)
    for index,choice in ipairs(field.choices) do
        if choice==value and field.labels then return field.labels[index] end
    end
    if type(value)=='boolean' then return value and '开启' or '关闭' end
    return tostring(value)..(field.key:find('percent',1,true) and '%' or ' 倍')
end
function Dynamic.items()
    local items={}
    for _,f in ipairs(Dynamic.fields) do
        local choices={}
        for _,v in ipairs(f.choices) do choices[#choices+1]={value=v,text=Dynamic.label(f,v)} end
        items[#items+1]={key=f.key,title=f.title,choices=choices}
    end
    return items
end
function Dynamic.request(values,request)
    request.view,request.rotation='cut',0
    request.show_adjacent,request.protect_text=false,false
    request.margin_percent=values.dynamic_panel_margin_percent or 0
    request.experimental=false
    request.transition_mode,request.cross_page='classic',false
    return request
end
return Dynamic
