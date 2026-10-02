local Parser = require("webdavmanga.opds_parser")
local ok, Driver = pcall(require, "webdavmanga.opds_driver")
assert(ok, "OPDS stable-identity driver must exist")

local function feed(author, id, href, count)
    return assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom" '
        .. 'xmlns:pse="http://vaemendis.net/opds-pse/ns"><title>Series</title>'
        .. '<author><name>' .. author .. '</name></author><entry><id>' .. id
        .. '</id><title>Chapter</title><link rel="http://vaemendis.net/opds-pse/stream" '
        .. 'href="' .. href .. '" pse:count="' .. tostring(count or 27)
        .. '" pse:lastRead="2" type="image/jpeg"/></entry></feed>', 'https://srv/opds'))
end
local source = { id = "source-1", kind = "opds", server_kind = "suwayomi",
    server_url = "https://srv/opds", username = "alice", password = "password-secret" }
local metadata = feed("Suwayomi", "urn:suwayomi:chapter:abc:metadata",
    "https://srv/chapter/abc/page/{pageNumber}")
local chapter = { id = "urn:suwayomi:chapter:abc", name = "Chapter", href = "https://srv/metadata" }
local context = { feed_url = "https://srv/opds/manga/9", series_id = "urn:suwayomi:manga:9",
    series_name = "Series", series_feed_url = "https://srv/opds/manga/9" }
local suwayomi = assert(Driver.resolve(source, context, chapter, metadata))
assert(suwayomi.chapter_id == "urn:suwayomi:chapter:abc")
assert(suwayomi.series_id == "urn:suwayomi:manga:9" and suwayomi.source_id == "source-1")
assert(suwayomi.server_kind == "suwayomi" and suwayomi.page_count == 27)
assert(suwayomi.server_last_read == 2 and suwayomi.chapter_name == "Chapter")
assert(suwayomi.stream_template == "https://srv/chapter/abc/page/{pageNumber}",
    "driver must preserve zero-based PSE template for the page adapter")
assert(suwayomi.stream_template:gsub("{pageNumber}", "0") == "https://srv/chapter/abc/page/0")
assert(suwayomi.stream_template:gsub("{pageNumber}", "26") == "https://srv/chapter/abc/page/26")
assert(suwayomi.password == nil and suwayomi.username == nil)
local suwayomi_live = feed("Suwayomi", "urn:suwayomi:chapter:live:metadata",
    "https://srv/api/v1/manga/9/chapter/1/page/{pageNumber}?updateProgress=true&amp;opds=true")
local live_descriptor = assert(Driver.resolve(source, context, suwayomi_live.entries[1]))
assert(live_descriptor.stream_template:find("opds=true", 1, true),
    "Suwayomi's non-secret OPDS page flag must survive descriptor redaction")
local doubled = feed("Suwayomi", "urn:chapter:metadata:metadata", "https://srv/p/{pageNumber}")
assert(Driver.resolve(source, {}, doubled.entries[1]).chapter_id == "urn:chapter:metadata",
    "strip only one terminal metadata suffix")
local interior = feed("Suwayomi", "urn:chapter:metadata:abc", "https://srv/p/{pageNumber}")
assert(Driver.resolve(source, {}, interior.entries[1]).chapter_id == "urn:chapter:metadata:abc")
local missing, missing_error = Driver.resolve(source, context, chapter)
assert(missing == nil and missing_error == "metadata_required")
local mismatch = feed("Suwayomi", "urn:other:metadata", "https://srv/p/{pageNumber}")
local bad, err = Driver.resolve(source, context, chapter, mismatch)
assert(bad == nil and err == "chapter_identity_mismatch")

source.server_kind = "kavita"
local kavita = feed("Kavita", "title-is-not-id", "https://alice:password-secret@srv/api/opds/key-secret/image"
    .. "?seriesId=12&amp;chapterId=34&amp;pageNumber={pageNumber}&amp;apiKey=query-secret"
    .. "&amp;width={width}&amp;maxWidth={maxWidth}&amp;height={height}&amp;maxHeight={maxHeight}")
local kv = assert(Driver.resolve(source, {}, kavita.entries[1]))
assert(kv.series_id == "12" and kv.chapter_id == "34")
assert(kv.stream_template:find("pageNumber={pageNumber}", 1, true))
assert(kv.stream_template:find("width={width}", 1, true))
assert(kv.stream_template:find("maxWidth={maxWidth}", 1, true))
assert(kv.stream_template:find("height={height}", 1, true))
assert(kv.stream_template:find("maxHeight={maxHeight}", 1, true))
assert(not kv.stream_template:find("secret", 1, true) and not kv.stream_template:find("alice", 1, true))
assert(kv.requires_source_restore == true)
local no_query = feed("Kavita", "chapter-34", "https://srv/series/12/chapter/34/{pageNumber}")
bad, err = Driver.resolve(source, { series_id = "12" }, no_query.entries[1])
assert(bad == nil and err == "missing_chapter_id", "Kavita must use query ids only")

source.server_kind = "komga"
local komga = feed("Komga", "title-is-not-id", "https://srv/api/v1/books/book-7/pages/{pageNumber}")
local kg = assert(Driver.resolve(source, { feed_url = "https://srv/opds/v1.2/series/series-8" }, komga.entries[1]))
assert(kg.chapter_id == "book-7" and kg.series_id == "series-8")
local aggregate = { feed_url = "https://srv/opds/v1.2/books/latest", series_name = "Misleading title" }
assert(Driver.resolve(source, aggregate, komga.entries[1]).series_id == nil,
    "aggregate feed title is not series identity evidence")
assert(Driver.resolve(source, aggregate, komga.entries[1], { id = "book-7", seriesId = "series-9" }).series_id == "series-9")
assert(Driver.resolve(source, aggregate, komga.entries[1], { id = "book-7", seriesId = "series-9" }).series_feed_url == nil,
    "REST series identity cannot turn the aggregate catalog into a series catalog")
bad, err = Driver.resolve(source, aggregate, komga.entries[1], { id = "other-book", seriesId = "series-9" })
assert(bad == nil and err == "chapter_identity_mismatch")
local absent = feed("Komga", "book-7", "https://srv/pages/{pageNumber}")
bad, err = Driver.resolve(source, aggregate, absent.entries[1])
assert(bad == nil and err == "missing_chapter_id")

source.server_kind = "auto"
assert(Driver.resolve(source, { feed = komga }, komga.entries[1]).server_kind == "komga")
assert(Driver.resolve(source, { feed = metadata, series_id = "9" }, metadata.entries[1]).server_kind == "suwayomi")
assert(Driver.resolve(source, { feed = kavita }, kavita.entries[1]).server_kind == "kavita")
bad, err = Driver.resolve(source, {}, { id = "unknown", stream = { template = "https://srv/p/{pageNumber}", count = 2 } })
assert(bad == nil and err == "unsupported_server")
source.server_kind = "komga"
assert(Driver.resolve(source, { feed = kavita }, komga.entries[1]).server_kind == "komga", "explicit kind wins")
for _, count in ipairs({1, 100000}) do
    local boundary = feed("Komga", "book-7", "https://srv/api/v1/books/book-7/pages/{pageNumber}", count)
    assert(Driver.resolve(source, {}, boundary.entries[1]).page_count == count)
end

for _, count in ipairs({0, 100001, 2.5}) do
    local invalid = feed("Komga", "book-7", "https://srv/api/v1/books/book-7/pages/{pageNumber}", count)
    bad, err = Driver.resolve(source, {}, invalid.entries[1])
    assert(bad == nil and err == "invalid_page_count", "invalid count must fail before pointer creation")
end
local invalid = feed("Komga", "book-7", "https://srv/api/v1/books/book-7/pages/0")
bad, err = Driver.resolve(source, {}, invalid.entries[1])
assert(bad == nil and err == "invalid_stream_template")
source.server_kind = "suwayomi"
bad, err = Driver.resolve(source, {}, { name = "No stable identity", stream = metadata.entries[1].stream })
assert(bad == nil and err == "missing_chapter_id")

local raw = "https://alice:password-secret@srv/api/opds/path-secret/image?seriesId=12&chapterId=34"
    .. "&pageNumber={pageNumber}&token=token-secret&arbitrary=private-data#private-fragment"
local redacted, restore = Driver.redact_url(raw)
assert(restore == true and not redacted:find("secret", 1, true) and not redacted:find("private", 1, true))
assert(redacted:find("seriesId=12", 1, true) and redacted:find("chapterId=34", 1, true))
assert(redacted:find("pageNumber={pageNumber}", 1, true))
local again, still_restore = Driver.redact_url(redacted)
assert(again == redacted and still_restore == true, "redaction is idempotent")
local mixed_case = Driver.redact_url("https://srv/API/OPDS/case-secret/image?chapterId=34&pageNumber={pageNumber}")
assert(not mixed_case:find("case-secret", 1, true), "Kavita route casing must not leak a path API key")
local unsafe_id = Driver.redact_url("https://srv/p/{pageNumber}?seriesId=secret%2Fvalue&sort=number_asc")
local alias_template = Driver.redact_url("https://srv/p?page={pageNumber}&w={width}&h={height}&mw={maxWidth}&mh={maxHeight}")
assert(alias_template == "https://srv/p?page={pageNumber}&w={width}&h={height}&mw={maxWidth}&mh={maxHeight}",
    "safe template values survive even when the server uses a different parameter name")
assert(not unsafe_id:find("secret", 1, true) and unsafe_id:find("sort=number_asc", 1, true))
local unsafe_opds = Driver.redact_url("https://srv/p/{pageNumber}?opds=private-token")
assert(not unsafe_opds:find("private-token", 1, true),
    "only boolean OPDS protocol flags may survive redaction")
local direct = metadata.entries[1]
direct.image_url = raw
local scrubbed = assert(Driver.resolve(source, { series_feed_url = raw }, direct))
assert(scrubbed.cover_url == redacted and scrubbed.series_feed_url == redacted)
assert(scrubbed.requires_source_restore == true)
assert(direct.image_url == raw, "redaction must not mutate fetched runtime metadata")
print("rebuild_0405_opds_drivers_spec: passed")
