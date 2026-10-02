-- Host pixel double for the public Blitbuffer API used by strip composition.
local M = {allocated={}}
function M.new(w,h,pixel,parent)
    local b={w=w,h=h,pixel=pixel or function() return 255 end,parent=parent,frees=0}
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getPixel(x,y) assert(self.frees==0,"read after free"); return self.pixel(x,y) end
    function b:viewport(x,y,vw,vh)
        return M.new(vw,vh,function(px,py) return self:getPixel(x+px,y+py) end,self)
    end
    function b:scale(sw,sh)
        local pixels={}
        for y=0,sh-1 do for x=0,sw-1 do
            pixels[y*sw+x]=self:getPixel(math.min(self.w-1,math.floor(x*self.w/sw)),
                math.min(self.h-1,math.floor(y*self.h/sh)))
        end end
        return M.new(sw,sh,function(x,y) return pixels[y*sw+x] end)
    end
    function b:fill(color) self.pixel=function() return color end end
    function b:rotatedCopy(angle)
        local cw=(-angle)%360
        local w,h=self.w,self.h
        local rw,rh=w,h
        if cw==90 or cw==270 then rw,rh=h,w end
        local values={}
        for y=0,rh-1 do for x=0,rw-1 do
            local sx,sy=x,y
            if cw==90 then sx,sy=y,h-x-1
            elseif cw==180 then sx,sy=w-x-1,h-y-1
            elseif cw==270 then sx,sy=w-y-1,x end
            values[y*rw+x]=self:getPixel(sx,sy)
        end end
        return M.new(rw,rh,function(x,y) return values[y*rw+x] end)
    end
    function b:blitFrom(src,dx,dy,sx,sy,bw,bh)
        local old=self.pixel; local values={}
        for y=0,bh-1 do for x=0,bw-1 do values[y*bw+x]=src:getPixel(sx+x,sy+y) end end
        self.pixel=function(x,y)
            if x>=dx and x<dx+bw and y>=dy and y<dy+bh then return values[(y-dy)*bw+x-dx] end
            return old(x,y)
        end
    end
    function b:free() self.frees=self.frees+1; assert(self.frees==1,"double free") end
    if not parent then M.allocated[#M.allocated+1]=b end
    return b
end
M.bb={TYPE_BB8=1,COLOR_WHITE=255,COLOR_BLACK=0,new=function(w,h) return M.new(w,h) end}
return M
