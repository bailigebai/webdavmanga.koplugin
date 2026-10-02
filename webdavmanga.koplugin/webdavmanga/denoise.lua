local Denoise = {}

local function default_backend()
    local ffi = require("ffi")
    require("ffi/leptonica_h")
    pcall(ffi.cdef, [[
        PIX *pixRead(const char *filename);
        PIX *pixMedianFilter(PIX *pixs, l_int32 wf, l_int32 hf);
    ]])
    local leptonica = ffi.loadlib("leptonica", "6")
    return {
        read = function(path) return leptonica.pixRead(path) end,
        median = function(pix, width, height)
            return leptonica.pixMedianFilter(pix, width, height)
        end,
        write_png = function(path, pix)
            return leptonica.pixWritePng(path, pix, 0.0) == 0
        end,
        destroy = function(pix)
            if pix ~= nil then leptonica.pixDestroy(ffi.new("PIX *[1]", pix)) end
        end,
    }
end

local function invoke(backend, method, ...)
    local ok, first, second = pcall(backend[method], ...)
    if not ok then return nil, first end
    return first, second
end

function Denoise.process(input_path, output_path, options)
    options = options or {}
    local backend = options.backend
    if not backend then
        local ok, value = pcall(default_backend)
        if not ok then return nil, value end
        backend = value
    end
    local source, read_error = invoke(backend, "read", input_path)
    if not source then return nil, read_error or "read_failed" end
    local filtered, filter_error = invoke(backend, "median", source, 3, 3)
    if not filtered then
        pcall(backend.destroy, source)
        return nil, filter_error or "filter_failed"
    end
    local written, write_error = invoke(backend, "write_png", output_path, filtered)
    pcall(backend.destroy, filtered)
    if filtered ~= source then pcall(backend.destroy, source) end
    if not written then return nil, write_error or "write_failed" end
    return { applied = true, extension = "png" }
end

return Denoise
