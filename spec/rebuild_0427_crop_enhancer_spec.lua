local Crop=require('webdavmanga.auto_crop')
local Processor=require('webdavmanga.page_processor')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local function page(pixel,w,h)
    w,h=w or 200,h or 300
    local b={reads=0,writes=0,frees=0}
    function b:getWidth() return w end
    function b:getHeight() return h end
    function b:getPixel(x,y)
        self.reads=self.reads+1
        assert(x>=0 and x<w and y>=0 and y<h,'samples bounded')
        assert(self.reads<=320*320,'scan bounded')
        return pixel(x,y)
    end
    function b:free() self.frees=self.frees+1 end
    return b
end
local function art(x,y)
    return x>=25 and x<175 and y>=40 and y<260
end
local opts={enhanced=true,threshold=242,max_percent=30,border_width=2,min_area=4,padding_percent=1}
local scan=page(function(x,y)
    if x<2 or x>=198 or y<2 or y>=298 then return 0 end
    if art(x,y) then return 30 end
    if x==10 and y==20 then return 0 end
    return 255
end)
local c,reason=Crop.detect(scan,opts)
expect(c and reason=='enhanced_crop','enhanced crop removes thin edge frame instead of refusing dark edges')
expect(c.x>=20 and c.x<=25 and c.y>=34 and c.y<=40
    and c.x+c.w>=175 and c.x+c.w<=180 and c.y+c.h>=260 and c.y+c.h<=266,
    'literal content rectangle stays complete with modest safe margin')
expect(scan.frees==0 and scan.writes==0,'detector borrows original without freeing or mutating')
local legacy,legacy_reason=Crop.detect(scan,{max_percent=30})
expect(not legacy and legacy_reason=='dark_edge','enhancement off retains original conservative detector')
local dialogue=page(function(x,y)
    if art(x,y) or (x<18 and y>=100 and y<130) then return 30 end
    return 255
end)
c=assert(Crop.detect(dialogue,opts))
expect(c.x==0 and c.x+c.w>=175,'content touching page edge is kept, unlike blanket edge-component removal')
local tiny=page(function(x,y)
    if art(x,y) or (x==23 and y==100) then return 0 end
    return 255
end)
c=assert(Crop.detect(tiny,opts))
expect(c.x<=23,'small punctuation near content remains inside crop')
local disabled=page(function(x,y) return art(x,y) and 0 or 255 end)
local no,why=Crop.detect(disabled,{enhanced=true,max_percent=0})
expect(not no and why=='unsafe_box','maximum zero prevents trimming')
for _,color in ipairs({0,255}) do
    local b=page(function() return color end)
    expect(Crop.detect(b,opts)==nil,'blank/dark pages preserve full page')
end
expect(Crop.detect(page(function(x) return x<100 and 0 or 255 end),opts)==nil,
    'full-bleed content is not discarded as border noise')
local huge=page(function(x,y)
    return x>=1000 and x<7000 and y>=1500 and y<10500 and 0 or 255
end,8000,12000)
c=assert(Crop.detect(huge,opts))
expect(c.x<=1000 and c.y<=1500 and c.x+c.w>=7000 and c.y+c.h>=10500,
    'bounded analysis maps outward to full-resolution crop')
expect(huge.reads<=320*320,'huge source has bounded work')
local settings={auto_crop_enabled=true,auto_crop_enhance_enabled=true,
    auto_crop_border_width=2,auto_crop_min_area=4,auto_crop_padding_percent=1}
local image={width=200,height=300}
local p=assert(Processor.profile(settings,image,200,300))
expect(p.crop.enhanced==true and p.crop.border_width==2,'preprocessing routes selected algorithm and parameters')
for _,field in ipairs({'auto_crop_enhance_enabled','auto_crop_border_width','auto_crop_min_area','auto_crop_padding_percent'}) do
    local changed={}
    for k,v in pairs(settings) do changed[k]=v end
    if field=='auto_crop_enhance_enabled' then changed[field]=false
    else changed[field]=settings[field]+1 end
    expect(Processor.profile(changed,image,200,300).id~=p.id,field..' invalidates prepared crop metadata')
end
local source=page(function(x,y) return art(x,y) and 0 or 255 end)
local shown,metadata=Processor.process_buffer(source,p)
expect(shown==source and source.frees==0 and metadata.crop_checked and metadata.crop_reason=='enhanced_crop',
    'memory processing caches accepted enhanced decision without a second buffer')
local bad=page(function() error('unavailable pixel') end)
local _,badmeta=Processor.process_buffer(bad,p)
expect(badmeta.crop_checked and badmeta.crop==nil,'unreadable pixels cache safe full-page refusal')
settings.auto_crop_enabled=false
expect(Processor.profile(settings,image,200,300)==nil,'enhancement switch alone does not override crop master or original-image path')
print('rebuild_0427_crop_enhancer_spec: '..checks..' checks passed')
