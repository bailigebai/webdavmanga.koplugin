local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

local fixture = read_file("spec/fixtures/multistatus.xml")

local replacements = {
    ["%%E6%%BC%%AB%%E7%%94%%BB"] = "漫画",
    ["%%E6%%B5%%B7%%E8%%B4%%BC%%E7%%8E%%8B"] = "海贼王",
    ["%%E7%%AC%%AC10%%E8%%AF%%9D"] = "第10话",
    ["%%E7%%AC%%AC2%%E8%%AF%%9D"] = "第2话",
    ["%%20"] = " ",
    ["%%26"] = "&",
    ["%%23"] = "#",
    ["%%3F"] = "?",
    ["%%2E"] = ".",
}
local function decode_url(value)
    for encoded, decoded in pairs(replacements) do
        value = value:gsub(encoded, decoded)
    end
    return value
end

local function html_decode(value)
    return value:gsub("&amp;", "&"):gsub("&quot;", '"')
end

local encoded = {
    ["漫画"] = "%E6%BC%AB%E7%94%BB",
    ["海贼王"] = "%E6%B5%B7%E8%B4%BC%E7%8E%8B",
}
local function encode_segment(value)
    return encoded[value] or value:gsub(" ", "%%20"):gsub("&", "%%26")
end


local captured = { propfind_calls = 0, propfind_stream_calls = 0, download_calls = 0 }
local part_files = {}
local removed_parts = {}
local download_body = read_file("webdavmanga.koplugin/resources/format_samples/lossy.webp")
local download_headers = {
    etag = '"page-etag"',
    ["last-modified"] = "today",
    ["cOnTeNt-LeNgTh"] = tostring(#download_body),
}
local transport = {
    propfind = function(_self, url, auth)
        captured.propfind_calls = captured.propfind_calls + 1
        captured.url, captured.auth = url, auth
        return 207, { etag = "listing" }, fixture, "207 Multi-Status"
    end,
    propfind_stream = function(_self, url, auth, on_chunk)
        captured.propfind_stream_calls = captured.propfind_stream_calls + 1
        captured.stream_url, captured.stream_auth = url, auth
        for first = 1, #fixture, 37 do
            local ok, err = on_chunk(fixture:sub(first, first + 36))
            if not ok then return nil, nil, nil, err end
        end
        return 207, { etag = "listing" }, "207 Multi-Status"
    end,
    get_to_file = function(_self, url, auth, part_path, progress_callback)
        captured.download_calls = captured.download_calls + 1
        captured.download_url = url
        captured.download_auth = auth
        captured.part_path = part_path
        captured.progress_callback = progress_callback
        part_files[part_path] = download_body
        return 200, download_headers, "200 OK"
    end,
}

local Client = require("webdavmanga.client")
local Probe = require("webdavmanga.image_probe")
local function fake_md5(value)
    return ("%032x"):format(#tostring(value or ""))
end
local manifest_lock_owners = {}
local manifest_fs = {
    open = io.open,
    remove = os.remove,
    size = function(path)
        local handle, detail = io.open(path, "rb")
        if not handle then return nil, detail end
        local size = handle:seek("end")
        handle:close()
        return size
    end,
    sync = function(handle) return handle:flush() end,
    atomic_replace = function(source, target)
        os.remove(target)
        return os.rename(source, target)
    end,
}
function manifest_fs.open_exclusive(path, mode)
    local handle, detail = io.open(path, mode == "wb+" and "wb+x" or "wbx")
    if handle and path:sub(-9) == ".wdm-lock" then
        manifest_lock_owners[path] = handle
    end
    return handle, detail
end
function manifest_fs.open_existing(path)
    local handle, detail = io.open(path, "rb")
    if handle then return handle end
    return nil, detail, true
end
function manifest_fs.release_lock(lock)
    if manifest_lock_owners[lock.path] ~= lock.handle then
        return nil, "test manifest lock identity changed"
    end
    local closed, close_detail = lock.handle:close()
    if not closed then return nil, close_detail end
    local removed, remove_detail = os.remove(lock.path)
    if not removed then return nil, remove_detail, true end
    manifest_lock_owners[lock.path] = nil
    return true, nil, true
end
local memory_probe = {
    inspect = function(path, extension)
        return Probe.inspect(path, extension, {
            open_file = function(candidate, mode)
                expect(mode == "rb", "client probe should open the part read-only")
                local content = part_files[candidate]
                if content == nil then return nil, "missing part" end
                return {
                    read = function(_self, count) return content:sub(1, count) end,
                    close = function() return true end,
                }
            end,
        })
    end,
}
local client = Client:new{
    connection = {
        server_url = "https://nas.example/dav",
        username = "reader",
        password = "secret",
        root_path = "/漫画",
    },
    transport = transport,
    decode_url = decode_url,
    html_decode = html_decode,
    encode_segment = encode_segment,
    file_size = function(path) return part_files[path] and #part_files[path] or 0 end,
    image_probe = memory_probe,
    md5 = fake_md5,
    manifest_fs = manifest_fs,
    remove_file = function(path)
        removed_parts[#removed_parts + 1] = path
        part_files[path] = nil
        return true
    end,
}

local function listed_directory(path)
    local manifest_path = "spec/.tmp-client-listed.manifest"
    local descriptor, err = client:write_directory_manifest(path, manifest_path)
    if not descriptor then return nil, err end
    local manifest = assert(require("webdavmanga.manifest").open(manifest_path, { md5 = fake_md5 }))
    local directory = { folders = {}, images = {} }
    for _, pair in ipairs({ { "folder", "folders" }, { "image", "images" } }) do
        local index = require("webdavmanga.chapter_index"):new{ manifest = manifest, kind = pair[1] }
        for position = 1, index:count() do directory[pair[2]][position] = index:get(position) end
    end
    manifest:close()
    os.remove(manifest_path)
    return directory
end
local StreamXml = require("webdavmanga.webdav_xml")
-- Retain the former parser/business cases through the real streaming + manifest pipeline.
local Xml = {}
function Xml.parse(body, path, options)
    local target = "spec/.tmp-client-xml.manifest"
    local Manifest = require("webdavmanga.manifest")
    local descriptor, err = Manifest.build({
        part_path = target, request_path = path, md5 = fake_md5, fs = manifest_fs,
    }, function(emit)
        local parser = StreamXml.new_stream{
            request_path = path, decode_url = options.decode_url,
            html_decode = options.html_decode, on_response = emit,
        }
        local ok, push_error = parser:push(body)
        if not ok then return nil, push_error end
        return parser:finish()
    end)
    if not descriptor then return nil, err end
    local manifest = assert(Manifest.open(target, { md5 = fake_md5 }))
    local entries = {}
    for _, kind in ipairs({ "folder", "image", "document" }) do
        local index = require("webdavmanga.chapter_index"):new{ manifest = manifest, kind = kind }
        for position = 1, index:count() do entries[#entries + 1] = index:get(position) end
    end
    manifest:close()
    os.remove(target)
    return entries
end
local entries, parse_err = Xml.parse(fixture, "/漫画/海贼王", {
    decode_url = decode_url,
    html_decode = html_decode,
})
expect(entries ~= nil and parse_err == nil, "fixture should parse")
expect(#entries == 6, ("current collection should be excluded; got %d (%s)")
    :format(#entries, table.concat((function()
        local names = {}
        for _, entry in ipairs(entries) do names[#names + 1] = entry.name end
        return names
    end)(), "|")))
expect(entries[2].name == "第10话" and entries[2].is_folder,
    "alternate namespace collection should parse")
expect(entries[1].name == "第2话" and entries[1].is_folder,
    "expanded collection tag should parse")
expect(entries[4].name == "10.JPG" and entries[4].is_file,
    "self-closing resourcetype should identify a file")
expect(entries[4].size == 2048 and entries[4].etag == '"etag-10"',
    "file metadata should parse and decode entities")
expect(entries[5].name == "A & B.webp", "URL and XML entities should decode")
expect(entries[5].path == "/漫画/海贼王/A & B.webp", "paths should use requested root")

local reserved_body = [[
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/%E6%BC%AB%E7%94%BB/%E6%B5%B7%E8%B4%BC%E7%8E%8B/A%23B%3FC.jpg?download=1#view</d:href>
  <d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>]]
local reserved_entries = assert(Xml.parse(reserved_body, "/漫画/海贼王", {
    decode_url = decode_url, html_decode = html_decode,
}))
expect(reserved_entries[1].name == "A#B?C.jpg"
    and reserved_entries[1].path == "/漫画/海贼王/A#B?C.jpg",
    "encoded # and ? filename characters must survive query/fragment stripping")

local boundary_body = [[
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/漫画/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/漫画/漫画/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/漫画/A/deep.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/漫画/missing.jpg</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>9</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
</d:multistatus>]]
local boundary_entries = assert(Xml.parse(boundary_body, "/漫画", {
    decode_url = decode_url, html_decode = html_decode,
}))
expect(#boundary_entries == 1 and boundary_entries[1].name == "漫画"
    and boundary_entries[1].is_folder,
    "same-named direct children should survive self filtering while deep and failed responses are ignored")

local root_body = [[
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/A/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>]]
local root_entries = assert(Xml.parse(root_body, "/", {
    decode_url = decode_url, html_decode = html_decode,
}))
expect(#root_entries == 1 and root_entries[1].name == "A" and root_entries[1].path == "/A",
    "a WebDAV base href should anchor direct children when the configured root is slash")

local traversal_body = [[
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/漫画/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/dav/漫画/%2E%2E/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>]]
local traversal_entries = assert(Xml.parse(traversal_body, "/漫画", {
    decode_url = decode_url, html_decode = html_decode,
}))
expect(#traversal_entries == 0,
    "encoded dot-segment children must not escape the requested WebDAV collection")

local malformed, malformed_err = Xml.parse("not XML", "/漫画", {
    decode_url = decode_url, html_decode = html_decode,
})
expect(malformed == nil and malformed_err.code == "decode", "malformed XML should be typed")
local directory = assert(listed_directory("/漫画/海贼王"))
expect(#directory.folders == 2 and #directory.images == 3,
    "one directory listing should return chapter folders and supported images together")
expect(directory.folders[1].name == "第2话" and directory.images[1].name == "2.jpg",
    "combined directory results should retain natural ordering")

local propfinds_before_escape = captured.propfind_stream_calls
local escaped_listing, escaped_listing_err = listed_directory("/漫画/..")
expect(escaped_listing == nil and escaped_listing_err.code == "invalid_path"
    and captured.propfind_stream_calls == propfinds_before_escape,
    "the client must reject a collection outside the configured root before PROPFIND")

local downloads_before_escape = captured.download_calls
local escaped_download, escaped_download_err = client:download(
    "/漫画/../private.jpg", "/cache/escape.part")
expect(escaped_download == nil and escaped_download_err.code == "invalid_path"
    and captured.download_calls == downloads_before_escape,
    "the client must reject an image outside the configured root before GET")

local folders = assert(listed_directory("/漫画/海贼王")).folders
expect(#folders == 2, "folder listing should filter files")
expect(folders[1].name == "第2话" and folders[2].name == "第10话",
    "folders should use natural order")
expect(captured.stream_url == "https://nas.example/dav/%E6%BC%AB%E7%94%BB/%E6%B5%B7%E8%B4%BC%E7%8E%8B/",
    "PROPFIND collection URL should end with slash")
expect(captured.stream_auth.username == "reader" and captured.stream_auth.password == "secret",
    "credentials should be passed separately")

local images = assert(listed_directory("/漫画/海贼王")).images
expect(#images == 3, "image listing should filter folders and unsupported files")
expect(images[1].name == "2.jpg" and images[2].name == "10.JPG"
    and images[3].name == "A & B.webp", "images should use natural order")

local metadata = assert(client:download(
    "/漫画/海贼王/A & B.webp", "/cache/page.jpg.part", function() end))
expect(captured.download_url:find("A%%20%%26%%20B.webp$"), "download path should encode")
expect(captured.part_path == "/cache/page.jpg.part", "part path should pass through")
expect(metadata.size == #download_body and metadata.etag == '"page-etag"'
    and metadata.modified == "today" and metadata.format == "webp"
    and metadata.width == 8 and metadata.height == 12,
    "download metadata should expose verified format and dimensions")
expect(#removed_parts == 0, "a verified image should retain its part for publication")

local function expect_decode_rejection(name, remote_path, body, headers, detail)
    local part_path = "/cache/" .. name .. ".part"
    download_body = body
    download_headers = headers or { ["Content-Length"] = tostring(#body) }
    local rejected, err = client:download(remote_path, part_path)
    expect(rejected == nil and err.code == "decode" and err.detail == detail,
        name .. " should return the expected decode contract")
    expect(part_files[part_path] == nil and removed_parts[#removed_parts] == part_path,
        name .. " should delete the rejected part before it can be published")
end

local valid_jpeg = read_file("webdavmanga.koplugin/resources/format_samples/baseline.jpg")
expect_decode_rejection("length-mismatch", "/漫画/page.jpg", valid_jpeg,
    { ["cOnTeNT-LeNgTh"] = tostring(#valid_jpeg + 1) }, "content_length_mismatch")
for _, case in ipairs({
    { "length-duplicate", {
        ["Content-Length"] = tostring(#valid_jpeg),
        ["content-length"] = tostring(#valid_jpeg),
    } },
    { "length-table", { ["Content-Length"] = { tostring(#valid_jpeg) } } },
    { "length-comma", { ["Content-Length"] = tostring(#valid_jpeg) .. ", " .. tostring(#valid_jpeg) } },
    { "length-float", { ["Content-Length"] = tostring(#valid_jpeg) .. ".0" } },
    { "length-exponent", { ["Content-Length"] = tostring(#valid_jpeg) .. "e0" } },
    { "length-unsafe", { ["Content-Length"] = "9007199254740992" } },
}) do
    expect_decode_rejection(case[1], "/漫画/page.jpg", valid_jpeg,
        case[2], "invalid_content_length")
end
expect_decode_rejection("html-login", "/漫画/page.jpg",
    "<!doctype html><html><title>Login</title></html>", nil,
    "unknown_image_signature")
expect_decode_rejection("bad-signature", "/漫画/page.jpg",
    "this is not an image", nil, "unknown_image_signature")
expect_decode_rejection("extension-mismatch", "/漫画/page.png",
    valid_jpeg, nil, "extension_signature_mismatch")

local manifest_path = "spec/.tmp-client-task5.manifest"
os.remove(manifest_path)
local legacy_calls_before_manifest = captured.propfind_calls
local streams_before_manifest = captured.propfind_stream_calls
local manifest_descriptor = assert(client:write_directory_manifest(
    "/漫画/海贼王", manifest_path))
local descriptor_keys = {
    part_path = true, size = true, count = true,
    folders = true, images = true, documents = true, digest = true,
}
local descriptor_key_count = 0
for key in pairs(manifest_descriptor) do
    descriptor_key_count = descriptor_key_count + 1
    expect(descriptor_keys[key] == true,
        "the client descriptor must not contain streamed payload data: " .. tostring(key))
end
expect(descriptor_key_count == 7 and manifest_descriptor.part_path == manifest_path
    and manifest_descriptor.count == 6 and manifest_descriptor.folders == 2
    and manifest_descriptor.images == 3 and manifest_descriptor.documents == 1
    and manifest_descriptor.payload_bytes == nil,
    "write_directory_manifest should return exactly the compact document-aware contract")
expect(captured.propfind_calls == legacy_calls_before_manifest
    and captured.propfind_stream_calls == streams_before_manifest + 1,
    "manifest creation must use streamed transport instead of the legacy body API")
expect(captured.stream_url
        == "https://nas.example/dav/%E6%BC%AB%E7%94%BB/%E6%B5%B7%E8%B4%BC%E7%8E%8B/"
    and captured.stream_auth.username == "reader"
    and captured.stream_auth.password == "secret",
    "streaming should preserve the encoded collection URL and separate credentials")
local Manifest = require("webdavmanga.manifest")
local ChapterIndex = require("webdavmanga.chapter_index")
local opened_manifest = assert(Manifest.open(manifest_path, { md5 = fake_md5 }))
local opened_images = ChapterIndex:new{ manifest = opened_manifest, kind = "image" }
expect(opened_images:get(1).name == "2.jpg" and opened_images:get(3).name == "A & B.webp",
    "the client should publish a readable naturally sorted manifest")
opened_manifest:close()

local streams_before_escape = captured.propfind_stream_calls
local escaped_manifest, escaped_manifest_err = client:write_directory_manifest(
    "/漫画/../private", "spec/.tmp-client-escape.manifest")
expect(escaped_manifest == nil and escaped_manifest_err.code == "invalid_path"
    and captured.propfind_stream_calls == streams_before_escape,
    "manifest paths outside the configured root must be rejected before PROPFIND")

local successful_stream = transport.propfind_stream
transport.propfind_stream = function(_self, _url, _auth, on_chunk)
    local ok, err = on_chunk("<d:multistatus xmlns:d=\"DAV:\"><d:response>"
        .. "<d:href>/漫画/海贼王/1.jpg</d:href>")
    if not ok then return nil, nil, nil, err end
    return 207, {}, "207 Multi-Status"
end
local truncated_manifest_path = "spec/.tmp-client-truncated.manifest"
local truncated_manifest, truncated_manifest_err = client:write_directory_manifest(
    "/漫画/海贼王", truncated_manifest_path)
expect(truncated_manifest == nil and truncated_manifest_err.code == "decode"
    and io.open(truncated_manifest_path, "rb") == nil,
    "truncated XML must fail closed without leaving a publishable manifest part")

transport.propfind_stream = function(_self, _url, _auth, _on_chunk)
    return 401, {}, "401 Unauthorized"
end
local denied_manifest, denied_manifest_err = client:write_directory_manifest(
    "/漫画/海贼王", "spec/.tmp-client-denied.manifest")
expect(denied_manifest == nil and denied_manifest_err.http_status == 401,
    "streamed manifest HTTP failures should preserve the typed error contract")

transport.propfind_stream = successful_stream
local legacy_calls_before_test = captured.propfind_calls
expect(client:test_connection(), "successful streamed multistatus should validate connection")
expect(captured.propfind_calls == legacy_calls_before_test
    and captured.propfind_stream_calls == streams_before_escape + 1,
    "test_connection must stream and discard responses without the legacy parser")

transport.propfind_stream = function(_self, _url, _auth, on_chunk)
    local body = [[<d:multistatus xmlns:d="DAV:"><d:response>
        <d:href>/漫画/</d:href><d:propstat><d:prop><d:resourcetype/></d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response></d:multistatus>]]
    local ok, err = on_chunk(body)
    if not ok then return nil, nil, nil, err end
    return 207, {}, "207 Multi-Status"
end
local empty_connection, empty_connection_err = client:test_connection()
expect(empty_connection == nil and empty_connection_err.code == "decode",
    "test_connection should require at least one valid streamed response")
transport.propfind_stream = successful_stream

transport.propfind_stream = function() return 401, {}, "401 Unauthorized" end
local denied, denied_err = listed_directory("/漫画")
expect(denied == nil and denied_err.http_status == 401, "HTTP errors should be typed")
expect(not tostring(denied_err.detail):find("secret", 1, true), "typed error should not contain password")

transport.propfind_stream = function() return nil, nil, nil, "connection timed out" end
local offline, offline_err = listed_directory("/漫画")
expect(offline == nil and offline_err.code == "transport", "network errors should be typed")

transport.get_to_file = function() return 200, {}, "200 OK" end
local empty, empty_err = client:download("/漫画/empty.jpg", "/cache/empty.part")
expect(empty == nil and empty_err.code == "storage"
    and removed_parts[#removed_parts] == "/cache/empty.part",
    "zero-byte download should fail and delete its part")

transport.get_to_file = function()
    return nil, nil, "Permission denied", "storage"
end
local unwritable, unwritable_err = client:download("/漫画/1.jpg", "/cache/1.part")
expect(unwritable == nil and unwritable_err.code == "storage",
    "transport disk failures should remain typed as storage")

os.remove(manifest_path)
os.remove(truncated_manifest_path)
os.remove("spec/.tmp-client-escape.manifest")
os.remove("spec/.tmp-client-denied.manifest")

local budget_options
local actual_get=transport.get_to_file
transport.get_to_file=function(_,url,auth,part,progress,options)
 budget_options=options;return nil,nil,"cache_limit","storage" end
local bounded,bounded_error=client:download("/漫画/1.jpg","/cache/bounded.part",nil,{max_bytes=77})
expect(not bounded and bounded_error.detail=="cache_limit" and budget_options.max_bytes==77,
 "client carries quota through HTTP boundary and preserves its storage reason")
transport.get_to_file=actual_get

print(("webdav_client_spec: %d checks"):format(checks))
