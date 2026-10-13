-- Recognition from MangaWeb v0.8.91; rendering stays in the shared panel session.
local Options=require('webdavmanga.panel_options')
local Web={}
Web.fields={
    {key='web_panel_zoom_enabled',default=false,title='Web 分格',choices={false,true}},
    {key='web_panel_strength_percent',default=100,title='Web 识别强度',minimum=50,maximum=200,integer=true,
        description='整数50～200%；默认100%。越大越容易识别浅线。',suffix='%'},
    {key='web_panel_min_area_permille',default=2,title='最小候选面积',choices={1,2,5,10,20},labels={'0.1%','0.2%','0.5%','1%','2%'}},
    {key='web_panel_frame_min',default=1,title='边框严格度',choices={1,2,3,4}},
    {key='web_panel_dialogue_distance_percent',default=12,title='对白保护距离',minimum=5,maximum=25,integer=true,
        description='整数5～25%；相对于页面短边，默认12%。',suffix='%'},
}
function Web.normalize(values)
    for _,f in ipairs(Web.fields)do if not Options.valid(f,values[f.key])then values[f.key]=f.default end end
    return values
end
function Web.validate(values)
    for _,f in ipairs(Web.fields)do if not Options.valid(f,values[f.key])then return false end end
    return true
end
function Web.items()
    local result={}
    for _,f in ipairs(Web.fields)do
        local choices
        if f.choices then choices={};for _,v in ipairs(f.choices)do choices[#choices+1]={value=v,text=Options.label(f,v)}end end
        result[#result+1]={key=f.key,title=f.title,choices=choices,description=f.description}
    end
    return result
end
function Web.restore_detection(values)
    for _,f in ipairs(Web.fields)do if f.key~='web_panel_zoom_enabled'then values[f.key]=f.default end end
    return values
end
function Web.request(values,request)
    request.strength_percent=values.web_panel_strength_percent or 100
    request.min_area_permille=values.web_panel_min_area_permille or 2
    request.frame_min=values.web_panel_frame_min or 1
    request.dialogue_distance_percent=values.web_panel_dialogue_distance_percent or 12
    return request
end
function Web.sort(panels,direction)return require('webdavmanga.panel_detector').sort(panels,direction)end
function Web.detect(raster,options)
    local panels,reason=require('webdavmanga.web_panel_analysis').detect(raster,options)
    if not panels then return nil,reason end
    return Web.sort(panels,options and options.direction or 'normal')
end
return Web
