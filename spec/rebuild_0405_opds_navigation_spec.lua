local function expect(condition, message)
    assert(condition, message)
end

local shown = {}
local closes = {}
local ui_manager = {
    show = function(_self, widget) shown[#shown + 1] = widget end,
    close = function(_self, widget)
        closes[#closes + 1] = widget
        if widget.close_callback then widget.close_callback() end
    end,
}
local widget = { new = function(_self, model) return model end }
package.loaded["ui/widget/infomessage"] = widget
package.loaded["ui/widget/menu"] = widget
package.loaded["ui/widget/multiinputdialog"] = widget
package.loaded["ui/uimanager"] = ui_manager

local Ui = require("webdavmanga.ui_opds")
local root_url = "https://x/root"
local child_url = "https://x/child"
local entry = { id = "c1", name = "Komga", url = root_url }
local root_feed = { title = "根", entries = {
    { name = "子", kind = "series", href = child_url },
} }
local child_feed = { title = "子", entries = {
    { name = "卷", kind = "volume", href = "https://x/volume" },
} }
local fetches = {}
local fetch_handler = function(_url) return root_feed end
local catalog = {
    list = function() return { entry } end,
    active = function() return entry end,
    set_active = function() return true end,
    fetch = function(_self, _id, url)
        fetches[#fetches + 1] = url
        return fetch_handler(url)
    end,
}
local shelf_returns = 0
local ui = Ui:new{ catalog = catalog, reader = { open = function() end },
    async = { run = function(work, done)
        local ok, value = pcall(work); done(ok, value); return {cancel=function() end}
    end },
    open_category_shelf = function()
        shelf_returns = shelf_returns + 1
        return true
    end }
local adapter = ui.ui

local backs, child_backs = 0, 0
adapter:show_menu{ title = "父", items = {}, on_back = function() backs = backs + 1 end }
local parent = shown[#shown]
adapter:show_menu{ title = "子", items = {}, on_back = function() child_backs = child_backs + 1 end }
expect(backs == 0, "replacing the parent must not execute its back callback")
parent.close_callback()
expect(backs == 0, "a late parent close must remain inert")
parent.item_table[#parent.item_table].callback()
expect(backs == 0 and adapter.current_menu == shown[#shown],
    "a stale parent back action must not close the child")
shown[#shown].close_callback()
expect(child_backs == 1, "a real child dismissal must navigate back exactly once")
shown[#shown].close_callback()
expect(child_backs == 1, "a duplicate child close must stay inert")

local stale_actions = 0
adapter:show_menu{ title = "旧", items = {{ text = "动作", callback = function()
    stale_actions = stale_actions + 1
end }} }
local old_menu = shown[#shown]
adapter:show_menu{ title = "新", items = {} }
old_menu.item_table[1].callback()
expect(stale_actions == 0 and adapter.current_menu == shown[#shown],
    "a stale menu action must not change the active page")

shown, closes, fetches = {}, {}, {}
local nested = false
fetch_handler = function(url)
    if url == root_url and not nested then
        nested = true
        ui:open_url(entry, child_url, "子", nil, child_url)
        return root_feed
    end
    if url == child_url then return child_feed end
    return root_feed
end
ui:open_url(entry, root_url, "根", nil, root_url)
expect(ui.current and ui.current.feed == child_feed,
    "an older fetch completing last must not replace the child model")
expect(shown[#shown] and shown[#shown].title == "子",
    "an older fetch completing last must not replace the child menu")

shown, closes, fetches = {}, {}, {}
fetch_handler = function(url)
    if url == child_url then return child_feed end
    return root_feed
end
ui:open_catalog(entry)
local root_menu = shown[#shown]
root_menu.item_table[1].callback()
local child_menu = shown[#shown]
local count_before_refresh = #fetches
child_menu.item_table[#child_menu.item_table - 1].callback()
expect(#fetches == count_before_refresh + 1 and fetches[#fetches] == child_url,
    "refresh must fetch the visible child URL")
local refreshed_menu = shown[#shown]
refreshed_menu.item_table[#refreshed_menu.item_table].callback()
expect(fetches[#fetches] == root_url and shown[#shown].title == "Komga",
    "refresh must preserve the parent relation")

shown, closes, fetches = {}, {}, {}
local fail_child = true
fetch_handler = function(url)
    if url == child_url then
        if fail_child then
            fail_child = false
            return nil, "offline"
        end
        return child_feed
    end
    return root_feed
end
ui:open_catalog(entry)
shown[#shown].item_table[1].callback()
local error_menu = shown[#shown]
expect(error_menu.title == "OPDS 加载失败" and error_menu.item_table[1].text == "重试",
    "a failed child fetch must offer retry at the same level")
error_menu.item_table[1].callback()
expect(fetches[#fetches] == child_url and shown[#shown].title == "子",
    "retry must fetch the failed child URL")
shown[#shown].item_table[#shown[#shown].item_table].callback()
expect(fetches[#fetches] == root_url and shown[#shown].title == "Komga",
    "retry must preserve the parent relation")

shown, closes, fetches = {}, {}, {}
local volume_url = "https://x/volume"
local volume_feed = { title = "卷", entries = {
    { name = "1.jpg", kind = "page", image_url = "https://x/1.jpg" },
} }
fetch_handler = function(url)
    if url == volume_url then return volume_feed end
    if url == child_url then return child_feed end
    return root_feed
end
ui:open_catalog(entry)
shown[#shown].item_table[1].callback()
shown[#shown].item_table[1].callback()
expect(shown[#shown].title == "卷", "second-level child should be visible")
shown[#shown].item_table[#shown[#shown].item_table].callback()
expect(fetches[#fetches] == child_url and shown[#shown].title == "子",
    "first back must restore the immediate parent")
shown[#shown].item_table[#shown[#shown].item_table].callback()
expect(fetches[#fetches] == root_url and shown[#shown].title == "Komga",
    "second back must restore the grandparent")

shown, closes, fetches = {}, {}, {}
local empty_feed = { title = "空目录", entries = {} }
fetch_handler = function(url)
    if url == child_url then return empty_feed end
    return root_feed
end
ui:open_catalog(entry)
local visible_parent = shown[#shown]
local before_empty = #shown
visible_parent.item_table[1].callback()
expect(#shown == before_empty + 1 and shown[#shown].title == "子",
    "an empty child feed must replace the visible parent menu")
expect(ui.current and ui.current.feed == empty_feed,
    "the empty child menu must match the current model")
shown[#shown].item_table[#shown[#shown].item_table].callback()
expect(shown[#shown].title == "Komga",
    "an empty child feed must still allow returning to its parent")

shown, closes, fetches = {}, {}, {}
catalog.active = function() return nil end
ui:show_home()
expect(shown[#shown] and shown[#shown].text:find("连接设置", 1, true)
    and adapter.current_menu == nil,
    "without an active unified OPDS source, the adapter must direct users to connection settings")
catalog.active = function() return entry end

shown, closes, fetches = {}, {}, {}
local loading_parent
fetch_handler = function(url)
    if url == child_url then
        loading_parent.close_callback()
        return child_feed
    end
    return root_feed
end
ui:open_catalog(entry)
loading_parent = shown[#shown]
loading_parent.item_table[1].callback()
expect(shelf_returns == 0 and adapter.current_menu == shown[#shown] and shown[#shown].title == "子",
    "a replaced parent close callback during fetch must be inert; scheduled pending-menu cancellation is covered separately")

shown, closes, fetches = {}, {}, {}
local loading_home
fetch_handler = function(url)
    if url == child_url then loading_home.close_callback() end
    return root_feed
end
ui:show_home()
loading_home = shown[#shown]
loading_home.item_table[1].callback()
expect(#shown == 2 and adapter.current_menu == shown[#shown] and shelf_returns == 0,
    "a stale root close callback must not cancel or reopen the current child")

shown, closes, fetches = {}, {}, {}
local sensitive_url = "https://alice:supersecret@x/private?api_key=topsecret&chapter=42"
fetch_handler = function()
    return nil, { code = "http", http_status = 401,
        detail = "GET " .. sensitive_url .. " Authorization: Basic abc123" }
end
ui:open_url(entry, sensitive_url, sensitive_url, nil, sensitive_url)
local sensitive_error = shown[#shown]
expect(sensitive_error.title == "OPDS 加载失败",
    "failure title must not echo a query-bearing URL")
expect(sensitive_error.subtitle == "网络或服务器暂时不可用，请重试。"
    and not sensitive_error.subtitle:find("https://", 1, true)
    and not sensitive_error.subtitle:find("topsecret", 1, true)
    and not sensitive_error.subtitle:find("supersecret", 1, true)
    and not sensitive_error.subtitle:find("abc123", 1, true),
    "failure detail must show a safe cause without URL, query, or credentials")
fetch_handler = function() return nil, "GET " .. sensitive_url end
ui:open_url(entry, sensitive_url, sensitive_url, nil, sensitive_url)
expect(not shown[#shown].subtitle:find("topsecret", 1, true),
    "raw string transport errors must not leak a complete query")
catalog.get = function() return entry end
fetch_handler = function()
    return nil, { code = "transport", detail = "GET " .. sensitive_url }
end
ui:open_record{ manga = { opds_catalog_id = entry.id,
    opds_feed_url = sensitive_url } }
expect(not shown[#shown].text:find("topsecret", 1, true),
    "record reopen errors must not leak a complete query")

print("rebuild_0405_opds_navigation_spec: passed")
