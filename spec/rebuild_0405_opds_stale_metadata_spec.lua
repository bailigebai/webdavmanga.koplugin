local Ui = require("webdavmanga.ui_opds")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local source = { id = "source", server_kind = "suwayomi", url = "https://fixture.invalid/api/v1/opds" }
local function chapter(id, streamed)
    return { id = "urn:chapter:" .. id, name = "Chapter " .. id, kind = "volume",
        href = source.url .. "/chapter/" .. id,
        stream = streamed and { template = "https://fixture.invalid/api/v1/manga/4/chapter/" .. id
            .. "/page/{pageNumber}", count = 27 } or nil }
end
local function scenario(action)
    local a, b = chapter("10"), chapter("11", true)
    local feed = { id = "urn:manga:4", title = "Series", entries = { a, b } }
    local jobs, dialogs, pointers, history, progress = {}, {}, {}, {}, {}
    local menu, context, opens = nil, nil, 0
    local ui = Ui:new{
        catalog = { get = function() return source end, fetch = function(_, _, url)
            expect(url == a.href, "only the selected lazy chapter requests metadata")
            return { entries = { chapter("10", true) } }
        end },
        async = { run = function(work, done)
            local job = { work = work, done = done, cancel = function(self) self.cancelled = true end }
            jobs[#jobs + 1] = job; return job
        end },
        pointer = { save = function(_, descriptor)
            local path = "/pointers/" .. descriptor.chapter_id .. ".meguru"
            pointers[path] = descriptor; return path
        end, load = function(_, path) return pointers[path] end },
        reader = { open = function(_, next_context)
            opens, context = opens + 1, next_context
            -- Reader boundary: opening the selected chapter makes its first page visible.
            history[#history + 1] = next_context.chapter.chapter_id
            progress[next_context.chapter.chapter_id] = next_context.initial_page
            return true
        end },
        ui = { show_menu = function(_, model) menu = model; return true end,
            show_resume = function(_, model) dialogs[#dialogs + 1] = model; return true end,
            close_menu = function() end, show_info = function() end },
    }
    ui:_show_feed(source, feed, "Series", nil, source.url .. "/manga/4")
    local a_item, b_item
    for _, item in ipairs(menu.items) do
        if item.text == a.name then a_item = item end
        if item.text == b.name then b_item = item end
    end
    a_item.callback()
    expect(#jobs == 1 and #dialogs == 0, "A metadata is pending before any resume choice")
    local stale = jobs[1]
    if action == "select" or action == "choice" then
        b_item.callback()
        expect(#dialogs == 1, "B immediately presents its own resume choice")
        if action == "select" then expect(dialogs[1].items[1].callback(), "B enters Reader") end
    elseif action == "handoff" then
        local descriptor = assert(ui.driver.resolve(source, ui:_driver_context(), b))
        expect(ui:open_descriptor(descriptor, source, { page = 5 }), "direct pointer handoff opens B")
    elseif action == "close" then
        menu.on_close()
    elseif action == "switch" then
        ui:cancel()
    end
    local previous_context, previous_opens, previous_dialogs = context, opens, #dialogs
    -- Cancellation alone is insufficient: a queued/native completion may still arrive.
    local ok, value = pcall(stale.work); stale.done(ok, value)
    expect(#dialogs == previous_dialogs, action .. ": late A metadata never reopens A resume dialog")
    expect(stale.cancelled, action .. ": superseded metadata HTTP work is cancelled")
    expect(context == previous_context and opens == previous_opens,
        action .. ": late A cannot replace the current Reader")
    expect(progress["urn:chapter:10"] == nil and #history == previous_opens,
        action .. ": late A never writes history or progress")
    expect(pointers["/pointers/urn:chapter:10.meguru"] == nil,
        action .. ": late A never creates a pointer")
end
for _, action in ipairs({ "select", "choice", "handoff", "close", "switch" }) do scenario(action) end
print("rebuild_0405_opds_stale_metadata_spec: " .. checks .. " checks")
