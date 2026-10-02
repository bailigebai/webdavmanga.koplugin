-- Release gate: real Formats -> Browser -> Bridge -> ArchivePages -> BookIndex
-- -> Reader routing. Only HTTP, native FFI/codec, scheduler and UI/storage edges
-- are controlled. Injected native capability is NOT evidence about a device build.
local Formats = require("webdavmanga.image_formats")
local Bridge = require("webdavmanga.document_bridge")
local Browser = require("webdavmanga.ui_browser")
local ArchivePages = require("webdavmanga.archive_pages")
local ArchiveStream = require("webdavmanga.archive_stream")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function unhex(hex)
    return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
local png = unhex("89504e470d0a1a0a0000000d4948445200000001000000010804000000b51c0c020000000b4944415478da63fcff1f0003030200efa35e2a0000000049454e44ae426082")
local function le(value, count)
    local bytes = {}
    for i = 1, count do bytes[i] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function zip(failure)
    local name = failure == "mismatch" and "001.jpg" or "001.png"
    -- CRC32 of the fixed PNG above, independently calculated with Python zlib.
    local common = le(0, 2) .. le(0, 2) .. le(0, 4) .. le(failure == "decode" and 862265672 or 2441460739, 4)
        .. le(#png, 4) .. le(#png, 4) .. le(#name, 2) .. le(0, 2)
    local header = "PK\003\004" .. le(20, 2) .. common .. name
        .. (failure == "decode" and string.rep("x", #png) or png)
    local directory = "PK\001\002" .. le(20, 2) .. le(20, 2) .. common
        .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4)
        .. le(failure == "unsafe" and 4294967000 or 0, 4) .. name
    local bytes = header .. directory .. "PK\005\006" .. le(0, 4) .. le(1, 2) .. le(1, 2)
        .. le(#directory, 4) .. le(#header, 4) .. le(0, 2)
    if failure == "index" then return bytes:sub(1, #bytes - 5) end
    return bytes
end
local function tar(failure)
    local size = failure == "unsafe" and 999999 or #png
    local header = (failure == "mismatch" and "001.jpg" or "001.png")
        .. string.rep("\0", 93 + 24) .. ("%011o\0"):format(size)
        .. string.rep("\0", 12) .. "        " .. "0" .. string.rep("\0", 355)
    local checksum = 0
    for i = 1, #header do checksum = checksum + header:byte(i) end
    header = header:sub(1, 148) .. ("%06o\0 "):format(checksum) .. header:sub(157)
    if failure == "index" then header = header:sub(1, 124) .. "not-an-octal!" .. header:sub(137) end
    return header .. (failure == "decode" and string.rep("x", #png) or png) .. string.rep("\0", 512 - #png + 1024)
end
local function write(path, bytes)
    local file = assert(io.open(path, "wb")); file:write(bytes); file:close()
end
local function absent(path)
    local file = io.open(path, "rb"); if file then file:close(); return false end; return true
end
-- Minimal host JSON boundary, shared with the existing bridge integration specs.
local saved_json, encoded, serial = package.loaded.json, {}, 0
package.loaded.json = {
    encode = function(value) serial = serial + 1; local key = "{\"gate\":" .. serial .. "}"; encoded[key] = value; return key end,
    decode = function(key) return encoded[key] end,
}
local secrets = { "gate-user", "gate-password", "/private-gate/", "gate-title", "token=gate-query", "private-gate-host" }
local function native_stream(state, failure)
    if failure == "unavailable" then
        -- Fail the actual native loader, independent of host libarchive presence.
        return ArchiveStream:new{ ffi = {}, libarchive = nil }
    end
    local ffi = {
        new = function() return {} end,
        copy = function(buffer, bytes) buffer.bytes = bytes end,
        string = function(value, count) return type(value) == "table" and value.bytes:sub(1, count) or value end,
        cast = function(_, callback)
            if failure == "callback" then return nil end
            state.callbacks = state.callbacks + 1
            return setmetatable({ free = function() state.freed = state.freed + 1 end }, {
                __call = function(_, ...) return callback(...) end,
            })
        end,
    }
    local lib = {
        archive_read_new = function() state.allocated = state.allocated + 1; return { cursor = 0 } end,
        archive_entry_new = function() return {} end,
        archive_read_support_format_all = function() end,
        archive_read_support_filter_all = function() end,
        archive_read_set_seek_callback = function(handle, callback) handle.seek = callback; return 0 end,
        archive_read_open2 = function(handle, _, _, read)
            state.native_opens = state.native_opens + 1
            if failure == "codec" then return -1 end
            -- Invoke production read and seek callbacks; a routing stub cannot pass.
            handle.seek(handle, nil, 0, 0)
            if read(handle, nil, {}) <= 0 then return -1 end
            return 0
        end,
        archive_read_next_header2 = function(handle, entry)
            if failure == "index" then return -1 end
            handle.cursor = handle.cursor + 1
            if handle.cursor > 1 then return 1 end
            entry.name, entry.size = failure == "mismatch" and "001.jpg" or "001.png", #png
            if failure == "unsafe" then entry.size = 128 * 1024 * 1024 + 1 end
            return 0
        end,
        -- Some device codecs reject solid archives while skipping header data.
        archive_read_data_skip = function() return failure == "solid" and -1 or 0 end,
        archive_entry_pathname = function(entry) return entry.name end,
        archive_entry_size = function(entry) return entry.size end,
        archive_entry_filetype = function() return 32768 end,
        archive_read_data = function(handle, buffer)
            if failure == "solid" then return -1 end
            if handle.decoded then return 0 end
            handle.decoded = true
            buffer.bytes = failure == "decode" and string.rep("x", #png) or png
            return #buffer.bytes
        end,
        archive_read_close = function() state.native_closed = state.native_closed + 1; return 0 end,
        archive_free = function() return 0 end,
        archive_entry_free = function() return 0 end,
        archive_set_error = function() return 0 end,
    }
    return ArchiveStream:new{ ffi = ffi, libarchive = lib, formats = Formats }
end
local matrix = {
    { "cbz", "zip" }, { "zip", "zip" }, { "cbt", "tar" }, { "tar", "tar" },
    { "cbr", "libarchive" }, { "rar", "libarchive" }, { "cb7", "libarchive" }, { "7z", "libarchive" },
}
local function fixture(extension, adapter, failure, mupdf_available)
    local s = { tasks = {}, parts = {}, opening_parts = {}, finals = {}, records = {}, logs = {}, ranges = {}, downloads = 0,
        contexts = {}, prompts = 0, native_opens = 0, allocated = 0, native_closed = 0, callbacks = 0, freed = 0,
        closed = 0, mupdf_probes = 0, mupdf_calls = 0 }
    local bytes = adapter == "zip" and zip(failure) or adapter == "tar" and tar(failure)
        or (adapter == "libarchive" and "native fixture" .. string.rep("x", 140000))
    local entry = { name = "gate-title." .. extension, path = "/private-gate/gate-title." .. extension,
        size = #bytes, etag = "v1", file_kind = "document",
        connection = { server_url = "https://private-gate-host?token=gate-query", username = secrets[1], password = secrets[2] } }
    s.entry = entry
    local stream = native_stream(s, failure)
    local cache = {
        key_for = function(_, identity, path, kind) return identity .. "|" .. path .. "|" .. tostring(kind) end,
        lookup_record = function(_, key)
            for _, record in ipairs(s.records) do
                if record.key == key then return record.path, record end
            end
        end,
        paths_for = function(_, _, _, token)
            local path = os.tmpname(); os.remove(path); s.parts[#s.parts + 1] = path
            if token and token:find("_opening_", 1, true) then s.opening_parts[path] = true end
            return path .. ".final", path
        end,
        discard_part = function() end,
        clear_matching_cache = function() return true end,
        publish = function(_, record, path)
            local final = path .. ".final"; assert(os.rename(path, final))
            record.path = final; s.records[#s.records + 1] = record; s.finals[#s.finals + 1] = final
            return final
        end,
        remove = function(_, key)
            for index, record in ipairs(s.records) do
                if record.key == key then os.remove(record.path); table.remove(s.records, index); break end
            end
            return true
        end,
    }
    s.bridge = Bridge:new{
        cache = cache, identity = "gate-identity", archive_pages = ArchivePages:new{ archive_stream = stream },
        file_size = function(path)
            local file = io.open(path, "rb"); if not file then return 0 end
            local size = file:seek("end"); file:close(); return size
        end,
        mupdf_pages = { remote_capability = function()
                s.mupdf_probes = s.mupdf_probes + 1; return mupdf_available == true
            end,
            inspect_remote = function() s.mupdf_calls = s.mupdf_calls + 1; return nil, "mupdf_inspection_failed" end,
            inspect_local = function() return nil end },
        logger = { warn = function(...) local values = {...}; s.logs[#s.logs + 1] = table.concat(values, " ") end },
        client_factory = function() return {
            read_range = function(_, path, first, last)
                s.ranges[#s.ranges + 1] = { first, last }
                return bytes:sub(first + 1, last + 1), { ["Content-Range"] = ("bytes %d-%d/%d"):format(first, last, #bytes) }
            end,
            download_document = function(_, _, target)
                s.downloads = s.downloads + 1; write(target, bytes); return { size = #bytes }
            end,
        } end,
        async = { run = function(work, done, options)
            s.tasks[#s.tasks + 1] = { work = work, done = done, options = options }
            return { cancel = function() end }
        end },
        open_reader = function(context) s.contexts[#s.contexts + 1] = context; return true end,
        ui_manager = { showReader = function() s.native_reader = true; return true end },
    }
    local ui = {
        show_progress = function(_, model) s.progress = model; return { close = function() end } end,
        show_info = function(_, message) s.message = message end,
        confirm = function(_, model) s.prompt = model; s.prompts = s.prompts + 1; return true end,
    }
    s.browser = Browser:new{
        settings = { get_connection = function() return entry.connection end }, settings_ui = {}, directory_store = {}, ui = ui,
        open_reader = function() error("image-folder route unexpectedly used") end,
        open_document = function(item, callbacks)
            local fallback = callbacks.on_document_fallback_prompt
            callbacks.on_document_fallback_prompt = function(kind, reason, retry)
                s.reason, s.kind, s.retry = reason, kind, retry
                return fallback(kind, reason, retry)
            end
            return s.bridge:open(item, callbacks)
        end,
    }
    function s:start()
        self.browser:_open_document_with_progress(self.entry, {
            on_error = function(err) self.error = err end,
            on_closed = function() self.closed = self.closed + 1 end,
        })
    end
    function s:run(index)
        local task = assert(self.tasks[index]); local ok, result = pcall(task.work)
        task.done(ok, result, ok and nil or result); return task, result
    end
    function s:drain(first)
        local i = first or 1; while i <= #self.tasks do self:run(i); i = i + 1 end
    end
    function s:clean_parts(label)
        for _, path in ipairs(self.parts) do
            expect(absent(path) and absent(path .. ".zipwork"), label .. " must remove owned part/work")
        end
    end
    function s:seed_parts()
        for _, path in ipairs(self.parts) do
            write(path, "partial")
            if not self.opening_parts[path] then write(path .. ".zipwork", "work") end
        end
    end
    function s:cleanup()
        for _, path in ipairs(self.parts) do os.remove(path); os.remove(path .. ".zipwork") end
        for _, path in ipairs(self.finals) do os.remove(path) end
    end
    return s
end

-- Breaks: missing/uppercase routes, .7z sent to ZIP, capability overclaim,
-- broken manifest adapter identity, invalid first image and hidden full download.
for _, row in ipairs(matrix) do
    for _, extension in ipairs({ row[1], row[1]:upper() }) do
      for _, mupdf_available in ipairs({ false, true }) do
        local s = fixture(extension, row[2], nil, mupdf_available)
        expect(Formats.is_document(s.entry.name) and Formats.extension(s.entry.name) == row[1], extension .. " document classification")
        local cap = s.bridge:stream_capability(s.entry)
        expect(cap.supported and cap.kind == "archive_pages", extension .. " must advertise the real archive adapter")
        s:start(); s:drain()
        expect(#s.contexts == 1 and not s.error and s.prompts == 0 and s.downloads == 0,
            extension .. " must open real first image with zero complete downloads; reason=" .. tostring(s.reason)
                .. "; detail=" .. tostring(s.error and s.error.detail) .. "; message=" .. tostring(s.message))
        expect(s.mupdf_calls == 0, extension .. " archive must not try remote MuPDF")
        if row[2] == "libarchive" then
            expect(s.mupdf_probes == 0, extension .. " must not probe remote MuPDF capability; calls=" .. s.mupdf_probes)
        else
            expect(s.mupdf_probes == 1, extension .. " retains its existing capability probe")
        end
        local context = s.contexts[1]
        expect(context.layout == "archive_images" and context.chapter_index:count() == 1
            and context.chapter_index:get(1).archive_kind == row[2], extension .. " Reader adapter identity")
        expect(#s.ranges > 0, extension .. " must consume real Range reader")
        local expected_opens = 1 -- Every native archive stages opening images in one reader.
        expect((row[2] == "libarchive" and s.native_opens == expected_opens) or (row[2] ~= "libarchive" and s.native_opens == 0),
            extension .. " must select the native codec only for RAR/7z")
        local page, manifest
        for _, record in ipairs(s.records) do
            if record.kind == "page" then page = record elseif record.kind == "manifest" then manifest = record end
        end
        expect(page and page.width == 1 and page.height == 1 and manifest, extension .. " must validate PNG and publish manifest")
        s:clean_parts(extension .. " success")
        context.source_context.on_return()
        expect(s.closed == 1 and s.downloads == 0, extension .. " Reader close callback")
        s:clean_parts(extension .. " close")
        expect(s.allocated == s.native_closed and s.callbacks == s.freed, extension .. " releases native readers and callbacks")
        s:cleanup()
      end
    end
end

-- Missing libraries are injected below the real native loader, never inferred
-- from the developer machine. Solid here means a device rejecting the container.
local saved_ffi, saved_preload = package.loaded.ffi, package.preload.ffi
package.loaded.ffi = nil
package.preload.ffi = function() error("native unavailable") end
local reasons = {
    zip = { index = "zip_eocd_missing", unsafe = "zip_local_offset_invalid",
        decode = "unknown_image_signature", mismatch = "extension_signature_mismatch" },
    tar = { index = "tar_header_invalid", unsafe = "tar_entry_out_of_range",
        decode = "unknown_image_signature", mismatch = "extension_signature_mismatch" },
    libarchive = { unavailable = "libarchive_unavailable", codec = "libarchive_open_failed",
        callback = "libarchive_callback_unavailable", solid = "archive_skip_failed",
        index = "archive_header_failed", unsafe = "archive_no_images", decode = "unknown_image_signature",
        mismatch = "extension_signature_mismatch" },
}
for _, row in ipairs(matrix) do
    for failure, reason in pairs(reasons[row[2]]) do
        for _, extension in ipairs({ row[1], row[1]:upper() }) do
          for _, mupdf_available in ipairs({ false, true }) do
            for _, action in ipairs({ "confirm", "cancel", "back", "outside" }) do
                local label = extension .. "/" .. failure .. "/" .. action .. "/mupdf=" .. tostring(mupdf_available)
                local s = fixture(extension, row[2], failure, mupdf_available)
                if failure == "unavailable" then
                    expect(not s.bridge:stream_capability(s.entry).supported, label .. " cannot promise missing native codec")
                end
                s:start(); s:seed_parts(); local task, result = s:run(1)
                expect(s.mupdf_calls == 0, label .. " cannot attempt remote MuPDF before fallback")
                local expected_reason = failure == "solid" and row[2] == "libarchive"
                    and "archive_read_failed" or reason
                expect(s.prompt and s.reason == expected_reason and s.kind == row[1] and s.downloads == 0
                    and #s.tasks == 1 and #s.contexts == 0 and not s.native_reader,
                    label .. " must classify and wait; got " .. tostring(s.reason))
                expect(s.prompt.text:find(row[1]:upper(), 1, true), label .. " prompt names format")
                if failure == "codec" or failure == "unavailable" or failure == "callback" then
                    expect(s.prompt.text:find("设备", 1, true), label .. " explains device capability")
                end
                s:clean_parts(label)
                local visible = s.prompt.text .. table.concat(s.logs, "\n")
                for _, secret in ipairs(secrets) do expect(not visible:find(secret, 1, true), label .. " redacts " .. secret) end
                task.done(true, result)
                expect(s.prompts == 1 and s.downloads == 0, label .. " ignores duplicate completion")
                if action == "confirm" then
                    s.prompt.on_confirm(); s.prompt.on_confirm(); s.retry()
                    s:drain(2)
                    expect(s.downloads == 1 and s.prompts == 1, label .. " explicit confirmation downloads exactly once")
                else
                    -- Production ConfirmBox routes cancel/back/outside to this
                    -- same callback; the existing fallback suite covers widget wiring.
                    s.prompt.on_cancel(); s.prompt.on_confirm(); s.retry()
                    task.done(true, result); task.options.on_reaped()
                    expect(s.downloads == 0 and #s.tasks == 1 and #s.contexts == 0,
                        label .. " dismissal permanently invalidates late retry/completion")
                end
                s:clean_parts(label .. " terminal")
                expect(s.mupdf_calls == 0, label .. " cannot attempt remote MuPDF after fallback")
                if row[2] == "libarchive" then
                    expect(s.mupdf_probes == 0, label .. " cannot probe remote MuPDF before or after fallback")
                end
                expect(s.allocated == s.native_closed and s.callbacks == s.freed, label .. " releases native resources")
                s:cleanup()
            end
          end
        end
    end
end
package.loaded.ffi, package.preload.ffi = saved_ffi, saved_preload

-- Breaks: worker writes after cancellation/timeout resurrect a reader or leave
-- owned temporary files. The reaper must remove files created after first cleanup.
for _, row in ipairs(matrix) do
    for _, event in ipairs({ "cancel", "timeout", "close" }) do
        local s = fixture(row[1], row[2]); s:start(); s:seed_parts()
        local task = s.tasks[1]
        if event == "cancel" then s.progress.on_cancel()
        elseif event == "close" then s.bridge:cancel_all()
        else task.done(false, nil, "async timeout") end
        s:clean_parts(row[1] .. " " .. event)
        s:seed_parts(); task.options.on_reaped()
        s:clean_parts(row[1] .. " late reaper")
        task.done(true, { error = "archive_read_failed" })
        expect(s.downloads == 0 and #s.contexts == 0, row[1] .. " late worker cannot open/download")
        s:cleanup()
    end
end

-- Non-archive paths retain their classification and advertised engine.
local existing = fixture("cbz", "zip")
-- Keep this archive gate's independent MuPDF fallback case explicit. The
-- restored image-PDF capability is covered by the document stream suite.
existing.bridge.pdf_image_stream = {}
local existing_probes = 0
existing.bridge.mupdf_pages.remote_capability = function() existing_probes = existing_probes + 1; return true end
for _, row in ipairs({ { "pdf", "mupdf_pages" }, { "mobi", "mobi_images" },
    { "azw", "mobi_images" }, { "azw3", "mobi_images" }, { "epub", "archive_pages" } }) do
    local probes_before = existing_probes
    local cap = existing.bridge:stream_capability({ name = "book." .. row[1] })
    expect(Formats.is_document("book." .. row[1]) and cap.supported and cap.kind == row[2], row[1] .. " existing route preserved")
    expect(existing_probes == probes_before + 1, row[1] .. " existing capability probe preserved")
end
expect(Formats.is_image("page.PNG") and not Formats.is_document("page.PNG")
    and not Formats.is_document("image-folder"), "image files/folders must remain outside document routing")
existing:cleanup()
package.loaded.json = saved_json
print(("rebuild_0405_archive_gate_spec: %d checks"):format(checks))
