local Reporter = {}
Reporter.__index = Reporter

local STAGES = {
    open_chapter = "打开章节失败",
    download_page = "下载图片失败",
    validate_page = "图片校验失败",
    save_cache_index = "保存缓存索引失败",
    load_cover = "加载封面失败",
    close_reader = "退出漫画清理失败",
    gray_enhance = "去灰增强失败，已回退原图",
    gray_enhance_preview = "去灰预览失败，原图未修改",
}

local unpack_values = table.unpack or unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

local function as_string(value)
    if type(value) == "table" and value.code ~= nil then
        local parts = { "code=" .. tostring(value.code) }
        if value.http_status ~= nil then
            parts[#parts + 1] = "http_status=" .. tostring(value.http_status)
        end
        if value.detail ~= nil then
            parts[#parts + 1] = "detail=" .. tostring(value.detail)
        end
        return table.concat(parts, " ")
    end
    local ok, text = pcall(tostring, value)
    return ok and text or "<unprintable error>"
end

function Reporter.sanitize(value)
    local text = as_string(value)
    text = text:gsub("([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][ \t]*:[ \t]*)[^\r\n]*",
        "%1[redacted]")
    text = text:gsub("([%a][%w+.-]*://)[^/%s@]+@", "%1[redacted]@")
    text = text:gsub("([Bb][Aa][Ss][Ii][Cc]%s+)[^%s]+", "%1[redacted]")
    text = text:gsub("[%c]", " ")
    if #text > 2000 then text = text:sub(1, 1987) .. " [truncated]" end
    return text
end

function Reporter:new(options)
    options = options or {}
    local object = setmetatable({}, self)
    object.logger = options.logger
    object.ui = options.ui
    object.id_factory = options.id_factory
    object.id_sequence = 0
    object.reporting = false
    return object
end

function Reporter:_next_id()
    self.id_sequence = self.id_sequence + 1
    if type(self.id_factory) == "function" then
        local ok, identifier = pcall(self.id_factory)
        if ok and identifier ~= nil then return Reporter.sanitize(identifier) end
    end
    return ("E%04d"):format(self.id_sequence)
end

function Reporter:_log(stage, identifier, error_value)
    if not self.logger or type(self.logger.err) ~= "function" then return end
    pcall(self.logger.err, "WebDavManga:", Reporter.sanitize(stage),
        identifier, Reporter.sanitize(error_value))
end

function Reporter:report(stage, error_value, options)
    options = options or {}
    local identifier = self:_next_id()
    self:_log(stage, identifier, error_value)
    if self.reporting or options.silent or not self.ui or type(self.ui.show_info) ~= "function" then
        return identifier
    end

    self.reporting = true
    local message = (STAGES[stage] or Reporter.sanitize(stage) .. "失败")
        .. "\n错误编号：" .. identifier
    if options.reason then message = message .. "\n" .. Reporter.sanitize(options.reason) end
    pcall(self.ui.show_info, self.ui, message)
    self.reporting = false
    return identifier
end

function Reporter:guard(stage, callback, fallback, cleanup, options)
    assert(type(callback) == "function", "callback is required")
    local results = pack(xpcall(callback, function(err)
        local message = as_string(err)
        if debug and type(debug.traceback) == "function" then
            local traced, traceback = pcall(debug.traceback, message, 2)
            if traced then return traceback end
        end
        return message
    end))
    if results[1] then return unpack_values(results, 2, results.n) end
    if type(cleanup) == "function" then pcall(cleanup) end
    self:report(stage, results[2], options)
    return fallback
end

function Reporter:wrap(stage, callback, fallback, cleanup, options)
    local unpack_values = table.unpack or unpack
    return function(...)
        local arguments = { n = select("#", ...), ... }
        return self:guard(stage, function()
            return callback(unpack_values(arguments, 1, arguments.n))
        end, fallback, cleanup, options)
    end
end

return Reporter
