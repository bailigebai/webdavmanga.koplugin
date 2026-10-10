local pixels=dofile(assert(TEST_REPO_ROOT)..'/spec/fixtures/webtoon_buffer.lua')
package.loaded['ffi/blitbuffer']=pixels.bb
local Reader=require('webdavmanga.ui_reader')
local State=require('webdavmanga.state')
local Settings=require('webdavmanga.settings')
local Crop=require('webdavmanga.auto_crop')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local data,jobs,shown={},{},{}
local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,
    saveSetting=function(_,k,v) data[k]=v end,flush=function() return true end}}
assert(s:set_reader({fit_mode='webtoon',auto_crop_enabled=true,prefetch_near_count=0,prefetch_far_count=0,
    webtoon_smart_enabled=false,webtoon_fit_percent=0}))
local image={name='1.png',path='/1.png',width=100,height=300}
local shell={get_content_size=function() return 100,100 end,show_loading=function() return true end,
    show_page=function(_,b,v) shown[#shown+1]={b,v};return true end,
    show_error=function(_,m) error(m.message) end,close_now=function() shown={} end,
    free_buffer_later=function(_,b) b:free();return true end}
local reader=Reader:new{state=State:new(),settings=s,
    loader={identity='crop-webtoon',request=function(_,_,img,cb) jobs[#jobs+1]={img,cb};return {} end,
        prefetch=function() end,cancel_generation=function() end},
    progress={chapter_id=function() return 'crop' end,resolve=function() return {index=1,segment='whole'} end,
        save=function() return true end},cache={key_for=function(_,_,p) return p end,set_protected=function() end},
    render_image={renderImageFile=function(_,_,_,w,h)
        return pixels.new(w,h,function(x,y) return x>=10 and x<90 and y>=20 and y<280 and 0 or 255 end)
    end},open_chapter=function() end,
    ui={create_shell=function() return shell end,show_shell=function() return true end,
        close_shell=function() shell:close_now();return true end,schedule=function(_,cb) cb() end}}
local detect=Crop.detect
local scans=0
Crop.detect=function(...) scans=scans+1;return detect(...) end
local function complete()
    local job=jobs[#jobs];job[2].on_ready(job[1].path,false,{width=100,height=300})
end
assert(reader:open{manga={name='m'},chapter={name='c'},chapter_index={count=function() return 1 end,
    get=function() return image end,window=function() return {image} end}})
complete()
expect(scans==1 and reader.webtoon_session~=nil,'first strip source is processed once')
reader:next_page()
local fraction=reader.webtoon_fraction
local previous=reader.webtoon_session
expect(reader:set_crop_enhance_option('auto_crop_enhance_enabled',true),'apply enhancement in real strip reader')
expect(reader.webtoon_session~=previous and #jobs==2,
    'enhancement invalidates cropped strip source cache instead of just reusing it')
complete()
expect(scans==2 and math.abs(reader.webtoon_fraction-fraction)<.011,
    'enhancement analyzes new strip source once and preserves current scroll fraction')
expect(reader:set_crop_enhance_option('auto_crop_padding_percent',5),'update strip padding')
complete()
expect(scans==3 and #jobs==3 and math.abs(reader.webtoon_fraction-fraction)<.011,
    'new padding recomputes without losing strip position')
reader:next_page();reader:previous_page()
expect(scans==3 and #jobs==3,'same strip scrolling reuses enhanced source instead of analyzing repeatedly')
local paused=jobs[#jobs]
expect(reader:set_crop_enhance_option('auto_crop_min_area',5),'start new pending crop source')
expect(reader:set_crop_enhance_option('auto_crop_min_area',6),'supersede pending crop source')
local before=scans
paused[2].on_ready(paused[1].path,false,{width=100,height=300})
expect(scans==before,'old completed crop callback cannot overwrite new pending setting')
complete()
expect(scans==before+1 and reader.reader_settings.auto_crop_min_area==6,
    'latest crop source alone is analyzed and displayed')
before=scans
expect(reader:set_auto_crop_enabled(false),'turn crop master off in a strip')
complete()
expect(scans==before and not reader:_processing_enabled(),'crop master off reloads original without crop analysis')
expect(reader:set_auto_crop_enabled(true),'turn crop master back on')
complete()
expect(scans==before+1,'crop master on recomputes current strip')
local input
reader.ui.show_number_input=function(_,model) input=model;return true end
expect(reader:show_crop_input('auto_crop_strength') and input.on_save('30'),
    'existing crop strength dialog saves in live strip reader')
complete()
expect(scans==before+2,'existing strength settings also refresh cropped strip cache')
reader:force_close('test')
Crop.detect=detect
for _,b in ipairs(pixels.allocated) do expect(b.frees==1,'all owned strip source and frame allocations release exactly once') end
print('rebuild_0427_crop_reader_spec: '..checks..' checks passed')
