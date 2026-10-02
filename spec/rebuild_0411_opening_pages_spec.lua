local Bridge = require("webdavmanga.document_bridge")
local BookIndex = require("webdavmanga.book_index")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local JPEG_BYTES = string.char(0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8,
    0, 1, 0, 1, 1, 1, 0x11, 0, 0xFF, 0xD9)

local function make_index(count)
    local items = {}
    for page = 1, count do
        items[page] = { name = page .. ".jpg", path = "/book.cbz#zip/" .. page }
    end
    return BookIndex.from_items(items)
end

local function fixture(count, failing_page, publish_fail_at, evict_first_on_second)
    local written, paths, extracted = {}, {}, {}
    local events, records, publish_count = {}, {}, 0
    local cache = {
        paths_for = function(_, key, _, token)
            local path = os.tmpname() .. "." .. token .. ".part"
            paths[#paths + 1] = path
            return path .. ".final", path
        end,
        discard_part = function() return true end,
        lookup_record = function(_, key)
            local record = records[key]
            return record and record.path, record
        end,
        publish = function(_, record, part_path)
            publish_count = publish_count + 1
            if publish_count == publish_fail_at then return nil, "disk_full" end
            if publish_count == 2 and publish_fail_at == "throw" then error("disk failure") end
            local file = io.open(part_path, "rb")
            expect(file ~= nil, "publisher receives staged bytes")
            if file then file:close() end
            events[#events + 1] = "publish_" .. record.remote_path
            record.path = part_path .. ".final"
            assert(os.rename(part_path, record.path))
            records[record.key] = record
            if publish_count == 2 and evict_first_on_second then
                local first = records["/book.cbz#zip/1"]
                os.remove(first.path)
                records[first.key] = nil
            end
            return part_path
        end,
        remove = function(_, key)
            local record = records[key]
            if record then os.remove(record.path); records[key] = nil end
            events[#events + 1] = "remove_" .. key
            return true
        end,
    }
    local bridge = Bridge:new{
        cache = cache,
        client_factory = function() end,
        file_size = function(path)
            local file = io.open(path, "rb")
            if not file then return 0 end
            local size = file:seek("end"); file:close()
            return size
        end,
    }
    local job = { token = "open-test", canceled = false, index_complete = true,
        key_for_page = function(_, page) return page.path end,
        record_for_page = function(_, page, metadata)
            return { key = page.path, kind = "page", remote_path = page.path,
                size = metadata.size, extension = "jpg", format = metadata.format,
                width = metadata.width, height = metadata.height }
        end }
    local function extract(page, target)
        extracted[#extracted + 1] = page.path
        local file = assert(io.open(target, "wb"))
        assert(file:write(JPEG_BYTES)); file:close()
        written[target] = true
        if #extracted == failing_page then return nil, "invalid_image" end
        return { format = "jpeg", width = 1, height = 1, size = #JPEG_BYTES }
    end
    return bridge, job, make_index(count), extract, paths, extracted,
        written, events, records
end

local function open_fake_format(bridge, job, index, extract)
    local staged, stage_error = bridge:_stage_opening_pages(job, index, 3, extract)
    if not staged then return nil, stage_error end
    local published, publish_error = bridge:_publish_opening_pages(job, staged)
    if not published then return nil, publish_error end
    return bridge.open_reader({ chapter_index = index })
end

for _, failing_page in ipairs({ false, 2, 3 }) do
    local bridge, job, index, extract, _, _, _, events, records
        = fixture(25, failing_page)
    local opened = 0
    bridge.open_reader = function(context)
        opened = opened + 1
        events[#events + 1] = "open"
        expect(context.chapter_index == index
            and records[index:get(1).path] and records[index:get(2).path]
            and records[index:get(3).path],
            "fake format hands Reader an index only after all opening records exist")
        return true
    end
    local result = open_fake_format(bridge, job, index, extract)
    expect((failing_page == false and result == true and opened == 1)
        or (failing_page ~= false and result == nil and opened == 0),
        "fake format never enters Reader after page two or three fails")
    for _, record in pairs(records) do os.remove(record.path) end
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(25, nil, nil, true)
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    local published = bridge:_publish_opening_pages(job, staged)
    expect(published == nil and next(records) == nil,
        "opening fails and rolls back if cache quota evicts an earlier staged page")
end

do
    local bridge, job, index, extract, _, extracted, _, events, records = fixture(25)
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    expect(#events == 0 and #extracted == 3,
        "no page is indexed while the opening set is still being validated")
    assert(bridge:_publish_opening_pages(job, staged))
    events[#events + 1] = "open"
    expect(#events == 4 and events[1] == "publish_/book.cbz#zip/1"
        and events[2] == "publish_/book.cbz#zip/2"
        and events[3] == "publish_/book.cbz#zip/3" and events[4] == "open",
        "Reader opens only after all three staged pages publish")
    for _, record in pairs(records) do
        local file = io.open(record.path, "rb")
        expect(file ~= nil, "published opening survives part-file cleanup")
        if file then file:close() end
        os.remove(record.path)
    end
end

do
    local bridge, job, index, extract, _, _, _, events, records = fixture(25, nil, 2)
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    local published, reason = bridge:_publish_opening_pages(job, staged)
    expect(published == nil and reason == "disk_full" and next(records) == nil,
        "partial publish rolls back every task-owned record before Reader entry")
    expect(events[1] == "publish_/book.cbz#zip/1"
        and events[2] == "remove_/book.cbz#zip/1",
        "rollback targets the page already published by this task")
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(25, nil, "throw")
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    local published = bridge:_publish_opening_pages(job, staged)
    expect(published == nil and next(records) == nil,
        "publisher exception rolls back records written earlier in the set")
end

do
    local bridge, job, index, _, paths, extracted, _, _, records = fixture(3, nil, 2)
    local staged = {}
    for position = 1, 3 do
        local page = index:get(position)
        local part = assert(bridge:_opening_part(job, page, position))
        local file = assert(io.open(part.part_path, "wb"))
        assert(file:write(JPEG_BYTES)); file:close()
        part.metadata = { format = "jpeg", width = 1, height = 1,
            size = #JPEG_BYTES }
        staged[position] = part
    end
    local published = bridge:_publish_opening_pages(job, staged, index)
    expect(published == nil and #extracted == 0 and next(records) == nil,
        "already extracted opening artifacts publish without a second extraction")
    for _, path in ipairs(paths) do
        local file = io.open(path, "rb")
        expect(file == nil, "failed external handoff cleans every supplied task-owned part")
        if file then file:close(); os.remove(path) end
    end
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(25)
    local one_page = assert(bridge:_stage_opening_pages(job, index, 1, extract))
    local published = bridge:_publish_opening_pages(job, one_page, index)
    expect(published == nil and next(records) == nil,
        "publisher rejects one supplied page when the index requires three")
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(1)
    job.index_complete = nil
    local staged = assert(bridge:_stage_opening_pages(job, index, 1, extract))
    local published = bridge:_publish_opening_pages(job, staged, index)
    expect(published == nil and next(records) == nil,
        "unknown total and incomplete one-page directory cannot open early")
end

for _, count in ipairs({ 1, 2 }) do
    local bridge, job, index, extract, _, _, _, _, records = fixture(count)
    job.index_complete = true
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    expect(bridge:_publish_opening_pages(job, staged, index) == true,
        "explicitly complete short directory opens its entire opening set")
    for _, record in pairs(records) do os.remove(record.path) end
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(1)
    job.total_pages = 25
    job.index_complete = false
    local staged = assert(bridge:_stage_opening_pages(job, index, 1, extract))
    local published = bridge:_publish_opening_pages(job, staged, index)
    expect(published == nil and next(records) == nil,
        "known total count prevents a partial one-page index from opening early")
end

do
    local bridge, job, index, extract, _, _, _, _, records = fixture(3)
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    staged[2].page = staged[1].page
    local published = bridge:_publish_opening_pages(job, staged, index)
    expect(published == nil and next(records) == nil,
        "publisher rejects duplicated or out-of-order opening pages")
end

for _, count in ipairs({ 1, 2, 3, 25 }) do
    local bridge, job, index, extract, paths, extracted = fixture(count)
    local staged = assert(bridge:_stage_opening_pages(job, index, 3, extract))
    local needed = math.min(count, 3)
    expect(#staged == needed and #extracted == needed,
        "opening stages exactly min(3, page count) before publishing")
    for page = 1, needed do
        expect(staged[page].page == index:get(page)
            and staged[page].metadata.size == #JPEG_BYTES
            and staged[page].part_path == paths[page],
            "each staged page retains its own page, metadata and part path")
    end
    expect(paths[1] ~= paths[2] and paths[2] ~= paths[3] or needed < 3,
        "opening pages have distinct task-owned part paths")
    for _, path in ipairs(paths) do os.remove(path) end
end

do
    local bridge, job, index, extract, paths = fixture(25)
    local staged = bridge:_stage_opening_pages(job, index, nil, extract)
    expect(staged and #staged == 3, "shared staging defaults to three opening pages")
    for _, path in ipairs(paths) do os.remove(path) end
end

do
    local bridge, job, index, _, paths = fixture(1)
    local part = assert(bridge:_opening_part(job, index:get(1), 1))
    bridge:_discard_opening_parts(job)
    local late = assert(io.open(part.part_path, "wb"))
    assert(late:write(JPEG_BYTES)); late:close()
    bridge:_discard_opening_parts(job)
    local surviving = io.open(part.part_path, "rb")
    expect(surviving == nil,
        "reap cleanup removes a late task-owned part after earlier cancellation cleanup")
    if surviving then surviving:close() end
    for _, path in ipairs(paths) do os.remove(path) end
end

for _, failing_page in ipairs({ 2, 3 }) do
    local bridge, job, index, extract, paths = fixture(25, failing_page)
    local staged, reason = bridge:_stage_opening_pages(job, index, 3, extract)
    expect(staged == nil and reason == "invalid_image",
        "a later opening-page failure rejects the whole staged set")
    for _, path in ipairs(paths) do
        local file = io.open(path, "rb")
        expect(file == nil, "failed opening removes every task-owned part")
        if file then file:close(); os.remove(path) end
    end
end

do
    local bridge, job, index, _, paths = fixture(3)
    local staged = bridge:_stage_opening_pages(job, index, 3, function(_, target)
        local file = assert(io.open(target, "wb"))
        assert(file:write("jpg")); file:close()
        return { format = "jpeg", width = 1, height = 1, size = 3 }
    end)
    expect(staged == nil, "metadata cannot make non-image bytes a valid opening page")
    for _, path in ipairs(paths) do os.remove(path) end
end

do
    local bridge, job, index, _, paths, _, _, _, records = fixture(1)
    local page = index:get(1)
    local part = assert(bridge:_opening_part(job, page, 1))
    local file = assert(io.open(part.part_path, "wb"))
    assert(file:write("jpg")); file:close()
    part.metadata = { format = "jpeg", width = 1, height = 1, size = 3 }
    local published = bridge:_publish_opening_pages(job, { part }, index)
    expect(published == nil and next(records) == nil,
        "external handoff also checks actual image bytes before publication")
    for _, path in ipairs(paths) do os.remove(path) end
end

do
    local bridge, job, index, _, _, _, _, _, records = fixture(1)
    local foreign_path = os.tmpname() .. ".foreign"
    local file = assert(io.open(foreign_path, "wb"))
    assert(file:write(JPEG_BYTES)); file:close()
    local page = index:get(1)
    local staged = { { page = page, key = page.path, extension = "jpg",
        token = job.token .. "_external", part_path = foreign_path,
        metadata = { format = "jpeg", width = 1, height = 1,
            size = #JPEG_BYTES } } }
    local published = bridge:_publish_opening_pages(job, staged, index)
    local surviving = io.open(foreign_path, "rb")
    expect(published == nil and next(records) == nil and surviving ~= nil,
        "unregistered external file is neither published nor deleted")
    if surviving then surviving:close() end
    os.remove(foreign_path)
end

do
    local bridge, job, index, extract, paths = fixture(25)
    local calls = 0
    local throwing_extract = function(page, target)
        calls = calls + 1
        if calls == 2 then
            local file = assert(io.open(target, "wb"))
            assert(file:write("partial")); file:close()
            error("decoder failed")
        end
        return extract(page, target)
    end
    local staged = bridge:_stage_opening_pages(job, index, 3, throwing_extract)
    expect(staged == nil, "extractor exception rejects the whole opening set")
    for _, path in ipairs(paths) do
        local file = io.open(path, "rb")
        expect(file == nil, "extractor exception cleans every task-owned part")
        if file then file:close(); os.remove(path) end
    end
end

do
    local bridge, job, index, extract, paths = fixture(25)
    local calls = 0
    local canceled_extract = function(page, target)
        calls = calls + 1
        local metadata = extract(page, target)
        if calls == 2 then job.canceled = true end
        return metadata
    end
    local staged = bridge:_stage_opening_pages(job, index, 3, canceled_extract)
    expect(staged == nil and calls == 2, "cancel stops opening before page three")
    for _, path in ipairs(paths) do
        local file = io.open(path, "rb")
        expect(file == nil, "cancel removes every task-owned part")
        if file then file:close(); os.remove(path) end
    end
end

print(("rebuild_0411_opening_pages_spec: %d checks"):format(checks))
