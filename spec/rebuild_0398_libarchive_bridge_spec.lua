local Bridge = require("webdavmanga.document_bridge")
local BookIndex = require("webdavmanga.book_index")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local bridge = Bridge:new{
    cache = {},
    client_factory = function() return {} end,
    open_reader = function() return true end,
    archive_pages = {
        can_stream = function(_, kind)
            return kind == "cbr" or kind == "cb7" or kind == "rar" or kind == "7z"
        end,
        inspect_remote = function() end,
    },
}
for _, extension in ipairs({ "cbr", "cb7", "rar", "7z" }) do
    local capability = bridge:stream_capability{ name = "comic." .. extension }
    expect(capability.kind == "archive_pages" and capability.supported == true,
        extension .. " must use the Range-backed libarchive page adapter")
end

local fallback = Bridge:new{
    cache = {}, client_factory = function() return {} end,
    open_reader = function() return true end,
    archive_pages = { inspect_remote = function() end },
}
local native = fallback:stream_capability{ name = "comic.cbr" }
expect(native.kind == "mupdf_pages" or native.supported == false,
    "CBR without libarchive capability must retain a safe native fallback")

local temporary = {}
local function temp()
    local path = os.tmpname(); temporary[#temporary + 1] = path; return path
end
local opened, downloaded, error_message = 0, 0, nil
local records = {}
local JPEG = string.char(255,216,255,192,0,11,8,0,2,0,2,1,1,17,0,255,217)
local cache = {
    key_for = function(_, identity, path) return identity .. "|" .. path end,
    lookup_record = function(_, key) return records[key] and records[key].path, records[key] end,
    paths_for = function()
        local final, part = temp(), temp(); os.remove(final); os.remove(part)
        return final, part
    end,
    discard_part = function() return true end,
    clear_matching_cache = function() return true end,
    publish = function(_, record, part)
        local final = temp(); os.remove(final)
        assert(os.rename(part, final)); record.path = final; records[record.key] = record; return final
    end,
    remove = function(_, key) if records[key] then os.remove(records[key].path);records[key]=nil end;return true end,
}
local archive_pages = {
    can_stream = function(_, kind) return kind == "rar" end,
    inspect_remote = function(_, descriptor, kind, path, options)
        expect(kind == "rar" and path == "/comic.rar"
            and descriptor.read_at(0, 4) == "data",
            "RAR inspection must receive a live Range reader")
        local output = assert(io.open(options.opening_targets[1], "wb")); output:write(JPEG); output:close()
        return { layout = "archive_images", total_pages = 1,
            opening_metadata = {{size=#JPEG,format="jpeg",width=2,height=2}},
            index = BookIndex.from_items({{
            name = "001.jpg", path = path .. "#archive/1", is_file = true,
            archive_kind = "libarchive", archive_format = "rar",
            archive_remote_path = path, archive_source_size = 100,
            archive_entry_name = "001.jpg", archive_entry_ordinal = 1,
            archive_size = #JPEG,
        }}) }
    end,
    extract_remote = function(_, image, read_at, target)
        expect(image.archive_entry_ordinal == 1 and read_at(0, 4) == "data",
            "RAR first page must be extracted by ordinal through Range")
        local file = assert(io.open(target, "wb")); file:write("JPEG"); file:close()
        return { size = 4, format = "jpeg", width = 2, height = 2 }
    end,
}
local routed = Bridge:new{
    cache = cache,
    archive_pages = archive_pages,
    file_size = function(path)
        local file=io.open(path,"rb");if not file then return 0 end
        local size=file:seek("end");file:close();return size
    end,
    client_factory = function()
        return {
            connection = {},
            read_range = function(_, _, first, last)
                local bytes = (first == 0 and last >= 3) and "data" or string.rep("x", last - first + 1)
                return bytes, { ["Content-Range"] = ("bytes %d-%d/100"):format(first, last) }
            end,
            download_document = function() downloaded = downloaded + 1 end,
        }
    end,
    async = { run = function(work, done)
        done(true, work()); return { cancel = function() end }
    end },
    open_reader = function(context)
        opened = opened + 1
        expect(context.layout == "archive_images"
            and context.chapter_index:get(1).archive_kind == "libarchive",
            "RAR must reach the WebDAV manga image reader after index serialization")
        return true
    end,
}
expect(routed:open({ name = "comic.rar", path = "/comic.rar", size = 100,
    file_kind = "document", connection = {} }, {
    on_error = function(message) error_message = message end,
}) == true and opened == 1 and downloaded == 0 and error_message == nil,
    "RAR streaming must not fall back to a complete document download")
for _, path in ipairs(temporary) do os.remove(path) end

print(("rebuild_0398_libarchive_bridge_spec: %d checks"):format(checks))
