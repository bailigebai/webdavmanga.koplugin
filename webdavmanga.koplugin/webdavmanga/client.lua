local Errors = require("webdavmanga.errors")
local Formats = require("webdavmanga.image_formats")
local Manifest = require("webdavmanga.manifest")
local Path = require("webdavmanga.path")
local WebDavXml = require("webdavmanga.webdav_xml")

local Client = {}
Client.__index = Client

local MAX_SAFE_INTEGER = 9007199254740991

local function header_value(headers, wanted)
    wanted = tostring(wanted or ""):lower()
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == wanted then return value end
    end
    return nil
end

local function content_length(headers)
    local raw
    local count = 0
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == "content-length" then
            count = count + 1
            raw = value
        end
    end
    if count == 0 then return nil end
    if count ~= 1 or type(raw) ~= "string" then
        return nil, "invalid_content_length"
    end
    local digits = raw:match("^%s*(%d+)%s*$")
    if not digits then return nil, "invalid_content_length" end
    local value = tonumber(digits)
    if not value or value ~= value or value == math.huge or value == -math.huge
        or value > MAX_SAFE_INTEGER or math.floor(value) ~= value then
        return nil, "invalid_content_length"
    end
    return value
end

local function content_range_total(headers)
    local value
    local count = 0
    for key, candidate in pairs(type(headers) == "table" and headers or {}) do
        if tostring(key):lower() == "content-range" then
            count = count + 1
            value = candidate
        end
    end
    if count == 0 then return nil end
    if count ~= 1 or type(value) ~= "string" then
        return nil, "invalid_content_range"
    end
    local first, last, total = value:match(
        "^%s*bytes%s+(%d+)%-(%d+)%/(%d+)%s*$")
    first, last, total = tonumber(first), tonumber(last), tonumber(total)
    if not first or not last or not total
        or first < 0 or last < first or total <= last then
        return nil, "invalid_content_range"
    end
    return total
end

local function default_utilities()
    local util = require("util")
    return util.urlEncode, util.urlDecode, util.htmlEntitiesToUtf8
end

local function default_file_size(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "size")
end

local function default_read_file_prefix(path, count)
    local file, open_error = io.open(path, "rb")
    if not file then return nil, open_error end
    local prefix = file:read(count)
    local closed, close_error = file:close()
    if not prefix then return nil, "cannot read downloaded document" end
    if not closed then return nil, close_error end
    return prefix
end

local function valid_document_signature(extension, prefix)
    if type(prefix) ~= "string" then return false end
    if extension == "pdf" then
        return prefix:find("%PDF-", 1, true) ~= nil
    elseif extension == "mobi" or extension == "azw" or extension == "azw3" then
        return prefix:sub(61, 68) == "BOOKMOBI"
    end
    return true
end

function Client:new(options)
    options = options or {}
    local encode_segment, decode_url, html_decode
    if not options.encode_segment or not options.decode_url or not options.html_decode then
        encode_segment, decode_url, html_decode = default_utilities()
    end
    local object = setmetatable({}, self)
    object.connection = assert(options.connection, "connection is required")
    if options.transport then
        object.transport = options.transport
    else
        local Transport = require("webdavmanga.transport")
        object.transport = Transport:new()
    end
    object.encode_segment = options.encode_segment or encode_segment
    object.decode_url = options.decode_url or decode_url
    object.html_decode = options.html_decode or html_decode
    object.file_size = options.file_size or default_file_size
    object.read_file_prefix = options.read_file_prefix or default_read_file_prefix
    object.image_probe = options.image_probe or require("webdavmanga.image_probe")
    object.remove_file = options.remove_file or os.remove
    object.range_download = options.range_download ~= false
    object.md5 = options.md5
    object.manifest_fs = options.manifest_fs
    object.manifest_run_size = options.manifest_run_size
    return object
end

function Client:_auth()
    return {
        username = self.connection.username,
        password = self.connection.password,
    }
end

function Client:_collection_url(remote_path)
    local url = Path.build_url(self.connection.server_url, remote_path, self.encode_segment)
    if url:sub(-1) ~= "/" then url = url .. "/" end
    return url
end

function Client:_resource_url(remote_path)
    return Path.build_url(self.connection.server_url, remote_path, self.encode_segment)
end

local function streamed_error(code, status, stream_error)
    if type(code) ~= "number" then
        if type(stream_error) == "table" and stream_error.code then
            return stream_error
        end
        return Errors.transport(stream_error or status or code)
    end
    if code < 200 or code >= 300 then return Errors.http(code, status) end
    return nil
end

function Client:write_directory_manifest(remote_path, part_path, options)
    if not Path.is_within_remote(remote_path, self.connection.root_path) then
        return nil, Errors.invalid_path()
    end
    local descriptor, build_error = Manifest.build({
        part_path = part_path,
        max_temp_bytes=options and options.max_temp_bytes,
        request_path = remote_path,
        md5 = self.md5,
        fs = self.manifest_fs,
        run_size = self.manifest_run_size,
    }, function(emit)
        local parser = WebDavXml.new_stream{
            request_path = remote_path,
            decode_url = self.decode_url,
            html_decode = self.html_decode,
            on_response = emit,
        }
        local code, _headers, status, stream_error = self.transport:propfind_stream(
            self:_collection_url(remote_path), self:_auth(), function(chunk)
                return parser:push(chunk)
            end)
        local request_error = streamed_error(code, status, stream_error)
        if request_error then return nil, request_error end
        return parser:finish()
    end)
    if not descriptor then return nil, build_error end
    local result = {
        part_path = descriptor.part_path,
        size = descriptor.size,
        count = descriptor.count,
        folders = descriptor.folders,
        images = descriptor.images,
        digest = descriptor.digest,
    }
    if descriptor.documents and descriptor.documents > 0 then
        result.documents = descriptor.documents
    end
    return result
end

function Client:download(remote_path, part_path, progress_callback, options)
    if not Path.is_within_remote(remote_path, self.connection.root_path) then
        return nil, Errors.invalid_path()
    end
    local download_method = self.transport.get_range_to_file
        and self.range_download ~= false and self.transport.get_range_to_file
        or self.transport.get_to_file
    local code, headers, status, error_kind = download_method(self.transport,
        self:_resource_url(remote_path), self:_auth(), part_path, progress_callback, options)
    if type(code) ~= "number" then
        if error_kind == "storage" then return nil, Errors.storage(status) end
        return nil, Errors.transport(status or code)
    end
    if code < 200 or code >= 300 then
        return nil, Errors.http(code, status)
    end
    local size = tonumber(self.file_size(part_path)) or 0
    if size <= 0 then
        self.remove_file(part_path)
        return nil, Errors.storage("downloaded file is empty")
    end
    headers = headers or {}
    local expected, length_error = content_length(headers)
    if length_error then
        self.remove_file(part_path)
        return nil, Errors.image_decode(length_error, "webdav")
    end
    local range_total, range_error = content_range_total(headers)
    if range_error then
        self.remove_file(part_path)
        return nil, Errors.image_decode(range_error, "webdav")
    end
    -- A Range assembler may return the first segment's Content-Length while
    -- Content-Range carries the verified entity size.  Prefer that total when
    -- it is present; ordinary full GETs still require Content-Length to match.
    if (range_total and range_total ~= size)
        or (not range_total and expected and expected ~= size) then
        self.remove_file(part_path)
        return nil, Errors.image_decode("content_length_mismatch", "webdav")
    end
    local image_info, probe_error = self.image_probe.inspect(
        part_path, Formats.extension(remote_path), {
            allow_extension_mismatch = true,
        })
    if not image_info then
        self.remove_file(part_path)
        return nil, Errors.image_decode(probe_error, "webdav")
    end
    return {
        size = size,
        etag = header_value(headers, "etag"),
        modified = header_value(headers, "last-modified"),
        format = image_info.format,
        width = image_info.width,
        height = image_info.height,
        extension_mismatch = image_info.extension_mismatch == true,
    }
end

function Client:download_document(remote_path, part_path, progress_callback)
    if not Path.is_within_remote(remote_path, self.connection.root_path) then
        return nil, Errors.invalid_path()
    end
    if not Formats.is_document(remote_path) then
        return nil, Errors.document("staging", "unsupported document format")
    end
    local download_method = self.transport.get_range_to_file
        and self.range_download ~= false and self.transport.get_range_to_file
        or self.transport.get_to_file
    local code, headers, status, error_kind = download_method(self.transport,
        self:_resource_url(remote_path), self:_auth(), part_path, progress_callback)
    if type(code) ~= "number" then
        if error_kind == "storage" then return nil, Errors.storage(status) end
        return nil, Errors.transport(status or code)
    end
    if code < 200 or code >= 300 then
        return nil, Errors.http(code, status)
    end
    local size = tonumber(self.file_size(part_path)) or 0
    if size <= 0 then
        self.remove_file(part_path)
        return nil, Errors.document("staging", "downloaded document is empty")
    end
    headers = headers or {}
    local expected, length_error = content_length(headers)
    if length_error or (expected and expected ~= size) then
        self.remove_file(part_path)
        return nil, Errors.document("staging", length_error or "content_length_mismatch")
    end
    local extension = Formats.extension(remote_path)
    if extension == "pdf" or extension == "mobi" or extension == "azw" or extension == "azw3" then
        local prefix, read_error = self.read_file_prefix(part_path, 1024)
        if not prefix then
            self.remove_file(part_path)
            return nil, Errors.storage(read_error or "document validation read failed")
        end
        if not valid_document_signature(extension, prefix) then
            self.remove_file(part_path)
            return nil, Errors.document("staging", "invalid_document_signature")
        end
    end
    return {
        size = size,
        etag = header_value(headers, "etag"),
        modified = header_value(headers, "last-modified"),
        format = extension,
    }
end

function Client:read_range(remote_path, first, last)
    if not Path.is_within_remote(remote_path, self.connection.root_path) then
        return nil, Errors.invalid_path()
    end
    if not Formats.is_document(remote_path) then
        return nil, Errors.document("stream", "unsupported document format")
    end
    if not self.transport.get_range_bytes then
        return nil, Errors.document("stream", "range reader unavailable")
    end
    first = tonumber(first)
    last = tonumber(last)
    if not first or not last or first ~= math.floor(first)
        or last ~= math.floor(last) or first < 0 or last < first then
        return nil, Errors.document("stream", "invalid byte range")
    end
    local body, headers, detail = self.transport:get_range_bytes(
        self:_resource_url(remote_path), self:_auth(), first, last)
    if not body then
        return nil, Errors.transport(detail or "range request failed")
    end
    return body, headers
end

function Client:test_connection()
    local remote_path = self.connection.root_path
    if not Path.is_within_remote(remote_path, self.connection.root_path) then
        return nil, Errors.invalid_path()
    end
    local valid_responses = 0
    local parser = WebDavXml.new_stream{
        request_path = remote_path,
        decode_url = self.decode_url,
        html_decode = self.html_decode,
        on_response = function()
            valid_responses = valid_responses + 1
            return true
        end,
    }
    local code, _headers, status, stream_error = self.transport:propfind_stream(
        self:_collection_url(remote_path), self:_auth(), function(chunk)
            return parser:push(chunk)
        end)
    local request_error = streamed_error(code, status, stream_error)
    if request_error then return nil, request_error end
    local finished, finish_error = parser:finish()
    if not finished then return nil, finish_error end
    if valid_responses < 1 then
        return nil, Errors.decode("missing valid response elements")
    end
    return true
end

return Client
