-- Zero-based numeric arrays. LuaJIT uses compact native storage; desktop
-- verification uses the same interface without introducing a runtime dependency.
local Arrays = {}
local ok, ffi = pcall(require, "ffi")
function Arrays.new(kind, size)
    if ok and type(ffi.new) == "function" then
        local worked, value = pcall(ffi.new, kind, size)
        if worked and type(value) == "cdata" then return value end
    end
    local value = {}
    for i=0,size-1 do value[i]=0 end
    return value
end
function Arrays.fill(value, size, byte)
    if type(value) == "cdata" then ffi.fill(value, size, byte); return end
    for i=0,size-1 do value[i]=byte end
end
return Arrays
