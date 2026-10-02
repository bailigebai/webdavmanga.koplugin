local Client = require("webdavmanga.opds_client")

local calls = {}
local transport = {
    get_bytes = function(_self, url, auth, maximum)
        calls[#calls + 1] = { url = url, auth = auth, maximum = maximum }
        return 200, { ["content-type"] = "application/atom+xml" }, "OK",
            '<feed xmlns="http://www.w3.org/2005/Atom"><title>书架</title></feed>'
    end,
}
local client = Client:new{ transport = transport, maximum_bytes = 12345 }
local catalog = assert(client:fetch("https://example.test/catalog", {
    username = "davuser", password = "secret",
}))
assert(catalog.title == "书架")
assert(catalog.is_atom_feed == true, "Atom root must be identified for connection tests")
assert(#calls == 1)
assert(calls[1].url == "https://example.test/catalog")
assert(calls[1].auth.username == "davuser" and calls[1].auth.password == "secret")
assert(calls[1].maximum == 12345)

local failing = Client:new{
    transport = { get_bytes = function() return 401, {}, "Unauthorized", "no" end },
}
local result, err = failing:fetch("https://example.test/catalog", {})
assert(result == nil and err.code == "http" and err.http_status == 401)

local non_atom = Client:new{
    transport = { get_bytes = function() return 200, {}, "OK",
        '<collection><entry><title>伪目录</title></entry></collection>' end },
}
local rejected, rejection = non_atom:fetch("https://example.test/not-atom", {})
assert(rejected == nil and rejection.code == "decode",
    "a non-Atom document with entries must not pass as an OPDS feed")

print("opds_client_spec: passed")
