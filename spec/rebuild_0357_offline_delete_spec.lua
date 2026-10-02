local OfflineCache = require("webdavmanga.offline_cache")
local UiLibrary = require("webdavmanga.ui_library")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local files = {
    ["/mnt/us/Offline/A-aaaaaaaa.jpg"] = true,
    ["/mnt/us/Offline/B-bbbbbbbb.jpg"] = true,
    ["/mnt/us/Other/C-cccccccc.jpg"] = true,
    ["/mnt/us/Offline/plain.jpg"] = true,
}
local remove_calls, flush_calls = {}, 0
local fs = {
    exists = function(path) return files[path] == true end,
    remove = function(path)
        remove_calls[#remove_calls + 1] = path
        if path == "/mnt/us/Offline/B-bbbbbbbb.jpg" then return nil, "denied" end
        files[path] = nil
        return true
    end,
    make_path = function() return true end,
}
local store = {
    readSetting = function(_, key, fallback)
        if key == "entries" then
            return {
                ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\0/mnt/us/Offline"] = {
                    namespace = "webdavmanga-offline-v1", owned = true,
                    key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", identity = "source-a",
                    remote_path = "/remote/A.jpg", manga_path = "/Books/A",
                    manga_name = "A", root = "/mnt/us/Offline",
                    local_path = "/mnt/us/Offline/A-aaaaaaaa.jpg", size = 10,
                    extension = "jpg", format = "jpeg", width = 10, height = 10,
                },
                ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0/mnt/us/Offline"] = {
                    namespace = "webdavmanga-offline-v1", owned = true,
                    key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", identity = "source-a",
                    remote_path = "/remote/B.jpg", manga_path = "/Books/B",
                    manga_name = "B", root = "/mnt/us/Offline",
                    local_path = "/mnt/us/Offline/B-bbbbbbbb.jpg", size = 10,
                    extension = "jpg", format = "jpeg", width = 10, height = 10,
                },
                ["cccccccccccccccccccccccccccccccc\0/mnt/us/Other"] = {
                    namespace = "webdavmanga-offline-v1", owned = true,
                    key = "cccccccccccccccccccccccccccccccc", identity = "other",
                    remote_path = "/remote/C.jpg", manga_path = "/Books/C",
                    manga_name = "C", root = "/mnt/us/Other",
                    local_path = "/mnt/us/Other/C-cccccccc.jpg", size = 10,
                    extension = "jpg", format = "jpeg", width = 10, height = 10,
                },
            }
        elseif key == "jobs" then
            return {
                ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\0/mnt/us/Offline"] = {
                    schema_version = 2, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\0/mnt/us/Offline",
                    identity = "source-a", root = "/mnt/us/Offline", manga_path = "/Books/A",
                    manga_name = "A", status = "complete",
                },
                ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0/mnt/us/Offline"] = {
                    schema_version = 2, key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0/mnt/us/Offline",
                    identity = "source-a", root = "/mnt/us/Offline", manga_path = "/Books/B",
                    manga_name = "B", status = "complete",
                },
            }
        end
        return fallback
    end,
    saveSetting = function() end,
    flush = function() flush_calls = flush_calls + 1 end,
}
local cache = OfflineCache:new{ store = store, root_provider = function() return "/mnt/us/Offline" end, fs = fs,
    md5 = function(value) return value:find("A") and string.rep("a", 32) or string.rep("b", 32) end }
local result = cache:delete_mangas("source-a", { "/Books/A", "/Books/B" })
expect(#result.deleted_paths == 1 and result.deleted_paths[1] == "/Books/A")
expect(#result.failed_paths == 1 and result.failed_paths[1] == "/Books/B")
expect(files["/mnt/us/Offline/A-aaaaaaaa.jpg"] == nil and files["/mnt/us/Offline/B-bbbbbbbb.jpg"] ~= nil)
expect(cache.entries["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0/mnt/us/Offline"] ~= nil)
expect(files["/mnt/us/Other/C-cccccccc.jpg"] ~= nil and files["/mnt/us/Offline/plain.jpg"] ~= nil)
expect(#remove_calls == 2 and flush_calls == 1, "one _flush call writes the batch")

local ui_confirm, shelf_shows, delete_calls = nil, 0, 0
local grid = { show = function(self, model) self.model = model; shelf_shows = shelf_shows + 1; return true end }
local ui = {
    confirm = function(_, model) ui_confirm = model end,
    show_info = function() end,
}
local library = UiLibrary:new{
    settings = { get_connection = function() return {} end }, library = { ALL = "all" },
    cover_service = {}, cover_grid = grid, browser = {}, ui = ui,
    identity_provider = function() return "source-a" end,
    offline_cache = {
        root = function() return "/mnt/us/Offline" end,
        list_mangas = function() return {
            { manga = { name = "A", path = "/Books/A" }, cover_path = "/mnt/us/Offline/A-aaaaaaaa.jpg" },
            { manga = { name = "B", path = "/Books/B" }, cover_path = "/mnt/us/Offline/B-bbbbbbbb.jpg" },
        } end,
        delete_mangas = function(_, identity, paths)
            delete_calls = delete_calls + 1
            expect(identity == "source-a" and #paths == 1 and paths[1] == "/Books/A")
            return { deleted_paths = paths, failed_paths = {} }
        end,
    },
    offline_manager = { status = function() return {
        running = true, identity = "source-a", root = "/mnt/us/Offline", manga_path = "/Books/B",
    } end },
}
library:show_offline_shelf()
expect(grid.model.allow_multi_select == true and type(grid.model.on_batch_action) == "function")
grid.model.on_batch_action({ grid.model.items[1], grid.model.items[2] })
expect(delete_calls == 0 and ui_confirm and ui_confirm.text:find("1", 1, true),
    "downloading manga must be rejected before confirmation")
ui_confirm.cancel_callback()
expect(shelf_shows == 2, "cancel after rejecting a manga reopens shelf")
grid.model.on_batch_action({ grid.model.items[1] })
expect(ui_confirm and type(ui_confirm.on_confirm) == "function" and type(ui_confirm.cancel_callback) == "function")
ui_confirm.cancel_callback()
expect(shelf_shows == 3, "cancel reopens shelf")
grid.model.on_batch_action({ grid.model.items[1] })
ui_confirm.on_confirm()
expect(delete_calls == 1 and shelf_shows == 4, "confirm deletes and reopens shelf")

local fallback_message
library.ui.confirm = nil
library.ui.show_info = function(_, message) fallback_message = message end
library:show_offline_shelf()
local calls_before_fallback = delete_calls
local shelves_before_fallback = shelf_shows
local fallback_result = grid.model.on_batch_action({ grid.model.items[1] })
expect(fallback_result == false and delete_calls == calls_before_fallback
    and fallback_message == "当前界面不支持删除确认，已取消删除。"
    and shelf_shows == shelves_before_fallback + 1,
    "missing confirmation adapter must cancel without deleting")

print(("rebuild_0357_offline_delete_spec: %d checks"):format(checks))
