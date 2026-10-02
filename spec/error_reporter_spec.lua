local shown, logged, cleaned = {}, {}, 0
local Reporter = require("webdavmanga.error_reporter")
local reporter = Reporter:new{
    id_factory = function() return "E042" end,
    ui = { show_info = function(_self, text) shown[#shown + 1] = text end },
    logger = { err = function(_, ...) logged[#logged + 1] = table.concat({...}, " ") end },
}

local value = reporter:guard("open_chapter", function()
    error("Authorization: Basic secret https://name:pass@nas/private")
end, "fallback", function() cleaned = cleaned + 1 end)

assert(value == "fallback" and cleaned == 1)
assert(shown[1]:find("打开章节失败", 1, true) and shown[1]:find("E042", 1, true))
assert(logged[1]:find("stack traceback", 1, true))
assert(not logged[1]:find("secret", 1, true) and not logged[1]:find("pass@", 1, true))

local bearer = Reporter.sanitize("Authorization: Bearer secret-token")
local digest = Reporter.sanitize("before\nAuthorization: Digest username=reader, realm=nas, response=digest-secret\r\nafter")
local multi_token = Reporter.sanitize("Authorization: Custom first-token second-token third-token")
assert(not bearer:find("secret-token", 1, true)
    and not digest:find("reader", 1, true)
    and not digest:find("digest-secret", 1, true)
    and not multi_token:find("first-token", 1, true)
    and not multi_token:find("second-token", 1, true)
    and not multi_token:find("third-token", 1, true),
    "Authorization values must be redacted through the end of their header line")

reporter:guard("close_reader", function() error("cleanup failed") end, true, nil, { silent = true })
assert(#shown == 1, "silent emergency cleanup must not show another dialog")

print("error_reporter_spec: 8 checks")
