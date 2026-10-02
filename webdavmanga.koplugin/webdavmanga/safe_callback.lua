local SafeCallback = {}
local Reporter = require("webdavmanga.error_reporter")

local unpack_values = table.unpack or unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

local function fallback_reporter(ui)
    local ok, logger = pcall(require, "logger")
    return Reporter:new{ logger = ok and logger or nil, ui = ui }
end

function SafeCallback.wrap(reporter, label, callback, fallback, cleanup, options)
    assert(type(callback) == "function", "callback is required")
    if type(reporter) ~= "table" or type(reporter.guard) ~= "function" then
        reporter = fallback_reporter(reporter)
    end
    return reporter:wrap(label, callback, fallback, cleanup, options)
end

function SafeCallback.call(reporter, label, callback, fallback, ...)
    if type(reporter) ~= "table" or type(reporter.guard) ~= "function" then
        reporter = fallback_reporter(reporter)
    end
    local arguments = pack(...)
    return reporter:guard(label, function()
        return callback(unpack_values(arguments, 1, arguments.n))
    end, fallback)
end

return SafeCallback
