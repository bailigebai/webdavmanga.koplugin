local Session = require("webdavmanga.webtoon_session")
local checks, allocations = 0, {}
local function expect(value, message) checks=checks+1; assert(value, message) end
local function buffer(w, h, pixel, parent)
    local b = {w=w,h=h,pixel=pixel or function() return 255 end,parent=parent,frees=0}
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getPixel(x,y) assert(self.frees==0); return self.pixel(x,y) end
    function b:viewport(x,y,vw,vh)
        return buffer(vw,vh,function(px,py) return self:getPixel(x+px,y+py) end,self)
    end
    function b:scale(sw,sh)
        local pixels={}
        for y=0,sh-1 do for x=0,sw-1 do
            pixels[y*sw+x]=self:getPixel(math.min(self.w-1,math.floor(x*self.w/sw)),
                math.min(self.h-1,math.floor(y*self.h/sh)))
        end end
        return buffer(sw,sh,function(x,y) return pixels[y*sw+x] end)
    end
    function b:fill(color) self.pixel=function() return color end end
    function b:blitFrom(src,dx,dy,sx,sy,bw,bh)
        local old=self.pixel; local values={}
        for y=0,bh-1 do for x=0,bw-1 do values[y*bw+x]=src:getPixel(sx+x,sy+y) end end
        self.pixel=function(x,y)
            if x>=dx and x<dx+bw and y>=dy and y<dy+bh then return values[(y-dy)*bw+x-dx] end
            return old(x,y)
        end
    end
    function b:free() self.frees=self.frees+1; expect(self.frees==1,"each owned allocation frees once") end
    if not parent then allocations[#allocations+1]=b end
    return b
end
local BB={TYPE_BB8=1,COLOR_WHITE=255,COLOR_BLACK=0,new=function(w,h) return buffer(w,h) end}
local function fixture(pages, options, delayed)
    local shown,jobs,errors,loads={}, {}, {}, 0
    options=options or {}
    local session=Session:new{width=100,height=100,settings=options,blitbuffer=BB,
        count=function() return #pages end,
        load=function(index,ready,failed)
            loads=loads+1
            local function finish()
                local value=pages[index]
                if value==false then return failed({code="transport"}) end
                return ready(buffer(value.w,value.h,value.pixel),{})
            end
            if delayed then jobs[#jobs+1]=finish else finish() end
        end,
        show=function(frame,point,metadata)
            if options.reject then return false end
            shown[#shown+1]={frame=frame,point=point,metadata=metadata}; return true
        end,
        on_error=function(err) errors[#errors+1]=err end,
    }
    return session,shown,jobs,errors,function() return loads end
end
do
    local s,shown=fixture({{w=100,h=60,pixel=function() return 30 end},
        {w=200,h=120,pixel=function() return 80 end}})
    expect(s:seek(1,0),"initial seek starts")
    local frame=shown[1].frame
    expect(frame:getPixel(50,59)==30 and frame:getPixel(50,60)==80,
        "different source widths align and join in one screen without a gap")
    local original=shown[1].point
    s:next(); expect(#shown==2 and shown[2].point.index==2,"next screen uses an image-local anchor")
    s:previous(); expect(shown[3].point.index==original.index and shown[3].point.y==original.y,
        "previous restores the exact successful forward anchor")
    s:close()
end
do
    local s,shown=fixture({{w=100,h=400,pixel=function(_,y)
        return y>=118 and y<120 and 255 or 50
    end}},{webtoon_fit_percent=12,webtoon_overlap_percent=5})
    s:seek(1,0); s:next()
    expect(shown[2].point.y<=100,"a separator beyond the displayed coverage cannot skip content")
    s:close()
end
do
    local s,shown=fixture({{w=100,h=300,pixel=function(_,y)
        return y>=104 and y<108 and 255 or 40
    end}},{webtoon_fit_percent=12,webtoon_overlap_percent=5})
    s:seek(1,0); s:next()
    expect(shown[1].metadata.displayed_height>=104 and shown[1].metadata.displayed_height<=112,
        "a close separator may fit slightly taller content into one screen")
    expect(shown[2].point.y<=shown[1].metadata.displayed_height,"next never passes rendered content")
    s:close()
end
do
    local s,shown=fixture({{w=100,h=300,pixel=function(_,y)
        return y>=88 and y<94 and 0 or 60
    end}},{webtoon_overlap_percent=10})
    s:seek(1,0); s:next()
    expect(shown[2].point.y>=88 and shown[2].point.y<=94,"black separators are detected too")
    s:close()
end
do
    local s,shown=fixture({{w=100,h=300,pixel=function() return 50 end}},
        {webtoon_overlap_percent=10,webtoon_margin_percent=20,display_background="black"})
    s:seek(1,0); s:next()
    expect(shown[2].point.y==90,"without separators a configured overlap prevents missed content")
    expect(shown[1].frame:getPixel(0,50)==0 and shown[1].frame:getPixel(10,50)==50,
        "symmetric margins use the selected background")
    s:close()
end
do
    local pages={{w=100,h=120,pixel=function() return 40 end},false}
    local s,shown,jobs,errors=fixture(pages,{webtoon_fit_percent=0},true)
    s:seek(1,0); jobs[1]()
    expect(#shown==1,"a full current screen can be displayed without fetching its neighbor")
    s:next(); expect(s:next(),"rapid next while busy is consumed without another request")
    expect(#shown==1,"the old screen stays while a required neighbor is pending")
    jobs[2]()
    expect(#shown==1 and #errors==1,"a failed required neighbor must not publish or advance")
    pages[2]={w=100,h=200,pixel=function() return 90 end}
    s:next(); jobs[3]()
    expect(#shown==2,"the same next action retries the failed destination")
    s:close()
end
do
    local s,shown,jobs=fixture({{w=100,h=500}},nil,true)
    s:seek(1,0); s:close(); jobs[1]()
    expect(#shown==0,"a late buffer after close is released and cannot show a screen")
end
do
    local options={reject=true}
    local s,shown,_,errors=fixture({{w=100,h=500}},options)
    s:seek(1,0)
    expect(#shown==0 and #errors==1 and not s.point,"a rejected screen must not commit its anchor")
    options.reject=false; s:seek(1,0)
    expect(#shown==1,"rejection leaves the session usable")
    s:close()
end
do
    local s,shown,_,errors=fixture({{w=100,h=100,pixel=function() return 60 end}},
        {webtoon_overlap_percent=0,webtoon_fit_percent=0,webtoon_smart_enabled=false})
    s:seek(1,0)
    expect(s:next()==false and #shown==1 and #errors==0,"an exact screen at chapter end is not a failed next image")
    s:close()
end
do
    local pages={}
    for i=1,10 do pages[i]={w=100,h=20,pixel=function() return 20+i end} end
    local s,shown,_,_,loads=fixture(pages)
    s:seek(1,0)
    expect(#shown==1 and loads()>=5,"short images compose without indexing the whole chapter")
    local retained=0; for _ in pairs(s.pages) do retained=retained+1 end
    expect(retained<=2,"the session retains at most two decoded source images")
    s:close()
end
do
    local s,shown=fixture({{w=100,h=1000,pixel=function() return 40 end},false},
        {webtoon_smart_enabled=false,webtoon_overlap_percent=5,webtoon_fit_percent=0})
    s:seek(1,0); s:next(); s:next()
    expect(s.point.y==190,"seek failure regression starts at the third screen")
    s:seek(2,0); s:previous()
    expect(s.point.y==95,"a failed seek retains exact successful-screen history")
    s:close()
end
print("rebuild_0411_webtoon_session_spec: "..checks.." checks passed")
