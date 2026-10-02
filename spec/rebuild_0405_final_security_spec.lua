-- Catches catalog credentials crossing an origin boundary, and deleted source
-- identities being reassigned. Parser, Settings, Catalog and Client stay real.
local Settings = require("webdavmanga.settings")
local Catalog = require("webdavmanga.opds_catalog")
local Client = require("webdavmanga.opds_client")
local Parser = require("webdavmanga.opds_parser")
local failures, checks = {}, 0
local function test(name, body)
    local ok, err = pcall(body)
    checks = checks + 1
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end
local values = {}
local store = {
    readSetting=function(_, k, fallback) if values[k] == nil then return fallback end; return values[k] end,
    saveSetting=function(_, k, v) values[k] = v end, flush=function() return true end,
}
local settings = Settings:new{store=store}
local input = {kind="opds", name="Test", server_url="https://catalog.invalid/opds/root",
    username="fixture-user", password="fixture-password", server_kind="suwayomi"}
local _, id = settings:add_source(input)
local requests = {}
local catalog = Catalog:new{settings=settings, client_factory=function()
    return Client:new{transport={get_bytes=function(_, url, auth)
        requests[#requests+1] = {url=url, auth=auth}
        return 200, {}, "OK", '<feed xmlns="http://www.w3.org/2005/Atom"><title>OK</title></feed>'
    end}}
end}
for _, fixture in ipairs({
    {rel="subsection", href="https://external.invalid/catalog"},
    {rel="next", href="https://external.invalid/redirect?token=fixture-sensitive"},
    {rel="http://opds-spec.org/acquisition", href="https://external.invalid/metadata"},
    {rel="search", href="https://catalog.invalid:8443/search"},
    {rel="subsection", href="//catalog.invalid/protocol-relative"},
    {rel="subsection", href="https://user:fixture-sensitive@catalog.invalid/metadata"},
    {rel="subsection", href="https://catalog.invalid\\@external.invalid/metadata"},
}) do
    test("#1 reject " .. fixture.rel .. " " .. fixture.href, function()
        local feed = assert(Parser.parse('<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>x</id><title>x</title><link rel="'
            .. fixture.rel .. '" type="application/atom+xml" href="' .. fixture.href .. '"/></entry></feed>', input.server_url))
        local before = #requests
        local result, err = catalog:fetch(id, feed.entries[1].links[1].href)
        assert(not result and #requests == before, "unsafe parsed target reached authenticated transport")
        local detail = type(err) == "table" and tostring(err.message or err.detail or err.code) or tostring(err)
        assert(not detail:find("fixture",1,true) and not detail:find("https://",1,true), "error disclosed a URL or credential")
    end)
end
for _, target in ipairs({"/relative", "chapter", "https://CATALOG.invalid:443/same", "https://catalog.invalid/same"}) do
    test("#1 safe target " .. target, function()
        assert(catalog:fetch(id, target), "safe relative/same-origin request rejected")
        assert(requests[#requests].auth.password == "fixture-password", "authorized request lost source authentication")
    end)
end
test("#3 deleted source stays missing after restart", function()
    assert(id == "source-1")
    local _, second = settings:add_source(input)
    assert(second == "source-2")
    assert(settings:remove_source(second)); settings:flush()
    settings = Settings:new{store=store}
    local _, third = settings:add_source(input)
    settings:flush()
    local restarted = Settings:new{store=store}
    assert(third == "source-3" and not restarted:get_source(second), "old pointer/history source id rebound to new source")
    local _, fourth = restarted:add_local_source{local_path="/books", name="Local"}
    assert(fourth == "source-4", "local and remote sources must share the allocator")
end)
test("#3 migrate high existing id", function()
    local old = {sources={{id="source-41", kind="opds", server_url=input.server_url}}}
    local migrated = Settings:new{store={readSetting=function(_,k,f) return old[k] or f end,
        saveSetting=function(_,k,v) old[k]=v end}}
    local _, added = migrated:add_source(input)
    assert(added == "source-42" and migrated:get_source("source-41"), "migration reused an id or changed existing identity")
end)
assert(#failures == 0, table.concat(failures, "\n"))
print("rebuild_0405_final_security_spec: " .. checks .. " checks")
