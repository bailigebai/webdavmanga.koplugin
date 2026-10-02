-- A screen-sized virtual strip. Source buffers belong to this session;
-- accepted screen buffers belong to Reader. No chapter-sized allocation.
local Session = {}
Session.__index = Session

local function release(buffer)
    if buffer and type(buffer.free) == "function" then pcall(buffer.free, buffer) end
end
local function size(buffer)
    return buffer:getWidth(), buffer:getHeight()
end
local function bounded(value, fallback, low, high)
    value = tonumber(value)
    if not value or value ~= value then value = fallback end
    return math.max(low, math.min(high, math.floor(value)))
end
local function luminance(buffer, x, y)
    local ok, value = pcall(function()
        local pixel = buffer:getPixel(x, y)
        if type(pixel) == "number" then return pixel end
        return tonumber(pixel:getColor8().a)
    end)
    return ok and value or nil
end

function Session.background(buffer)
    local w, h = size(buffer)
    local sum, count = 0, 0
    for row = 0, 7 do
        local y = math.min(h - 1, math.floor(row * h / 8))
        for _, x in ipairs({0, w - 1}) do
            local value = luminance(buffer, x, y)
            if value then sum, count = sum + value, count + 1 end
        end
    end
    return count > 0 and sum / count < 128 and "black" or "white"
end

-- Only choose boundaries within the pixels this screen will actually show.
-- Sampling may miss a gap; it can never make us skip unseen artwork.
local function boundary(buffer, screen_h, available, margin, reading_w)
    local first = math.floor(screen_h * 0.70)
    local stride = math.max(1, math.floor(screen_h / 250))
    local minimum = math.max(2, math.floor(screen_h * 0.012))
    local run, best, distance
    local function candidate(last)
        if not run or last - run < minimum then return end
        local cut = math.floor((run + last) / 2)
        local delta = math.abs(cut - screen_h)
        if not distance or delta < distance then best, distance = cut, delta end
    end
    for y = first, available - 1, stride do
        local white, black = true, true
        for column = 0, 23 do
            local x = margin + math.min(reading_w - 1, math.floor(column * reading_w / 24))
            local value = luminance(buffer, x, y)
            white = white and value ~= nil and value >= 245
            black = black and value ~= nil and value <= 12
            if not white and not black then break end
        end
        if white or black then run = run or y
        else candidate(y); run = nil end
    end
    candidate(available)
    return best
end

function Session:new(options)
    local settings = options.settings or {}
    local w, h = assert(options.width), assert(options.height)
    local margin = bounded(settings.webtoon_margin_percent, 0, 0, 20)
    local reading_w = math.max(1, math.floor(w * (1 - margin / 100)))
    return setmetatable({
        width = w, height = h, reading_w = reading_w,
        margin = math.floor((w - reading_w) / 2),
        overlap = bounded(settings.webtoon_overlap_percent, 5, 0, 20),
        fit = bounded(settings.webtoon_fit_percent, 5, 0, 15),
        smart = settings.webtoon_smart_enabled ~= false,
        background_mode = settings.display_background or "auto",
        bb = options.blitbuffer or require("ffi/blitbuffer"),
        load = assert(options.load), show = assert(options.show), count = assert(options.count),
        scale = options.scale or function(view,w,h) return view:scale(w,h) end,
        on_error = options.on_error, pages = {}, history = {}, tick = 0, token = 0,
    }, self)
end

function Session:_get(index, ready, failed, token)
    local cached = self.pages[index]
    if cached then
        self.tick = self.tick + 1; cached.tick = self.tick
        return ready(cached)
    end
    local delivered = false
    local ok = pcall(self.load, index, function(owner, metadata)
        if delivered then return end
        delivered = true
        if self.closed or token ~= self.token then release(owner); return end
        local valid, entry = pcall(function()
            metadata = metadata or {}
            local view = owner
            local crop = metadata.crop
            if crop then view = owner:viewport(crop.x, crop.y, crop.w, crop.h) end
            local w, h = size(view)
            assert(w > 0 and h > 0)
            return { owner = owner, buffer = view, w = w, h = h,
                height = math.max(1, math.ceil(h * self.reading_w / w)) }
        end)
        if not valid then release(owner); return failed({code="decode",reason="webtoon_image_invalid"}) end
        self.tick = self.tick + 1; entry.tick = self.tick
        self.pages[index] = entry
        local total, oldest, age = 0
        for id, value in pairs(self.pages) do
            total = total + 1
            if not age or value.tick < age then oldest, age = id, value.tick end
        end
        if total > 2 then
            release(self.pages[oldest].owner); self.pages[oldest] = nil
        end
        ready(entry)
    end, function(err)
        if delivered then return end
        delivered = true
        if not self.closed and token == self.token then failed(err) end
    end)
    if not ok and not delivered then
        delivered = true; failed({code="transport",reason="webtoon_load_failed"})
    end
end

local function advance(pieces, distance)
    for _, piece in ipairs(pieces) do
        if distance < piece.length then
            return {index=piece.index,y=piece.y+distance}
        end
        distance = distance - piece.length
    end
    local last = pieces[#pieces]
    return {index=last.index,y=last.y+last.length}
end

function Session:_render(point, action)
    if self.closed then return false end
    if self.busy then return true end
    self.busy = true; self.token = self.token + 1
    local token = self.token
    local pending = {pieces={},filled=0}
    self.pending = pending
    local max_h = math.floor(self.height * (1 + (self.smart and self.fit or 0) / 100))
    local anchor, end_point
    local function failed(err)
        if self.closed or token ~= self.token then return end
        release(pending.scratch); pending.scratch = nil
        self.pending, self.busy = nil, false
        if self.on_error then self.on_error(err or {code="decode",reason="webtoon_render_failed"}) end
    end
    local function publish()
        if self.closed or token ~= self.token then return end
        local available = pending.filled
        if available < 1 then return failed() end
        local cut = self.smart and boundary(pending.scratch, self.height, available,
            self.margin, self.reading_w) or nil
        local displayed = cut or math.min(self.height, available)
        local step = cut or math.max(1, math.floor(displayed * (1 - self.overlap / 100)))
        local frame
        local ok = pcall(function()
            frame = self.bb.new(self.width, self.height, self.bb.TYPE_BB8)
            frame:fill(pending.color)
            if displayed > self.height then
                local view = pending.scratch:viewport(0,0,self.width,displayed)
                local scaled = self.scale(view,math.max(1,math.floor(self.width*self.height/displayed)),self.height)
                local sw = scaled:getWidth()
                local copied = pcall(frame.blitFrom,frame,scaled,math.floor((self.width-sw)/2),0,0,0,sw,self.height)
                if scaled ~= view then release(scaled) end; assert(copied)
            else
                frame:blitFrom(pending.scratch,0,0,0,0,self.width,displayed)
            end
        end)
        release(pending.scratch); pending.scratch = nil
        if not ok then release(frame); return failed() end
        local metadata = {displayed_height=displayed,background=pending.background}
        -- Detach before invoking Reader: it may close/reopen during publication.
        self.pending = nil
        local accepted_ok, accepted = pcall(self.show,frame,anchor,metadata)
        if not accepted_ok or accepted == false then release(frame); return failed() end
        if self.closed or token ~= self.token then return end
        if action == "next" and self.point then
            self.history[#self.history+1] = self.point
            if #self.history > 128 then table.remove(self.history,1) end
        elseif action == "previous" then table.remove(self.history)
        elseif action == "seek" then self.history = {} end
        self.point = anchor
        self.next_point = advance(pending.pieces,step)
        self.end_point = end_point
        self.at_end = end_point ~= nil and available <= displayed
        self.end_count = self.count()
        self.busy = false
    end
    local append
    append = function(index, y, normalized)
        if index > self.count() then
            end_point = {index=index,y=0}
            return publish()
        end
        if #pending.pieces >= 64 then
            return failed({code="decode",reason="webtoon_too_many_fragments"})
        end
        self:_get(index,function(entry)
            if normalized then y = math.floor(normalized * entry.height) end
            if y == "last" then y = math.max(0,entry.height-self.height) end
            y = math.max(0,math.min(tonumber(y) or 0,entry.height))
            if y >= entry.height then return append(index+1,0) end
            if not anchor then anchor = {index=index,y=y,fraction=y/entry.height} end
            local length = math.min(max_h-pending.filled,entry.height-y)
            local ok = pcall(function()
                if not pending.scratch then
                    pending.background = self.background_mode == "auto" and Session.background(entry.buffer)
                        or (self.background_mode == "black" and "black" or "white")
                    pending.color = pending.background == "black" and self.bb.COLOR_BLACK or self.bb.COLOR_WHITE
                    pending.scratch = self.bb.new(self.width,max_h,self.bb.TYPE_BB8)
                    pending.scratch:fill(pending.color)
                end
                local sy = math.floor(y*entry.h/entry.height)
                local sh = math.max(1,math.min(entry.h-sy,math.ceil((y+length)*entry.h/entry.height)-sy))
                local view = entry.buffer:viewport(0,sy,entry.w,sh)
                local scaled = self.scale(view,self.reading_w,length)
                local copied = pcall(pending.scratch.blitFrom,pending.scratch,scaled,
                    self.margin,pending.filled,0,0,self.reading_w,length)
                if scaled ~= view then release(scaled) end; assert(copied)
            end)
            if not ok then return failed() end
            pending.pieces[#pending.pieces+1] = {index=index,y=y,length=length}
            pending.filled = pending.filled + length
            if y+length >= entry.height and index >= self.count() then
                end_point = {index=index+1,y=0}
            end
            if pending.filled >= max_h then return publish() end
            append(index+1,0)
        end,failed,token)
    end
    append(point.index,point.y,point.normalized)
    return true
end

function Session:seek(index, fraction)
    if self.busy then return true end
    return self:_render({index=index,y=0,normalized=tonumber(fraction)},"seek")
end
function Session:next()
    if self.busy then return true end
    if not self.point then return false end
    if self.at_end then
        if self.count() <= self.end_count then return false end
        return self:_render(self.end_point,"next")
    end
    return self:_render(self.next_point,"next")
end
function Session:previous()
    if self.busy then return true end
    if not self.point then return false end
    local point = self.history[#self.history]
    if not point then
        if self.point.y > 0 then point = {index=self.point.index,y=math.max(0,self.point.y-self.height)}
        elseif self.point.index > 1 then point = {index=self.point.index-1,y="last"}
        else return true end
    end
    return self:_render(point,"previous")
end
function Session:close()
    if self.closed then return end
    self.closed = true; self.token = self.token + 1
    if self.pending then release(self.pending.scratch) end
    self.pending, self.busy = nil, false
    for _, entry in pairs(self.pages) do release(entry.owner) end
    self.pages = {}
end

return Session
