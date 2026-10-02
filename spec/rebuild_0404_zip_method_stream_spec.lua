local ArchivePages = require("webdavmanga.archive_pages")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end

local function unhex(hex)
    return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end
-- Real PNG and stdlib bz2/zlib compressed bytes, not arbitrary payloads.
local png = unhex("89504e470d0a1a0a0000000d4948445200000001000000010804000000b51c0c020000000b4944415478da63fcff1f0003030200efa35e2a0000000049454e44ae426082")
local png12 = unhex("425a6839314159265359952e0b7a00001ef7dbfc5e0014801036e1540148000040102008010200001000008004a0005452034698990c8c8c86c81aa7a4f50d347a801a62068084d94d6741002c200c855485316887662aae3f433edce7a889ac47c22cee710f7e01c92360d2a2ee48a70a1212a5c16f40")
local png8 = unhex("eb0cf073e7e592e2626060e0f5f4700902d28c20ccc10224b7caf03001296e4f17c7908a5bc97ffecb3330333331bc5f1ca7051466f074f57359e794d00400")
local opf = [[<package><manifest><item id="late" href="010.png" media-type="image/png"/><item id="early" href="002.png" media-type="image/png"/></manifest><spine><itemref idref="late"/><itemref idref="early"/></spine></package>]]
local opf12 = unhex("425a683931415926535910351e4a00001999805003f0072fef5c202000890951a262343688d0340aa9a213c53469a01ea334b8a218ad988d4dc0537da21420368e1ec5184cb3622255d0ff1394fd30ddf10cdf5d9a28872775584db2cfc96874592b2a5cf6d905176af06146abaecf7b3264a9cc843b307c38a981490f94c90f26182e727e2ee48a70a120206a3c94")
local function xor(a, b)
    local result, place = 0, 1
    for _ = 1, 32 do
        if a % 2 ~= b % 2 then result = result + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
    end
    return result
end
local function crc32(data)
    local crc = 4294967295
    for i = 1, #data do
        crc = xor(crc, data:byte(i))
        for _ = 1, 8 do
            local low = crc % 2
            crc = math.floor(crc / 2)
            if low == 1 then crc = xor(crc, 3988292384) end
        end
    end
    return 4294967295 - crc
end
local function le(value, count)
    local bytes = {}
    for i = 1, count do bytes[i] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(bytes)
end
local function zip(entries)
    local parts, central, offset = {}, {}, 0
    for _, entry in ipairs(entries) do
        local name, data, method = entry.name, entry.data or "", entry.method or 0
        local compressed = entry.compressed or data
        local common = le(0, 2) .. le(method, 2) .. le(0, 4) .. le(crc32(data), 4)
            .. le(#compressed, 4) .. le(#data, 4) .. le(#name, 2) .. le(0, 2)
        local part = "PK\003\004" .. le(46, 2) .. common .. name .. compressed
        parts[#parts + 1] = part
        central[#central + 1] = "PK\001\002" .. le(46, 2) .. le(46, 2) .. common
            .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 4) .. le(offset, 4) .. name
        offset = offset + #part
    end
    central = table.concat(central)
    return table.concat(parts) .. central .. "PK\005\006" .. le(0, 4)
        .. le(#entries, 2) .. le(#entries, 2) .. le(#central, 4) .. le(offset, 4) .. le(0, 2)
end
local function remote(bytes, work)
    return { size = #bytes, metadata_work_path = work,
        read_at = function(offset, count) return bytes:sub(offset + 1, offset + count) end }
end
local function absent(path)
    local file = io.open(path, "rb")
    if file then file:close(); return false end
    return true
end
-- Only replace the installed native archive boundary. Indexing, extraction
-- dispatch, disk I/O, CRC checks, EPUB validation and image probing stay real.
local function stream_for(entries, failure)
    return {
        available = function() return failure ~= "unavailable" end,
        open = function()
            if failure == "open" then return nil, "libarchive_open_failed" end
            if failure == "callback" then return nil, "libarchive_callback_unavailable" end
            if failure == "reader" then return nil, "libarchive_reader_unavailable" end
            return { cursor = 0 }
        end,
        next = function(_, reader)
            reader.cursor = reader.cursor + 1
            local entry = entries[reader.cursor]
            if not entry then return nil end
            return { name = failure == "name" and "wrong.png" or entry.name,
                index = failure == "ordinal" and reader.cursor + 1 or reader.cursor,
                size = #(entry.data or ""), mode = failure == "mode" and "other"
                    or entry.name:sub(-1) == "/" and "other" or "file" }
        end,
        extract_current = function(_, reader, target)
            local entry = entries[reader.cursor]
            -- A routing bug must not get successful data for method 0/8.
            if entry.method ~= 12 then return nil, "wrong_native_route" end
            local file = assert(io.open(target, "wb"))
            file:write(failure == "oversize" and string.rep("x", 1024 * 1024 + 1)
                or failure == "crc" and string.rep("x", #entry.data) or entry.data)
            file:close()
            if failure == "codec" then return nil, "archive_read_failed" end
            if failure == "throw" then error("native failure") end
            return { size = #entry.data }
        end,
        close = function() if failure == "close" then return false end; return true end,
    }
end

local entries = {
    { name = "pages/" },
    { name = "001.png", data = png },
    { name = "002.png", data = png, method = 8, compressed = png8 },
    { name = "003.png", data = png, method = 12, compressed = png12 },
}
local descriptor = remote(zip(entries))
local archive = ArchivePages:new{ archive_stream = stream_for(entries) }
local book, reason = archive:inspect_remote(descriptor, "zip", "/comic.zip")
expect(book and not reason and book.index:count() == 3,
    "unsupported pure-Lua ZIP methods must use installed libarchive: " .. tostring(reason))
expect(book.index:get(1).archive_kind == "zip" and book.index:get(2).archive_kind == "zip",
    "methods 0/8 must keep the existing ZIP path")
local page = book.index:get(3)
expect(page.archive_kind == "libarchive" and page.archive_entry_ordinal == 4
    and page.archive_entry_name == "003.png" and page.archive_format == "zip"
    and page.path == "/comic.zip#archive/4" and page.archive_source_size == descriptor.size,
    "fallback identity must retain the central-directory ordinal including directories")
local BookIndex = require("webdavmanga.book_index")
local manifest = book.index:to_table()
local restored = manifest and BookIndex.from_table(manifest)
expect(restored and restored:get(3).archive_method == 12
    and restored:get(3).archive_crc32 == page.archive_crc32,
    "mixed ZIP method 12 index must survive the manifest round trip")
local forged = assert(book.index:to_table())
local forged_item = forged.items[3]
forged_item.archive_format = "cbr"
forged_item.archive_crc32, forged_item.archive_method, forged_item.archive_flags = nil, nil, nil
forged_item.archive_local_offset, forged_item.archive_compressed_size = nil, nil
expect(not BookIndex.from_table(forged),
    "ZIP identity must not become CBR by changing archive_format and deleting CRC fields")
forged_item.archive_kind, forged_item.archive_format, forged_item.archive_method = "tar", nil, 0
forged_item.archive_entry_offset, forged_item.path = 0, "/comic.zip#tar/4"
expect(not BookIndex.from_table(forged),
    "ZIP identity must not become TAR by replacing kind, path, offset and deleting CRC fields")
for _, route in ipairs({
    { "zip", { zip = true, libarchive = true } },
    { "cbz", { zip = true, libarchive = true } },
    { "epub", { zip = true, libarchive = true } },
    { "cbt", { tar = true } },
    { "cbr", { libarchive = true } },
    { "rar", { libarchive = true } },
    { "cb7", { libarchive = true } },
    { "7z", { libarchive = true } },
}) do
    for _, extension in ipairs({ route[1], route[1]:upper() }) do
        for _, page_kind in ipairs({ "zip", "tar", "libarchive" }) do
            local item = assert(book.index:to_table()).items[3]
            item.archive_remote_path, item.archive_kind = "/comic." .. extension, page_kind
            local marker = page_kind == "libarchive" and "archive" or page_kind
            item.path = item.archive_remote_path .. "#" .. marker .. "/4"
            item.archive_format = page_kind == "libarchive" and route[1] or nil
            if page_kind == "zip" then
                item.archive_method, item.archive_compressed_size = 0, #png
            elseif page_kind == "tar" then
                item.archive_method, item.archive_entry_offset = 0, 0
                item.archive_crc32, item.archive_flags = nil, nil
                item.archive_local_offset, item.archive_compressed_size = nil, nil
            end
            local accepted = BookIndex.from_table({ version = 1, count = 1, items = { item } }) ~= nil
            expect(accepted == (route[2][page_kind] == true),
                "archive route must bind remote extension " .. extension .. " to page kind " .. page_kind)
        end
    end
end
for _, kind in ipairs({ "zip", "cbz", "epub", "cbr", "rar", "cb7", "7z" }) do
    for _, extension in ipairs({ kind, kind:upper() }) do
        local item = assert(book.index:to_table()).items[3]
        item.archive_format, item.archive_remote_path = kind, "/comic." .. extension
        item.path = item.archive_remote_path .. "#archive/4"
        if kind ~= "zip" and kind ~= "cbz" and kind ~= "epub" then
            item.archive_crc32, item.archive_method, item.archive_flags = nil, nil, nil
            item.archive_local_offset, item.archive_compressed_size = nil, nil
        end
        expect(BookIndex.from_table({ version = 1, count = 1, items = { item } }),
            "libarchive identity must accept its matching case-insensitive remote extension: " .. extension)
        item.archive_remote_path, item.path = "/comic", "/comic#archive/4"
        expect(not BookIndex.from_table({ version = 1, count = 1, items = { item } }),
            "libarchive identity must reject a remote path without its format extension")
    end
end
for _, invalid in ipairs({ "archive_crc32", "archive_compressed_size", "archive_local_offset",
    "archive_flags", "archive_method", "encrypted", "offset", "stored", "deflated", "pure_zip" }) do
    local value = assert(book.index:to_table())
    local item = value.items[3]
    if invalid == "encrypted" then item.archive_flags = 1
    elseif invalid == "offset" then item.archive_local_offset = descriptor.size - 1
    elseif invalid == "stored" then item.archive_method = 0
    elseif invalid == "deflated" then item.archive_method = 8
    elseif invalid == "pure_zip" then item.archive_kind = "zip"; item.path = "/comic.zip#zip/4"
    else item[invalid] = nil end
    expect(not BookIndex.from_table(value), "ZIP fallback manifest must reject invalid " .. invalid)
end
local target = os.tmpname()
os.remove(target)
local metadata = archive:extract_remote(page, descriptor.read_at, target)
expect(metadata and metadata.format == "png" and metadata.width == 1,
    "method 12 must extract and pass the real image probe")
os.remove(target)
for _, corruption in ipairs({ "crc", "size" }) do
    local wrong_page = {}
    for key, value in pairs(page) do wrong_page[key] = value end
    if corruption == "crc" then wrong_page.archive_crc32 = 0
    else wrong_page.archive_size = #png + 1 end
    local failed, err = archive:extract_remote(wrong_page, descriptor.read_at, target)
    expect(not failed and err == (corruption == "crc" and "zip_crc_mismatch" or "zip_size_mismatch"),
        "valid fallback PNG must still reject central-directory " .. corruption .. " mismatch")
    expect(absent(target), "fallback integrity failure must remove the valid but wrong PNG")
end
local wrong_content_stream = stream_for(entries)
wrong_content_stream.extract_current = function(_, _, path)
    local file = assert(io.open(path, "wb"))
    -- Keep the valid PNG header and byte count, change an IDAT byte.
    file:write(png:sub(1, 45) .. string.char((png:byte(46) + 1) % 256) .. png:sub(47))
    file:close(); return { size = #png }
end
local wrong_content, wrong_content_error = ArchivePages:new{ archive_stream = wrong_content_stream }
    :extract_remote(page, descriptor.read_at, target)
expect(not wrong_content and wrong_content_error == "zip_crc_mismatch" and absent(target),
    "fallback PNG with valid image metadata but wrong bytes must fail ZIP CRC validation")
local no_next_stream = stream_for(entries)
no_next_stream.next = nil
local no_next, no_next_error = ArchivePages:new{ archive_stream = no_next_stream }
    :extract_remote(page, descriptor.read_at, target)
expect(not no_next and no_next_error == "zip_unsupported_method" and absent(target),
    "adapter without next must retain stable ZIP unsupported-method error")
expect(archive:extract_remote(book.index:get(1), descriptor.read_at, target),
    "stored siblings must still extract with the existing CRC-validated ZIP path")
os.remove(target)
archive.archiver = { Reader = { new = function() return {
    open = function(_, path)
        local file = assert(io.open(path, "rb")); local header = file:read(10); file:close()
        return header:sub(1, 4) == "PK\003\004" and header:byte(9) == 8
    end,
    next = function() return true end,
    extractToPath = function(_, _, path)
        local file = assert(io.open(path, "wb")); file:write(png); file:close(); return true
    end,
    close = function() return true end,
} end } }
expect(archive:extract_remote(book.index:get(2), descriptor.read_at, target),
    "deflated siblings must still extract through the existing one-entry ZIP and CRC validation")
expect(absent(target .. ".zipwork"), "deflated sibling extraction must remove its one-entry ZIP")
os.remove(target)
local pure = { entries[2], entries[3] }
local pure_book = ArchivePages:new{ archive_stream = stream_for(pure, "unavailable") }
    :inspect_remote(remote(zip(pure)), "cbz", "/pure.cbz")
expect(pure_book and pure_book.index:count() == 2, "pure methods 0/8 must not require libarchive")
for _, kind in ipairs({ "cbz", "zip" }) do
    local rejected, err = ArchivePages:new{ archive_stream = stream_for(entries, "unavailable") }
        :inspect_remote(descriptor, kind, "/comic." .. kind)
    expect(not rejected and err == "zip_unsupported_method", "unavailable adapter must preserve ZIP error")
end
for _, failure in ipairs({ "name", "ordinal", "mode", "codec", "open", "callback", "reader", "throw", "close" }) do
    local failed, err = ArchivePages:new{ archive_stream = stream_for(entries, failure) }
        :extract_remote(page, descriptor.read_at, target)
    local expected = (failure == "name" or failure == "ordinal" or failure == "mode")
        and "archive_entry_mismatch" or failure == "close" and "archive_read_failed"
        or "zip_unsupported_method"
    expect(not failed and err == expected, "fallback must reject " .. failure .. ": " .. tostring(err))
    expect(absent(target), "failed fallback must remove partial output: " .. failure)
end

-- EPUB requires the same native lexer boundary as the established EPUB spec.
-- Reuse its installed preload when running in Lua 5.1; LuaJIT may load real luxl.
if not pcall(require, "luxl") then
    local source = assert(io.open("spec/rebuild_0374_epub_pages_spec.lua", "rb"))
    local prelude = source:read("*a"); source:close()
    local start = assert(prelude:find('package.preload["luxl"]', 1, true))
    local finish = assert(prelude:find("local function xor32", start, true))
    assert(loadstring(prelude:sub(start, finish - 1)))()
end
local epub_entries = {
    { name = "META-INF/container.xml", data = [[<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]] },
    { name = "OEBPS/content.opf", data = opf, method = 12, compressed = opf12 },
    { name = "OEBPS/002.png", data = png, method = 8, compressed = png8 },
    { name = "OEBPS/010.png", data = png, method = 12, compressed = png12 },
}
local work = os.tmpname()
os.remove(work)
local epub_descriptor = remote(zip(epub_entries), work)
local epub_archive = ArchivePages:new{ archive_stream = stream_for(epub_entries) }
local epub, epub_error = epub_archive:inspect_remote(epub_descriptor, "epub", "/comic.epub")
expect(epub and not epub_error and epub.index:count() == 2,
    "EPUB metadata method 12 must use libarchive: " .. tostring(epub_error))
expect(epub.index:get(1).archive_entry_name == "OEBPS/010.png"
    and epub.index:get(1).archive_kind == "libarchive"
    and epub.index:get(1).archive_entry_ordinal == 4
    and epub.index:get(2).archive_entry_name == "OEBPS/002.png"
    and epub.index:get(2).archive_kind == "zip", "mixed EPUB pages must retain OPF spine order")
expect(absent(work), "successful EPUB metadata extraction must remove its work file")
for _, reader_method in ipairs({ false, true }) do
    local limited_stream = stream_for(epub_entries)
    local decoded = 0
    local function extract(_, _, path, max_bytes)
        local native_reader = {
            archive = {}, current = { name = "OEBPS/content.opf", mode = "file", size = #opf },
            consumed = false, closed = false,
            ffi = { new = function() return {} end,
                string = function(buffer, count) return buffer.bytes:sub(1, count) end },
            libarchive = { archive_read_data = function(_, buffer, count)
                count = math.min(count, 8 * 1024 * 1024 - decoded)
                buffer.bytes = string.rep("x", count); decoded = decoded + count
                return count
            end },
        }
        return require("webdavmanga.archive_stream"):new():extract_current(native_reader, path, max_bytes)
    end
    limited_stream.extract_current = extract
    if reader_method then
        local open = limited_stream.open
        limited_stream.extract_current = nil
        limited_stream.open = function(...)
            local reader = open(...)
            reader.extract_current = function(self, path, max_bytes) return extract(nil, self, path, max_bytes) end
            return reader
        end
    end
    local failed, err = ArchivePages:new{ archive_stream = limited_stream }
        :inspect_remote(epub_descriptor, "epub", "/comic.epub")
    expect(not failed and err == "epub_metadata_too_large" and absent(work),
        "oversized metadata must stop extraction and remove the temporary file")
    expect(decoded <= 1024 * 1024 + 2,
        "metadata must enforce the limit during native decoding, including reader-method fallback")
end
for _, failure in ipairs({ "codec", "throw", "name", "ordinal", "oversize", "crc", "close", "unavailable" }) do
    local failed, err = ArchivePages:new{ archive_stream = stream_for(epub_entries, failure) }
        :inspect_remote(epub_descriptor, "epub", "/comic.epub")
    local expected = (failure == "name" or failure == "ordinal") and "archive_entry_mismatch"
        or failure == "oversize" and "epub_metadata_too_large"
        or failure == "crc" and "zip_crc_mismatch"
        or failure == "close" and "archive_read_failed" or "zip_unsupported_method"
    expect(not failed and err == expected, "EPUB fallback must reject " .. failure .. ": " .. tostring(err))
    expect(absent(work), "failed EPUB metadata extraction must remove its work file: " .. failure)
end
-- os.tmpname may create the file; an adapter open failure still owns cleanup.
local allocated = os.tmpname()
local allocated_file = assert(io.open(allocated, "wb")); allocated_file:close()
local temporary_archive = ArchivePages:new{ archive_stream = stream_for(epub_entries, "open"),
    temp_name = function() return allocated end }
local temporary_book, temporary_error = temporary_archive:inspect_remote(
    remote(zip(epub_entries)), "epub", "/comic.epub")
expect(not temporary_book and temporary_error == "zip_unsupported_method",
    "temporary metadata adapter open failure must retain the unsupported-method error")
expect(absent(allocated), "metadata work allocated before adapter open failure must be removed")

for _, failure in ipairs({ "open", "read", "close", "cleanup" }) do
    local options = { archive_stream = stream_for(epub_entries) }
    if failure == "cleanup" then
        options.remove_file = function() return nil, "denied" end
    else
        options.open_file = function(path, mode)
            if failure == "open" then return nil end
            local file = assert(io.open(path, mode))
            return {
                read = function(_, count)
                    if failure == "read" then error("read failure") end
                    return file:read(count)
                end,
                close = function()
                    file:close()
                    if failure == "close" then return nil, "close failure" end
                    return true
                end,
            }
        end
    end
    local failed, err = ArchivePages:new(options):inspect_remote(epub_descriptor, "epub", "/comic.epub")
    expect(not failed and err == (failure == "cleanup" and "zip_write_failed" or "zip_read_failed"),
        "metadata I/O " .. failure .. " must return a stable error: " .. tostring(err))
    if failure ~= "cleanup" then expect(absent(work), "metadata I/O failure must remove work: " .. failure) end
    os.remove(work)
end
-- Exercise the real ArchivePages -> manifest -> Bridge -> reader pipeline.
-- Only the native codecs, HTTP and the established host json boundary are doubles.
local encoded, serial = {}, 0
package.preload.json = function() return {
    encode = function(value)
        serial = serial + 1; local bytes = '{"fixture":' .. serial .. '}'
        encoded[bytes] = value; return bytes
    end,
    decode = function(bytes) return encoded[bytes] end,
} end
local function bridge_case(kind, archive_entries, markers, source_bytes)
    local bytes, files, records, tasks = source_bytes or zip(archive_entries), {}, {}, {}
    local remote_path = "/comic." .. kind
    local function temporary(data)
        local path = os.tmpname(); files[#files + 1] = path
        if data then local file = assert(io.open(path, "wb")); file:write(data); file:close() end
        return path
    end
    local cache = {
        key_for = function(_, identity, path, cache_kind)
            return identity .. "|" .. path .. "|" .. tostring(cache_kind or "page")
        end,
        lookup_record = function(_, key) local record = records[key]; return record and record.path, record end,
        paths_for = function() return temporary(), temporary() end,
        discard_part = function() end,
        publish = function(_, record, part)
            record.path = temporary(); os.remove(record.path); assert(os.rename(part, record.path))
            records[record.key] = record; return record.path
        end,
        clear_matching_cache = function(_, predicate)
            for key, record in pairs(records) do
                if predicate(record, key) then os.remove(record.path); records[key] = nil end
            end
            return true
        end,
    }
    local contexts, open_error = {}, nil
    local bridge = require("webdavmanga.document_bridge"):new{
        cache = cache, identity = "nas-u",
        archive_pages = ArchivePages:new{ archive_stream = stream_for(archive_entries), archiver = archive.archiver },
        client_factory = function() return { read_range = function(_, _, first, last)
            return bytes:sub(first + 1, last + 1), {
                ["content-range"] = ("bytes %d-%d/%d"):format(first, last, #bytes) }
        end } end,
        async = { run = function(work_fn, done)
            tasks[#tasks + 1] = function() local ok, value = pcall(work_fn); done(ok, value) end
            return { cancel = function() end }
        end },
        file_size = function(path)
            local file = io.open(path, "rb"); if not file then return 0 end
            local size = file:seek("end"); file:close(); return size
        end,
        open_reader = function(context) contexts[#contexts + 1] = context; return true end,
        ui_manager = { showReader = function() error("unexpected native reader") end },
    }
    local entry = { name = "comic." .. kind, path = remote_path, size = #bytes,
        etag = "v1", file_kind = "document",
        connection = { server_url = "http://nas", username = "u", root_path = "/" } }
    local callbacks = { on_error = function(err) open_error = err end }
    local next_task = 1
    local function finish_open(expected)
        while #contexts < expected and tasks[next_task] do
            tasks[next_task]()
            next_task = next_task + 1
        end
    end
    expect(bridge:open(entry, callbacks) == true, "real " .. kind .. " archive must start in Bridge")
    finish_open(1)
    expect(#contexts == 1 and not open_error, "real " .. kind .. " archive must open its CRC-validated first image")
    local manifest_count = 0
    for _, record in pairs(records) do
        if record.kind == "manifest" then
            manifest_count = manifest_count + 1
            local file = assert(io.open(record.path, "rb")); local value = encoded[file:read("*a")]; file:close()
            expect(value and BookIndex.from_table(value), "Bridge must persist a valid mixed-method manifest")
        end
    end
    expect(manifest_count == 1, "Bridge must publish the archive manifest")
    local stale = {}
    for _, marker in ipairs(markers) do
        for _, cache_kind in ipairs({ "page", "cover" }) do
            local path = remote_path .. marker .. "99"
            local key = cache:key_for("nas-u", path, cache_kind == "cover" and "cover" or nil)
            local record = { kind = cache_kind, remote_path = path, modified = "old", path = temporary("old") }
            records[key] = record; stale[#stale + 1] = { key, record.path }
        end
    end
    local same_path = remote_path .. markers[1] .. "98"
    local foreign_key = cache:key_for("other-nas", same_path)
    records[foreign_key] = { kind = "page", remote_path = same_path, modified = "old", path = temporary("foreign") }
    local current_key = cache:key_for("nas-u", same_path)
    records[current_key] = { kind = "page", remote_path = same_path,
        modified = tostring(#bytes) .. ":2:v2:", path = temporary("current") }
    local unrelated_key = cache:key_for("nas-u", "/other.zip#zip/99")
    records[unrelated_key] = { kind = "page", remote_path = "/other.zip#zip/99", modified = "old", path = temporary("other") }
    entry.etag = "v2"; bridge:open(entry, callbacks); finish_open(2)
    expect(#contexts == 2 and not open_error, "updated mixed archive must reopen")
    for _, old in ipairs(stale) do
        expect(not records[old[1]] and absent(old[2]),
            "source update must clear every actual archive marker: " .. old[1])
    end
    expect(records[foreign_key] and records[current_key] and records[unrelated_key],
        "mixed-marker cleanup must preserve identity, current version and other books")
    if markers[#markers] == "#archive/" then
        for _, forged_kind in ipairs({ "cbr", "tar" }) do
            local active_manifest_key, corrupted_path
            for key, record in pairs(records) do
                if record.kind == "manifest" and record.etag == "v2" then
                    active_manifest_key, corrupted_path = key, record.path
                    local file = assert(io.open(record.path, "rb")); local value = encoded[file:read("*a")]; file:close()
                    for _, item in ipairs(value.items) do
                        if item.archive_kind == "libarchive" then
                            item.archive_format = "cbr"
                            item.archive_crc32, item.archive_method, item.archive_flags = nil, nil, nil
                            item.archive_local_offset, item.archive_compressed_size = nil, nil
                            if forged_kind == "tar" then
                                item.archive_kind, item.archive_format, item.archive_method = "tar", nil, 0
                                item.archive_entry_offset = (bytes:find(png, 1, true) or 1) - 1
                                item.path = remote_path .. "#tar/" .. item.archive_entry_ordinal
                            end
                        end
                    end
                end
            end
            local opened_before = #contexts
            bridge:open(entry, callbacks); finish_open(opened_before + 1)
            expect(#contexts == opened_before + 1 and not open_error and records[active_manifest_key].path ~= corrupted_path,
                "tampered cached archive identity must be discarded and re-inspected: " .. forged_kind
                    .. " contexts=" .. #contexts .. " tasks=" .. #tasks
                    .. " next=" .. next_task .. " error=" .. tostring(open_error and open_error.reason))
            for _, item in ipairs(contexts[#contexts].chapter_index.items) do
                if item.archive_kind == "libarchive" then
                    expect(item.archive_format == kind and item.archive_crc32 ~= nil,
                        "reader must receive the rebuilt ZIP identity and CRC, never the tampered cache")
                end
            end
        end
    end
    for _, path in ipairs(files) do os.remove(path) end
end
bridge_case("zip", entries, { "#zip/", "#archive/" })
bridge_case("cbz", { entries[4] }, { "#archive/" })
bridge_case("cbz", { entries[2] }, { "#zip/" })
bridge_case("epub", epub_entries, { "#zip/", "#archive/" })
local tar_header = "001.png" .. string.rep("\0", 93 + 24) .. ("%011o\0"):format(#png)
    .. string.rep("\0", 12) .. "        " .. "0" .. string.rep("\0", 355)
local tar_checksum = 0
for position = 1, #tar_header do tar_checksum = tar_checksum + tar_header:byte(position) end
tar_header = tar_header:sub(1, 148) .. ("%06o\0 "):format(tar_checksum) .. tar_header:sub(157)
bridge_case("cbt", {}, { "#tar/" }, tar_header .. png .. string.rep("\0", 512 - #png + 1024))

print(("rebuild_0404_zip_method_stream_spec: %d checks"):format(checks))
