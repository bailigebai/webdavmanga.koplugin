local Catalog = require("webdavmanga.opds_catalog")
local Library = require("webdavmanga.library")
local Pages = require("webdavmanga.opds_pages")
local Progress = require("webdavmanga.progress")
local Settings = require("webdavmanga.settings")
local Ui = require("webdavmanga.ui_opds")

local function memory_store()
    local values = {}
    return {
        values = values,
        readSetting = function(_, key, default)
            if values[key] == nil then return default end
            return values[key]
        end,
        saveSetting = function(_, key, value) values[key] = value end,
        flush = function() return true end,
    }
end
local settings = Settings:new{ store = memory_store() }
local source_url = "https://safe.example/opds?apiKey=query-secret"
local ok, source_id = settings:add_source{ kind = "opds", name = "私有目录",
    server_url = source_url, username = "reader", password = "separate-secret" }
assert(ok and source_id)
local requests = {}
local feed = { title = "卷一", entries = {
    { id = "p1", name = "1.jpg", kind = "page",
        image_url = "https://safe.example/1.jpg?apiKey=page-secret" },
} }
local catalog = Catalog:new{ settings = settings,
    client_factory = function() return { fetch = function(_, url, auth)
        requests[#requests + 1] = { url = url, auth = auth }
        return feed
    end } end }
local shown, context = {}, nil
local adapter = Ui:new{ catalog = catalog,
    async = { run = function(work, done)
        local ok, value = pcall(work); done(ok, value); return { cancel = function() end }
    end },
    reader = { open = function(_, value) context = value; return true end },
    ui = { show_menu = function(_, model) shown[#shown + 1] = model; return true end,
        close_menu = function() end, show_info = function() end },
}
adapter:open_url(settings:get_source(source_id),
    "https://reader:embedded-secret@safe.example/opds?apiKey=query-secret")
assert(#requests == 0 and context == nil,
    "embedded URL credentials must be rejected before any HTTP or Reader handoff")
assert(adapter:show_home() and shown[#shown].items[1].callback() and context,
    "the real OPDS menu must open a page context")

local progress_store, library_store = memory_store(), memory_store()
local progress = Progress:new{ store = progress_store, md5 = function(value) return value end }
local chapter_id = progress:chapter_id(context.connection, context.manga, context.chapter)
progress:save(chapter_id, context.chapter_index:get(1).path, 1, "whole", {
    connection = context.connection, manga = context.manga, chapter = context.chapter,
    total = 1, layout = context.layout, cover_hint = context.cover_hint,
    source_context = context.source_context,
})
local library = Library:new{ store = library_store, md5 = function(value) return value end }
assert(library:add_manga(context.connection, context.manga,
    { layout = context.layout, cover_hint = context.cover_hint }))

local function flatten(value, parts, seen)
    if type(value) ~= "table" then
        if type(value) == "string" then parts[#parts + 1] = value end
        return
    end
    if seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
        flatten(key, parts, seen)
        flatten(child, parts, seen)
    end
end
local parts = {}
flatten(progress_store.values, parts, {})
flatten(library_store.values, parts, {})
local persisted = table.concat(parts, "\n")
for _, secret in ipairs({ "embedded-secret", "query-secret", "page-secret",
    "separate-secret" }) do
    assert(not persisted:find(secret, 1, true),
        "Progress/Library persistence must not contain " .. secret)
end
assert(context.connection.kind == "opds"
    and not context.connection.server_url:find("safe.example", 1, true),
    "persistent connection must use a stable source identity, not a request URL")
local history = progress:list_history(context.connection)
assert(#history == 1 and history[1].connection.kind == "opds"
    and history[1].manga.opds_catalog_id == source_id,
    "history must preserve its OPDS kind and source id")

local other_ok = settings:add_source{ kind = "opds", name = "其他目录",
    server_url = "https://other.example/opds" }
assert(other_ok and settings:get_active_source_id() ~= source_id)
local page_auth
local pages = Pages:new{
    transport = { get_bytes = function(_, _, auth)
        page_auth = auth
        return 200, {}, "OK", "image-bytes"
    end },
    auth_provider = function(id)
        local source = settings:get_source(id)
        return source and { username = source.username, password = source.password } or {}
    end,
}
assert(pages.read_image(context.chapter_index:get(1), 1024) == "image-bytes"
    and page_auth.password == "separate-secret",
    "page requests must resolve credentials by the page source id, not the active source")
assert(adapter:open_record(history[1]) and requests[#requests].url == source_url
    and requests[#requests].auth.password == "separate-secret",
    "reopening history must resolve the request URL and credentials by source id")

local route_url = "https://safe.example/volumes"
    .. "?book=42&api_key=query-secret"
assert(adapter:open_url(settings:get_source(source_id), route_url))
assert(shown[#shown].items[1].callback() and context,
    "a routed OPDS feed must open through the real reader context")
local route_context = context
local route_chapter_id = progress:chapter_id(route_context.connection,
    route_context.manga, route_context.chapter)
progress:save(route_chapter_id, route_context.chapter_index:get(1).path, 1, "whole", {
    connection = route_context.connection, manga = route_context.manga,
    chapter = route_context.chapter, total = 1, layout = route_context.layout,
    cover_hint = route_context.cover_hint, source_context = route_context.source_context,
})
assert(library:add_manga(route_context.connection, route_context.manga,
    { layout = route_context.layout, cover_hint = route_context.cover_hint }))
assert(progress:flush())
local route_history
for _, record in ipairs(progress:list_history(route_context.connection)) do
    if record.manga.path == route_context.manga.path then route_history = record end
end
assert(route_history and adapter:open_record(route_history)
    and requests[#requests].url == "https://safe.example/volumes?book=42",
    "history must reopen a safe structured book route without its API key")
local saved_manga = library:get_manga(route_context.connection, route_context.manga.path)
assert(saved_manga and saved_manga.manga.opds_route_book == "42"
    and adapter:open_record(saved_manga)
    and requests[#requests].url == "https://safe.example/volumes?book=42",
    "library records must retain the structured route for reopening")
parts = {}
flatten(progress_store.values, parts, {})
flatten(library_store.values, parts, {})
persisted = table.concat(parts, "\n")
assert(not persisted:find("book=42", 1, true),
    "history must store the book route as structured data, not raw query text")
for _, secret in ipairs({ "embedded-secret", "query-secret", "page-secret",
    "separate-secret" }) do
    assert(not persisted:find(secret, 1, true),
        "routed Progress/Library persistence must not contain " .. secret)
end

local same_path_ok, same_path_id = settings:add_source{ kind = "opds",
    name = "同路径目录",
    server_url = "https://safe.example/volumes?api_key=query-secret" }
assert(same_path_ok and same_path_id)
local same_path_url = "https://safe.example/volumes?book=42&api_key=query-secret"
assert(adapter:open_url(settings:get_source(same_path_id), same_path_url))
assert(shown[#shown].items[1].callback() and context)
local same_path_context = context
assert(library:add_manga(same_path_context.connection, same_path_context.manga,
    { layout = same_path_context.layout, cover_hint = same_path_context.cover_hint }))
local same_path_record = library:get_manga(same_path_context.connection,
    same_path_context.manga.path)
assert(same_path_record and adapter:open_record(same_path_record)
    and requests[#requests].url
        == "https://safe.example/volumes?api_key=query-secret&book=42",
    "source-root API credentials and a structured book route must both survive reopening")
parts = {}
flatten(library_store.values, parts, {})
assert(not table.concat(parts, "\n"):find("query-secret", 1, true),
    "the library must never persist the source-root API key while retaining the route")

print("rebuild_0405_opds_privacy_spec: passed")
