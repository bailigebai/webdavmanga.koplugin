local ArchivePages = require("webdavmanga.archive_pages")
local BookIndex = require("webdavmanga.book_index")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local entries = {}
for index = 1, 45 do
    entries[index] = {
        name = ("%03d.jpg"):format(index), path = ("%03d.jpg"):format(index), mode = "file",
        size = 100 + index, index = index,
    }
end

local function fake_stream(limit)
    local cursor = 0
    return {
        available = function() return true end,
        open = function() cursor = 0; return {} end,
        next = function()
            cursor = cursor + 1
            return cursor <= limit and entries[cursor] or nil
        end,
        close = function() return true end,
    }
end

local partial, partial_error = ArchivePages:new{ archive_stream = fake_stream(21) }
    :inspect_remote({ size = 999, read_at = function() return "x" end },
        "7z", "/comic.7z", { page_limit = 20 })
expect(partial and not partial_error and partial.index:count() == 20,
    "first pass must expose twenty image pages: " .. tostring(partial_error))
expect(partial.incomplete == true and partial.total_pages == nil,
    "a stopped libarchive scan must expose an incomplete index")

local short, short_error = ArchivePages:new{ archive_stream = fake_stream(19) }
    :inspect_remote({ size = 999, read_at = function() return "x" end },
        "7z", "/short.7z", { page_limit = 20 })
expect(short and not short_error and short.index:count() == 19,
    "small archives must keep every available page")
expect(short.incomplete == false and short.total_pages == 19,
    "EOF before the limit must mark the index complete")

local exact, exact_error = ArchivePages:new{ archive_stream = fake_stream(20) }
    :inspect_remote({ size = 999, read_at = function() return "x" end },
        "7z", "/exact.7z", { page_limit = 20 })
expect(exact and not exact_error and exact.index:count() == 20,
    "an exact twenty-page archive must keep every page")
expect(exact.incomplete == false and exact.total_pages == 20,
    "an exact twenty-page archive must be complete instead of waiting forever")

local progress_counts = {}
local full, full_error = ArchivePages:new{ archive_stream = fake_stream(45) }
    :inspect_remote({ size = 999, read_at = function() return "x" end },
        "7z", "/background.7z", {
            progress_interval = 5,
            on_progress = function(index)
                progress_counts[#progress_counts + 1] = index:count()
                return true
            end,
        })
expect(full and not full_error and full.index:count() == 45,
    "a background scan must still produce the complete index")
expect(progress_counts[1] == 5 and progress_counts[4] == 20
    and progress_counts[5] == 25 and progress_counts[9] == 45,
    "a background scan must publish growing five-page index snapshots")

local live = BookIndex.from_items({ entries[1], entries[2] })
expect(live:replace_items({ entries[1], entries[2], entries[3] }) == true
    and live:count() == 3 and live:get(3).name == entries[3].path,
    "the reader's shared BookIndex must accept an atomic full-index replacement")
expect(live:replace_items({}) == false and live:count() == 3,
    "an invalid empty replacement must leave the live index unchanged")

print(("rebuild_0409_progressive_archive_spec: %d checks"):format(checks))
