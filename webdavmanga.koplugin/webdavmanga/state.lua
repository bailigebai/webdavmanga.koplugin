local State = {}
State.__index = State

function State:new()
    return setmetatable({ generation = 0, current = nil }, self)
end

function State:begin_chapter(context)
    self.generation = self.generation + 1
    self.current = context
    return self.generation
end

function State:is_current(generation)
    return self.current ~= nil and self.generation == generation
end

function State:leave_chapter()
    self.generation = self.generation + 1
    self.current = nil
    return self.generation
end

return State
