local Transport = {}
Transport.__index = Transport

local PROPFIND_BODY = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>]]

local function is_ip_address(host)
    return host:find(":", 1, true) ~= nil
        or host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function dns_name_matches(host, pattern)
    host = tostring(host or ""):lower():gsub("%.$", "")
    pattern = tostring(pattern or ""):lower():gsub("%.$", "")
    if host == "" or pattern == "" then return false end
    if not pattern:find("*", 1, true) then return host == pattern end
    if pattern:sub(1, 2) ~= "*." or pattern:find("*", 2, true) then return false end
    local suffix = pattern:sub(2)
    if host:sub(-#suffix) ~= suffix then return false end
    local prefix = host:sub(1, #host - #suffix)
    return prefix ~= "" and not prefix:find(".", 1, true)
end

function Transport.certificate_matches_hostname(certificate, host)
    host = tostring(host or ""):gsub("^%[", ""):gsub("%]$", "")
    if not certificate or host == "" then return false end
    if not is_ip_address(host) and type(certificate.checkhost) == "function" then
        local ok, matches = pcall(certificate.checkhost, certificate, host)
        if ok then return matches == true end
    end

    local ok_extensions, extensions = pcall(certificate.extensions, certificate)
    extensions = ok_extensions and extensions or {}
    local subject_alt_name = type(extensions) == "table" and extensions["2.5.29.17"] or nil
    if type(subject_alt_name) == "table" then
        local names = is_ip_address(host)
            and subject_alt_name.iPAddress or subject_alt_name.dNSName
        for _, name in ipairs(type(names) == "table" and names or {}) do
            if is_ip_address(host) then
                if tostring(name):lower() == host:lower() then return true end
            elseif dns_name_matches(host, name) then
                return true
            end
        end
        return false
    end
    if is_ip_address(host) then return false end

    local ok_subject, subject = pcall(certificate.subject, certificate)
    for _, field in ipairs(ok_subject and type(subject) == "table" and subject or {}) do
        if field.oid == "2.5.4.3" or field.name == "commonName" then
            if dns_name_matches(host, field.value) then return true end
        end
    end
    return false
end

local function forward_socket_methods(connection)
    local metatable = getmetatable(connection.sock)
    local methods = metatable and metatable.__index or {}
    for name, method in pairs(methods) do
        if type(method) == "function" then
            connection[name] = function(self, ...)
                return method(self.sock, ...)
            end
        end
    end
end

function Transport:new(dependencies)
    dependencies = dependencies or {}
    local object = setmetatable({}, self)
    object.http = dependencies.http or require("socket.http")
    object.socket = dependencies.socket or require("socket")
    object.socketutil = dependencies.socketutil or require("socketutil")
    object.ltn12 = dependencies.ltn12 or require("ltn12")
    object.open_file = dependencies.open_file or io.open
    object.remove_file = dependencies.remove_file or os.remove
    object.file_exists = dependencies.file_exists or function(path)
        local handle = io.open(path, "rb")
        if not handle then return false end
        handle:close()
        return true
    end
    object.ca_file = dependencies.ca_file
    object.base64 = dependencies.base64
    if dependencies.https then
        object.https = dependencies.https
    else
        object.ssl = dependencies.ssl or require("ssl")
        object.url = dependencies.url or require("socket.url")
        assert(type(object.ca_file) == "string" and object.ca_file ~= "",
            "HTTPS CA bundle path is required")
        assert(object.file_exists(object.ca_file),
            "HTTPS CA bundle does not exist: " .. object.ca_file)
        object.https = {
            request = function(request) return object:_https_request(request) end,
        }
    end
    return object
end

function Transport:_authorization(auth)
    if not auth or tostring(auth.username or "") == "" then return nil end
    if not self.base64 then self.base64 = require("mime").b64 end
    local raw = tostring(auth.username) .. ":" .. tostring(auth.password or "")
    return "Basic " .. tostring(self.base64(raw)):gsub("%s", "")
end

function Transport:_tls_socket_factory(parameters)
    local transport = self
    return function()
        local raw_socket, socket_error = transport.socket.tcp()
        if not raw_socket then return nil, socket_error end
        local connection = { sock = raw_socket }
        function connection:close()
            if not self.sock or type(self.sock.close) ~= "function" then return true end
            local ok, result = pcall(self.sock.close, self.sock)
            self.sock = nil
            return ok and result or nil
        end
        local metatable = getmetatable(raw_socket)
        local raw_settimeout = metatable and metatable.__index
            and metatable.__index.settimeout
        function connection:settimeout(...)
            if raw_settimeout then return raw_settimeout(self.sock, ...) end
            return self.sock:settimeout(...)
        end
        function connection:connect(host, port)
            local connected, connect_error = self.sock:connect(host, port)
            if not connected then
                self:close()
                return nil, connect_error
            end
            local wrapped, wrap_error = transport.ssl.wrap(self.sock, parameters)
            if not wrapped then
                self:close()
                return nil, wrap_error
            end
            self.sock = wrapped
            if self.sock.sni then
                local sni_ok, sni_error = pcall(self.sock.sni, self.sock, host)
                if not sni_ok then
                    self:close()
                    return nil, sni_error
                end
            end
            local handshaken, handshake_error = self.sock:dohandshake()
            if not handshaken then
                self:close()
                return nil, handshake_error
            end
            local certificate = self.sock:getpeercertificate()
            if not Transport.certificate_matches_hostname(certificate, host) then
                self:close()
                return nil, "TLS certificate hostname mismatch"
            end
            forward_socket_methods(self)
            return 1
        end
        return connection
    end
end

function Transport:_https_request(request)
    if self.http.PROXY or request.proxy then return nil, "HTTPS proxy not supported" end
    local parsed = self.url.parse(request.url)
    if not parsed or parsed.scheme ~= "https" or not parsed.host then
        return nil, "invalid HTTPS URL"
    end
    parsed.port = parsed.port or 443
    request.url = self.url.build(parsed)
    request.mode = "client"
    request.protocol = "any"
    request.options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" }
    request.verify = "peer"
    request.cafile = self.ca_file
    request.create = self:_tls_socket_factory(request)
    return self.http.request(request)
end

function Transport:_request(request)
    self.socketutil:set_timeout(
        self.socketutil.FILE_BLOCK_TIMEOUT,
        self.socketutil.FILE_TOTAL_TIMEOUT)
    local ok, result, code, headers, status = xpcall(function()
        local client = request.url:match("^https://") and self.https or self.http
        return client.request(request)
    end, debug.traceback)
    self.socketutil:reset_timeout()
    if not ok then
        return nil, nil, tostring(result)
    end
    if result == nil then return nil, nil, tostring(code or status or "transport failed") end
    return code, headers, status
end

function Transport:propfind_stream(url, auth, on_chunk)
    assert(type(on_chunk) == "function", "on_chunk is required")
    local sink_error
    local request = {
        url = url,
        method = "PROPFIND",
        redirect = false,
        headers = {
            ["Content-Type"] = "application/xml",
            ["Depth"] = "1",
            ["Content-Length"] = #PROPFIND_BODY,
            ["Authorization"] = self:_authorization(auth),
        },
        source = self.ltn12.source.string(PROPFIND_BODY),
        sink = function(chunk, err)
            if chunk then
                local called, ok, callback_error = pcall(on_chunk, chunk)
                if not called then
                    sink_error = "chunk consumer failed"
                    return nil, sink_error
                end
                if not ok then
                    sink_error = callback_error or "chunk consumer rejected data"
                    return nil, sink_error
                end
            end
            if err then
                sink_error = err
                return nil, err
            end
            return 1
        end,
    }
    local code, headers, status = self:_request(request)
    if sink_error then return nil, nil, nil, sink_error end
    if code == nil then return nil, nil, nil, status end
    return code, headers, status, nil
end

function Transport:get_to_file(url, auth, part_path, progress_callback)
    local handle, open_error = self.open_file(part_path, "wb")
    if not handle then
        self.remove_file(part_path)
        return nil, nil, tostring(open_error or "cannot open temporary file"), "storage"
    end
    local handle_closed = false
    local close_error
    local function close_handle()
        if handle_closed then return close_error == nil end
        handle_closed = true
        local ok, result, detail = pcall(handle.close, handle)
        if not ok then
            close_error = tostring(result)
        elseif result == nil then
            close_error = tostring(detail or "cannot close temporary file")
        end
        return close_error == nil
    end
    local sink_handle = {
        write = function(_self, ...)
            return handle:write(...)
        end,
        close = function()
            return close_handle()
        end,
    }
    local sink = self.ltn12.sink.file(sink_handle)
    local sink_error
    if type(sink) == "function" then
        local file_sink = sink
        sink = function(chunk, err)
            local ok, result, write_error = pcall(file_sink, chunk, err)
            if not ok then
                sink_error = result
                return nil, result
            end
            if result == nil and write_error then sink_error = write_error end
            return result, write_error
        end
    end
    if progress_callback then
        sink = self.socketutil.chainSinkWithProgressCallback(sink, progress_callback)
    end
    local code, headers, status = self:_request{
        url = url,
        method = "GET",
        redirect = false,
        sink = sink,
        headers = { ["Authorization"] = self:_authorization(auth) },
    }
    close_handle()
    if sink_error or close_error then
        self.remove_file(part_path)
        return nil, nil, tostring(sink_error or close_error), "storage"
    end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        self.remove_file(part_path)
    end
    return code, headers, status, nil
end

local function parse_content_range(value)
    if type(value) ~= "string" then return nil end
    local first, last, total = value:match(
        "^%s*bytes%s+(%d+)%-(%d+)%/(%d+)%s*$")
    first, last, total = tonumber(first), tonumber(last), tonumber(total)
    if not first or not last or not total
        or first < 0 or last < first or total <= last then
        return nil
    end
    return first, last, total
end

local function copy_headers(headers)
    local copy = {}
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        copy[key] = value
    end
    return copy
end

local function replace_header(headers, name, value)
    local wanted = tostring(name):lower()
    local duplicates = {}
    for key in pairs(headers) do
        if tostring(key):lower() == wanted then
            duplicates[#duplicates + 1] = key
        end
    end
    for _, key in ipairs(duplicates) do headers[key] = nil end
    headers[name] = value
end

local function header_value(headers, wanted)
    wanted = tostring(wanted or ""):lower()
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == wanted then return value end
    end
    return nil
end

-- Read one validated byte interval into memory.  This is intentionally
-- separate from get_range_to_file: a stream-capable document host can ask for
-- just the bytes needed by its parser, while older KOReader versions continue
-- using the safe complete-file path.
function Transport:get_range_bytes(url, auth, first, last)
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first < 0 or last < first
        or math.floor(first) ~= first or math.floor(last) ~= last then
        return nil, nil, "invalid byte range"
    end
    local chunks, bytes, sink_error = {}, 0, nil
    local sink = function(chunk, err)
        if chunk then
            chunks[#chunks + 1] = chunk
            bytes = bytes + #chunk
        end
        if err then sink_error = err; return nil, err end
        return 1
    end
    local code, headers, status = self:_request{
        url = url,
        method = "GET",
        redirect = false,
        sink = sink,
        headers = {
            ["Authorization"] = self:_authorization(auth),
            ["Range"] = ("bytes=%d-%d"):format(first, last),
            ["Accept-Encoding"] = "identity",
        },
    }
    if sink_error then return nil, headers, sink_error end
    if code ~= 206 then
        return nil, headers, status or ("HTTP " .. tostring(code))
    end
    local content_range = header_value(headers, "content-range")
    local response_first, response_last, total
    if type(content_range) == "string" then
        response_first, response_last, total = content_range:match(
            "^%s*bytes%s+(%d+)%-(%d+)%/(%d+)%s*$")
    end
    response_first, response_last, total = tonumber(response_first),
        tonumber(response_last), tonumber(total)
    if response_first ~= first or response_last ~= last
        or not total or total <= response_last or bytes ~= last - first + 1 then
        return nil, headers, "invalid Content-Range response"
    end
    return table.concat(chunks), headers, status
end

function Transport:get_bytes(url, auth, maximum_bytes)
    maximum_bytes = tonumber(maximum_bytes)
    if not maximum_bytes or maximum_bytes < 1
        or maximum_bytes ~= math.floor(maximum_bytes) then
        return nil, nil, "invalid maximum image size"
    end
    local chunks, size, sink_error = {}, 0, nil
    local sink = function(chunk, err)
        if chunk then
            if size + #chunk > maximum_bytes then
                sink_error = "response exceeds maximum image size"
                return nil, sink_error
            end
            chunks[#chunks + 1] = chunk
            size = size + #chunk
        end
        if err then sink_error = err; return nil, err end
        return 1
    end
    local code, headers, status = self:_request{
        url = url,
        method = "GET",
        redirect = false,
        sink = sink,
        headers = {
            ["Authorization"] = self:_authorization(auth),
            ["Accept-Encoding"] = "identity",
        },
    }
    if sink_error then return nil, headers, sink_error end
    return code, headers, status, table.concat(chunks)
end

-- Download a complete resource through bounded HTTP Range requests.  A server
-- that ignores Range or returns an invalid interval falls back to one full GET.
function Transport:get_range_to_file(url, auth, part_path, progress_callback, options)
    options = options or {}
    local chunk_size = math.floor(tonumber(options.chunk_size) or 1024 * 1024)
    if chunk_size < 32 * 1024 then chunk_size = 32 * 1024 end
    if chunk_size > 4 * 1024 * 1024 then chunk_size = 4 * 1024 * 1024 end

    local function request_part(first, last, mode, if_range)
        local handle, open_error = self.open_file(part_path, mode)
        if not handle then
            self.remove_file(part_path)
            return nil, nil, tostring(open_error or "cannot open temporary file"),
                "storage"
        end
        local handle_closed = false
        local close_error
        local bytes = 0
        local sink_error
        local function close_handle()
            if handle_closed then return close_error == nil end
            handle_closed = true
            local ok, result, detail = pcall(handle.close, handle)
            if not ok then
                close_error = tostring(result)
            elseif result == nil then
                close_error = tostring(detail or "cannot close temporary file")
            end
            return close_error == nil
        end
        local sink = function(chunk, err)
            if not chunk then
                close_handle()
                if err then sink_error = err; return nil, err end
                return 1
            end
            local ok, result, detail = pcall(handle.write, handle, chunk)
            if not ok or result == nil or result == false then
                sink_error = tostring(ok and detail or result
                    or "cannot write temporary file")
                return nil, sink_error
            end
            bytes = bytes + #chunk
            if progress_callback then
                local progress_ok, progress_error = pcall(progress_callback, #chunk)
                if not progress_ok then
                    sink_error = tostring(progress_error)
                    return nil, sink_error
                end
            end
            return 1
        end
        local request_headers = {
            ["Authorization"] = self:_authorization(auth),
            ["Range"] = ("bytes=%d-%d"):format(first, last),
            ["Accept-Encoding"] = "identity",
        }
        if if_range then request_headers["If-Range"] = if_range end
        local code, headers, status = self:_request{
            url = url,
            method = "GET",
            redirect = false,
            sink = sink,
            headers = request_headers,
        }
        close_handle()
        if sink_error or close_error then
            self.remove_file(part_path)
            return nil, nil, tostring(sink_error or close_error), "storage"
        end
        if type(code) ~= "number" or code < 200 or code >= 300 then
            self.remove_file(part_path)
        end
        return code, headers, status, nil, bytes
    end

    local code, headers, status, error_kind, bytes = request_part(
        0, chunk_size - 1, "wb")
    if error_kind then return nil, nil, status, error_kind end
    if code == 200 then
        return code, headers, status, nil
    end
    if code ~= 206 then
        -- Some WebDAV servers advertise Range support but answer a request
        -- with 405/416 (or another non-206 status). A complete GET is still
        -- a valid and more compatible way to fetch the image.
        self.remove_file(part_path)
        return self:get_to_file(url, auth, part_path, progress_callback)
    end

    local first, last, total = parse_content_range(header_value(headers, "content-range"))
    if first ~= 0 or not last or not total or bytes ~= last - first + 1 then
        self.remove_file(part_path)
        return self:get_to_file(url, auth, part_path, progress_callback)
    end

    local response_headers = copy_headers(headers)
    local if_range = header_value(headers, "etag")
        or header_value(headers, "last-modified")
    local offset = last + 1
    while offset < total do
        local requested_last = math.min(total - 1, offset + chunk_size - 1)
        local part_code, part_headers, part_status, part_error_kind, part_bytes =
            request_part(offset, requested_last, "ab", if_range)
        if part_error_kind then
            return nil, nil, part_status, part_error_kind
        end
        if part_code == 200 then
            self.remove_file(part_path)
            return self:get_to_file(url, auth, part_path, progress_callback)
        end
        if part_code ~= 206 then
            self.remove_file(part_path)
            return self:get_to_file(url, auth, part_path, progress_callback)
        end
        local part_first, part_last, part_total = parse_content_range(
            header_value(part_headers, "content-range"))
        local part_entity = header_value(part_headers, "etag")
            or header_value(part_headers, "last-modified")
        if part_first ~= offset or not part_last or part_last > requested_last
            or part_total ~= total or part_bytes ~= part_last - part_first + 1
            or (if_range and part_entity and part_entity ~= if_range) then
            self.remove_file(part_path)
            return self:get_to_file(url, auth, part_path, progress_callback)
        end
        offset = part_last + 1
        status = part_status
    end

    replace_header(response_headers, "Content-Length", tostring(total))
    return 200, response_headers, status, nil
end

-- Small JSON request helper used by optional account integrations.  It keeps
-- the same HTTPS certificate and timeout handling as WebDAV requests.
function Transport:request_json(method, url, parameters, auth)
    local JSON = require("json")
    local request_method = tostring(method or "GET"):upper()
    local values = parameters or {}
    local query = {}
    local function encode(value)
        local util = require("util")
        return util.urlEncode(tostring(value))
    end
    for key, value in pairs(values) do
        if request_method == "GET" then
            query[#query + 1] = encode(key) .. "=" .. encode(value)
        end
    end
    if #query > 0 then
        url = url .. (url:find("?", 1, true) and "&" or "?")
            .. table.concat(query, "&")
    end
    local body
    local request = {
        url = url,
        method = request_method,
        redirect = false,
        headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = self:_authorization(auth),
        },
    }
    if request_method ~= "GET" then
        local encoded, encode_error = JSON.encode(values)
        if not encoded then return nil, encode_error or "cannot encode JSON" end
        body = encoded
        request.headers["Content-Type"] = "application/json"
        request.headers["Content-Length"] = #body
        request.source = self.ltn12.source.string(body)
    end
    local chunks = {}
    request.sink = self.ltn12.sink.table(chunks)
    local code, _headers, status = self:_request(request)
    if type(code) ~= "number" then return nil, status or "request failed" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
    local raw = table.concat(chunks)
    if request_method == "PATCH" and raw == "" then return true end
    local ok, decoded = pcall(JSON.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid JSON response"
    end
    return decoded
end

return Transport
