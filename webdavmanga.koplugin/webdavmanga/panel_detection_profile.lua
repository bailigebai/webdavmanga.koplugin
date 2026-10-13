-- Bounded Otsu separation of foreground contrast relative to a known background.
-- Pure statistics: no buffers, settings, window or native resource ownership.
local Profile={}
function Profile.threshold(histogram,background,baseline)
    baseline=tonumber(baseline)
    if not baseline or baseline~=baseline or baseline%1~=0 or baseline<1 or baseline>254 then baseline=40 end
    if type(histogram)~='table' or type(background)~='number' or background~=background
        or background<0 or background>255 then return baseline end
    local difference,total,sum={},0,0
    for gray=0,255 do
        local count=histogram[gray] or 0
        if type(count)~='number' or count~=count or count<0 or count==math.huge then return baseline end
        local delta=math.floor(math.abs(gray-background))
        difference[delta]=(difference[delta] or 0)+count
        total=total+count;sum=sum+delta*count
    end
    if total<=0 then return baseline end
    local weight,partial,best,first,last=0,0,0,nil,nil
    for threshold=0,254 do
        local count=difference[threshold] or 0
        weight=weight+count;partial=partial+threshold*count
        if weight>0 and weight<total then
            local distance=partial/weight-(sum-partial)/(total-weight)
            local score=weight*(total-weight)*distance*distance
            if score>best then best,first,last=score,threshold,threshold
            elseif score==best and first then last=threshold end
        end
    end
    if not first or best<=0 then return baseline end
    local selected=math.floor((first+last)/2+.5)
    return math.max(math.max(1,math.ceil(baseline*.5)),math.min(math.min(254,math.floor(baseline*1.5)),selected))
end
return Profile
