local Driver = require("webdavmanga.opds_driver")
local source = { id = "source-1", server_kind = "komga", server_url = "https://srv/opds" }
local entry = { id = "book-7", name = "Chapter", stream = {
    template = "https://srv/api/v1/books/book-7/pages/{pageNumber}", count = 27 } }
local failures = {}
local function check(name, run)
    local ok, err = pcall(run)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end

check("encoded-path credentials", function()
    source.server_kind = "kavita"
    local raw = "https://alice:password-secret@srv/prefix%20space/%61pi/opds/path-secret/image"
        .. "?chapterId=34&seriesId=12&pageNumber={pageNumber}"
    local descriptor = assert(Driver.resolve(source, {}, { name = "Chapter", stream = { template = raw, count = 27 },
        image_url = raw }))
    assert(not descriptor.stream_template:find("secret", 1, true)
        and not descriptor.stream_template:find("alice", 1, true), "descriptor must redact URL credentials")
    assert(descriptor.cover_url == descriptor.stream_template and descriptor.requires_source_restore == true)
    assert(descriptor.stream_template:find("prefix%20space/%61pi/opds/{apiKey}", 1, true),
        "unrelated and route percent escapes must retain their original representation")
    assert(Driver.redact_url(descriptor.stream_template) == descriptor.stream_template)
end)

check("uppercase scheme credentials", function()
    local clean, restore = Driver.redact_url("HTTPS://alice:password-secret@srv/p/{pageNumber}")
    assert(clean == "https://srv/p/{pageNumber}" and restore == true, "scheme case cannot bypass userinfo removal")
    source.server_kind = "komga"
    local descriptor = assert(Driver.resolve(source, {}, { stream = {
        template = "HTTPS://alice:password-secret@srv/api/v1/books/book-7/pages/{pageNumber}", count = 27 } }))
    assert(not descriptor.stream_template:find("secret", 1, true) and descriptor.requires_source_restore == true)
end)

check("encoded slash inside complete Kavita key segment", function()
    source.server_kind = "kavita"
    local raw = "https://srv/prefix%20space/%61pi/%6Fpds/head-secret%2Ftail-secret/image%20name"
        .. "?chapterId=34&seriesId=12&pageNumber={pageNumber}"
    local descriptor = assert(Driver.resolve(source, {}, { stream = { template = raw, count = 27 }, image_url = raw }))
    local expected = "https://srv/prefix%20space/%61pi/%6Fpds/{apiKey}/image%20name"
        .. "?chapterId=34&seriesId=12&pageNumber={pageNumber}"
    assert(descriptor.stream_template == expected and descriptor.cover_url == expected,
        "the entire raw key segment, including its encoded slash suffix, must be redacted")
    assert(not descriptor.stream_template:find("secret", 1, true) and descriptor.requires_source_restore == true)
    local again, restore = Driver.redact_url(descriptor.stream_template)
    assert(again == expected and restore == true, "complete-segment redaction must remain idempotent")
end)

check("fragment-only page placeholder", function()
    source.server_kind = "komga"
    local descriptor, err = Driver.resolve(source, {}, { stream = {
        template = "https://srv/api/v1/books/book-7/pages/0#ignored-{pageNumber}", count = 27 } })
    assert(descriptor == nil and err == "invalid_stream_template", "fragment cannot supply the request page placeholder")
end)

check("dispatcher preserves absent series URL", function()
    source.server_kind = "komga"
    local descriptor = assert(Driver.resolve(source, { series_feed_url = "https://srv/opds/v1.2/books/latest" },
        entry, { id = "book-7", seriesId = "series-9" }))
    assert(descriptor.series_id == "series-9" and descriptor.series_feed_url == nil,
        "dispatcher cannot override missing series feed evidence")
end)

check("conflicting series identity", function()
    source.server_kind = "komga"
    local descriptor, err = Driver.resolve(source, { feed_url = "https://srv/opds/v1.2/series/series-8" },
        entry, { id = "book-7", seriesId = "series-9" })
    assert(descriptor == nil and err == "series_identity_mismatch", "conflicting proven series identities must fail")
end)

check("auto ignores query and fragment path claims", function()
    source.server_kind = "auto"
    for _, url in ipairs({ "https://srv/catalog?redirect=/api/opds/secret", "https://srv/catalog#/api/opds/secret" }) do
        local descriptor, err = Driver.resolve(source, { feed_url = url, feed = { author = "Komga" } }, entry)
        assert(descriptor and descriptor.server_kind == "komga", "query/fragment must not override author: " .. tostring(err))
    end
    for _, author in ipairs({ "NotKomga", "Not_Komga", "Suwayomix", "UnrelatedKavita" }) do
        local descriptor, err = Driver.resolve(source, { feed_url = "https://srv/catalog", feed = { author = author } }, entry)
        assert(descriptor == nil and err == "unsupported_server", "server author needs a word boundary")
    end
    for _, url in ipairs({ "https://srv/opds/v1.20", "https://srv/api/v1/opds-impostor" }) do
        local descriptor, err = Driver.resolve(source, { feed_url = url }, entry)
        assert(descriptor == nil and err == "unsupported_server", "server route needs a segment boundary")
    end
end)

check("auto rejects conflicting strong evidence", function()
    source.server_kind = "auto"
    local context = { feed_url = "https://srv/api/opds/key", feed = { author = "Komga" } }
    local descriptor, err = Driver.resolve(source, context, entry)
    assert(descriptor == nil and err == "ambiguous_server", "auto must not choose one conflicting server")
    source.server_kind = "komga"
    assert(Driver.resolve(source, context, entry).server_kind == "komga", "explicit server kind still takes precedence")
end)

assert(#failures == 0, table.concat(failures, "\n"))
print("rebuild_0405_opds_driver_boundaries_spec: 8 groups passed")
