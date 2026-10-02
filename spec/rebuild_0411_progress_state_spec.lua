local BookIndex = require("webdavmanga.book_index")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function pages(count)
    local items = {}
    for position = 1, count do
        items[position] = { name = position .. ".jpg", path = "/" .. position .. ".jpg" }
    end
    return items
end

local index = BookIndex.from_items(pages(3))
expect(index:replace_items(pages(20), "request-a") == true
    and index:count() == 20 and index.generation == "request-a",
    "accepts_matching_progress_generation: first generation may grow from 3 to 20")
expect(index:replace_items(pages(21), "request-a") == true
    and index:count() == 21 and index:get(21).path == "/21.jpg",
    "accepts_matching_progress_generation: matching generation may keep growing")

local same_length_rewrite = pages(21)
same_length_rewrite[1].path = "/other-first.jpg"
expect(index:replace_items(same_length_rewrite, "request-a") == false
    and index:count() == 21 and index:get(1).path == "/1.jpg",
    "never_rewrites_available_items: equal-length snapshot preserves published page identity")
local growing_rewrite = pages(22)
growing_rewrite[2].path = "/other-second.jpg"
expect(index:replace_items(growing_rewrite, "request-a") == false
    and index:count() == 21 and index:get(2).path == "/2.jpg",
    "never_rewrites_available_items: longer snapshot preserves published prefix")

expect(index:replace_items(pages(22), "request-b") == false
    and index:count() == 21 and index.generation == "request-a",
    "rejects_stale_progress_generation: another request cannot replace this index")
expect(index:replace_items(pages(20), "request-a") == false
    and index:count() == 21 and index:get(21).path == "/21.jpg",
    "never_shrinks_available_items: a shorter partial snapshot cannot remove pages")

expect(index:replace_items(pages(2)) == true and index:count() == 2,
    "legacy replacements without a generation retain their original behavior")

print(("rebuild_0411_progress_state_spec: %d checks"):format(checks))
