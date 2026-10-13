-- Independent mode policy. Display buffers and prefetch remain owned by the
-- existing panel session; detection always uses KOReader's native Leptonica.
local Options=require('webdavmanga.panel_options')
local Dynamic={}
Dynamic.fields={
    {key='dynamic_panel_zoom_enabled',default=false,title='动态面板变焦',choices={false,true}},
    {key='dynamic_panel_order',default='follow',title='动态阅读顺序',choices={'follow','normal','manga'},
        labels={'跟随翻页方向','左到右','右到左'}},
    {key='dynamic_panel_margin_percent',default=0,title='动态聚焦边距',choices={0,2,5,10}},
    {key='dynamic_panel_hold_margin_percent',default=10,title='动态长按原图扩展',choices={2,5,10,15,20}},
    {key='dynamic_panel_initial_zoom',default=1.2,title='动态自由缩放倍率',choices={1,1.2,1.5,2}},
    {key='dynamic_panel_detection_threshold',default=50,title='动态识别阈值',minimum=1,maximum=254,integer=true,
        description='请输入1～254整数。默认50；越小越容易识别浅线与噪点。'},
    {key='dynamic_panel_min_side_percent',default=12.5,title='动态最小宽高比例',minimum=2,maximum=50,integer=false,
        description='请输入2～50的有限数值（允许小数）。宽与高各占页面的比例，默认12.5%。'},
}
function Dynamic.normalize(values)
    for _,f in ipairs(Dynamic.fields) do
        if not Options.valid(f,values[f.key]) then values[f.key]=f.default end
    end
    return values
end
function Dynamic.validate(values)
    for _,f in ipairs(Dynamic.fields) do
        if not Options.valid(f,values[f.key]) then return false end
    end
    return true
end
function Dynamic.detect(raster,options)
    return require('webdavmanga.panel_detector').detect_native(raster,options)
end
function Dynamic.sort(panels,direction)
    return require('webdavmanga.panel_detector').sort(panels,direction)
end
function Dynamic.label(field,value)
    for index,choice in ipairs(field.choices or {}) do
        if choice==value and field.labels then return field.labels[index] end
    end
    if type(value)=='boolean' then return value and '开启' or '关闭' end
    return tostring(value)..(field.key:find('percent',1,true) and '%' or field.key=='dynamic_panel_initial_zoom' and ' 倍' or '')
end
function Dynamic.items()
    local items={}
    for _,f in ipairs(Dynamic.fields) do
        local choices
        if f.choices then choices={};for _,v in ipairs(f.choices) do choices[#choices+1]={value=v,text=Dynamic.label(f,v)} end end
        items[#items+1]={key=f.key,title=f.title,choices=choices,description=f.description}
    end
    return items
end
function Dynamic.request(values,request)
    request.view,request.rotation='cut',0
    request.show_adjacent,request.protect_text=false,false
    request.margin_percent=values.dynamic_panel_margin_percent or 0
    request.detection_threshold=values.dynamic_panel_detection_threshold or 50
    request.min_side_percent=values.dynamic_panel_min_side_percent or 12.5
    request.experimental=false
    request.transition_mode,request.cross_page='classic',false
    return request
end
return Dynamic
