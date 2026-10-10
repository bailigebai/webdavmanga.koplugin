local fixture=dofile('spec/helpers/reader_quadrant_host.lua')
local checks=0
local function expect(v,m) checks=checks+1;assert(v,m) end
local points={{x=100,y=150},{x=500,y=150},{x=100,y=650},{x=500,y=650}}
local ids={'top_left','top_right','bottom_left','bottom_right'}
local function host(options)
    local r,o=fixture(true,options)
    r.reader_settings.grid_zoom_enabled=true
    r.reader_settings.grid_zoom_guides=true
    r.reader_settings.grid_zoom_rtl=false
    r:_display_segment(r.position.segment,false)
    return r,o
end
local function guides(r)
    local vertical,horizontal=0,0
    for _,child in ipairs(r.shell.widget[1]) do
        local d,p=child.dimen,child.overlap_offset
        if d and p and d.w==1 and d.h==800 and p[1]==300 and p[2]==0 then vertical=vertical+1 end
        if d and p and d.w==600 and d.h==1 and p[1]==0 and p[2]==400 then horizontal=horizontal+1 end
    end
    return vertical==1 and horizontal==1
end
do
    local r,o=host()
    expect(guides(r),'whole-page grid draws both actual screen guide lines')
    r.reader_settings.grid_zoom_guides=false;r:_display_segment('whole',false)
    expect(not guides(r) and not r.shell.current_model.grid_guides,'guides can be hidden independently')
    r.shell.widget:onTap(nil,{ges='tap',pos={x=300,y=400}})
    expect(not r.quadrant_zoom,'single tap cannot enter grid')
end
for i,point in ipairs(points) do
    local r,o=host()
    local source,position=r.page_buffer,r.position
    local requests,decodes,saves=#o.requests,o.decodes,o.saves
    expect(r.shell.widget:onTwoFingerHold(nil,{ges='two_finger_hold',pos=point})==false
        and not r.quadrant_zoom,'grid can only be entered by two-finger tap, never hold')
    expect(r.shell.widget:onTwoFingerTap(nil,{ges='two_finger_tap',pos=point}),'native tap enters grid')
    o.image:getSize()
    expect(r.quadrant_zoom==ids[i] and r.page_viewport.w==300 and r.page_viewport.h==400,
        'tap selects '..ids[i])
    expect(o.image:getCurrentWidth()==600 and o.image:getCurrentHeight()==800
        and o.image.image_disposable==false,'quarter fits full screen and borrows source')
    expect(not r.shell.current_model.grid_guides,'hide guides while zoomed')
    expect(r.shell.widget:onTwoFingerHoldRelease(nil,{ges='two_finger_hold_release'})==false
        and r.quadrant_zoom==ids[i],'lifting fingers does not collapse tap-locked grid')
    expect(r.shell.widget:onTwoFingerTap(nil,{ges='two_finger_tap',pos=points[5-i]})
        and not r.quadrant_zoom,'second two-finger tap restores whole page')
    expect(r.shell.current_model.grid_guides==true,'guides return on whole page')
    expect(r.page_buffer==source and source.frees==0 and r.position==position
        and #o.requests==requests and o.decodes==decodes and o.saves==saves,
        'grid toggling does not reload, decode, save or free the source')
end
do
    local r,o=host()
    r.reader_settings.grid_zoom_enabled=false
    expect(r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})==false and not r.quadrant_zoom,
        'disabled grid has no two-finger entry when panels use hold')
    r.reader_settings.grid_zoom_enabled=true
    r.reader_settings.panel_entry_gesture='two_finger_tap'
    local entered=0
    r.enter_panel_mode=function() entered=entered+1;return true end
    expect(r.shell.widget:onTwoFingerTap(nil,{pos=points[1]}) and r.quadrant_zoom and entered==0,
        'grid tap has priority over configured panel tap entry')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect(r.shell.widget:onHold(nil,{pos=points[1]}) and entered==1,
        'panel hold remains usable even when former panel entry was two-finger only')
    local menu=0
    r.show_koreader_menu=function() menu=menu+1;return true end
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    r.shell.widget:onTap(nil,{pos={x=500,y=10}})
    expect(menu==1 and r.quadrant_zoom,'top menu keeps priority over grid collapse')
    r.shell.widget:onTap(nil,{pos={x=500,y=400}})
    expect(not r.quadrant_zoom and #o.requests==1,'single tap only restores grid, without turning page')
end
-- The grid selects quarters of the view being read, not hidden parts of a spread.
do
    local r,o=host({w=1200,h=800,split=true})
    r:_display_segment('right',false)
    local half=r.page_viewport
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    local quarter=r.page_viewport
    expect(quarter.w==300 and quarter.h==400 and quarter.parent.x==600
        and quarter.parent.w==600,'split-page grid uses selected right half')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect(r.position.segment=='right' and r.page_viewport.x==half.x and r.page_viewport.w==half.w,
        'collapse returns to exact spread half')
end
do
    local r,o=host({w=600,h=2400,fit_mode='width'})
    r.pan_y=350;r:_display_segment('whole',false)
    r.shell.widget:onTwoFingerTap(nil,{pos=points[4]})
    expect(r.page_viewport.parent.y==350 and r.page_viewport.y==400 and r.page_viewport.h==400,
        'fit-width grid uses current scrolling window')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect(r.pan_y==350 and r.page_viewport.y==350,'collapse preserves scroll anchor')
end
do
    local r,o=host()
    r.reader_settings.grid_zoom_rtl=true
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    local nexts,prevs=0,0
    r.next_page=function() nexts=nexts+1;return true end
    r.previous_page=function() prevs=prevs+1;return true end
    r:onSwipe(nil,{direction='east'})
    expect(nexts==1 and prevs==0 and r.direction=='normal','zoom RTL reverses swipe without changing base direction')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    r:onSwipe(nil,{direction='east'})
    expect(nexts==1 and prevs==1 and r.direction=='normal','collapse restores normal swipe direction')
end
for _,mode in ipairs({'controls','loading','pending','closed','webtoon','stale'}) do
    local r,o=host()
    if mode=='controls' then r.shell:show_controls{actions={}}
    elseif mode=='loading' then r.shell:show_loading('loading')
    elseif mode=='pending' then r.pending_request={}
    elseif mode=='closed' then r.shell.closed=true
    elseif mode=='webtoon' then r.webtoon_session={}
    elseif mode=='stale' then r.state:leave_chapter() end
    expect(r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})==false and not r.quadrant_zoom,
        mode..' cannot enter grid')
end
-- Crop and odd dimensions must use all of the current reading image.
do
    local r,o=host({w=640,h=880})
    r.page_crop={x=11,y=17,w=601,h=803}
    r:_display_segment('whole',false)
    r.shell.widget:onTwoFingerTap(nil,{pos=points[4]})
    expect(r.page_viewport.w==301 and r.page_viewport.h==402 and r.page_viewport.x==300
        and r.page_viewport.y==401 and r.page_viewport.parent.x==11 and r.page_viewport.parent.y==17,
        'odd cropped bottom-right quarter includes the last source pixel')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect(r.page_viewport.x==11 and r.page_viewport.y==17 and r.page_viewport.w==601,
        'grid collapse restores original crop')
end
-- Do not allow failed publication or late device input to change visible state.
do
    local r,o=host()
    local show=r.shell.show_page
    local model,view=r.shell.current_model,r.page_viewport
    r.shell.show_page=function() return false end
    expect(not r.shell.widget:onTwoFingerTap(nil,{pos=points[1]}) and not r.quadrant_zoom
        and r.page_viewport==view and r.shell.current_model==model,'failed grid publication keeps old page')
    r.shell.show_page=show
    expect(r.shell.widget:onTwoFingerTap(nil,{pos=points[1]}),'grid can be retried after failure')
    model,view=r.shell.current_model,r.page_viewport
    r.shell.show_page=function() return false end
    expect(not r.shell.widget:onTap(nil,{pos={x=300,y=400}}) and r.quadrant_zoom=='top_left'
        and r.page_viewport==view and r.shell.current_model==model,'failed collapse keeps old zoom')
    r.shell.show_page=show
    expect(r:onTwoFingerTap({}, {pos=points[1]})==false and r.quadrant_zoom=='top_left',
        'input from an old shell cannot change zoom')
    local shell=r.shell
    r:force_close('plugin_teardown')
    expect(not r.quadrant_zoom and shell.widget:onTwoFingerTap(nil,{pos=points[1]})==false,
        'close retires zoom and ignores late input')
end
-- Exercise the actual current-book UI callbacks, including display rollback.
do
    local r,o=host()
    local Settings=require('webdavmanga.settings')
    local data,failed={},false
    local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,
        saveSetting=function(_,k,v) data[k]=v end,flush=function() return not failed end}}
    r.settings,r.panel_book_key=s,string.rep('c',32)
    r.reader_settings=s:get_panel_reader(r.panel_book_key)
    r:toggle_controls('grid')
    local item=r.shell.current_model.actions[1]
    expect(item.callback() and r.reader_settings.grid_zoom_enabled
        and s:get_panel_reader(r.panel_book_key).grid_zoom_enabled and not s:get_reader().grid_zoom_enabled,
        'tap on real grid option applies only to current book')
    item=r.shell.current_model.actions[1]
    expect(item.hold_callback() and not r.reader_settings.grid_zoom_enabled
        and not s:get_reader().grid_zoom_enabled,'hold on real option saves both book and default')
    item=r.shell.current_model.actions[1]
    expect(item.hold_callback() and s:get_reader().grid_zoom_enabled,
        'long press can enable the default for new books')
    item=r.shell.current_model.actions[1]
    failed=true
    expect(item.callback()==false and r.reader_settings.grid_zoom_enabled
        and s:get_panel_reader(r.panel_book_key).grid_zoom_enabled,'failed UI save keeps grid option')
    failed=false
    expect(r:close_controls() and guides(r),'returning from settings repaints grid')
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    local show=r.shell.show_page
    r.shell.show_page=function() return false end
    expect(not r:set_grid_option('grid_zoom_enabled',false,true) and r.quadrant_zoom=='top_left'
        and r.reader_settings.grid_zoom_enabled and s:get_reader().grid_zoom_enabled
        and s:get_panel_reader(r.panel_book_key).grid_zoom_enabled,
        'failed disabling redraw restores zoom, current-book and default preferences')
    r.shell.show_page=show
    expect(r:set_grid_option('grid_zoom_enabled',false) and not r.quadrant_zoom
        and not r.shell.current_model.grid_guides,'disable restores whole page immediately')
    expect(not r:set_grid_option('grid_zoom_enabled','yes') and not r.reader_settings.grid_zoom_enabled,
        'invalid UI preference cannot change state')
    expect(#o.requests==1 and o.decodes==1,'all grid settings operate without another page decode')
end
for _,forward in ipairs({true,false}) do
    local r,o=host({w=1200,h=800,split=true})
    r:_display_segment(forward and 'left' or 'right',false)
    r.reader_settings.grid_zoom_rtl=true
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect(r:onSwipe(nil,{direction=forward and 'east' or 'west'}) and not r.quadrant_zoom
        and r.position.segment==(forward and 'right' or 'left') and r.shell.current_model.grid_guides
        and r.direction=='normal' and #o.requests==1,
        'both logical half-page directions end zoom and temporary RTL')
end
for _,forward in ipairs({true,false}) do
    local r,o=host({w=600,h=2400,fit_mode='width'})
    r.pan_y=forward and 0 or 680;r:_display_segment('whole',false)
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    expect((forward and r:next_page() or r:previous_page()) and not r.quadrant_zoom
        and r.pan_y==(forward and 680 or 0) and r.shell.current_model.grid_guides and #o.requests==1,
        'both fit-width scrolling directions end grid zoom')
end
for _,options in ipairs({{w=1200,h=800,split=true},{w=600,h=2400,fit_mode='width'}}) do
    local r,o=host(options)
    r.shell.widget:onTwoFingerTap(nil,{pos=points[1]})
    local model,view,segment,pan=r.shell.current_model,r.page_viewport,r.position.segment,r.pan_y
    r.shell.show_page=function() return false end
    expect(r:next_page()==false and r.quadrant_zoom=='top_left' and r.position.segment==segment
        and r.pan_y==pan and r.page_viewport==view and r.shell.current_model==model and #o.requests==1,
        'failed logical turn preserves original zoom and anchor without requesting another physical image')
end
for _,failure in ipairs({'widget','adapter'}) do
    local r,o=host()
    local Settings=require('webdavmanga.settings')
    local data={}
    local s=Settings:new{store={readSetting=function(_,k,d) return data[k] or d end,
        saveSetting=function(_,k,v) data[k]=v end,flush=function() return true end}}
    r.settings,r.panel_book_key=s,string.rep('d',32)
    r.reader_settings=s:get_panel_reader(r.panel_book_key)
    r:toggle_controls('grid')
    local model=r.shell.current_model
    if failure=='widget' then r.shell.widget.set_model=function() error('injected controls repaint failure') end
    else r.ui.show_controls=function() return false end end
    expect(model.actions[1].hold_callback()==false and not r.reader_settings.grid_zoom_enabled
        and not s:get_reader().grid_zoom_enabled and not s:get_panel_reader(r.panel_book_key).grid_zoom_enabled
        and r.shell.current_model==model and #o.requests==1 and r.page_buffer.frees==0,
        failure..' setting-page failure restores current book, global default and original controls')
end
print('rebuild_0426_grid_reader_spec: '..checks..' checks passed')
