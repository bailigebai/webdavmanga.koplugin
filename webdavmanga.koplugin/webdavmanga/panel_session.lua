local PanelSession = {}
PanelSession.__index = PanelSession

local function release(value, method)
    if value then pcall(function() value[method](value) end) end
end

function PanelSession:new(options)
    return setmetatable({
        source = assert(options.source), detector = assert(options.detector),
        schedule = options.schedule,
        screen_width = assert(options.screen_width), screen_height = assert(options.screen_height),
        token = 0, prefetch_token = 0, active = false,
    }, self)
end

function PanelSession:is_active()
    return self.active
end

function PanelSession:current()
    if not self.active then return nil end
    return {buffer=self.current_buffer, panel=self.panels[self.index], index=self.index, count=#self.panels}
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
    local operation, handle, buffer, pending = self.operation, self.handle, self.current_buffer, self.pending
    self.operation, self.handle, self.current_buffer, self.pending = nil, nil, nil, nil
    self.panels, self.index, self.callbacks, self.render_options = nil, nil, nil, nil
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
    if not self.active or not self.panels or not self.render_options then return end
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
    if callback then ok, accepted = pcall(callback, buffer, self.panels[index], index, #self.panels) end
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
    self.render_options = {
        screen_width=self.screen_width, screen_height=self.screen_height,
        margin_percent=source_request.margin_percent, show_adjacent=source_request.show_adjacent,
        max_pixels=source_request.max_pixels,
        view=source_request.view,rotation=source_request.rotation or 0,zoom=1,
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
                return self.detector.detect(raster, source_request)
            end)
            if self.token ~= token then return end
            if not detected or type(panels) ~= "table" or #panels == 0 then
                self:_fallback(token, detected and reason or "panel_detection_failed")
                return
            end
            self.panels = panels
            local index = source_request.desired == "last" and #panels or 1
            local buffer, err = self:_render(index)
            if not buffer then self:_fallback(token, err); return end
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
    if self.rendering or self.configuring then return false, "panel_session_busy" end
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
    return self:_publish(index, buffer,options)
end

function PanelSession:configure(values,commit,rollback)
    if self.rendering or self.configuring or self.pending or not self.active then return false,"panel_session_busy" end
    self.configuring=true
    local function finish(value,reason) self.configuring=false;return value,reason end
    local options={}
    for k,v in pairs(self.render_options) do options[k]=v end
    for k,v in pairs(values or {}) do options[k]=v end
    self:release_next()
    local buffer,reason=self:_render(self.index,options)
    if not buffer then return finish(false,reason) end
    local token=self.token
    if commit then
        local ok,accepted=pcall(commit)
        if not ok or accepted~=true then release(buffer,"free");return finish(false,"panel_settings_failed") end
    end
    if self.token~=token then
        release(buffer,"free")
        if rollback then pcall(rollback) end
        return finish(false,"panel_session_closed")
    end
    local accepted=self:_publish(self.index,buffer,options)
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
    if self.rendering or self.configuring then return nil, "panel_session_busy" end
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
