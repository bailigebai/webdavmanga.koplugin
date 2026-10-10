local PanelSession = {}
PanelSession.__index = PanelSession
local Transition=require("webdavmanga.panel_transition")

local function release(value, method)
    if value then pcall(function() value[method](value) end) end
end

function PanelSession:new(options)
    return setmetatable({
        source = assert(options.source), detector = assert(options.detector),
        schedule = options.schedule,
        schedule_frame=options.schedule_frame,cancel_frame=options.cancel_frame,
        animation_allowed=options.animation_allowed,
        screen_width = assert(options.screen_width), screen_height = assert(options.screen_height),
        token = 0, prefetch_token = 0, active = false,
    }, self)
end

function PanelSession:is_active()
    return self.active
end

function PanelSession:current()
    if not self.active then return nil end
    return {buffer=self.transition and self.transition.visible or self.current_buffer,
        panel=self.panels[self.index], index=self.index, count=#self.panels}
end

function PanelSession:release_next()
    self.prefetch_token = self.prefetch_token + 1
    local buffer = self.next_buffer
    self.next_buffer, self.next_index = nil, nil
    release(buffer, "free")
end

function PanelSession:close()
    self.token = self.token + 1
    self.active = false
    self.render_failures = 0
    local transition=self.transition
    self.transition=nil
    if transition then
        if self.cancel_frame and transition.action then pcall(self.cancel_frame,transition.action) end
        release(transition.visible,"free")
        transition.visible=nil
        release(transition.target,"free")
        transition.target=nil
    end
    local operation, handle, buffer, pending = self.operation, self.handle, self.current_buffer, self.pending
    self.operation, self.handle, self.current_buffer, self.pending = nil, nil, nil, nil
    self.panels, self.index, self.callbacks, self.render_options = nil, nil, nil, nil
    self.source_request,self.synthetic=nil,nil
    release(operation, "cancel")
    self:release_next()
    release(buffer, "free")
    if pending then release(pending.buffer, "free"); pending.buffer = nil end
    -- PanelSource.cancel may already have closed its ready handle.
    if handle and not handle.closed then release(handle, "close") end
end

function PanelSession:_fallback(token, reason)
    if self.token ~= token then return end
    local callback = self.callbacks and self.callbacks.on_fallback
    -- Reader must detach the displayed allocation before its owner frees it.
    if callback then
        local ok, accepted = pcall(callback, reason)
        if self.active and (not ok or accepted == false) then return end
    end
    if self.token == token then self:close() end
end

function PanelSession:_render(index,options)
    if self.rendering then return nil, "panel_session_busy" end
    local token, handle, panel_id = self.token, self.handle, self.panels[index].id
    -- Keep the reservation until native render unwinds, even if close is reentered.
    self.rendering = true
    local ok, buffer, reason = pcall(handle.render, handle, self.panels[index], options or self.render_options)
    self.rendering = false
    if not ok then return nil, "panel_render_failed" end
    if self.token ~= token then release(buffer, "free"); return nil, "panel_session_closed" end
    if not self.panels[index] or self.panels[index].id ~= panel_id then
        release(buffer, "free"); return nil, "panel_session_stale"
    end
    return buffer, reason or "panel_render_failed"
end

function PanelSession:_schedule_next()
    if self.transition or not self.active or not self.panels or not self.render_options then return end
    local index = self.index + 1
    if self.render_options.view=="free" or not self.schedule or index > #self.panels then return end
    local token, prefetch_token, done = self.token, self.prefetch_token, false
    pcall(self.schedule, function()
        if done or token ~= self.token or prefetch_token ~= self.prefetch_token or not self.active then return end
        done = true
        local options={}
        for k,v in pairs(self.render_options) do options[k]=v end
        options.pan_x,options.pan_y,options.zoom=0,0,1
        local buffer = self:_render(index,options)
        if token ~= self.token or prefetch_token ~= self.prefetch_token then
            release(buffer, "free")
        else
            self.next_buffer, self.next_index = buffer, buffer and index or nil
        end
    end)
end

function PanelSession:_publish(index, buffer,options)
    local token, pending = self.token, {buffer=buffer}
    self.pending = pending
    local callback = self.callbacks and self.callbacks.on_panel
    local ok, accepted = false, false
    if callback then
        -- These options have already rendered this allocation. The committed
        -- render_options below still belongs to the previous visible camera.
        ok, accepted = pcall(callback, buffer, self.panels[index], index, #self.panels,
            options or self.render_options)
    end
    if self.token ~= token then
        release(pending.buffer, "free"); pending.buffer = nil
        return false
    end
    self.pending = nil
    if not ok or accepted == false then release(buffer, "free"); return false end
    local previous = self.current_buffer
    self.current_buffer, self.index, self.active = buffer, index, true
    if options then self.render_options=options end
    self.render_failures = 0
    release(previous, "free")
    self:_schedule_next()
    return true
end

function PanelSession:start(request, callbacks)
    if self.rendering or self.configuring then return false, "panel_session_busy" end
    self:close()
    local token, source_request = self.token, {}
    for key, value in pairs(request or {}) do source_request[key] = value end
    source_request.screen_width, source_request.screen_height = self.screen_width, self.screen_height
    self.callbacks = callbacks or {}
    self.direction = source_request.direction or "normal"
    self.source_request=source_request
    self.render_options = {
        screen_width=self.screen_width, screen_height=self.screen_height,
        margin_percent=source_request.margin_percent, show_adjacent=source_request.show_adjacent,
        max_pixels=source_request.max_pixels,
        view=source_request.view,rotation=source_request.rotation or 0,zoom=1,
        protect_text=source_request.protect_text,
        transition_mode=source_request.transition_mode,transition_duration=source_request.transition_duration,
        transition_frames=source_request.transition_frames,
    }
    local finished, ready_handle = false, nil
    local ok, operation = pcall(self.source.open, self.source, source_request.generation, source_request, {
        on_ready = function(handle)
            if finished or self.token ~= token then
                if handle ~= ready_handle and not handle.closed then release(handle, "close") end
                return
            end
            finished, ready_handle, self.handle = true, handle, handle
            local detected, panels, reason = pcall(function()
                local raster, err = handle:detection_raster()
                if not raster then return nil, err end
                if source_request.view=="free" then
                    self.synthetic=true
                    return {{id="free-page",x=0,y=0,w=1,h=1}}
                end
                return self.detector.detect(raster, source_request)
            end)
            if self.token ~= token then return end
            if not detected or type(panels) ~= "table" or #panels == 0 then
                self:_fallback(token, detected and reason or "panel_detection_failed")
                return
            end
            self.panels = panels
            local index = source_request.desired == "last" and #panels or 1
            if type(source_request.desired)=="number" then index=math.max(1,math.min(#panels,math.floor(source_request.desired))) end
            local buffer, err = self:_render(index)
            if not buffer then self:_fallback(token, err); return end
            local allowed=true
            if self.animation_allowed then local ok,value=pcall(self.animation_allowed);allowed=ok and value==true end
            if allowed and source_request.cross_page and self.schedule_frame
                and Transition.has_headroom(self.screen_width,self.screen_height)
                and source_request.transition_mode~="classic" then
                local values={transition_mode="animated",transition_frames=source_request.transition_frames,
                    transition_duration=source_request.transition_duration}
                local plan=Transition.plan(values)
                if plan then
                    plan.fade_in=true;self.active,self.index=true,index
                    if not self:_begin_transition(index,buffer,self.render_options,plan) then
                        self:_fallback(token,"panel_publish_failed")
                    end
                    return
                end
            end
            if not self:_publish(index, buffer) then self:_fallback(token, "panel_publish_failed") end
        end,
        on_error = function(reason)
            if finished then return end
            finished = true
            self:_fallback(token, reason or "panel_source_unavailable")
        end,
    })
    if not ok then self:_fallback(token, "panel_source_unavailable"); return false end
    -- open may complete and close/restart the session before it returns.
    if self.token ~= token then release(operation, "cancel"); return false end
    self.operation = operation
    return true
end

function PanelSession:move(delta)
    if self.transition or self.rendering or self.configuring then return false, "panel_session_busy" end
    if not self.active or self.pending or (delta ~= 1 and delta ~= -1) then return false end
    if self.render_options.view=="free" then return false end
    local index = self.index + delta
    if index < 1 or index > #self.panels then
        if self.callbacks.on_boundary then pcall(self.callbacks.on_boundary, delta) end
        return false
    end
    local token, buffer = self.token, nil
    if self.next_index == index then buffer, self.next_buffer = self.next_buffer, nil end
    self:release_next()
    local options={}
    for k,v in pairs(self.render_options) do options[k]=v end
    options.pan_x,options.pan_y,options.zoom=0,0,1
    buffer = buffer or self:_render(index,options)
    if not buffer then
        if self.token == token and self.active then
            self.render_failures = self.render_failures + 1
            if self.render_failures >= 2 then self:_fallback(token, "panel_render_failed") end
        end
        return false
    end
    local from,to
    if self.handle.camera then
        local ok,a,b=pcall(function()
            return self.handle:camera(self.panels[self.index],self.render_options),
                self.handle:camera(self.panels[index],options)
        end)
        if ok then from,to=a,b end
    end
    local allowed=true
    if self.animation_allowed then local ok,value=pcall(self.animation_allowed);allowed=ok and value==true end
    local plan=allowed and self.schedule_frame and Transition.has_headroom(self.screen_width,self.screen_height)
        and Transition.plan(options,from,to)
    if plan then return self:_begin_transition(index,buffer,options,plan) end
    return self:_publish(index, buffer,options)
end

function PanelSession:finish_transition()
    local t=self.transition
    if not t then return true end
    local token=self.token
    if not t.target and not self.current_buffer then
        -- Cross-page fade-in has no Session-owned original. Recreate the target
        -- after a temporary widget failure instead of publishing nil pixels.
        t.target=self:_render(t.index,t.options)
        if self.token~=token or not self.active or not t.target then return false end
    end
    if not t.target then
        if t.recovering then return false end
        t.recovering=true
        local ok,shown=pcall(self.callbacks.on_panel,self.current_buffer,self.panels[self.index],
            self.index,#self.panels,self.render_options)
        t.recovering=nil
        if self.token~=token or not self.active then
            release(t.visible,"free");t.visible=nil;return false
        end
        if not ok or shown==false then return false end
        self.transition=nil;release(t.visible,"free");t.visible=nil
        self:_schedule_next()
        return true
    end
    if self.cancel_frame and t.action then pcall(self.cancel_frame,t.action) end
    self.transition=nil
    local target=t.target;t.target=nil
    local accepted=self:_publish(t.index,target,t.options)
    if self.token~=token or not self.active then
        release(t.visible,"free");t.visible=nil;return false
    end
    if not accepted and not self.current_buffer then
        self.transition=t
        return false
    end
    if not accepted and self.active and self.callbacks.on_panel then
        -- Reattach the original before releasing a transient display.
        local ok,shown=pcall(self.callbacks.on_panel,self.current_buffer,self.panels[self.index],
            self.index,#self.panels,self.render_options)
        if self.token~=token or not self.active then
            release(t.visible,"free");t.visible=nil;return false
        end
        if not ok or shown==false then
            self.transition=t -- retain the visible allocation until Reader can detach it
            return false
        end
    end
    release(t.visible,"free");t.visible=nil
    return accepted
end

function PanelSession:_begin_transition(index,target,options,plan)
    local token=self.token
    local t={index=index,target=target,options=options,step=0}
    self.transition=t
    local function step()
        if self.token~=token or self.transition~=t or not self.active or not t.target then return end
        t.action=nil;t.step=t.step+1
        if t.step>=plan.frames then self:finish_transition();return end
        local frame=Transition.frame(plan,t.step)
        local allocation
        if frame.box then
            local transient={}
            for k,v in pairs(options) do transient[k]=v end
            transient.transition_box=frame.box
            allocation=self:_render(index,transient)
        else
            local source=frame.use_target and target or self.current_buffer
            local ok,b=pcall(function()
                local copy=source:copy()
                local lightened=pcall(copy.lightenRect,copy,0,0,copy:getWidth(),copy:getHeight(),frame.white)
                if not lightened then release(copy,"free");return nil end
                return copy
            end)
            if ok then allocation=b end
        end
        if self.token~=token or self.transition~=t then release(allocation,"free");return end
        if not allocation then self:finish_transition();return end
        local pending={buffer=allocation};self.pending=pending
        local ok,shown=pcall(self.callbacks.on_panel,allocation,self.panels[index],index,#self.panels,options)
        if self.token~=token or self.transition~=t then
            if self.pending==pending then self.pending=nil end
            release(pending.buffer,"free");pending.buffer=nil;return
        end
        self.pending=nil
        if not ok or shown==false then release(allocation,"free");self:finish_transition();return end
        local old=t.visible;t.visible=allocation;release(old,"free")
        t.action=step
        local scheduled,result=pcall(self.schedule_frame,plan.delay,step)
        if not scheduled or result==false then self:finish_transition() end
    end
    t.action=step
    local ok,result=pcall(self.schedule_frame,plan.delay,step)
    if not ok or result==false then return self:finish_transition() end
    return true
end

function PanelSession:configure(values,commit,rollback)
    if self.transition or self.rendering or self.configuring or self.pending or not self.active then return false,"panel_session_busy" end
    self.configuring=true
    local function finish(value,reason) self.configuring=false;return value,reason end
    local options={}
    for k,v in pairs(self.render_options) do options[k]=v end
    for k,v in pairs(values or {}) do options[k]=v end
    local old_panels,old_index,old_synthetic=self.panels,self.index,self.synthetic
    if self.synthetic and options.view~="free" then
        local ok,panels,reason=pcall(function()
            local raster=self.handle:detection_raster()
            return self.detector.detect(raster,self.source_request)
        end)
        if not ok or type(panels)~="table" or #panels==0 then return finish(false,reason or "no_panels") end
        self.panels,self.index,self.synthetic=panels,1,nil
    end
    local function restore() self.panels,self.index,self.synthetic=old_panels,old_index,old_synthetic end
    self:release_next()
    local buffer,reason=self:_render(self.index,options)
    if not buffer then restore();return finish(false,reason) end
    local token=self.token
    if commit then
        local ok,accepted=pcall(commit)
        if not ok or accepted~=true then release(buffer,"free");restore();return finish(false,"panel_settings_failed") end
    end
    if self.token~=token then
        release(buffer,"free")
        if rollback then pcall(rollback) end
        return finish(false,"panel_session_closed")
    end
    local accepted=self:_publish(self.index,buffer,options)
    if not accepted and self.token==token then restore() end
    if not accepted and rollback then pcall(rollback) end
    return finish(accepted)
end

function PanelSession:pan(dx,dy)
    if not self.active or not self.handle.pan_options then return false end
    local values=self.handle:pan_options(self.panels[self.index],self.render_options,dx,dy)
    if not values then return false end
    return self:configure(values)
end

function PanelSession:zoom(factor)
    if type(factor)~="number" or factor~=factor or factor<=0 then return false end
    return self:configure({zoom=math.max(1,math.min(4,(self.render_options.zoom or 1)*factor))})
end

function PanelSession:set_direction(direction)
    if self.transition or self.rendering or self.configuring then return nil, "panel_session_busy" end
    if not self.active or self.pending or (direction ~= "normal" and direction ~= "manga") then return nil end
    local id = self.panels[self.index].id
    local ok, panels = pcall(self.detector.sort, self.panels, direction)
    if not ok or type(panels) ~= "table" then return nil end
    for index, panel in ipairs(panels) do
        if panel.id == id then
            self:release_next()
            self.panels, self.index, self.direction = panels, index, direction
            self:_schedule_next()
            return self:current()
        end
    end
end

return PanelSession
