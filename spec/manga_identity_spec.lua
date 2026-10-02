local Identity = require("webdavmanga.manga_identity")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local webdav = {
    kind = "webdav", server_url = " https://nas/dav/ ", username = " u ",
    root_path = "/A//",
}
local webdav_with_secret = {
    kind = "webdav", server_url = webdav.server_url, username = webdav.username,
    password = "password", token = "token", root_path = webdav.root_path,
}
local local_dir = {
    kind = "local", server_url = "local://", root_path = "/mnt/us/Comics",
    local_path = "/mnt/us/Comics",
}
local nodeshare = {
    kind = "nodeshare", server_url = "nodeshare://device", username = "u",
    root_path = "/mnt/us/Comics", local_path = "/mnt/us/Comics",
}

expect(type(Identity.connection(webdav)) == "string", "connection identity must be text")
expect(Identity.connection(webdav) == Identity.connection(webdav_with_secret),
    "password and token must not affect identity")
expect(Identity.connection(webdav):find("password", 1, true) == nil,
    "password must not enter identity")
expect(Identity.connection(webdav):find("token", 1, true) == nil,
    "token must not enter identity")
expect(Identity.manga(webdav, "/A/book") ~= Identity.manga(local_dir, "/mnt/us/Comics/book"),
    "WebDAV and local paths must be different identities")
expect(Identity.manga(webdav, "/A//book/") == Identity.manga(webdav, "/A/book"),
    "manga paths must be normalized")
expect(Identity.connection(nodeshare) ~= Identity.connection(webdav),
    "nodeshare and WebDAV connections must remain distinct")
expect(Identity.connection(nodeshare):find("nodeshare", 1, true) ~= nil,
    "nodeshare kind must be retained in identity")
local variants = Identity.connection_variants(webdav)
expect(type(variants) == "table" and variants.current == Identity.connection(webdav)
    and type(variants.legacy) == "string", "connection variants must expose current and legacy")
expect(variants.current ~= variants.legacy, "current identity must remain distinct from legacy identity")
local local_variants = Identity.connection_variants(local_dir)
expect(local_variants.current == Identity.connection(local_dir)
    and local_variants.legacy == local_variants.current,
    "local connections must not receive a WebDAV legacy alias")
local nodeshare_variants = Identity.connection_variants(nodeshare)
expect(nodeshare_variants.current == Identity.connection(nodeshare)
    and nodeshare_variants.legacy == nodeshare_variants.current,
    "nodeshare connections must not receive a WebDAV legacy alias")

print(("manga_identity_spec: %d checks"):format(checks))
