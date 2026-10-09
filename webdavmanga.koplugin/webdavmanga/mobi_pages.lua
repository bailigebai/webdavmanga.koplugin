local Formats = require("webdavmanga.image_formats")
local ImageProbe = require("webdavmanga.image_probe")

local MobiPages = {}
MobiPages.__index = MobiPages

local READ_CHUNK = 64 * 1024
local MAX_IMAGE_PROBE = 256 * 1024
local MAX_EXTH_BYTES = 1024 * 1024

local function u16(bytes, position)
    if not bytes then return nil end
    local a, b = bytes:byte(position, position + 1)
    if not b then return nil end
    return a * 256 + b
end

local function u32(bytes, position)
    if not bytes then return nil end
    local a, b, c, d = bytes:byte(position, position + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function read_at(handle, offset, count)
    if not handle:seek("set", offset) then return nil end
    local bytes = handle:read(count)
    if type(bytes) ~= "string" or #bytes ~= count then return nil end
    return bytes
end

local function read_exact(read_fn, offset, count)
    if type(read_fn) ~= "function" then return nil end
    local chunks, position, remaining = {}, offset, count
    while remaining > 0 do
        local bytes = read_fn(position, remaining)
        if type(bytes) ~= "string" or #bytes == 0 then return nil end
        if #bytes > remaining then return nil end
        chunks[#chunks + 1] = bytes
        position, remaining = position + #bytes, remaining - #bytes
    end
    return table.concat(chunks)
end

local function inspect_image(self, read_fn, offset, size)
    local probe_size = math.min(size, READ_CHUNK)
    local last_error
    while probe_size > 0 do
        local prefix = read_exact(read_fn, offset, probe_size)
        if not prefix then return nil, "mobi_resource_read_failed" end
        local metadata, error_message = self.probe.inspect_bytes(prefix, nil, size)
        if metadata then return metadata end
        last_error = error_message
        if probe_size >= size or probe_size >= MAX_IMAGE_PROBE then break end
        probe_size = math.min(size, probe_size * 2)
    end
    return nil, last_error or "unknown_image_signature"
end

local function complete_remote_metadata(image, metadata, size)
    metadata.size = size
    if not ImageProbe.matches_extension(metadata.format,
            Formats.extension(image and image.name)) then
        metadata.extension_mismatch = true
    end
    return metadata
end

local Index = {}
Index.__index = Index

function Index:count()
    return #self.items
end

function Index:get(position)
    position = tonumber(position)
    if not position or position < 1 or position > #self.items
        or math.floor(position) ~= position then return nil end
    return self.items[position]
end

function Index:find(path, hint)
    hint = tonumber(hint)
    if hint and self.items[hint] and self.items[hint].path == path then return hint end
    for position, item in ipairs(self.items) do
        if item.path == path then return position end
    end
end

function Index:window(center, radius)
    center = math.max(1, math.min(#self.items, math.floor(tonumber(center) or 1)))
    radius = math.max(0, math.floor(tonumber(radius) or 0))
    local result = {}
    for position = math.max(1, center - radius), math.min(#self.items, center + radius) do
        result[#result + 1] = self.items[position]
    end
    return result
end

function MobiPages:new(options)
    options = options or {}
    return setmetatable({
        open_file = options.open_file or io.open,
        probe = options.image_probe or ImageProbe,
    }, self)
end

function MobiPages:index_from_items(items)
    if type(items) ~= "table" then return nil end
    return setmetatable({ items = items }, Index)
end

function MobiPages:_fixed_layout(read_fn, record_offset, record_size, record_head)
    local flags = u32(record_head, 129)
    if not flags or math.floor(flags / 64) % 2 ~= 1 then return false end
    local header_length = u32(record_head, 21)
    local exth_offset = header_length and 16 + header_length or nil
    if not exth_offset or exth_offset + 12 > record_size then return false end
    local header = read_exact(read_fn, record_offset + exth_offset,
        math.min(record_size - exth_offset, MAX_EXTH_BYTES))
    if not header or header:sub(1, 4) ~= "EXTH" then return false end
    local length, count = u32(header, 5), u32(header, 9)
    if not length or length < 12 or length > #header or not count or count > 4096 then
        return false
    end
    local position = 13
    for _ = 1, count do
        local kind, size = u32(header, position), u32(header, position + 4)
        if not kind or not size or size < 8 or position + size - 1 > length then
            return false
        end
        if kind == 122 then
            local value = header:sub(position + 8, position + size - 1)
                :match("^%s*(.-)%s*$"):lower()
            return value == "true" or value == "yes" or value == "1"
        end
        position = position + size
    end
    return false
end

local function inspect_source(self, file_size, read_fn, remote_path, mobi_path,
        lazy_remote)
    if type(file_size) ~= "number" or file_size < 94 then
        return nil, "short_mobi"
    end
    local header = read_exact(read_fn, 0, 78)
    if not header then return nil, "mobi_header_read_failed" end
    if header:sub(61, 68) ~= "BOOKMOBI" then
        return nil, "not_mobi"
    end
    local record_count = u16(header, 77)
    if not record_count or record_count < 2 then return nil, "invalid_record_table" end
    local table_bytes = read_exact(read_fn, 78, record_count * 8)
    if not table_bytes then return nil, "mobi_record_table_read_failed" end
    local offsets = {}
    for position = 1, record_count do
        local offset = u32(table_bytes, (position - 1) * 8 + 1)
        -- Equal offsets are valid zero-length PalmDB records.
        if not offset or offset < 78 + record_count * 8 or offset >= file_size
            or (offsets[position - 1] and offset < offsets[position - 1]) then
            return nil, "invalid_record_offset"
        end
        offsets[position] = offset
    end
    local record0_size = (offsets[2] or file_size) - offsets[1]
    local record_head = read_exact(read_fn, offsets[1],
        math.min(record0_size, lazy_remote and 216 or 160))
    if not record_head or #record_head < 132 or record_head:sub(17, 20) ~= "MOBI" then
        return nil, "missing_mobi_header"
    end
    if u16(record_head, 13) ~= 0 then return nil, "encrypted_mobi" end
    local text_length = u32(record_head, 5) or 0
    local text_records = u16(record_head, 9) or 0
    local first_resource = u32(record_head, 109)
    if first_resource == 4294967295 then first_resource = text_records + 1 end
    if not first_resource or first_resource < 1 or first_resource >= record_count then
        return nil, "invalid_first_resource"
    end
    local fixed_layout = self:_fixed_layout(read_fn, offsets[1], record0_size, record_head)
    local pages, image_bytes, resource_read_failed = {}, 0, false
    remote_path = tostring(remote_path or mobi_path or "mobi")
    local last_resource = record_count - 1
    if lazy_remote then
        -- KF8 multi-flow books place FDST before FLIS/FCIS. It is a flow
        -- index, not an image; single-flow headers may contain a garbage index.
        local fdst = u32(record_head, 193)
        local flows = u32(record_head, 197)
        if u32(record_head, 37) == 8 and flows and flows > 1 and fdst
            and fdst > first_resource and fdst <= last_resource then
            last_resource = fdst - 1
        end
        for _, position in ipairs({ 201, 209 }) do
            local tail_index = u32(record_head, position)
            if tail_index and tail_index ~= 4294967295
                and tail_index > first_resource and tail_index <= last_resource then
                last_resource = math.min(last_resource, tail_index - 1)
            end
        end
    end
    local first_metadata, lazy_extension
    if lazy_remote then
        local offset = offsets[first_resource + 1]
        local size = (offsets[first_resource + 2] or file_size) - offset
        local probe_error
        first_metadata, probe_error = inspect_image(self, read_fn, offset, size)
        lazy_extension = first_metadata
            and Formats.extension_for_format(first_metadata.format) or nil
        if not first_metadata or not lazy_extension
            or first_metadata.width < 320 or first_metadata.height < 320 then
            return nil, probe_error == "mobi_resource_read_failed"
                and probe_error or "not_image_mobi"
        end
    end
    for record_number = first_resource, last_resource do
        local offset = offsets[record_number + 1]
        local size = (offsets[record_number + 2] or file_size) - offset
        if size > 0 then
            local metadata, probe_error
            if lazy_remote then
                metadata = record_number == first_resource and first_metadata or nil
            else
                metadata, probe_error = inspect_image(self, read_fn, offset, size)
            end
            if probe_error == "mobi_resource_read_failed" then
                resource_read_failed = true
            end
            if lazy_remote or (metadata and metadata.width >= 320
                    and metadata.height >= 320) then
                local extension = metadata
                    and Formats.extension_for_format(metadata.format) or lazy_extension
                if extension then
                    pages[#pages + 1] = {
                        name = ("%05d.%s"):format(record_number, extension),
                        path = remote_path .. "#mobi/" .. tostring(record_number),
                        size = size, is_file = true,
                        format = metadata and metadata.format or nil,
                        width = metadata and metadata.width or nil,
                        height = metadata and metadata.height or nil,
                        mobi_path = mobi_path,
                        mobi_remote_path = not mobi_path and remote_path or nil,
                        mobi_source_size = not mobi_path and file_size or nil,
                        mobi_record = record_number, mobi_offset = offset,
                        mobi_size = size,
                    }
                    if not mobi_path then pages[#pages].remote_read_at = read_fn end
                    image_bytes = image_bytes + size
                end
            end
        end
    end
    if resource_read_failed and #pages == 0 then
        return nil, "mobi_resource_read_failed"
    end
    -- ponytail: old image MOBIs may omit fixed-layout metadata; page count and
    -- resource volume are the cheap signal until a real misclassification
    -- requires parsing their compressed markup.
    if (fixed_layout and #pages < 2)
        or (not fixed_layout and (#pages < 4 or image_bytes < text_length)) then
        return nil, "not_image_mobi"
    end
    return {
        index = self:index_from_items(pages),
        fixed_layout = fixed_layout, text_length = text_length,
    }
end

function MobiPages:inspect(path, remote_path)
    if type(path) ~= "string" or path == "" then return nil, "invalid_mobi_path" end
    local handle, open_error = self.open_file(path, "rb")
    if not handle then return nil, open_error or "open_failed" end
    local book, error_message = inspect_source(self, handle:seek("end"),
        function(offset, count) return read_at(handle, offset, count) end,
        remote_path, path)
    handle:close()
    return book, error_message
end

function MobiPages:inspect_lazy(path, remote_path)
    if type(path) ~= "string" or path == "" then return nil, "invalid_mobi_path" end
    local handle, open_error = self.open_file(path, "rb")
    if not handle then return nil, open_error or "open_failed" end
    local book, error_message = inspect_source(self, handle:seek("end"),
        function(offset, count) return read_at(handle, offset, count) end,
        remote_path, path, true)
    handle:close()
    return book, error_message
end

function MobiPages:inspect_remote(descriptor, remote_path)
    if type(descriptor) ~= "table" or type(descriptor.read_at) ~= "function" then
        return nil, "invalid_remote_mobi"
    end
    local file_size = tonumber(descriptor.size)
    if not file_size or file_size < 94 or file_size ~= math.floor(file_size) then
        return nil, "short_mobi"
    end
    return inspect_source(self, file_size, descriptor.read_at, remote_path, nil, true)
end

function MobiPages:extract(image, target_path)
    if type(image) ~= "table" or type(image.mobi_path) ~= "string"
        or type(target_path) ~= "string" then return nil, "invalid_mobi_page" end
    local source, open_error = self.open_file(image.mobi_path, "rb")
    if not source then return nil, open_error or "open_failed" end
    local metadata, error_message = self:extract_remote(image,
        function(offset, count) return read_at(source, offset, count) end,
        target_path)
    source:close()
    return metadata, error_message
end

function MobiPages:extract_remote(image, read_fn, target_path)
    if type(image) ~= "table" or type(read_fn) ~= "function" then
        return nil, "invalid_remote_mobi_page"
    end
    local offset = tonumber(image.mobi_offset)
    local size = tonumber(image.mobi_size or image.size)
    if not offset or not size or offset < 0 or size < 1
        or math.floor(offset) ~= offset or math.floor(size) ~= size then
        return nil, "invalid_mobi_page"
    end
    if type(target_path) ~= "string" or target_path == "" then
        local bytes = read_exact(read_fn, offset, size)
        if not bytes then
            return nil, "short_mobi_page"
        end
        local metadata, probe_error = self.probe.inspect_bytes(
            bytes:sub(1, MAX_IMAGE_PROBE), nil, size)
        if not metadata then return nil, probe_error end
        complete_remote_metadata(image, metadata, size)
        metadata.data = bytes
        return metadata
    end
    local target, target_error = self.open_file(target_path, "wb")
    if not target then return nil, target_error or "target_open_failed" end
    local position, remaining = offset, size
    local prefix, prefix_size = {}, 0
    local ok, error_value = true, nil
    while remaining > 0 do
        local amount = math.min(remaining, READ_CHUNK)
        local bytes = read_exact(read_fn, position, amount)
        if not bytes then
            ok, error_value = false, "short_mobi_page"
            break
        end
        if not target:write(bytes) then
            ok, error_value = false, "write_failed"
            break
        end
        if prefix_size < MAX_IMAGE_PROBE then
            local chunk = bytes:sub(1, MAX_IMAGE_PROBE - prefix_size)
            prefix[#prefix + 1] = chunk
            prefix_size = prefix_size + #chunk
        end
        position, remaining = position + amount, remaining - amount
    end
    local closed = target:close()
    if not ok or closed == false then
        os.remove(target_path)
        return nil, error_value or "write_failed"
    end
    local metadata, probe_error = self.probe.inspect_bytes(
        table.concat(prefix), nil, size)
    if not metadata then
        os.remove(target_path)
        return nil, probe_error
    end
    return complete_remote_metadata(image, metadata, size)
end

return MobiPages
