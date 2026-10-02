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

local function write_file(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

local fixture = read_file("spec/fixtures/multistatus.xml")
local replacements = {
    ["%%E6%%BC%%AB%%E7%%94%%BB"] = "漫画",
    ["%%E6%%B5%%B7%%E8%%B4%%BC%%E7%%8E%%8B"] = "海贼王",
    ["%%E7%%AC%%AC10%%E8%%AF%%9D"] = "第10话",
    ["%%E7%%AC%%AC2%%E8%%AF%%9D"] = "第2话",
    ["%%20"] = " ",
    ["%%26"] = "&",
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

local WebDavXml = require("webdavmanga.webdav_xml")

local expected_fixture_records = {
    {
        full_path = "/dav/漫画/海贼王", name = "海贼王",
        is_folder = true,
    },
    {
        full_path = "/dav/漫画/海贼王/第10话", name = "第10话",
        is_folder = true,
    },
    {
        full_path = "/dav/漫画/海贼王/第2话", name = "第2话",
        is_folder = true,
    },
    {
        full_path = "/dav/漫画/海贼王/10.JPG", name = "10.JPG",
        is_file = true, size = 2048, etag = '"etag-10"',
        modified = "Sat, 29 Aug 2026 12:00:00 GMT",
    },
    {
        full_path = "/dav/漫画/海贼王/2.jpg", name = "2.jpg",
        is_file = true, size = 1024,
    },
    {
        full_path = "/dav/漫画/海贼王/A & B.webp", name = "A & B.webp",
        is_file = true, size = 4096,
    },
    {
        full_path = "/dav/漫画/海贼王/notes.txt", name = "notes.txt",
        is_file = true, size = 99,
    },
}

local record_fields = {
    "full_path", "name", "is_folder", "is_file",
    "size", "modified", "etag",
}

local function expect_records(actual, expected, label)
    expect(#actual == #expected,
        ("%s should emit %d records, got %d"):format(label, #expected, #actual))
    for index, wanted in ipairs(expected) do
        local got = actual[index]
        for _, field in ipairs(record_fields) do
            expect(got[field] == wanted[field],
                ("%s record %d field %s mismatch: %s ~= %s")
                    :format(label, index, field, tostring(got[field]), tostring(wanted[field])))
        end
    end
end

local function parse_chunks(body, request_path, chunks)
    local seen = {}
    local parser = WebDavXml.new_stream{
        request_path = request_path,
        decode_url = decode_url,
        html_decode = html_decode,
        on_response = function(record)
            seen[#seen + 1] = record
            return true
        end,
    }
    for _, chunk in ipairs(chunks or { body }) do
        local ok, err = parser:push(chunk)
        expect(ok == true and err == nil, "a valid chunk should be accepted")
    end
    local ok, err = parser:finish()
    expect(ok == true and err == nil, "a complete stream should finish")
    return seen
end

local baseline = parse_chunks(fixture, "/漫画/海贼王")
expect_records(baseline, expected_fixture_records, "fixture baseline")

-- Each literal cut is derived from the fixture bytes. A parser that assumes
-- tag, percent escape, entity, or UTF-8 boundaries align with chunks fails.
local cuts = {}
local function add_cuts_around(body, needle)
    local start_at = 1
    while true do
        local first, last = body:find(needle, start_at, true)
        if not first then break end
        for cut = math.max(1, first - 2), math.min(#body - 1, last + 1) do
            cuts[cut] = true
        end
        start_at = first + 1
    end
end
for _, needle in ipairs({
    "<d:response", "<x:response", "</d:response>", "</x:response>",
    "%E7%AC%AC10%E8%AF%9D", "%E7%AC%AC2%E8%AF%9D", "&quot;",
}) do
    add_cuts_around(fixture, needle)
end
for cut in pairs(cuts) do
    local seen = parse_chunks(fixture, "/漫画/海贼王", {
        fixture:sub(1, cut), fixture:sub(cut + 1),
    })
    expect_records(seen, expected_fixture_records, "fixture cut at byte " .. cut)
end

local utf8_body = [[<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/dav/Books/A/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/dav/Books/A/章节二/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/dav/Books/A/A%20&amp;%20B.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>]]
local expected_utf8 = {
    { full_path = "/dav/Books/A", name = "A", is_folder = true },
    { full_path = "/dav/Books/A/章节二", name = "章节二", is_folder = true },
    { full_path = "/dav/Books/A/A & B.jpg", name = "A & B.jpg", is_file = true },
}
local utf8_cuts = {}
add_cuts_around(utf8_body, "章节二")
add_cuts_around(utf8_body, "&amp;")
for cut in pairs(cuts) do utf8_cuts[cut] = true end
-- Rebuild only the UTF-8/entity cuts; the fixture cuts above are out of range
-- or harmless, but checking the actual target range documents the byte split.
utf8_cuts = {}
local function collect_local_cuts(needle)
    local first, last = assert(utf8_body:find(needle, 1, true))
    for cut = first - 1, last do utf8_cuts[cut] = true end
end
collect_local_cuts("章节二")
collect_local_cuts("&amp;")
for cut in pairs(utf8_cuts) do
    local seen = parse_chunks(utf8_body, "/Books/A", {
        utf8_body:sub(1, cut), utf8_body:sub(cut + 1),
    })
    expect_records(seen, expected_utf8, "UTF-8/entity cut at byte " .. cut)
end

local hostile_body = [[<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/prefix/team/Books/A/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/prefix/team/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/prefix/team/Books/A/failed.jpg</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>99</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
<d:response><d:href>/prefix/team/Other/private.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/prefix/team/Books/A/%2E%2E/private.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>]]
local hostile_records = parse_chunks(hostile_body, "/Books/A", {
    hostile_body:sub(1, 17), hostile_body:sub(18, 211), hostile_body:sub(212),
})
expect_records(hostile_records, {
    { full_path = "/prefix/team/Books/A", name = "A", is_folder = true },
    { full_path = "/prefix/team/Books/A/1.jpg", name = "1.jpg", is_file = true, size = 12 },
}, "status, server-prefix, and collection-boundary filtering")

local missing_parser = WebDavXml.new_stream{
    request_path = "/Books/A", decode_url = decode_url,
    html_decode = html_decode, on_response = function() return true end,
}
expect(missing_parser:push("<d:multistatus xmlns:d=\"DAV:\"></d:multistatus>"),
    "an empty multistatus chunk is syntactically streamable")
local missing_ok, missing_err = missing_parser:finish()
expect(missing_ok == nil and missing_err.code == "decode",
    "a stream with no response elements must fail closed")

local malformed_parser = WebDavXml.new_stream{
    request_path = "/Books/A", decode_url = decode_url,
    html_decode = html_decode, on_response = function() return true end,
}
local malformed_ok, malformed_err = malformed_parser:push(
    "<d:multistatus xmlns:d=\"DAV:\">"
    .. "<d:response><d:href>/Books/A/1.jpg</d:href></d:responze>")
if malformed_ok then malformed_ok, malformed_err = malformed_parser:finish() end
expect(malformed_ok == nil and malformed_err.code == "decode",
    "a malformed response close tag must fail closed")

local mismatched_parser = WebDavXml.new_stream{
    request_path = "/Books/A", decode_url = decode_url,
    html_decode = html_decode, on_response = function() return true end,
}
local mismatch_ok, mismatch_err = mismatched_parser:push(
    "<d:multistatus xmlns:d=\"DAV:\" xmlns:x=\"DAV:\">"
    .. "<d:response><d:href>/Books/A/1.jpg</d:href></x:response>")
expect(mismatch_ok == nil and mismatch_err.code == "decode",
    "a response close with a different qualified name must fail closed")

-- Many complete blocks exceed the single-block cap in aggregate. Success proves
-- emitted blocks are discarded rather than accumulated in the parser.
local emitted = 0
local bounded_parser = WebDavXml.new_stream{
    request_path = "/Books/A", decode_url = decode_url,
    html_decode = html_decode,
    on_response = function()
        emitted = emitted + 1
        return true
    end,
}
expect(bounded_parser:push("<d:multistatus xmlns:d=\"DAV:\">"),
    "the bounded stream should accept its DAV root")
for index = 1, 3500 do
    local chunk = ("<d:response><d:href>/Books/A/%d.jpg</d:href>"
        .. "<d:propstat><d:prop><d:resourcetype/></d:prop>"
        .. "<d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
        .. "</d:response>"):format(index)
    expect(bounded_parser:push(chunk), "complete response blocks should stream indefinitely")
end
expect(bounded_parser:push("</d:multistatus>"),
    "the bounded stream should close its DAV root")
expect(bounded_parser:finish() and emitted == 3500,
    "the parser should emit and discard every complete response block")

local oversized_parser = WebDavXml.new_stream{
    request_path = "/Books/A", decode_url = decode_url,
    html_decode = html_decode, on_response = function() return true end,
}
expect(oversized_parser:push("<d:multistatus xmlns:d=\"DAV:\">"),
    "the oversized stream should accept its DAV root")
local oversized_ok, oversized_err = oversized_parser:push(
    "<d:response>" .. string.rep("x", 256 * 1024 + 1))
expect(oversized_ok == nil and oversized_err.code == "decode",
    "an unterminated response larger than 256 KiB must fail before finish")

local function stream_outcome(body, observer)
    local parser = WebDavXml.new_stream{
        request_path = "/Books/A", decode_url = decode_url,
        html_decode = html_decode, on_response = observer or function() return true end,
    }
    local chunks = type(body) == "table" and body or { body }
    for _, chunk in ipairs(chunks) do
        local pushed, push_error = parser:push(chunk)
        if not pushed then return nil, push_error end
    end
    return parser:finish()
end

local function expect_stream_decode(body, label)
    local ok, err = stream_outcome(body)
    expect(ok == nil and err and err.code == "decode", label)
end

local valid_response_prefix = [[<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/>]]
local valid_response_suffix = [[</d:prop><d:status>HTTP/1.1 200 OK</d:status>
</d:propstat></d:response></d:multistatus>]]

local xml_description_retained_peak = 0
do
local grammar_root_open = [[<d:multistatus xmlns:d="DAV:"><d:response>]]
local grammar_root_close = [[</d:response></d:multistatus>]]
local grammar_href = [[<d:href>/Books/A/grammar.jpg</d:href>]]
local grammar_status = [[<d:status>HTTP/1.1 200 OK</d:status>]]
local grammar_prop = [[<d:prop><d:resourcetype/><d:getcontentlength>17</d:getcontentlength></d:prop>]]
local grammar_propstat = [[<d:propstat>]] .. grammar_prop .. grammar_status
    .. [[</d:propstat>]]
local grammar_error = [[<d:error/>]]
local grammar_description =
    [[<d:responsedescription>grammar note</d:responsedescription>]]
local grammar_location =
    [[<d:location><d:href>/Books/B/moved.jpg</d:href></d:location>]]
local function grammar_response(children)
    return grammar_root_open .. children .. grammar_root_close
end

local direct_status_records = parse_chunks(grammar_response(
    grammar_href .. grammar_status .. grammar_error .. grammar_description),
    "/Books/A")
expect_records(direct_status_records, {
    { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
}, "ordered direct-status response grammar")
local located_status_records = parse_chunks(grammar_response(
    grammar_href .. grammar_status .. grammar_error .. grammar_description
        .. grammar_location), "/Books/A")
expect_records(located_status_records, {
    { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
}, "ordered response suffix through location")
local propstat_records = parse_chunks(grammar_response(
    grammar_href .. grammar_propstat .. grammar_error .. grammar_description),
    "/Books/A")
expect_records(propstat_records, {
    {
        full_path = "/Books/A/grammar.jpg", name = "grammar.jpg",
        is_file = true, size = 17,
    },
}, "ordered propstat response grammar")

local rebound_location = [[<x:location xmlns:x="DAV:"><y:href xmlns:y="DAV:">]]
    .. [[/Books/B/rebound.jpg</y:href></x:location>]]
local rebound_location_body = grammar_response(
    grammar_href .. grammar_status .. grammar_description .. rebound_location)
local rebound_location_records = parse_chunks(rebound_location_body, "/Books/A")
expect_records(rebound_location_records, {
    { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
}, "a location with exactly one namespace-qualified DAV href")

local location_split_cuts = {}
for _, needle in ipairs({
    [[<x:location xmlns:x="DAV:">]],
    [[<y:href xmlns:y="DAV:">]],
    [[</y:href>]],
    [[</x:location>]],
}) do
    local first, last = assert(rebound_location_body:find(needle, 1, true))
    for cut = math.max(1, first - 1), math.min(#rebound_location_body - 1, last) do
        location_split_cuts[cut] = true
    end
end
for cut in pairs(location_split_cuts) do
    local records = parse_chunks(rebound_location_body, "/Books/A", {
        rebound_location_body:sub(1, cut),
        rebound_location_body:sub(cut + 1),
    })
    expect_records(records, {
        { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
    }, "chunk-split exact DAV location grammar at " .. cut)
end

local location_invalid_cases = {
    {
        "self-closing response location",
        grammar_href .. grammar_status .. [[<d:location/>]],
    },
    {
        "response location with zero href children",
        grammar_href .. grammar_status .. [[<d:location></d:location>]],
    },
    {
        "response location with a non-DAV href",
        grammar_href .. grammar_status
            .. [[<d:location><x:href xmlns:x="urn:not-dav">]]
            .. [[/Books/B/bad.jpg</x:href></d:location>]],
    },
    {
        "response location with two DAV href children",
        grammar_href .. grammar_status .. [[<d:location>]]
            .. [[<d:href>/Books/B/one.jpg</d:href>]]
            .. [[<d:href>/Books/B/two.jpg</d:href></d:location>]],
    },
    {
        "response location with leading character data",
        grammar_href .. grammar_status
            .. [[<d:location>move:<d:href>/Books/B/moved.jpg</d:href></d:location>]],
    },
    {
        "response location with trailing character data",
        grammar_href .. grammar_status
            .. [[<d:location><d:href>/Books/B/moved.jpg</d:href>tail</d:location>]],
    },
    {
        "response location with CDATA",
        grammar_href .. grammar_status
            .. "<d:location><![CDATA[move]]><d:href>"
            .. [[/Books/B/moved.jpg</d:href></d:location>]],
    },
    {
        "response location with another child",
        grammar_href .. grammar_status
            .. [[<d:location><d:error/></d:location>]],
    },
    {
        "response location before the required branch",
        grammar_href .. grammar_location .. grammar_status,
    },
    {
        "DAV href after the final response location",
        grammar_href .. grammar_status .. grammar_location
            .. [[<d:href>/Books/B/late.jpg</d:href>]],
    },
}
for _, case in ipairs(location_invalid_cases) do
    expect_stream_decode(grammar_response(case[2]),
        case[1] .. " must fail closed")
end

local root_level_location = [[<d:multistatus xmlns:d="DAV:"><d:response>]]
    .. grammar_href .. grammar_status .. [[</d:response>]]
    .. grammar_location .. [[</d:multistatus>]]
expect_stream_decode(root_level_location,
    "DAV location outside a response must fail closed")

for _, case in ipairs({
    {
        label = "chunk-split duplicate location href",
        body = grammar_response(grammar_href .. grammar_status
            .. [[<d:location><d:href>/Books/B/one.jpg</d:href>]]
            .. [[<d:href>/Books/B/two.jpg</d:href></d:location>]]),
        needle = [[</d:href><d:href>]],
    },
    {
        label = "chunk-split location character data",
        body = grammar_response(grammar_href .. grammar_status
            .. [[<d:location>move:<d:href>/Books/B/moved.jpg</d:href></d:location>]]),
        needle = [[move:<d:href>]],
    },
    {
        label = "chunk-split location CDATA",
        body = grammar_response(grammar_href .. grammar_status
            .. "<d:location><![CDATA[move]]><d:href>"
            .. [[/Books/B/moved.jpg</d:href></d:location>]]),
        needle = "<![CDATA[move]]>",
    },
}) do
    local first, last = assert(case.body:find(case.needle, 1, true))
    for cut = math.max(1, first - 1), math.min(#case.body - 1, last) do
        expect_stream_decode({
            case.body:sub(1, cut), case.body:sub(cut + 1),
        }, case.label .. " must fail closed at " .. cut)
    end
end

local direct_extra_href_one =
    [[<d:href>/alternate/grammar-one.jpg</d:href>]]
local direct_extra_href_two =
    [[<x:href xmlns:x="DAV:">/alternate/grammar-two.jpg</x:href>]]
local multi_href_direct_body = grammar_response(grammar_href
    .. direct_extra_href_one .. direct_extra_href_two .. grammar_status
    .. grammar_error .. grammar_description .. grammar_location)
local multi_href_direct_records = parse_chunks(multi_href_direct_body, "/Books/A")
expect_records(multi_href_direct_records, {
    { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
}, "direct status with zero-or-more extra DAV hrefs preserves the primary href")

local direct_href_split_cuts = {}
for _, needle in ipairs({
    direct_extra_href_one,
    direct_extra_href_two,
    direct_extra_href_two .. grammar_status,
}) do
    local first, last = assert(multi_href_direct_body:find(needle, 1, true))
    for cut = math.max(1, first - 1), math.min(#multi_href_direct_body - 1, last) do
        direct_href_split_cuts[cut] = true
    end
end
for cut in pairs(direct_href_split_cuts) do
    local records = parse_chunks(multi_href_direct_body, "/Books/A", {
        multi_href_direct_body:sub(1, cut),
        multi_href_direct_body:sub(cut + 1),
    })
    expect_records(records, {
        { full_path = "/Books/A/grammar.jpg", name = "grammar.jpg", is_file = true },
    }, "chunk-split direct extra href grammar at " .. cut)
end

for _, case in ipairs({
    {
        "response status before href",
        grammar_status .. grammar_href .. grammar_description,
    },
    {
        "propstat status before prop",
        grammar_href .. [[<d:propstat>]] .. grammar_status .. grammar_prop
            .. grammar_description .. [[</d:propstat>]],
    },
    {
        "response propstat mixed with direct status",
        grammar_href .. grammar_propstat .. grammar_status .. grammar_description,
    },
    { "response missing href", grammar_status },
    { "response missing status-or-propstat branch", grammar_href },
    {
        "propstat missing prop",
        grammar_href .. [[<d:propstat>]] .. grammar_status .. [[</d:propstat>]],
    },
    {
        "propstat missing status",
        grammar_href .. [[<d:propstat>]] .. grammar_prop .. [[</d:propstat>]],
    },
    {
        "response direct status mixed with propstat",
        grammar_href .. grammar_status .. grammar_propstat,
    },
    {
        "direct extra hrefs missing their required status",
        grammar_href .. direct_extra_href_one .. direct_extra_href_two,
    },
    {
        "direct extra href after status",
        grammar_href .. grammar_status .. direct_extra_href_one,
    },
    {
        "direct extra hrefs mixed into a propstat branch",
        grammar_href .. direct_extra_href_one .. grammar_propstat,
    },
    {
        "propstat branch followed by a direct extra href",
        grammar_href .. grammar_propstat .. direct_extra_href_one,
    },
    {
        "non-DAV direct extra href before status",
        grammar_href
            .. [[<x:href xmlns:x="urn:not-dav">/alternate/bad.jpg</x:href>]]
            .. grammar_status,
    },
    {
        "extra DAV href with the wrong parent before status",
        grammar_href .. [[<d:error><d:href>/alternate/bad.jpg</d:href></d:error>]]
            .. grammar_status,
    },
    {
        "response error before the selected branch",
        grammar_href .. grammar_error .. grammar_status,
    },
    {
        "response duplicate error",
        grammar_href .. grammar_status .. grammar_error .. grammar_error,
    },
    {
        "response element after location",
        grammar_href .. grammar_status .. grammar_location .. grammar_error,
    },
    {
        "response duplicate location",
        grammar_href .. grammar_status .. grammar_location .. grammar_location,
    },
    {
        "propstat error before status",
        grammar_href .. [[<d:propstat>]] .. grammar_prop .. grammar_error
            .. grammar_status .. [[</d:propstat>]],
    },
    {
        "propstat duplicate prop",
        grammar_href .. [[<d:propstat>]] .. grammar_prop .. grammar_prop
            .. grammar_status .. [[</d:propstat>]],
    },
    {
        "propstat duplicate error",
        grammar_href .. [[<d:propstat>]] .. grammar_prop .. grammar_status
            .. grammar_error .. grammar_error .. [[</d:propstat>]],
    },
}) do
    expect_stream_decode(grammar_response(case[2]),
        case[1] .. " must fail closed")
end

for _, case in ipairs({
    {
        label = "chunk-split direct href after status",
        body = grammar_response(
            grammar_href .. grammar_status .. direct_extra_href_one),
        needle = grammar_status .. direct_extra_href_one,
    },
    {
        label = "chunk-split direct hrefs without status",
        body = grammar_response(
            grammar_href .. direct_extra_href_one .. direct_extra_href_two),
        needle = direct_extra_href_one .. direct_extra_href_two,
    },
    {
        label = "chunk-split direct href mixed with propstat",
        body = grammar_response(
            grammar_href .. direct_extra_href_one .. grammar_propstat),
        needle = direct_extra_href_one .. [[<d:propstat>]],
    },
}) do
    local first, last = assert(case.body:find(case.needle, 1, true))
    for cut = math.max(1, first - 1), math.min(#case.body - 1, last) do
        expect_stream_decode({
            case.body:sub(1, cut), case.body:sub(cut + 1),
        }, case.label .. " must fail closed at " .. cut)
    end
end

local long_description_chunk = string.rep("n", 4096)
for _, case in ipairs({
    {
        label = "response",
        prefix = grammar_root_open .. grammar_href .. grammar_propstat
            .. [[<d:responsedescription>]],
        suffix = [[</d:responsedescription>]] .. grammar_root_close,
    },
    {
        label = "propstat",
        prefix = grammar_root_open .. grammar_href .. [[<d:propstat>]]
            .. grammar_prop .. grammar_status .. [[<d:responsedescription>]],
        suffix = [[</d:responsedescription></d:propstat>]] .. grammar_root_close,
    },
}) do
    local emitted = 0
    local parser = WebDavXml.new_stream{
        request_path = "/Books/A", decode_url = decode_url,
        html_decode = html_decode,
        on_response = function() emitted = emitted + 1 end,
    }
    expect(parser:push(case.prefix),
        "a long " .. case.label .. " description prefix should parse")
    local retained_baseline = #parser.tail
    local retained_peak = retained_baseline
    for _ = 1, 24 do
        expect(parser:push(long_description_chunk),
            "long description chunks below the response cap should parse")
        retained_peak = math.max(retained_peak, #parser.tail)
    end
    xml_description_retained_peak = math.max(
        xml_description_retained_peak, retained_peak)
    expect(retained_peak <= retained_baseline,
        "consumed " .. case.label
            .. " responsedescription PCDATA must not remain in the tail buffer")
    expect(parser:push(case.suffix) and parser:finish() and emitted == 1,
        "a bounded long " .. case.label .. " description should finish")
end

do
    local parser = WebDavXml.new_stream{
        request_path = "/Books/A", decode_url = decode_url,
        html_decode = html_decode, on_response = function() return true end,
    }
    expect(parser:push(grammar_root_open .. grammar_href .. grammar_propstat
        .. [[<d:responsedescription>]]),
        "the description-cap probe prefix should parse")
    local cap_ok, cap_error = true, nil
    for _ = 1, 70 do
        cap_ok, cap_error = parser:push(long_description_chunk)
        if not cap_ok then break end
    end
    expect(cap_ok == nil and cap_error and cap_error.code == "decode",
        "discarded description PCDATA must still count toward the 256 KiB response cap")
end
end

expect_stream_decode([[<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/>
</d:propstat></d:prop></d:response></d:multistatus>]],
    "cross-nested DAV elements must fail closed")
expect_stream_decode([[<x:multistatus xmlns:x="urn:not-dav"><x:response>
<x:href>/Books/A/1.jpg</x:href></x:response></x:multistatus>]],
    "a non-DAV multistatus root must fail closed")
expect_stream_decode([[<d:multistatus xmlns:d="DAV:" xmlns:x="urn:not-dav">
<x:response><d:href>/Books/A/1.jpg</d:href></x:response></d:multistatus>]],
    "a non-DAV response element must fail closed")
expect_stream_decode([[<d:multistatus xmlns:d="DAV:" xmlns:x="urn:not-dav">
<d:response><d:href>/Books/A/1.jpg</d:href><x:propstat><d:prop/>
</x:propstat></d:response></d:multistatus>]],
    "a non-DAV propstat element must fail closed")
expect_stream_decode([[<d:multistatus xmlns:d="DAV:" xmlns:x="urn:not-dav">
<d:response><d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop/>
<x:status>HTTP/1.1 200 OK</x:status></d:propstat></d:response></d:multistatus>]],
    "a non-DAV status element must fail closed")

local no_reason_seen = 0
local no_reason_ok, no_reason_err = stream_outcome([[
<d:multistatus xmlns:d="DAV:"><d:response><d:href>/Books/A/404.jpg</d:href>
<d:propstat><d:prop><d:resourcetype/></d:prop>
<d:status>HTTP/1.1 404</d:status></d:propstat></d:response></d:multistatus>]],
    function() no_reason_seen = no_reason_seen + 1 end)
expect(no_reason_ok == true and no_reason_err == nil and no_reason_seen == 0,
    "HTTP/1.1 404 without a reason phrase must be parsed and filtered")

for _, invalid_status in ipairs({
    "HTTP/1 200", "HTTP/1.1 20 OK", "HTTP/1.1 200OK", "garbage 200",
}) do
    expect_stream_decode(valid_response_prefix .. "</d:prop><d:status>"
        .. invalid_status .. "</d:status></d:propstat></d:response></d:multistatus>",
        "invalid DAV status must fail closed: " .. invalid_status)
end

local observed_without_return
local observer_ok, observer_err = stream_outcome(
    valid_response_prefix .. valid_response_suffix,
    function(record) observed_without_return = record end)
expect(observer_ok == true and observer_err == nil
    and observed_without_return.name == "1.jpg",
    "the brief observer callback with no return value must succeed")
local explicit_false_ok = stream_outcome(
    valid_response_prefix .. valid_response_suffix, function() return false end)
expect(explicit_false_ok == nil, "an explicit false observer result must stop parsing")
local callback_error_ok, callback_error = stream_outcome(
    valid_response_prefix .. valid_response_suffix,
    function() return nil, "observer storage failed" end)
expect(callback_error_ok == nil and callback_error.code == "decode",
    "nil plus an observer error must stop parsing")

local complete_oversized = "<d:multistatus xmlns:d=\"DAV:\"><d:response>"
    .. "<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:getetag>"
    .. string.rep("x", 256 * 1024)
    .. "</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status>"
    .. "</d:propstat></d:response></d:multistatus>"
expect_stream_decode(complete_oversized,
    "a complete response larger than 256 KiB must fail before emission")

local function content_length_body(value)
    return valid_response_prefix .. "<d:getcontentlength>" .. value
        .. "</d:getcontentlength>" .. valid_response_suffix
end
for _, invalid_length in ipairs({
    "", "12junk", "1e2", "-1", "+1", "9007199254740992", string.rep("9", 400),
}) do
    expect_stream_decode(content_length_body(invalid_length),
        "invalid getcontentlength must fail closed: " .. invalid_length:sub(1, 24))
end
local strict_lengths = {}
for _, valid_length in ipairs({ "0", "12", "9007199254740991" }) do
    local ok, err = stream_outcome(content_length_body(valid_length), function(record)
        strict_lengths[#strict_lengths + 1] = record.size
    end)
    expect(ok == true and err == nil,
        "a strict safe decimal getcontentlength should parse: " .. valid_length)
end
expect(strict_lengths[1] == 0 and strict_lengths[2] == 12
    and strict_lengths[3] == 9007199254740991,
    "strict getcontentlength values should remain exact")

local special_response = [[<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>]]
local special_valid = [[<?xml version="1.0" encoding="UTF-8"?>
<?probe streamed?><!---->]] .. special_response
local special_records = parse_chunks(special_valid, "/Books/A")
expect_records(special_records, {
    { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
}, "valid XML declaration, PI, and comment")
for _, marker in ipairs({
    "<?xml", "version", "?>", "<?probe", "streamed", "<!--", "-->",
}) do
    local first, last = assert(special_valid:find(marker, 1, true))
    for cut = first, last do
        local split_records = parse_chunks(special_valid, "/Books/A", {
            special_valid:sub(1, cut), special_valid:sub(cut + 1),
        })
        expect_records(split_records, {
            { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
        }, "chunk-split XML special syntax " .. marker .. " at " .. cut)
    end
end

for _, invalid_special in ipairs({
    "<?>\n", "<? ?>\n", "<?1bad value?>\n", "<?XML value?>\n",
    "<?probe/data?>\n",
    "<?probe\11data?>\n", "<!-- illegal \1 control -->\n",
    "<?xml?>\n", "<?xml version=\"2.0\"?>\n",
    "<?xml encoding=\"UTF-8\" version=\"1.0\"?>\n",
    "<?xml version=\"1.0\" extra=\"blocked\"?>\n",
    "<?xml version=\"1.0\" standalone=\"maybe\"?>\n",
    "<!-- illegal -- interior -->\n", "<!-- illegal --->\n",
    "<![CDATA[   ]]>\n",
    "<!DOCTYPE d:multistatus [<!ENTITY ext SYSTEM \"file:///blocked\">]>\n",
}) do
    expect_stream_decode(invalid_special .. special_response,
        "invalid XML special syntax must fail closed: "
            .. invalid_special:gsub("%s+", " "):sub(1, 48))
    for cut = 1, #invalid_special - 1 do
        expect_stream_decode({
            invalid_special:sub(1, cut),
            invalid_special:sub(cut + 1), special_response,
        }, "chunk-split invalid XML special syntax must fail closed at " .. cut)
    end
end
expect_stream_decode(special_response:gsub("</d:response>",
        "</d:response><![CDATA[ \n ]]>", 1),
    "whitespace-only CDATA outside a response must fail closed")

local response_description_body = [[<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:responsedescription>Partial results &amp; retry later</d:responsedescription>
</d:multistatus>]]
local description_records = parse_chunks(response_description_body, "/Books/A")
expect_records(description_records, {
    { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
}, "root DAV responsedescription")
local description_start = assert(response_description_body:find(
    "<d:responsedescription>", 1, true))
local description_end = assert(response_description_body:find(
    "</d:responsedescription>", 1, true)) + #"</d:responsedescription>" - 1
for cut = description_start, description_end do
    local split_records = parse_chunks(response_description_body, "/Books/A", {
        response_description_body:sub(1, cut),
        response_description_body:sub(cut + 1),
    })
    expect_records(split_records, {
        { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
    }, "chunk-split root responsedescription at " .. cut)
end

local description_element = [[<d:responsedescription>note</d:responsedescription>]]
local description_response = assert(response_description_body:match(
    "(<d:response>[%s%S]-</d:response>)"))
for _, invalid_description_body in ipairs({
    [[<d:multistatus xmlns:d="DAV:">]] .. description_element
        .. description_response .. [[</d:multistatus>]],
    response_description_body:gsub("</d:multistatus>",
        description_element .. "</d:multistatus>", 1),
    response_description_body:gsub("<d:responsedescription>",
        "<x:responsedescription xmlns:x=\"urn:not-dav\">", 1)
        :gsub("</d:responsedescription>", "</x:responsedescription>", 1),
    response_description_body:gsub("Partial results &amp; retry later",
        "<d:href>/Books/A/ignored</d:href>", 1),
    response_description_body:gsub("</d:responsedescription>",
        "</d:responsedescription><d:response><d:href>/Books/A/2.jpg</d:href>"
            .. "</d:response>", 1),
    response_description_body:gsub("Partial results &amp; retry later", "note", 1)
        :gsub("</d:multistatus>", "stray text</d:multistatus>", 1),
}) do
    expect_stream_decode(invalid_description_body,
        "invalid root responsedescription placement/content must fail closed")
end

do
local function response_with_text(element, value)
    return [[<d:multistatus xmlns:d="DAV:"><d:response><d:href>]]
        .. (element == "href" and value or "/Books/A/entity.jpg")
        .. [[</d:href><d:propstat><d:prop><d:resourcetype/>]]
        .. (element == "getetag" and "<d:getetag>" .. value .. "</d:getetag>" or "")
        .. (element == "ignored" and "<d:ignored>" .. value .. "</d:ignored>" or "")
        .. [[</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>]]
        .. [[</d:response></d:multistatus>]]
end

for _, body in ipairs({
    response_with_text("href", "/Books/A/bad]]>href.jpg"),
    response_with_text("getetag", "bad]]>etag"),
    response_with_text("ignored", "bad]]>discarded"),
    (response_description_body:gsub("Partial results &amp; retry later",
        "bad]]>root description", 1)),
}) do
    expect_stream_decode(body,
        "literal ]]> must be rejected in every ordinary CharData location")
    local first = assert(body:find("]]>", 1, true))
    for cut = first, first + 1 do
        expect_stream_decode({ body:sub(1, cut), body:sub(cut + 1) },
            "chunk-split literal ]]> must fail closed at " .. cut)
    end
end

local valid_entity_description = response_description_body:gsub(
    "Partial results &amp; retry later",
    "&lt;&gt;&apos;&quot;&amp;&#65;&#x41;&#9;&#x10FFFF;", 1)
local valid_entity_ok, valid_entity_error = stream_outcome(valid_entity_description)
expect(valid_entity_ok == true and valid_entity_error == nil,
    "predefined and legal numeric XML entities must be accepted")
local cdata_entity_body = response_with_text("href",
    "<![CDATA[/Books/A/A&B.jpg]]>")
local cdata_entity_ok, cdata_entity_error = stream_outcome(cdata_entity_body)
expect(cdata_entity_ok == true and cdata_entity_error == nil,
    "CDATA content must not treat a literal ampersand as an entity")

for _, invalid_entity in ipairs({
    "&", "&amp", "&unknown;", "&#;", "&#x;", "&#X41;",
    "&#0;", "&#xD800;", "&#xFFFE;", "&#x110000;",
    "&#999999999999999999999999;", "&amp nope;",
}) do
    local body = response_with_text("getetag", invalid_entity)
    expect_stream_decode(body,
        "invalid XML entity must fail closed: " .. invalid_entity)
    local start_at = assert(body:find(invalid_entity, 1, true))
    for cut = start_at, start_at + #invalid_entity - 1 do
        expect_stream_decode({ body:sub(1, cut), body:sub(cut + 1) },
            "chunk-split invalid XML entity must fail closed at " .. cut)
    end
end

for _, supported_encoding in ipairs({ "UTF-8", "utf-8", "Utf-8" }) do
    local body = ("<?xml version=\"1.0\" encoding=\"%s\"?>"):format(
        supported_encoding) .. special_response
    local ok, err = stream_outcome(body)
    expect(ok == true and err == nil,
        "the UTF-8 byte parser must accept case-insensitive UTF-8 declarations")
end
for _, unsupported_encoding in ipairs({
    "UTF-16", "UTF-16LE", "ISO-8859-1", "US-ASCII", "made-up-codec",
}) do
    local declaration = ("<?xml version=\"1.0\" encoding=\"%s\"?>"):format(
        unsupported_encoding)
    local body = declaration .. special_response
    expect_stream_decode(body,
        "a non-UTF-8 declaration must fail closed: " .. unsupported_encoding)
    for cut = 1, #declaration - 1 do
        expect_stream_decode({ body:sub(1, cut), body:sub(cut + 1) },
            "chunk-split incompatible encoding must fail closed at " .. cut)
    end
end

for _, invalid_utf8 in ipairs({
    string.char(0x80),
    string.char(0xc0, 0xaf),
    string.char(0xe0, 0x80, 0x80),
    string.char(0xed, 0xa0, 0x80),
    string.char(0xf4, 0x90, 0x80, 0x80),
    string.char(0xf5, 0x80, 0x80, 0x80),
}) do
    local body = response_with_text("href", "/Books/A/" .. invalid_utf8 .. ".jpg")
    expect_stream_decode(body, "invalid UTF-8 bytes must fail closed")
    local sequence_at = assert(body:find(invalid_utf8, 1, true))
    for cut = sequence_at, sequence_at + #invalid_utf8 - 1 do
        expect_stream_decode({ body:sub(1, cut), body:sub(cut + 1) },
            "chunk-split invalid UTF-8 must fail closed at " .. cut)
    end
end
end

do
local nested_descriptions = [[<d:multistatus xmlns:d="DAV:"><d:response>
<d:href>/Books/A/1.jpg</d:href><d:propstat><d:prop><d:resourcetype/>
</d:prop><d:status>HTTP/1.1 200 OK</d:status>
<d:responsedescription>propstat &amp; &#65;</d:responsedescription></d:propstat>
<d:responsedescription>response &lt; note</d:responsedescription></d:response>
<d:responsedescription>root &#x41;</d:responsedescription></d:multistatus>]]
local nested_records = parse_chunks(nested_descriptions, "/Books/A")
expect_records(nested_records, {
    { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
}, "root, response, and propstat DAV responsedescription")
local scan_from = 1
while true do
    local first = nested_descriptions:find("<d:responsedescription>", scan_from, true)
    if not first then break end
    local last = assert(nested_descriptions:find(
        "</d:responsedescription>", first, true)) + #"</d:responsedescription>" - 1
    for cut = first, last do
        local records = parse_chunks(nested_descriptions, "/Books/A", {
            nested_descriptions:sub(1, cut), nested_descriptions:sub(cut + 1),
        })
        expect_records(records, {
            { full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true },
        }, "chunk-split nested DAV responsedescription at " .. cut)
    end
    scan_from = last + 1
end

local response_description =
    "<d:responsedescription>response note</d:responsedescription>"
local propstat_description =
    "<d:responsedescription>propstat note</d:responsedescription>"
local response_open = [[<d:multistatus xmlns:d="DAV:"><d:response>]]
local response_close = [[</d:response></d:multistatus>]]
local href = [[<d:href>/Books/A/1.jpg</d:href>]]
local propstat = [[<d:propstat><d:prop><d:resourcetype/></d:prop>
<d:status>HTTP/1.1 200 OK</d:status></d:propstat>]]
for _, body in ipairs({
    response_open .. response_description .. href .. propstat .. response_close,
    response_open .. href .. [[<d:propstat>]] .. propstat_description
        .. [[<d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat>]]
        .. response_close,
    response_open .. href .. propstat .. response_description .. propstat
        .. response_close,
    response_open .. href .. [[<d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status>]]
        .. propstat_description .. [[<d:error/></d:propstat>]] .. response_close,
    response_open .. href .. propstat
        .. [[<x:responsedescription xmlns:x="urn:not-dav">bad</x:responsedescription>]]
        .. response_close,
    response_open .. href .. [[<d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status>
<x:responsedescription xmlns:x="urn:not-dav">bad</x:responsedescription></d:propstat>]]
        .. response_close,
    response_open .. href .. propstat
        .. [[<d:responsedescription><d:href>child</d:href></d:responsedescription>]]
        .. response_close,
    response_open .. href .. propstat
        .. "<d:responsedescription><![CDATA[child]]></d:responsedescription>"
        .. response_close,
    response_open .. href .. propstat
        .. [[<d:responsedescription>bare & text</d:responsedescription>]]
        .. response_close,
    response_open .. href .. [[<d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status>]]
        .. "<d:responsedescription>bad]]>text</d:responsedescription></d:propstat>"
        .. response_close,
}) do
    expect_stream_decode(body,
        "misplaced or malformed nested DAV responsedescription must fail closed")
end
end

local ManifestPosix = require("webdavmanga.manifest_posix")
local injected_posix_adapter
local Manifest = require("webdavmanga.manifest")
local ChapterIndex = require("webdavmanga.chapter_index")

do
local nodes = {}
local descriptors = {}
local next_descriptor = 40
local create_calls = {}
local write_descriptors = {}
local close_count = 0
local unlinked_while_open = false
local sync_count = 0
local sys = {
    O_RDONLY = 0, O_WRONLY = 1, O_RDWR = 2,
    O_CREAT = 64, O_EXCL = 128,
    OWNER_MODE = 384,
}
local function descriptor_node(descriptor)
    local opened = descriptors[descriptor]
    if not opened or opened.closed then return nil, "bad descriptor", "io" end
    return opened.node, opened
end
function sys.open_create(path, flags, mode)
    create_calls[#create_calls + 1] = { path = path, flags = flags, mode = mode }
    if nodes[path] then return nil, "already exists", "exists" end
    next_descriptor = next_descriptor + 1
    local node = { dev = 7, ino = next_descriptor, content = "" }
    nodes[path] = node
    descriptors[next_descriptor] = { node = node, position = 0, closed = false }
    return next_descriptor
end
function sys.open_read(path)
    local node = nodes[path]
    if not node then return nil, "not found", "not_found" end
    next_descriptor = next_descriptor + 1
    descriptors[next_descriptor] = { node = node, position = 0, closed = false }
    return next_descriptor
end
function sys.write(descriptor, value, offset, length)
    local node, opened = descriptor_node(descriptor)
    if not node then return nil, opened, "io" end
    write_descriptors[#write_descriptors + 1] = descriptor
    local amount = math.min(length, 2)
    local fragment = value:sub(offset + 1, offset + amount)
    node.content = node.content:sub(1, opened.position) .. fragment
        .. node.content:sub(opened.position + amount + 1)
    opened.position = opened.position + amount
    return amount
end
function sys.read(descriptor, count)
    local node, opened = descriptor_node(descriptor)
    if not node then return nil, opened, "io" end
    if opened.position >= #node.content then return nil end
    local value = node.content:sub(opened.position + 1, opened.position + count)
    opened.position = opened.position + #value
    return value
end
function sys.seek(descriptor, whence, offset)
    local node, opened = descriptor_node(descriptor)
    if not node then return nil, opened, "io" end
    local base = whence == "set" and 0
        or whence == "cur" and opened.position or #node.content
    opened.position = base + offset
    return opened.position
end
function sys.sync(descriptor)
    local node, err = descriptor_node(descriptor)
    if not node then return nil, err, "io" end
    sync_count = sync_count + 1
    return true
end
function sys.close(descriptor)
    local opened = descriptors[descriptor]
    if not opened or opened.closed then return nil, "bad descriptor", "io" end
    opened.closed = true
    close_count = close_count + 1
    return true
end
function sys.fstat(descriptor)
    local node, err = descriptor_node(descriptor)
    if not node then return nil, err, "io" end
    return node.dev, node.ino
end
function sys.lstat(path)
    local node = nodes[path]
    if not node then return nil, "not found", "not_found" end
    return node.dev, node.ino
end
function sys.unlink(path)
    if not nodes[path] then return nil, "not found", "not_found" end
    unlinked_while_open = close_count == 0
    nodes[path] = nil
    return true
end
function sys.atomic_replace(source, target)
    if not nodes[source] then return nil, "source missing", "not_found" end
    nodes[target] = nodes[source]
    nodes[source] = nil
    return true
end

local adapter = assert(ManifestPosix.from_syscalls(sys))
injected_posix_adapter = adapter
local lock_handle = assert(adapter.open_exclusive("lock", "wb+"))
expect(#create_calls == 1
    and create_calls[1].flags == 64 + 128 + 2
    and create_calls[1].mode == 384,
    "the POSIX adapter must pass typed O_CREAT|O_EXCL|O_RDWR and mode 0600")
assert(lock_handle:write("WDMLOCK1\towner\n"))
expect(nodes.lock.content == "WDMLOCK1\towner\n"
    and #write_descriptors > 1,
    "partial writes must complete on the descriptor returned by exclusive open")
for _, descriptor in ipairs(write_descriptors) do
    expect(descriptor == 41,
        "exclusive content must never be written through a reopened pathname")
end
assert(lock_handle:flush())
expect(sync_count == 1, "handle flush must call the reliable fsync primitive")

local owned_node = nodes.lock
nodes.lock = { dev = owned_node.dev, ino = owned_node.ino + 100, content = "new owner" }
local released, release_error = adapter.release_lock({
    path = "lock", handle = lock_handle, payload = "WDMLOCK1\towner\n",
})
expect(released == nil and release_error ~= nil and nodes.lock.content == "new owner"
    and close_count == 0,
    "an old descriptor must not unlink a pathname with a different inode")
nodes.lock = owned_node
assert(adapter.release_lock({
    path = "lock", handle = lock_handle, payload = "WDMLOCK1\towner\n",
}))
expect(nodes.lock == nil and unlinked_while_open and close_count == 0,
    "owner release must compare inode and unlink while the original fd remains open")
assert(lock_handle:close())
expect(close_count == 1, "the owner descriptor must close only after safe unlink")
end

local UINT32 = 4294967296
local function fake_md5(value)
    value = tostring(value or "")
    local a, b, c, d = 2166136261, 1315423911, 2654435761, 2246822519
    for index = 1, #value do
        local byte = value:byte(index)
        a = (a * 33 + byte + index) % UINT32
        b = (b * 37 + byte * 3 + index) % UINT32
        c = (c * 41 + byte * 5 + index) % UINT32
        d = (d * 43 + byte * 7 + index) % UINT32
    end
    return ("%08x%08x%08x%08x"):format(a, b, c, d)
end

local function file_size(path)
    local file = assert(io.open(path, "rb"))
    local size = assert(file:seek("end"))
    file:close()
    return size
end

local function path_exists(path)
    local handle = io.open(path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

local function strict_exclusive(path, mode)
    local exclusive_mode = mode == "wb+" and "wb+x" or "wbx"
    return io.open(path, exclusive_mode)
end

local function replace_for_windows_test(source, target)
    os.remove(target)
    return os.rename(source, target)
end

local temp_prefix = "spec/.tmp-task5-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000))

local function test_filesystem(overrides)
    overrides = overrides or {}
    local owned_locks = {}
    local fs = {}
    fs.open = overrides.open or io.open
    fs.remove = overrides.remove or os.remove
    fs.size = overrides.size or file_size
    fs.sync = overrides.sync or function(handle) return handle:flush() end
    fs.atomic_replace = overrides.atomic_replace or replace_for_windows_test
    fs.open_exclusive = function(path, mode)
        local opener = overrides.open_exclusive or strict_exclusive
        local handle, detail = opener(path, mode)
        if handle and path:sub(-9) == ".wdm-lock" then
            owned_locks[path] = handle
        end
        return handle, detail
    end
    fs.open_existing = overrides.open_existing or function(path)
        local handle, detail = fs.open(path, "rb")
        if handle then return handle end
        return nil, detail, true
    end
    fs.release_lock = overrides.release_lock or function(lock)
        if owned_locks[lock.path] ~= lock.handle then
            return nil, "injected lock identity mismatch"
        end
        local closed, close_detail = lock.handle:close()
        if not closed then return nil, close_detail end
        local removed, detail = fs.remove(lock.path)
        if not removed then return nil, detail, true end
        owned_locks[lock.path] = nil
        return true, nil, true
    end
    return fs
end

-- Lupa/Windows has no production-quality fsync + inode-safe release adapter.
-- The builder must fail before invoking the producer instead of falling back
-- to stdio.  The remaining disk-format tests inject the explicit host harness.
local raw_manifest_build = Manifest.build
local posix_descriptor = assert(raw_manifest_build({
    part_path = "virtual-posix.manifest", request_path = "/Books/A",
    md5 = fake_md5, fs = injected_posix_adapter,
}, function(emit)
    assert(emit({
        full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true,
    }))
    return true
end))
expect(posix_descriptor.count == 1 and posix_descriptor.images == 1,
    "the descriptor-backed KPW6 storage capability path must build end to end")
local posix_manifest = assert(Manifest.open("virtual-posix.manifest", {
    open = injected_posix_adapter.open,
    size = injected_posix_adapter.size,
    md5 = fake_md5,
}))
expect(posix_manifest:_record_at(1).name == "1.jpg",
    "the descriptor-backed adapter must publish a readable manifest")
assert(posix_manifest:close())
assert(injected_posix_adapter.remove("virtual-posix.manifest"))

if ManifestPosix.new() == nil then
    local no_platform_path = temp_prefix .. "-no-platform-default.manifest"
    local no_platform_producer_called = false
    local no_platform, no_platform_error = raw_manifest_build({
        part_path = no_platform_path, request_path = "/Books/A", md5 = fake_md5,
    }, function()
        no_platform_producer_called = true
        return true
    end)
    expect(no_platform == nil and no_platform_error.code == "storage"
        and not no_platform_producer_called and not path_exists(no_platform_path),
        "a platform without reliable POSIX capabilities must fail closed")
end

Manifest.build = function(options, producer)
    if options.fs == nil then
        local copied = {}
        for key, value in pairs(options) do copied[key] = value end
        copied.fs = test_filesystem()
        options = copied
    end
    return raw_manifest_build(options, producer)
end

local stress_path = temp_prefix .. ".manifest"
local started = os.clock()
local descriptor = assert(Manifest.build({
    part_path = stress_path,
    request_path = "/Books/A",
    md5 = fake_md5,
    run_size = 128,
}, function(emit)
    assert(emit({
        full_path = "/dav/Books/A", name = "A", is_folder = true,
    }))
    for index = 20000, 1, -1 do
        assert(emit({
            full_path = "/dav/Books/A/" .. index .. ".jpg",
            name = index .. ".jpg", is_file = true, size = index,
        }))
    end
    -- These records must not enter the direct-child image index.
    assert(emit({
        full_path = "/dav/Books/A/deep/inside.jpg",
        name = "inside.jpg", is_file = true,
    }))
    assert(emit({
        full_path = "/dav/Books/A/readme.txt",
        name = "readme.txt", is_file = true,
    }))
    assert(emit({
        full_path = "/dav/Books/private.jpg",
        name = "private.jpg", is_file = true,
    }))
    return true
end))
local build_seconds = os.clock() - started
expect(descriptor.count == 20001 and descriptor.images == 20000
    and descriptor.documents == 1 and descriptor.folders == 0 and descriptor.payload_bytes == nil,
    "the 20,000-entry descriptor must stay compact")
expect(descriptor.max_run_entries <= 128,
    "the builder must never sort more than run_size entries in memory")
expect(type(descriptor.max_active_runs) == "number"
    and descriptor.max_active_runs <= 16,
    "leveled merging must retain only logarithmically many active runs")
expect(type(descriptor.max_merge_sources) == "number"
    and descriptor.max_merge_sources <= 2,
    "each immediate merge must use a constant two-source fan-in")
expect(type(descriptor.max_owned_temps) == "number"
    and descriptor.max_owned_temps <= 24,
    "temporary-file ownership must discard retired paths instead of growing per run")
expect(type(descriptor.max_auxiliary_entries) == "number"
    and descriptor.max_auxiliary_entries <= 192,
    "all manifest auxiliary collections must stay bounded during the stress build")
expect(descriptor.size == file_size(stress_path) and #descriptor.digest == 32,
    "the descriptor should report the closed manifest size and digest")

local max_read = 0
local full_read_attempts = 0
local function instrumented_open(path, mode)
    local raw, err = io.open(path, mode)
    if not raw then return nil, err end
    if not tostring(mode):find("r", 1, true) then return raw end
    local wrapper = {}
    function wrapper:read(amount)
        if amount == "*a" or amount == "*all" then
            full_read_attempts = full_read_attempts + 1
            return nil, "full reads are forbidden"
        end
        if type(amount) == "number" and amount > max_read then max_read = amount end
        return raw:read(amount)
    end
    function wrapper:seek(...) return raw:seek(...) end
    function wrapper:close() return raw:close() end
    return wrapper
end
local read_fs = {
    open = instrumented_open,
    size = file_size,
    md5 = fake_md5,
}
local manifest = assert(Manifest.open(stress_path, read_fs))
local images = ChapterIndex:new{ manifest = manifest, kind = "image" }
expect(images:count() == 20000, "the disk-backed image index should expose all entries")
expect(images:get(2).name == "2.jpg" and images:get(10).name == "10.jpg",
    "manifest order must use natural sorting")
expect(images:get(20000).name == "20000.jpg",
    "random access should reach the final ordinal")
expect(images:find("/Books/A/19999.jpg") == 19999,
    "path lookup should return the natural-sort image ordinal")
expect(images:find("/Books/A/19999.jpg", 19999) == 19999,
    "a correct hint should preserve the path-verified result")
expect(#images:window(10000, 2) == 5
    and images:window(1, 2)[1].name == "1.jpg",
    "window should read only the bounded neighborhood and clamp at the start")
local iterated = {}
for item, index in images:iterator(19998, 3) do
    iterated[#iterated + 1] = index .. ":" .. item.name
end
expect(table.concat(iterated, ",")
        == "19998:19998.jpg,19999:19999.jpg,20000:20000.jpg",
    "iterator should read the requested bounded page")
expect(full_read_attempts == 0 and max_read <= 4096,
    "open and random access must use bounded reads, never load the manifest")
manifest:close()

local mixed_path = temp_prefix .. "-mixed.manifest"
local function colliding_md5(value)
    if value == "/Books/A/collision-a.jpg"
        or value == "/Books/A/collision-b.jpg" then
        return "0123456789abcdef0123456789abcdef"
    end
    return fake_md5(value)
end
local mixed_descriptor = assert(Manifest.build({
    part_path = mixed_path, request_path = "/Books/A",
    md5 = colliding_md5, run_size = 2,
}, function(emit)
    assert(emit({ full_path = "/srv/Books/A", name = "A", is_folder = true }))
    assert(emit({ full_path = "/srv/Books/A/Chapter 10", name = "Chapter 10", is_folder = true }))
    assert(emit({ full_path = "/srv/Books/A/Chapter 2", name = "Chapter 2", is_folder = true }))
    assert(emit({ full_path = "/srv/Books/A/collision-b.jpg", name = "collision-b.jpg", is_file = true }))
    assert(emit({ full_path = "/srv/Books/A/collision-a.jpg", name = "collision-a.jpg", is_file = true }))
    return true
end))
expect(mixed_descriptor.count == 4 and mixed_descriptor.folders == 2
    and mixed_descriptor.images == 2,
    "manifest counts should distinguish folder and image ordinals")
local mixed = assert(Manifest.open(mixed_path, { md5 = colliding_md5 }))
local folders = ChapterIndex:new{ manifest = mixed, kind = "folder" }
local collision_images = ChapterIndex:new{ manifest = mixed, kind = "image" }
expect(folders:get(1).name == "Chapter 2" and folders:get(2).name == "Chapter 10",
    "folder ordinals should be naturally sorted independently")
expect(collision_images:find("/Books/A/collision-a.jpg") == 1
    and collision_images:find("/Books/A/collision-b.jpg") == 2,
    "hash collisions must compare candidate record paths")
expect(collision_images:find("/Books/A/../private.jpg") == nil,
    "find must reject normalized paths that escape the collection")
mixed:close()

local repeated_anchor_path = temp_prefix .. "-repeated-anchor.manifest"
local repeated_anchor = assert(Manifest.build({
    part_path = repeated_anchor_path, request_path = "/Books/A",
    md5 = fake_md5, run_size = 2,
}, function(emit)
    assert(emit({
        full_path = "/short/Books/A/cache/Books/A/not-a-child.jpg",
        name = "not-a-child.jpg", is_file = true,
    }))
    assert(emit({
        full_path = "/long/server/Books/A/cache/Books/A",
        name = "A", is_folder = true,
    }))
    assert(emit({
        full_path = "/long/server/Books/A/cache/Books/A/1.jpg",
        name = "1.jpg", is_file = true,
    }))
    return true
end))
expect(repeated_anchor.count == 1 and repeated_anchor.images == 1,
    "an exact self response must override an earlier substring anchor")
local repeated_manifest = assert(Manifest.open(repeated_anchor_path, { md5 = fake_md5 }))
local repeated_images = ChapterIndex:new{ manifest = repeated_manifest, kind = "image" }
expect(repeated_images:get(1).path == "/Books/A/1.jpg",
    "a repeated requested suffix in the server prefix must keep the exact self child")
repeated_manifest:close()

local duplicate_path = temp_prefix .. "-duplicate.manifest"
local duplicate_manifest, duplicate_error = Manifest.build({
    part_path = duplicate_path, request_path = "/Books/A",
    md5 = fake_md5, run_size = 1,
}, function(emit)
    assert(emit({
        full_path = "/srv/Books/A/same.jpg", name = "same.jpg", is_file = true,
    }))
    assert(emit({
        full_path = "/srv//Books/A/same.jpg", name = "same.jpg", is_file = true,
    }))
    return true
end)
expect(duplicate_manifest == nil and duplicate_error.code == "decode",
    "duplicate normalized child paths must be rejected deterministically")

local kind_conflict_path = temp_prefix .. "-kind-conflict.manifest"
local conflict_manifest, conflict_error = Manifest.build({
    part_path = kind_conflict_path, request_path = "/Books/A",
    md5 = fake_md5, run_size = 1,
}, function(emit)
    assert(emit({
        full_path = "/srv/Books/A/conflict.jpg", name = "conflict.jpg", is_folder = true,
    }))
    assert(emit({
        full_path = "/srv/Books/A/conflict.jpg", name = "conflict.jpg", is_file = true,
    }))
    return true
end)
expect(conflict_manifest == nil and conflict_error.code == "decode",
    "a folder/image collision at one normalized path must be rejected")

local ZERO_MD5 = string.rep("0", 32)
local function semantic_md5(value)
    if tostring(value):sub(1, 1) == "/" then return fake_md5(value) end
    return ZERO_MD5
end
local semantic_path = temp_prefix .. "-semantic.manifest"
assert(Manifest.build({
    part_path = semantic_path, request_path = "/Books/A",
    md5 = semantic_md5, run_size = 1,
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    assert(emit({ full_path = "/Books/A/b.jpg", name = "b.jpg", is_file = true }))
    return true
end))
local semantic_content = read_file(semantic_path)
local semantic_paths_hex = assert(semantic_content:match("\npaths=([0-9a-f]+)\n"))
local semantic_paths_offset = assert(tonumber(semantic_paths_hex, 16))
local first_hash_start = semantic_paths_offset + 1
local corrupted_hash_content = semantic_content:sub(1, first_hash_start - 1)
    .. ZERO_MD5 .. semantic_content:sub(first_hash_start + 32)
local bad_path_hash = temp_prefix .. "-semantic-hash.manifest"
write_file(bad_path_hash, corrupted_hash_content)
local hash_manifest, hash_error = Manifest.open(bad_path_hash, { md5 = semantic_md5 })
expect(hash_manifest == nil and hash_error.code == "decode",
    "a digest-valid path row whose hash does not match record.path must fail closed")

local function constant_md5() return ZERO_MD5 end
local permutation_path = temp_prefix .. "-semantic-permutation.manifest"
assert(Manifest.build({
    part_path = permutation_path, request_path = "/Books/A",
    md5 = constant_md5, run_size = 1,
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    assert(emit({ full_path = "/Books/A/b.jpg", name = "b.jpg", is_file = true }))
    return true
end))
local permutation_content = read_file(permutation_path)
local permutation_offset = assert(tonumber(
    assert(permutation_content:match("\npaths=([0-9a-f]+)\n")), 16))
local second_ordinal_start = permutation_offset + 42 + 34
local duplicate_ordinal_content = permutation_content:sub(1, second_ordinal_start - 1)
    .. "00000001" .. permutation_content:sub(second_ordinal_start + 8)
local duplicate_ordinal_path = temp_prefix .. "-semantic-ordinal.manifest"
write_file(duplicate_ordinal_path, duplicate_ordinal_content)
local ordinal_manifest, ordinal_error = Manifest.open(
    duplicate_ordinal_path, { md5 = constant_md5 })
expect(ordinal_manifest == nil and ordinal_error.code == "decode",
    "path ordinals must form a complete unique permutation")

local duplicate_record_content, duplicate_replacements = permutation_content:gsub(
    "/Books/A/b%.jpg", "/Books/A/a.jpg", 1)
expect(duplicate_replacements == 1,
    "the semantic fixture must contain the second record path exactly once")
local duplicate_record_path = temp_prefix .. "-semantic-record.manifest"
write_file(duplicate_record_path, duplicate_record_content)
local duplicate_record_manifest, duplicate_record_error = Manifest.open(
    duplicate_record_path, { md5 = constant_md5 })
expect(duplicate_record_manifest == nil and duplicate_record_error.code == "decode",
    "digest-valid duplicate record paths must fail closed")

local strict_size_path = temp_prefix .. "-strict-size.manifest"
assert(Manifest.build({
    part_path = strict_size_path, request_path = "/Books/A", md5 = fake_md5,
}, function(emit)
    assert(emit({
        full_path = "/Books/A/max.jpg", name = "max.jpg", is_file = true,
        size = 9007199254740991,
    }))
    return true
end))
local strict_size_manifest = assert(Manifest.open(strict_size_path, { md5 = fake_md5 }))
expect(strict_size_manifest:_record_at(1).size == 9007199254740991,
    "the maximum safe manifest size integer must round-trip exactly")
strict_size_manifest:close()

local invalid_sizes = {
    -1, 1.5, math.huge, 0 / 0, "", "12junk", "1e2", "+1",
    "9007199254740992", string.rep("9", 400),
}
local invalid_size_paths = {}
for index, invalid_size in ipairs(invalid_sizes) do
    local invalid_size_path = temp_prefix .. "-invalid-size-" .. index .. ".manifest"
    invalid_size_paths[#invalid_size_paths + 1] = invalid_size_path
    local invalid_manifest, invalid_error = Manifest.build({
        part_path = invalid_size_path, request_path = "/Books/A", md5 = fake_md5,
    }, function(emit)
        local ok, err = emit({
            full_path = "/Books/A/bad.jpg", name = "bad.jpg", is_file = true,
            size = invalid_size,
        })
        if not ok then return nil, err end
        return true
    end)
    expect(invalid_manifest == nil and invalid_error.code == "decode",
        "manifest sizes must be strict finite safe non-negative integers: "
            .. tostring(invalid_size):sub(1, 24))
end

local overflow_offset_path = temp_prefix .. "-overflow-offset.manifest"
local overflow_offset_content, overflow_replacements = permutation_content:gsub(
    "\npaths=[0-9a-f]+\n", "\npaths=ffffffffffffffff\n", 1)
expect(overflow_replacements == 1,
    "the offset fixture must contain one fixed-width paths field")
write_file(overflow_offset_path, overflow_offset_content)
local overflow_manifest, overflow_error = Manifest.open(
    overflow_offset_path, { md5 = constant_md5 })
expect(overflow_manifest == nil and overflow_error.code == "decode",
    "manifest offsets beyond the safe integer range must fail closed")

local io_fault_paths = {}
local function exercise_read_fault(label, path_fragment, run_size)
    local target = temp_prefix .. "-io-" .. label .. ".manifest"
    io_fault_paths[#io_fault_paths + 1] = target
    local matching_reads = 0
    local injected = false
    local function fault_open(path, mode)
        local raw, err = io.open(path, mode)
        if not raw then return nil, err end
        if mode ~= "rb" or not path:find(path_fragment, 1, true) then return raw end
        local wrapper = {}
        function wrapper:read(amount)
            matching_reads = matching_reads + 1
            if matching_reads == 2 then
                injected = true
                return nil, "injected mid-stream read failure"
            end
            return raw:read(amount)
        end
        function wrapper:seek(...) return raw:seek(...) end
        function wrapper:close() return raw:close() end
        return wrapper
    end
    local failed, failure = Manifest.build({
        part_path = target, request_path = "/Books/A", md5 = fake_md5,
        run_size = run_size or 1,
        fs = test_filesystem({
            open = fault_open,
            open_exclusive = strict_exclusive,
            remove = os.remove,
            size = file_size,
            sync = function(handle) return handle:flush() end,
        }),
    }, function(emit)
        assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
        assert(emit({ full_path = "/Books/A/b.jpg", name = "b.jpg", is_file = true }))
        return true
    end)
    expect(injected, label .. " must reach the injected mid-stream read failure")
    expect(failed == nil and failure.code == "storage",
        label .. " I/O failure must not be treated as EOF or decode corruption")
    expect(io.open(target, "rb") == nil,
        label .. " I/O failure must not publish a self-consistent truncation")
end

exercise_read_fault("record", "spool", 1)
exercise_read_fault("path-row", "paths-run", 1)
exercise_read_fault("copy", "ordinals", 1)

local early_spool_path = temp_prefix .. "-early-spool.manifest"
io_fault_paths[#io_fault_paths + 1] = early_spool_path
local spool_reads = 0
local function early_spool_open(path, mode)
    local raw, err = io.open(path, mode)
    if not raw then return nil, err end
    if mode ~= "rb" or not path:find("spool", 1, true) then return raw end
    local wrapper = {}
    function wrapper:read(amount)
        spool_reads = spool_reads + 1
        if spool_reads == 3 then return nil end
        return raw:read(amount)
    end
    function wrapper:seek(...) return raw:seek(...) end
    function wrapper:close() return raw:close() end
    return wrapper
end
local early_spool, early_spool_error = Manifest.build({
    part_path = early_spool_path, request_path = "/Books/A", md5 = fake_md5,
    fs = test_filesystem({
        open = early_spool_open, open_exclusive = strict_exclusive,
        remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
    }),
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    assert(emit({ full_path = "/Books/A/b.jpg", name = "b.jpg", is_file = true }))
    return true
end)
expect(early_spool == nil and early_spool_error.code == "decode",
    "a clean early EOF at a record boundary must fail the exact spool count")

local short_copy_path = temp_prefix .. "-short-copy.manifest"
io_fault_paths[#io_fault_paths + 1] = short_copy_path
local short_copy_reads = 0
local function short_copy_open(path, mode)
    local raw, err = io.open(path, mode)
    if not raw then return nil, err end
    if mode ~= "rb" or not path:find("ordinals", 1, true) then return raw end
    local wrapper = {}
    function wrapper:read(amount)
        short_copy_reads = short_copy_reads + 1
        if short_copy_reads == 1 then return raw:read(17) end
        return nil
    end
    function wrapper:seek(...) return raw:seek(...) end
    function wrapper:close() return raw:close() end
    return wrapper
end
local short_copy, short_copy_error = Manifest.build({
    part_path = short_copy_path, request_path = "/Books/A", md5 = fake_md5,
    fs = test_filesystem({
        open = short_copy_open, open_exclusive = strict_exclusive,
        remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
    }),
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    assert(emit({ full_path = "/Books/A/b.jpg", name = "b.jpg", is_file = true }))
    return true
end)
expect(short_copy == nil and short_copy_error.code == "decode",
    "copy_file must verify the exact ordinal section size before publication")

local semantic_write_path = temp_prefix .. "-semantic-write.manifest"
io_fault_paths[#io_fault_paths + 1] = semantic_write_path
local semantic_write_changed = false
local function semantic_write_open(path, mode)
    local raw, err = io.open(path, mode)
    if not raw then return nil, err end
    if mode:sub(1, 3) ~= "wb+" then return raw end
    local wrapper = {}
    function wrapper:write(value)
        if not semantic_write_changed and #value == 42
            and value:sub(33, 33) == "\t" then
            semantic_write_changed = true
            value = (value:sub(1, 1) == "0" and "1" or "0") .. value:sub(2)
        end
        return raw:write(value)
    end
    function wrapper:read(...) return raw:read(...) end
    function wrapper:seek(...) return raw:seek(...) end
    function wrapper:flush(...) return raw:flush(...) end
    function wrapper:close(...) return raw:close(...) end
    return wrapper
end
local function semantic_write_exclusive(path, mode)
    return semantic_write_open(path, mode == "wb+" and "wb+x" or "wbx")
end
local semantic_write, semantic_write_error = Manifest.build({
    part_path = semantic_write_path, request_path = "/Books/A", md5 = fake_md5,
    fs = test_filesystem({
        open = semantic_write_open, open_exclusive = semantic_write_exclusive,
        remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
    }),
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    return true
end)
expect(semantic_write_changed and semantic_write == nil
    and semantic_write_error.code == "decode",
    "the closed build must pass semantic Manifest.open validation before rename")

local small_content = read_file(mixed_path)
local bad_magic_path = temp_prefix .. "-bad-magic.manifest"
write_file(bad_magic_path, "X" .. small_content:sub(2))
local bad_magic, bad_magic_err = Manifest.open(bad_magic_path, { md5 = colliding_md5 })
expect(bad_magic == nil and bad_magic_err.code == "decode",
    "a wrong manifest version/magic must fail closed")

local truncated_path = temp_prefix .. "-truncated.manifest"
write_file(truncated_path, small_content:sub(1, #small_content - 1))
local truncated, truncated_err = Manifest.open(truncated_path, { md5 = colliding_md5 })
expect(truncated == nil and truncated_err.code == "decode",
    "a truncated data/index section must fail closed")

local bad_digest_path = temp_prefix .. "-bad-digest.manifest"
local original_digest_lead = assert(small_content:match("digest=(.)"))
local corrupt_digest_lead = original_digest_lead == "f" and "e" or "f"
local changed_digest, replacements_count = small_content:gsub(
    "digest=.", "digest=" .. corrupt_digest_lead, 1)
expect(replacements_count == 1, "the small fixture should contain one digest field")
write_file(bad_digest_path, changed_digest)
local bad_digest, bad_digest_err = Manifest.open(bad_digest_path, { md5 = colliding_md5 })
expect(bad_digest == nil and bad_digest_err.code == "decode",
    "an altered integrity digest must fail closed")

do
local no_exclusive_path = temp_prefix .. "-no-exclusive.manifest"
local no_exclusive_producer_called = false
local no_exclusive, no_exclusive_error = Manifest.build({
    part_path = no_exclusive_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "no-exclusive",
    fs = {
        open = function(path, mode) return io.open(path, mode) end,
        remove = os.remove, size = file_size,
        sync = function(handle) return handle:flush() end,
        atomic_replace = replace_for_windows_test,
    },
}, function(emit)
    no_exclusive_producer_called = true
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    return true
end)
expect(no_exclusive == nil and no_exclusive_error.code == "storage"
    and not no_exclusive_producer_called and not path_exists(no_exclusive_path),
    "a custom filesystem without an atomic exclusive primitive must fail closed")

local invisible_target_path = temp_prefix .. "-invisible-target.manifest"
local target_absent_at_publish = false
local invisible_descriptor = assert(Manifest.build({
    part_path = invisible_target_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "invisible-target",
    fs = test_filesystem({
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
        atomic_replace = function(source, target)
            target_absent_at_publish = not path_exists(target)
            return os.rename(source, target)
        end,
    }),
}, function(emit)
    expect(not path_exists(invisible_target_path),
        "part_path must stay absent while the manifest is being built")
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    return true
end))
expect(target_absent_at_publish and invisible_descriptor.count == 1,
    "atomic publication must not expose a zero-byte target reservation")

local old_target_path = temp_prefix .. "-old-target.manifest"
assert(Manifest.build({
    part_path = old_target_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "old-target-seed",
}, function(emit)
    assert(emit({ full_path = "/Books/A/old.jpg", name = "old.jpg", is_file = true }))
    return true
end))
local old_target_content = read_file(old_target_path)
local old_visible_during_build = false
local old_visible_at_publish = false
local replaced_old = assert(Manifest.build({
    part_path = old_target_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "old-target-replacement",
    fs = test_filesystem({
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
        atomic_replace = function(source, target)
            old_visible_at_publish = read_file(target) == old_target_content
            return replace_for_windows_test(source, target)
        end,
    }),
}, function(emit)
    old_visible_during_build = read_file(old_target_path) == old_target_content
    assert(emit({ full_path = "/Books/A/new.jpg", name = "new.jpg", is_file = true }))
    return true
end))
expect(old_visible_during_build and old_visible_at_publish and replaced_old.count == 1,
    "a valid old target must remain unchanged until atomic replacement")
local replaced_old_manifest = assert(Manifest.open(old_target_path, { md5 = fake_md5 }))
expect(replaced_old_manifest:_record_at(1).name == "new.jpg",
    "atomic replacement must publish the new valid manifest")
replaced_old_manifest:close()
os.remove(no_exclusive_path)
os.remove(invisible_target_path)
os.remove(old_target_path)
end

do
local no_atomic_path = temp_prefix .. "-no-atomic.manifest"
local no_atomic_producer_called = false
local no_atomic, no_atomic_error = Manifest.build({
    part_path = no_atomic_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "no-atomic",
    fs = {
        open = function(path, mode) return io.open(path, mode) end,
        open_exclusive = strict_exclusive, remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
    },
}, function()
    no_atomic_producer_called = true
    return true
end)
expect(no_atomic == nil and no_atomic_error.code == "storage"
    and not no_atomic_producer_called and not path_exists(no_atomic_path)
    and not path_exists(no_atomic_path .. ".wdm-lock"),
    "a custom filesystem without atomic replacement must fail before locking")
end

do
local rename_only_path = temp_prefix .. "-rename-only.manifest"
local rename_only_producer_called = false
local rename_only, rename_only_error = Manifest.build({
    part_path = rename_only_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "rename-only",
    fs = {
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        rename = os.rename, size = file_size,
        sync = function(handle) return handle:flush() end,
        release_lock = function() return true end,
        open_existing = function(path)
            local handle, err = io.open(path, "rb")
            if handle then return handle end
            return nil, err, true
        end,
    },
}, function()
    rename_only_producer_called = true
    return true
end)
expect(rename_only == nil and rename_only_error.code == "storage"
    and not rename_only_producer_called and not path_exists(rename_only_path),
    "an arbitrary rename dependency must not be promoted to atomic_replace")
os.remove(rename_only_path)
os.remove(rename_only_path .. ".wdm-lock")
end

do
local no_sync_path = temp_prefix .. "-no-sync.manifest"
local no_sync_producer_called = false
local no_sync, no_sync_error = Manifest.build({
    part_path = no_sync_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "no-sync",
    fs = {
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        atomic_replace = replace_for_windows_test, size = file_size,
        release_lock = function() return true end,
        open_existing = function(path)
            local handle, err = io.open(path, "rb")
            if handle then return handle end
            return nil, err, true
        end,
    },
}, function()
    no_sync_producer_called = true
    return true
end)
expect(no_sync == nil and no_sync_error.code == "storage"
    and not no_sync_producer_called and not path_exists(no_sync_path),
    "a custom filesystem without reliable fsync must fail before locking")
os.remove(no_sync_path)
os.remove(no_sync_path .. ".wdm-lock")
end

do
local no_release_path = temp_prefix .. "-no-owner-release.manifest"
local no_release_producer_called = false
local no_release, no_release_error = Manifest.build({
    part_path = no_release_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "no-owner-release",
    fs = {
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        atomic_replace = replace_for_windows_test, size = file_size,
        sync = function(handle) return handle:flush() end,
        open_existing = function(path)
            local handle, err = io.open(path, "rb")
            if handle then return handle end
            return nil, err, true
        end,
    },
}, function()
    no_release_producer_called = true
    return true
end)
expect(no_release == nil and no_release_error.code == "storage"
    and not no_release_producer_called and not path_exists(no_release_path),
    "a custom filesystem without owner-safe lock release must fail before locking")
os.remove(no_release_path)
os.remove(no_release_path .. ".wdm-lock")
end

do
local permission_path = temp_prefix .. "-permission-existing.manifest"
local permission_producer_called = false
local function permission_open(path, mode)
    if path == permission_path and mode == "rb" then
        return nil, "injected permission denied"
    end
    return io.open(path, mode)
end
local permission_build, permission_error = Manifest.build({
    part_path = permission_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "permission-existing",
    fs = {
        open = permission_open, open_exclusive = strict_exclusive,
        remove = os.remove, atomic_replace = replace_for_windows_test,
        size = file_size, sync = function(handle) return handle:flush() end,
        release_lock = function() return true end,
        open_existing = function()
            return nil, "injected permission denied", false
        end,
    },
}, function()
    permission_producer_called = true
    return true
end)
expect(permission_build == nil and permission_error.code == "storage"
    and not permission_producer_called and not path_exists(permission_path),
    "an existing-target permission error must not be treated as not-found")
os.remove(permission_path)
os.remove(permission_path .. ".wdm-lock")
end

do
local replaced_lock_path = temp_prefix .. "-replaced-lock.manifest"
local replaced_lock_sidecar = replaced_lock_path .. ".wdm-lock"
local release_called = false
local unsafe_remove_attempts = 0
local published = false
local replaced_lock_build, replaced_lock_error = Manifest.build({
    part_path = replaced_lock_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "old-lock-owner",
    fs = {
        open = io.open, open_exclusive = strict_exclusive,
        remove = function(path)
            if path == replaced_lock_sidecar and published then
                unsafe_remove_attempts = unsafe_remove_attempts + 1
                return nil, "pathname now belongs to a new lock owner"
            end
            return os.remove(path)
        end,
        atomic_replace = function(source, target)
            local moved, move_error = replace_for_windows_test(source, target)
            if moved then published = true end
            return moved, move_error
        end,
        size = file_size, sync = function(handle) return handle:flush() end,
        open_existing = function(path)
            local handle, err = io.open(path, "rb")
            if handle then return handle end
            return nil, err, true
        end,
        release_lock = function()
            release_called = true
            return nil, "lock pathname identity no longer matches owner fd"
        end,
    },
}, function(emit)
    assert(emit({ full_path = "/Books/A/winner.jpg", name = "winner.jpg", is_file = true }))
    return true
end)
expect(published and release_called and unsafe_remove_attempts == 0
    and replaced_lock_build == nil and replaced_lock_error.code == "storage"
    and path_exists(replaced_lock_path) and path_exists(replaced_lock_sidecar),
    "an old lock owner must not unlink a pathname replaced by a new owner")
local replaced_lock_manifest = assert(Manifest.open(replaced_lock_path, { md5 = fake_md5 }))
expect(replaced_lock_manifest:_record_at(1).name == "winner.jpg",
    "lock identity failure after publication must preserve the winner")
replaced_lock_manifest:close()
os.remove(replaced_lock_sidecar)
os.remove(replaced_lock_path)
end

local external_target_path = temp_prefix .. "-external-target.manifest"
write_file(external_target_path, "external sentinel")
local external_build, external_build_error = Manifest.build({
    part_path = external_target_path, request_path = "/Books/A", md5 = fake_md5,
}, function(emit)
    assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
    return true
end)
expect(external_build == nil and external_build_error.code == "storage"
    and read_file(external_target_path) == "external sentinel",
    "build must preserve and reject an externally owned part_path")

do
local external_temp_target = temp_prefix .. "-external-temp.manifest"
local external_temp_path = external_temp_target
    .. ".wdm-external-temp-owner-1-building"
write_file(external_temp_path, "external temporary sentinel")
local external_temp_build, external_temp_error = Manifest.build({
    part_path = external_temp_target, request_path = "/Books/A", md5 = fake_md5,
    nonce = "external-temp-owner",
}, function()
    error("producer must not run after an exclusive temporary-path collision")
end)
expect(external_temp_build == nil and external_temp_error.code == "storage"
    and read_file(external_temp_path) == "external temporary sentinel"
    and not path_exists(external_temp_target),
    "failed exclusive creation must never register or remove an external same-name file")
os.remove(external_temp_path)
end

do
local stale_target = temp_prefix .. "-stale-lock.manifest"
local stale_lock = stale_target .. ".wdm-lock"
local stale_payload = "WDMLOCK1\tcrashed-owner\n"
write_file(stale_lock, stale_payload)
local stale_producer_called = false
local stale_build, stale_error = Manifest.build({
    part_path = stale_target, request_path = "/Books/A", md5 = fake_md5,
    nonce = "stale-contender",
}, function()
    stale_producer_called = true
    return true
end)
expect(stale_build == nil and stale_error.code == "storage"
    and not stale_producer_called and read_file(stale_lock) == stale_payload
    and not path_exists(stale_target),
    "a stale lock must fail closed without being reclaimed or deleted by a non-owner")
os.remove(stale_lock)
end

do
local concurrent_target_path = temp_prefix .. "-concurrent.manifest"
local concurrent_lock_path = concurrent_target_path .. ".wdm-lock"
local inner_descriptor
local inner_error
local lock_remove_count = 0
local concurrent_temp_paths = {}
local function concurrent_exclusive(path, mode)
    if path:find(".wdm-", 1, true) then concurrent_temp_paths[path] = true end
    return strict_exclusive(path, mode)
end
local function concurrent_remove(path)
    local removed, remove_error = os.remove(path)
    if path == concurrent_lock_path and removed then
        lock_remove_count = lock_remove_count + 1
    end
    return removed, remove_error
end
local outer_descriptor, outer_error = Manifest.build({
    part_path = concurrent_target_path, request_path = "/Books/A",
    md5 = fake_md5, nonce = "outer-context",
    fs = test_filesystem({
        open = io.open, open_exclusive = concurrent_exclusive,
        remove = concurrent_remove, size = file_size,
        sync = function(handle) return handle:flush() end,
        atomic_replace = replace_for_windows_test,
    }),
}, function(emit)
    inner_descriptor, inner_error = Manifest.build({
        part_path = concurrent_target_path, request_path = "/Books/A",
        md5 = fake_md5, nonce = "inner-context",
        fs = test_filesystem({
            open = io.open, open_exclusive = concurrent_exclusive,
            remove = concurrent_remove, size = file_size,
            sync = function(handle) return handle:flush() end,
            atomic_replace = replace_for_windows_test,
        }),
    }, function(inner_emit)
        assert(inner_emit({
            full_path = "/Books/A/inner.jpg", name = "inner.jpg", is_file = true,
        }))
        return true
    end)
    expect(inner_descriptor == nil and inner_error.code == "storage"
        and path_exists(concurrent_lock_path)
        and read_file(concurrent_lock_path) == "WDMLOCK1\touter-context\n",
        "the losing context must leave the active owner's lock in place")
    expect(not path_exists(concurrent_target_path),
        "a competing context must not reserve part_path")
    assert(emit({
        full_path = "/Books/A/outer.jpg", name = "outer.jpg", is_file = true,
    }))
    return true
end)
expect(outer_descriptor ~= nil and outer_error == nil,
    "the context that atomically owns the fixed lock must remain the publisher")
expect(inner_descriptor == nil and inner_error.code == "storage"
    and lock_remove_count == 1 and not path_exists(concurrent_lock_path),
    "only the lock owner may release the fixed sidecar lock")
for temporary_path in pairs(concurrent_temp_paths) do
    if temporary_path ~= concurrent_lock_path then
        expect(temporary_path:find("outer%-context") ~= nil,
            "the losing context must not reserve any work temporary file")
    end
end
local concurrent_manifest = assert(Manifest.open(concurrent_target_path, { md5 = fake_md5 }))
expect(concurrent_manifest:_record_at(1).name == "outer.jpg",
    "the lock owner must publish its manifest without interference")
concurrent_manifest:close()
os.remove(concurrent_target_path)
end

do
local atomic_path = temp_prefix .. "-atomic.manifest"
local atomic_events = {}
local function tracked_open(path, mode)
    local raw, err = io.open(path, mode)
    if not raw then return nil, err end
    if mode:sub(1, 3) ~= "wb+" then return raw end
    local wrapper = {}
    function wrapper:write(...) return raw:write(...) end
    function wrapper:read(...) return raw:read(...) end
    function wrapper:seek(...) return raw:seek(...) end
    function wrapper:flush(...) return raw:flush(...) end
    function wrapper:close(...)
        atomic_events[#atomic_events + 1] = "close"
        return raw:close(...)
    end
    return wrapper
end
local function tracked_exclusive(path, mode)
    if path:find("-building", 1, true) then
        return tracked_open(path, mode == "wb+" and "wb+x" or "wbx")
    end
    return strict_exclusive(path, mode)
end
local tracked_fs = test_filesystem({
    open = tracked_open,
    open_exclusive = tracked_exclusive,
    remove = os.remove,
    atomic_replace = function(source, target)
        atomic_events[#atomic_events + 1] = "rename"
        os.remove(target)
        return os.rename(source, target)
    end,
    size = file_size,
    sync = function(handle)
        atomic_events[#atomic_events + 1] = "sync"
        return handle:flush()
    end,
})
assert(Manifest.build({
    part_path = atomic_path, request_path = "/Books/A",
    md5 = fake_md5, fs = tracked_fs,
}, function(emit)
    assert(emit({ full_path = "/Books/A/1.jpg", name = "1.jpg", is_file = true }))
    return true
end))
expect(table.concat(atomic_events, ","):match("sync,close,rename$") ~= nil,
    "the completed part must be synced and closed before atomic publication")
os.remove(atomic_path)
end

local function exercise_publication_failure(label, failed_stage)
    local target = temp_prefix .. "-" .. label .. ".manifest"
    assert(Manifest.build({
        part_path = target, request_path = "/Books/A", md5 = fake_md5,
        nonce = label .. "-seed",
    }, function(emit)
        assert(emit({
            full_path = "/Books/A/old.jpg", name = "old.jpg", is_file = true,
        }))
        return true
    end))
    local old_content = read_file(target)
    local owned = {}
    local function exclusive(path, mode)
        local handle, err = strict_exclusive(path, mode)
        if handle then owned[path] = true end
        return handle, err
    end
    local reached_failure = false
    local failed, failure = Manifest.build({
        part_path = target, request_path = "/Books/A", md5 = fake_md5,
        nonce = label,
        fs = test_filesystem({
            open = io.open,
            open_exclusive = exclusive,
            remove = os.remove,
            size = file_size,
            sync = function(handle)
                if failed_stage == "sync" then
                    reached_failure = true
                    return nil, "injected sync failure"
                end
                return handle:flush()
            end,
            atomic_replace = function()
                if failed_stage == "replace" then
                    reached_failure = true
                    return nil, "injected atomic replace failure"
                end
                return nil, "unexpected atomic replacement"
            end,
        }),
    }, function(emit)
        assert(emit({ full_path = "/Books/A/a.jpg", name = "a.jpg", is_file = true }))
        return true
    end)
    expect(reached_failure and failed == nil and failure.code == "storage",
        label .. " must reach and propagate the injected storage failure")
    for owned_path in pairs(owned) do
        if owned_path ~= target then expect(not path_exists(owned_path),
            label .. " must remove every file exclusively owned by this build")
        end
    end
    expect(read_file(target) == old_content,
        label .. " must preserve the previously valid target byte-for-byte")
    os.remove(target)
end

exercise_publication_failure("sync-failure", "sync")
exercise_publication_failure("replace-failure", "replace")

do
local uncertain_replace_path = temp_prefix .. "-uncertain-replace.manifest"
local uncertain_replace, uncertain_replace_error = Manifest.build({
    part_path = uncertain_replace_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "uncertain-replace",
    fs = test_filesystem({
        open = io.open, open_exclusive = strict_exclusive, remove = os.remove,
        size = file_size, sync = function(handle) return handle:flush() end,
        atomic_replace = function(source, target)
            local moved, move_error = replace_for_windows_test(source, target)
            if not moved then return nil, move_error end
            return nil, "injected uncertain result after committed replacement"
        end,
    }),
}, function(emit)
    assert(emit({ full_path = "/Books/A/winner.jpg", name = "winner.jpg", is_file = true }))
    return true
end)
expect(uncertain_replace == nil and uncertain_replace_error.code == "storage"
    and path_exists(uncertain_replace_path),
    "an uncertain replace result must never trigger deletion of a published target")
local uncertain_manifest = assert(Manifest.open(uncertain_replace_path, { md5 = fake_md5 }))
expect(uncertain_manifest:_record_at(1).name == "winner.jpg",
    "the target left by an uncertain replace must remain a valid winner")
uncertain_manifest:close()
os.remove(uncertain_replace_path)
end

do
local release_failure_path = temp_prefix .. "-release-failure.manifest"
local release_failure_lock = release_failure_path .. ".wdm-lock"
local replacement_committed = false
local release_failure, release_failure_error = Manifest.build({
    part_path = release_failure_path, request_path = "/Books/A", md5 = fake_md5,
    nonce = "release-failure",
    fs = test_filesystem({
        open = io.open, open_exclusive = strict_exclusive,
        remove = function(path)
            if replacement_committed and path == release_failure_lock then
                return nil, "injected owner lock release failure"
            end
            return os.remove(path)
        end,
        size = file_size, sync = function(handle) return handle:flush() end,
        atomic_replace = function(source, target)
            local moved, move_error = replace_for_windows_test(source, target)
            if moved then replacement_committed = true end
            return moved, move_error
        end,
    }),
}, function(emit)
    assert(emit({ full_path = "/Books/A/published.jpg", name = "published.jpg", is_file = true }))
    return true
end)
expect(replacement_committed and release_failure == nil
    and release_failure_error.code == "storage"
    and path_exists(release_failure_path) and path_exists(release_failure_lock),
    "a post-publication lock-release failure must preserve both winner and owner lock")
local release_failure_manifest = assert(Manifest.open(
    release_failure_path, { md5 = fake_md5 }))
expect(release_failure_manifest:_record_at(1).name == "published.jpg",
    "post-publication cleanup must not delete the winning target")
release_failure_manifest:close()
os.remove(release_failure_lock)
os.remove(release_failure_path)
end

for _, path in ipairs({
    stress_path, mixed_path, bad_magic_path, truncated_path,
    bad_digest_path, repeated_anchor_path, duplicate_path,
    external_target_path,
    kind_conflict_path, semantic_path, bad_path_hash, permutation_path,
    duplicate_ordinal_path, duplicate_record_path, strict_size_path,
    overflow_offset_path,
}) do
    os.remove(path)
end
for _, path in ipairs(invalid_size_paths) do os.remove(path) end
for _, path in ipairs(io_fault_paths) do os.remove(path) end

print(("manifest_spec: %d checks; 20000 entries built in %.3fs; bytes %d; "
    .. "max run %d; active runs %d; merge sources %d; owned temps %d; "
    .. "aux %d; max read %d; xml retained %d")
    :format(checks, build_seconds, descriptor.size,
        descriptor.max_run_entries, descriptor.max_active_runs,
        descriptor.max_merge_sources, descriptor.max_owned_temps,
        descriptor.max_auxiliary_entries, max_read,
        xml_description_retained_peak))
