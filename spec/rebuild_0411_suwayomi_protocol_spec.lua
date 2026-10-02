-- Synthetic protocol fixtures based on Suwayomi's public OPDS builders, without
-- server addresses, credentials, book files or device logs from the user.
local Driver = require("webdavmanga.opds_driver")
local Parser = require("webdavmanga.opds_parser")
local Pages = require("webdavmanga.opds_pages")
local Ui = require("webdavmanga.ui_opds")
local checks, failures = 0, {}
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function test(name, run)
    local ok, err = pcall(run)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local chapter_id = "urn:suwayomi:chapter:42"
local page_path = "/api/v1/manga/7/chapter/2/page/{pageNumber}?updateProgress=false&opds=true"
local chapter = { id = chapter_id, name = "Chapter", stream = {
    template = "https://srv" .. page_path, count = 20 } }

test("official endpoint detection", function()
    for _, route in ipairs({ "/api/opds/v1.2", "/api/opds/v1.2/series/7/chapters",
        "/proxy/api/opds/v1.2/series/7/chapters", "/proxy/%61pi/%6fpds/v1.2/series/7",
        "/api/v1/opds/manga/7", "/api/v1/opds/v1.2/series/7" }) do
        for _, author in ipairs({ "Suwayomi", "" }) do
            local descriptor, err = Driver.resolve({ id = "s1", server_kind = "auto" },
                { feed_url = "https://srv" .. route, feed = { author = author }, series_id = "S" }, chapter)
            expect(descriptor and descriptor.server_kind == "suwayomi",
                "complete Suwayomi route must identify only Suwayomi: " .. tostring(err))
        end
    end
end)

test("protocol segment is not an API key", function()
    for _, route in ipairs({ "/api/opds/v1.2/series/7", "/prefix/%61pi/opds/%761.2/series/7" }) do
        local clean, restore = Driver.redact_url("https://srv" .. route)
        expect(clean == "https://srv" .. route and not restore,
            "Suwayomi protocol version is public route data")
    end
end)

test("public language tags survive saved navigation", function()
    local source = { url = "https://srv/api/opds/v1.2" }
    for _, language in ipairs({ "en", "zh-Hans-CN", "pt-BR", "haw", "es-419" }) do
        local url = source.url .. "/series/7/chapters?lang=" .. language
        local clean, restore = Driver.redact_url(url)
        expect(clean == url and not restore, "valid public locale stays intact")
        expect(Pages.restore_url(clean, source) == url, "saved locale does not require a source secret")
    end
    for _, language in ipairs({ "", "password-secret", "token=abc", "en%26token%3Dsecret",
        "en--US", "en-", "en_US", "en-123456789", "en " , string.rep("a", 65) }) do
        local clean, restore = Driver.redact_url(source.url .. "/series/7/chapters?lang=" .. language)
        expect(clean:find("{query:lang}", 1, true) and restore, "invalid language remains redacted")
    end
end)

test("genuine contradictions still reject", function()
    local descriptor, err = Driver.resolve({ id = "s1", server_kind = "auto" },
        { feed_url = "https://srv/api/opds/v1.2/series/7", feed = { author = "Komga" } }, chapter)
    expect(not descriptor and err == "ambiguous_server", "conflicting author still rejects")
    descriptor, err = Driver.resolve({ id = "s1", server_kind = "auto" },
        { feed_url = "https://srv/opds/v1.2/proxy/api/opds/key" }, chapter)
    expect(not descriptor and err == "ambiguous_server", "independent route claims still reject")
    descriptor, err = Driver.resolve({ id = "s1", server_kind = "auto" },
        { feed_url = "https://srv/catalog?redirect=/api/opds/v1.2#/api/v1/opds" }, chapter)
    expect(not descriptor and err == "unsupported_server", "query and fragment are not evidence")
end)

local function feed(entries, url)
    return assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom" '
        .. 'xmlns:pse="http://vaemendis.net/opds-pse/ns"><title>Catalog</title>'
        .. '<author><name>Suwayomi</name></author>' .. entries .. '</feed>', url))
end

local function exercise(kind, has_stream, conflict, select_remote, second_page)
    local root = "https://srv/api/opds/v1.2/library/series"
    local initial_series = "https://srv/api/opds/v1.2/series/7/chapters?lang=en&sort=number_asc"
    local series = initial_series .. (second_page and "&pageNumber=2" or "")
    local metadata = "https://srv/api/opds/v1.2/series/7/chapter/2/metadata?lang=en"
    local source = { id = "s1", server_kind = kind, url = "https://srv/api/opds/v1.2" }
    local stream_xml = '<link rel="http://vaemendis.net/opds-pse/stream" type="image/jpeg" '
        .. 'href="' .. page_path:gsub("&", "&amp;") .. '" pse:count="20"'
        .. (conflict and ' pse:lastRead="5"' or '') .. '/>'
    local remote_xml = stream_xml:gsub('lastRead="5"', 'lastRead="15"')
    local catalogs = {
        [root] = feed('<entry><id>urn:suwayomi:manga:7</id><title>Series</title>'
            .. '<link rel="subsection" type="application/atom+xml;profile=opds-catalog;kind=acquisition" '
            .. 'href="/api/opds/v1.2/series/7/chapters?lang=en"/></entry>', root),
        [series] = feed('<entry><id>' .. chapter_id .. '</id><title>Chapter</title>'
            .. (has_stream and stream_xml or '<link rel="subsection" '
                .. 'type="application/atom+xml;type=entry;profile=opds-catalog" '
                .. 'href="' .. metadata .. '"/>') .. '</entry>', series),
        [metadata] = feed('<entry><id>' .. chapter_id .. ':metadata</id><title>Chapter</title>'
            .. stream_xml .. '</entry>' .. (conflict and '<entry><id>' .. chapter_id
                .. ':metadata:remote</id><title>Remote Chapter</title>' .. remote_xml .. '</entry>' or ''), metadata),
    }
    catalogs[initial_series] = catalogs[series]
    expect(catalogs[root].entries[1].kind == "series", "manga subsection remains a series")
    if not has_stream then
        expect(catalogs[series].entries[1].kind == "volume", "Atom entry subsection is a chapter detail")
    end
    local menus, infos, fetched, opened, open_options = {}, {}, {}, nil, nil
    local app = Ui:new{pointer = {}, reader = {}, catalog = {fetch = function(_, id, url)
        expect(id == "s1", "selected source is retained")
        fetched[#fetched + 1] = url
        expect(catalogs[url] ~= nil, "only expected catalog URLs are requested")
        return catalogs[url]
    end}, ui = {show_menu = function(_, model) menus[#menus + 1] = model; return true end,
        show_info = function(_, message) infos[#infos + 1] = message end},
        async = {run = function(work, done) local ok, value = pcall(work); done(ok, value); return {} end}}
    app.request_open = function(_, descriptor, _, options) opened, open_options = descriptor, options; return true end
    expect(app:open_url(source, root), "series catalog opens")
    local function callback(title)
        for _, item in ipairs(menus[#menus].items) do
            if item.text == title then return item.callback end
        end
        error("expected menu item missing")
    end
    local function click(title) return callback(title)() end
    expect(click("Series"), "series opens")
    if second_page then
        expect(app:open_url(source, series, nil, nil, series, app.current.series_context),
            "next chapter catalog page opens with the original series context")
    end
    local old_chapter_callback = callback("Chapter")
    expect(old_chapter_callback(), "chapter opens")
    local choice_model, choice_callback
    if conflict then
        expect(not opened, "two server progress variants require an explicit choice")
        expect(not old_chapter_callback(), "replaced chapter catalog callback is retired")
        choice_model = menus[#menus]
        choice_callback = callback(select_remote and "Remote Chapter" or "Chapter")
        expect(choice_callback(), "chosen progress variant opens")
        expect(opened and opened.server_last_read == (select_remote and 15 or 5),
            "the selected variant retains its own server reading position")
        expect(not open_options.navigation_page,
            "same chapter variants must not become duplicate chapter neighbors")
    end
    expect(#infos == 0 and opened and opened.page_count == 20, "chapter reaches reader without errors")
    expect(opened.server_kind == "suwayomi" and opened.chapter_id == chapter_id,
        "resolved server and stable chapter identity are retained")
    expect(opened.series_id == "urn:suwayomi:manga:7", "metadata must not become a new series")
    expect(not opened.series_feed_url:find("{apiKey}", 1, true), "series route version must remain intact")
    expect(Pages.restore_url(opened.series_feed_url, source) == series,
        "saved official series URL restores with public language and sort intact")
    local fetch_count = (has_stream and 2 or 3) + (second_page and 1 or 0)
    expect(#fetched == fetch_count, "metadata is fetched exactly when needed")
    local index = assert(Pages.virtual_index(opened, "/pointer"))
    local first = assert(index:get(1).image_url(800, 1200, source))
    local last = assert(index:get(20).image_url(800, 1200, source))
    expect(first == "https://srv/api/v1/manga/7/chapter/2/page/0?opds=true&updateProgress=true",
        "first page uses zero-based Suwayomi protocol URL")
    expect(last == "https://srv/api/v1/manga/7/chapter/2/page/19?opds=true&updateProgress=true",
        "last page uses zero-based Suwayomi protocol URL")
    if conflict then
        expect(choice_model.on_back(), "choice details return to the original chapter catalog")
        expect(not choice_callback(), "choice callback is retired after returning")
        expect(#fetched == fetch_count + 1 and fetched[#fetched] == series,
            "back reloads the real chapter catalog page once")
    end
end
for _, kind in ipairs({ "auto", "suwayomi" }) do
    for _, ready in ipairs({ false, true }) do
        test(kind .. (ready and " direct PSE" or " metadata PSE"), function() exercise(kind, ready) end)
    end
end
for _, kind in ipairs({ "auto", "suwayomi" }) do
    test(kind .. " second catalog page direct PSE", function() exercise(kind, true, false, false, true) end)
    test(kind .. " second catalog page progress choice", function() exercise(kind, false, true, true, true) end)
end
for _, kind in ipairs({ "auto", "suwayomi" }) do
    for _, select_remote in ipairs({ false, true }) do
        test(kind .. (select_remote and " remote progress choice" or " local progress choice"),
            function() exercise(kind, false, true, select_remote) end)
    end
end

assert(#failures == 0, table.concat(failures, "\n"))
print(("rebuild_0411_suwayomi_protocol_spec: %d checks"):format(checks))
