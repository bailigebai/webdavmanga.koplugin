local UiLibrary = require("webdavmanga.ui_library")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end

-- A synchronous entitlement continuation must not fall through and open again.
for _, authorized in ipairs({ true, false }) do
    local opens, prompts, resume = 0, 0
    local controller = UiLibrary:new{
        settings = { get_connection = function() return {} end },
        library = {}, cover_service = {}, cover_grid = {}, browser = {}, ui = {},
        premium_access = { can_open = function() return authorized end },
        request_license = function(callback) prompts = prompts + 1; resume = callback end,
        open_cached_document = function() opens = opens + 1; return true end,
    }
    local document = { name = "book.pdf", remote_path = "/book.pdf", local_path = "/cache/book.pdf" }
    controller:_open_cached_document(document)
    if authorized then
        expect(opens == 1 and prompts == 0, "authorized cached document opens once")
    else
        expect(opens == 0 and prompts == 1, "unauthorized cached document waits for entitlement")
        resume(); resume()
        expect(opens == 1, "entitlement completion opens cached document once")
    end
end
print(("rebuild_0405_cached_open_once_spec: %d checks"):format(checks))
