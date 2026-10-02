local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local captured_request
local response_body = "<d:multistatus xmlns:d=\"DAV:\"/>"
local http_mode = "success"
local fake_http = {
    request = function(request)
        captured_request = request
        if http_mode == "raise" then error("network exploded") end
        if http_mode == "soft_fail" then return nil, "certificate verify failed" end
        if type(request.sink) == "table" and request.sink.target then
            request.sink.target[#request.sink.target + 1] = response_body
        elseif request.method == "PROPFIND" and type(request.sink) == "function" then
            local first = math.floor(#response_body / 3)
            local second = math.floor(#response_body * 2 / 3)
            for _, chunk in ipairs({
                response_body:sub(1, first),
                response_body:sub(first + 1, second),
                response_body:sub(second + 1),
            }) do
                if chunk ~= "" then
                    local sink_ok, sink_err = request.sink(chunk)
                    if not sink_ok then return nil, sink_err end
                end
            end
            local sink_ok, sink_err = request.sink(nil)
            if not sink_ok then return nil, sink_err end
        elseif request.method == "GET" and type(request.sink) == "function" then
            request.sink("page-")
            request.sink("data")
            request.sink(nil)
        end
        if http_mode == "denied" then
            return 1, 401, { server = "fake" }, "401 Unauthorized"
        end
        local headers = { etag = '"abc"' }
        if request.method == "GET" then headers["cOnTeNt-LeNgTh"] = "9" end
        return 1, request.method == "PROPFIND" and 207 or 200, headers, "OK"
    end,
}
local https_request_count = 0
local fake_https = {
    request = function(request)
        https_request_count = https_request_count + 1
        return fake_http.request(request)
    end,
}

local fake_socket = {
    skip = function(_count, _first, ...)
        return ...
    end,
}

local set_timeout_count, reset_timeout_count = 0, 0
local progress_wrapped = false
local fake_socketutil = {
    FILE_BLOCK_TIMEOUT = 11,
    FILE_TOTAL_TIMEOUT = 22,
    set_timeout = function(_self, block, total)
        expect(block == 11 and total == 22, "KOReader file timeouts should be used")
        set_timeout_count = set_timeout_count + 1
    end,
    reset_timeout = function(_self)
        reset_timeout_count = reset_timeout_count + 1
    end,
    chainSinkWithProgressCallback = function(sink, callback)
        progress_wrapped = type(callback) == "function"
        return function(chunk, err)
            if chunk then callback(#chunk) end
            return sink(chunk, err)
        end
    end,
}

local fail_write = false
local fake_ltn12 = {
    source = {
        string = function(body) return { body = body } end,
    },
    sink = {
        table = function(target) return { target = target } end,
        file = function(handle)
            return function(chunk)
                if not chunk then
                    handle:close()
                    return 1
                end
                if fail_write then return nil, "No space left while writing" end
                return handle:write(chunk)
            end
        end,
    },
}

local opened = {}
local written_by_path = {}
local handles_by_path = {}
local file_events = {}
local fail_open = false
local function fake_open(path, mode)
    if fail_open then return nil, "No space left on device" end
    local handle = { path = path, closed = false }
    function handle:write(chunk)
        written_by_path[self.path] = (written_by_path[self.path] or 0) + #chunk
        return 1
    end
    function handle:close()
        if not self.closed then file_events[#file_events + 1] = "close:" .. self.path end
        self.closed = true
        return true
    end
    opened[#opened + 1] = { path = path, mode = mode, handle = handle }
    handles_by_path[path] = handle
    return handle
end

local removed = {}
local function fake_remove(path)
    file_events[#file_events + 1] = "remove:" .. path
    removed[#removed + 1] = path
    return true
end

local Transport = require("webdavmanga.transport")
local function propfind(target, url, auth)
    local chunks = {}
    local code, headers, status, err = target:propfind_stream(url, auth, function(chunk)
        chunks[#chunks + 1] = chunk
        return true
    end)
    if not code then return nil, nil, nil, err or status end
    return code, headers, table.concat(chunks), status
end
local transport = Transport:new{
    http = fake_http,
    https = fake_https,
    socket = fake_socket,
    socketutil = fake_socketutil,
    ltn12 = fake_ltn12,
    open_file = fake_open,
    remove_file = fake_remove,
    base64 = function(value) return "ENC<" .. value .. ">" end,
}

local auth = { username = "reader", password = "p%20word" }
local code, headers, body, status = propfind(transport, "https://nas/dav/%E6%BC%AB/", auth)
expect(code == 207 and headers.etag == '"abc"' and body == response_body,
    "PROPFIND response should be captured")
expect(status == "OK", "status should pass through")
expect(captured_request.method == "PROPFIND", "PROPFIND method should be used")
expect(captured_request.redirect == false,
    "credential-bearing requests should not follow redirects")
expect(captured_request.headers.Depth == "1", "Depth must be one")
expect(captured_request.headers["Content-Type"] == "application/xml",
    "XML content type should be sent")
expect(captured_request.headers["Content-Length"] == #captured_request.source.body,
    "body length should be exact")
expect(captured_request.source.body:find("resourcetype", 1, true),
    "requested properties should include resource type")
expect(captured_request.headers.Authorization == "Basic ENC<reader:p%20word>"
    and captured_request.user == nil and captured_request.password == nil,
    "Basic auth should preserve raw percent sequences without LuaSocket URL decoding")
expect(set_timeout_count == 1 and reset_timeout_count == 1,
    "PROPFIND should set and reset timeouts")
expect(https_request_count == 1, "HTTPS URLs should use KOReader's LuaSec client")

local wildcard_certificate = {
    extensions = function()
        return { ["2.5.29.17"] = { dNSName = { "*.example.com" } } }
    end,
    subject = function() return {} end,
}
expect(Transport.certificate_matches_hostname(wildcard_certificate, "nas.example.com"),
    "TLS hostname verification should accept one-label SAN wildcards")
expect(not Transport.certificate_matches_hostname(wildcard_certificate, "deep.nas.example.com"),
    "TLS hostname verification should reject multi-label wildcard expansion")
local ip_certificate = {
    extensions = function()
        return { ["2.5.29.17"] = { iPAddress = { "192.168.1.10" } } }
    end,
    subject = function() return {} end,
}
expect(Transport.certificate_matches_hostname(ip_certificate, "192.168.1.10")
    and not Transport.certificate_matches_hostname(ip_certificate, "192.168.1.11"),
    "TLS IP literals should require an exact IP subjectAltName")

local secure_request
local secure_transport = Transport:new{
    http = {
        request = function(request)
            secure_request = request
            return 1, 207, {}, "OK"
        end,
    },
    socket = fake_socket,
    socketutil = fake_socketutil,
    ltn12 = fake_ltn12,
    ssl = {},
    url = {
        parse = function(value)
            return { scheme = "https", host = "nas.example.com", path = "/dav", original = value }
        end,
        build = function(parts) return parts.original end,
    },
    ca_file = "/data/ca-bundle.crt",
    file_exists = function(path) return path == "/data/ca-bundle.crt" end,
    open_file = fake_open,
    remove_file = fake_remove,
    base64 = function(value) return "ENC<" .. value .. ">" end,
}
propfind(secure_transport, "https://nas.example.com/dav", auth)
expect(secure_request.verify == "peer"
    and secure_request.cafile == "/data/ca-bundle.crt"
    and type(secure_request.create) == "function",
    "production HTTPS must require peer verification and KOReader's CA bundle")

local tls_close_count = 0
local raw_socket_methods = {}
function raw_socket_methods:settimeout() return true end
function raw_socket_methods:connect() return 1 end
function raw_socket_methods:close() tls_close_count = tls_close_count + 1; return true end
local raw_socket = setmetatable({}, { __index = raw_socket_methods })
local wrapped_socket_methods = {}
function wrapped_socket_methods:sni() end
function wrapped_socket_methods:dohandshake() return nil, "certificate verify failed" end
function wrapped_socket_methods:close() tls_close_count = tls_close_count + 1; return true end
local wrapped_socket = setmetatable({}, { __index = wrapped_socket_methods })
local failing_transport = Transport:new{
    http = { request = function() end },
    socket = { tcp = function() return raw_socket end },
    socketutil = fake_socketutil,
    ltn12 = fake_ltn12,
    ssl = { wrap = function() return wrapped_socket end },
    url = { parse = function() end, build = function() end },
    ca_file = "/data/ca-bundle.crt",
    file_exists = function() return true end,
    open_file = fake_open,
    remove_file = fake_remove,
}
local failed_connection = failing_transport:_tls_socket_factory{
    verify = "peer", cafile = "/data/ca-bundle.crt",
}()
local connected, connect_error = failed_connection:connect("nas.example.com", 443)
expect(connected == nil and connect_error == "certificate verify failed"
    and tls_close_count == 1 and type(failed_connection.close) == "function",
    "TLS handshake failure should preserve the error and close the socket safely")
failed_connection:close()
expect(tls_close_count == 1,
    "LuaSocket's failure finalizer should be able to close the connection idempotently")

propfind(transport, "http://nas/dav/", auth)
expect(https_request_count == 1, "plain HTTP URLs should keep using the HTTP client")

local progress = function() end
code, headers, status = transport:get_to_file(
    "https://nas/dav/page.jpg", auth, "/cache/page.jpg.part", progress)
expect(code == 200 and headers.etag == '"abc"',
    "GET response should pass through: code=" .. tostring(code)
        .. " status=" .. tostring(status))
expect(status == "OK" and captured_request.method == "GET", "GET method should be used")
expect(opened[1].path == "/cache/page.jpg.part" and opened[1].mode == "wb",
    "temporary file should open in binary mode")
expect(progress_wrapped, "progress callback should wrap the sink")
expect(written_by_path["/cache/page.jpg.part"] == 9
    and headers["cOnTeNt-LeNgTh"] == "9",
    "GET should stream and count the same mixed-case Content-Length bytes")
expect(handles_by_path["/cache/page.jpg.part"].closed,
    "a successful GET should leave its output handle closed")
expect(#removed == 0, "successful GET should keep the part file")
expect(set_timeout_count == 4 and reset_timeout_count == 4,
    "GET should set and reset timeouts")

http_mode = "denied"
code = transport:get_to_file("https://nas/dav/private.jpg", auth, "/cache/private.part")
expect(code == 401, "HTTP denial should return status")
expect(removed[1] == "/cache/private.part", "failed GET should remove partial file")
expect(handles_by_path["/cache/private.part"].closed,
    "an HTTP failure should close its output handle before cleanup")
expect(reset_timeout_count == 5, "denied GET should reset timeout")

http_mode = "raise"
local failed_code, failed_headers, failed_body, failed_status = propfind(transport,
    "https://nas/dav/", auth)
expect(failed_code == nil and failed_headers == nil and failed_body == nil,
    "transport exception should not escape")
expect(failed_status:find("network exploded", 1, true), "transport error should be returned")
expect(reset_timeout_count == 6, "exception path should reset timeout")

http_mode = "soft_fail"
local soft_code, _soft_headers, _soft_body, soft_status = propfind(transport,
    "https://nas/dav/", auth)
expect(soft_code == nil and soft_status:find("certificate verify failed", 1, true),
    "non-throwing LuaSocket/TLS failures should preserve their error detail")

http_mode = "raise"
local request_part = "/cache/request-exception.part"
local request_code = transport:get_to_file(
    "https://nas/dav/request-exception.jpg", auth, request_part)
expect(request_code == nil and handles_by_path[request_part].closed,
    "a request exception should close the output handle")
expect(file_events[#file_events - 1] == "close:" .. request_part
    and file_events[#file_events] == "remove:" .. request_part,
    "request-exception cleanup must close before deleting the part")

fail_open = true
local disk_code, _disk_headers, disk_status, disk_kind = transport:get_to_file(
    "https://nas/dav/page.jpg", auth, "/cache/full.part")
expect(disk_code == nil and disk_kind == "storage"
    and disk_status:find("No space", 1, true),
    "temporary-file open failures should be identified as storage errors")

fail_open = false
fail_write = true
http_mode = "success"
local original_request = fake_http.request
fake_http.request = function(request)
    captured_request = request
    if type(request.sink) == "function" then request.sink("page-data") end
    return 1, 200, { etag = '"abc"' }, "OK"
end
local write_code, _write_headers, write_status, write_kind = transport:get_to_file(
    "https://nas/dav/page.jpg", auth, "/cache/write-full.part")
expect(write_code == nil and write_kind == "storage"
    and write_status:find("No space", 1, true),
    "temporary-file write failures should be identified as storage errors")
expect(removed[#removed] == "/cache/write-full.part",
    "a write-failed partial file should be removed")
expect(handles_by_path["/cache/write-full.part"].closed,
    "a write failure should close the output handle even without sink EOF")
expect(file_events[#file_events - 1] == "close:/cache/write-full.part"
    and file_events[#file_events] == "remove:/cache/write-full.part",
    "write-failure cleanup must close before deleting the part")
fake_http.request = original_request

response_body = "<d:multistatus xmlns:d=\"DAV:\"><d:response>"
    .. "<d:href>/Books/A/</d:href></d:response></d:multistatus>"
local streamed_chunks = {}
local stream_code, stream_headers, stream_status, stream_error = transport:propfind_stream(
    "https://nas/dav/Books/A/", auth, function(chunk)
        streamed_chunks[#streamed_chunks + 1] = chunk
        return true
    end)
expect(stream_code == 207 and stream_headers.etag == '"abc"'
    and stream_status == "OK" and stream_error == nil,
    "streamed PROPFIND should return only status metadata")
expect(table.concat(streamed_chunks) == response_body and #streamed_chunks == 3,
    "PROPFIND bytes should be forwarded incrementally without a response table")
expect(type(captured_request.sink) == "function",
    "streamed PROPFIND must use a callback sink rather than an accumulating sink")

local callback_calls = 0
local rejected_code, rejected_headers, rejected_status, rejected_error =
    transport:propfind_stream("https://nas/dav/Books/A/", auth, function()
        callback_calls = callback_calls + 1
        return nil, "parser rejected chunk"
    end)
expect(rejected_code == nil and rejected_headers == nil and rejected_status == nil
    and rejected_error == "parser rejected chunk" and callback_calls == 1,
    "a chunk consumer failure should abort the sink and remain bounded")

print(("transport_spec: %d checks"):format(checks))
