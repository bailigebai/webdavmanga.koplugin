local Pdf = require("webdavmanga.pdf_image_stream")
local checks = 0
local function expect(value, message) checks = checks + 1; assert(value, message) end
local function jpeg(width, height)
    return string.char(255,216,255,192,0,11,8,math.floor(height/256),height%256,
        math.floor(width/256),width%256,1,1,17,0,255,217)
end
local function fixture(options)
    options = options or {}
    local count = options.count or 1
    local pdf, offsets = "%PDF-1.4\n", {}
    local function add(n, body)
        offsets[n] = #pdf
        pdf = pdf .. n .. " 0 obj\n" .. body .. "\nendobj\n"
    end
    local kids = {}
    for page = 1, count do kids[#kids+1] = (3 + (page-1)*4) .. " 0 R" end
    local content_array_number = 3 + count * 4
    add(1, "<< /Type /Catalog /Pages 2 0 R " .. (options.catalog_extra or "") .. " >>")
    add(2, "<< /Type /Pages /Count " .. count .. " /Kids [" .. table.concat(kids," ") .. "] >>")
    for page = 1, count do
        local n = 3 + (page-1)*4
        local watermark = options.watermark
        local contents = options.content_array and page == 1 and content_array_number or n + 3
        add(n, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents " .. contents
            .. " 0 R " .. (options.page_extra or "") .. " /Resources << " .. (options.resources_extra or "")
            .. " /XObject << /Main " .. (n+1) .. " 0 R "
            .. (watermark and ("/Mark " .. (n+2) .. " 0 R ") or "") .. ">> >> >>")
        local bytes = options.flate and "compressed" or jpeg(100,100)
        if options.bad_page == page then bytes = "broken" end
        add(n+1, "<< /Subtype /Image /Width " .. (options.width or 100)
            .. " /Height 100 /BitsPerComponent " .. (options.bits or 8) .. " /ColorSpace "
            .. (options.color or "/DeviceGray") .. " /Filter /" .. (options.filter or (options.flate and "FlateDecode" or "DCTDecode"))
            .. " " .. (options.image_extra or "") .. " /Length " .. #bytes .. " >>\nstream\n" .. bytes .. "\nendstream")
        local side = options.equal and 100 or options.near and 95 or 5
        local mark = options.mark_flate or (options.bad_mark and "broken" or jpeg(side,side))
        add(n+2, "<< /Subtype /" .. (options.form and "Form" or "Image")
            .. " /Width " .. side .. " /Height " .. side
            .. (options.mark_flate and " /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode"
                or " /Filter /DCTDecode") .. " /Length " .. #mark
            .. " >>\nstream\n" .. mark .. "\nendstream")
        local content = options.content or ("q 100 0 0 100 0 0 cm /Main Do Q"
            .. (watermark and " q 5 0 0 5 0 0 cm /Mark Do Q" or ""))
        add(n+3, "<< /Length " .. #content .. " >>\nstream\n" .. content .. "\nendstream")
        if count > 1 then pdf = pdf .. string.rep("% padding\n", 8000) end
    end
    if options.content_array then
        add(content_array_number, "[ 6 0 R" .. (options.content_array_extra or "") .. " ]")
    end
    local base_count = 2 + count * 4 + (options.content_array and 1 or 0)
    for position, body in ipairs(options.extra_objects or {}) do
        add(base_count + position, body)
    end
    local xref = #pdf
    local object_count = base_count + #(options.extra_objects or {})
    pdf = pdf .. "xref\n0 " .. (object_count + 1) .. "\n0000000000 65535 f \n"
    for n = 1, object_count do pdf = pdf .. ("%010d 00000 n \n"):format(offsets[n]) end
    pdf = pdf .. "trailer\n<< /Size " .. (object_count + 1) .. " /Root 1 0 R "
        .. (options.encrypted and "/Encrypt 4 0 R" or "") .. " >>\nstartxref\n" .. xref .. "\n%%EOF\n"
    return pdf
end
local function descriptor(bytes)
    return { size = #bytes, read_at = function(offset,count) return bytes:sub(offset+1,offset+count) end }
end
local target = os.tmpname()
local parser = Pdf:new()
local book, reason = parser:inspect_remote(descriptor(fixture{watermark=true}), "/book.pdf", target)
expect(book ~= nil, "large JPEG plus small watermark must stream: " .. tostring(reason))
local file = assert(io.open(target,"rb")); local actual = file:read("*a"); file:close(); os.remove(target)
expect(actual == jpeg(100,100), "dominant JPEG bytes must be preserved directly")

local strict = Pdf:new()
strict._dominant_image = function() error("strict success must not call compatibility") end
expect(strict:inspect_remote(descriptor(fixture()), "/strict.pdf") ~= nil, "strict JPEG remains first choice")
local indirect_array, indirect_error = Pdf:new():inspect_remote(
    descriptor(fixture{ content_array = true }), "/single-array.pdf")
expect(indirect_array ~= nil and indirect_error == nil,
    "one indirect /Contents array containing one stream is a valid image page")
local multiple_array = Pdf:new():inspect_remote(
    descriptor(fixture{ content_array = true, content_array_extra = " 6 0 R" }),
    "/multiple-array.pdf")
expect(multiple_array == nil, "multiple content streams are not silently discarded")
local compact_state = Pdf:new():inspect_remote(descriptor(fixture{
    resources_extra = "/ExtGState << /G3 7 0 R >>",
    extra_objects = { "<</BM/Normal/ca 1>>" },
    content = "q 100 0 0 100 0 0 cm /G3 gs /Main Do Q",
}), "/compact-state.pdf")
expect(compact_state ~= nil, "compact, fully opaque ExtGState preserves the image")
local clipped_content = "1 0 0 -1 0 100 cm q 10 10 80 80 re W* n q "
    .. "80 0 0 -80 10 90 cm 0 0 0 RG 0 0 0 rg /G3 gs /Main Do Q Q"
local clipped_options = {
    resources_extra = "/ExtGState << /G3 7 0 R >>",
    extra_objects = { "<</BM/Normal/ca 1>>" },
    content = clipped_content,
}
local clipped = Pdf:new():inspect_remote(descriptor(fixture(clipped_options)),
    "/clipped-single-image.pdf")
expect(clipped ~= nil, "upright single image with a blank page margin streams")
for label, content in pairs({
    cropped = clipped_content:gsub("10 10 80 80 re", "10 10 30 80 re"),
    rotated = clipped_content:gsub("1 0 0 %-1 0 100 cm", "0 1 -1 0 100 0 cm"),
    painted = clipped_content .. " BT (extra) Tj ET",
}) do
    local value = Pdf:new():inspect_remote(descriptor(fixture{
        resources_extra = clipped_options.resources_extra,
        extra_objects = clipped_options.extra_objects,
        content = content,
    }), "/unsafe-" .. label .. ".pdf")
    expect(value == nil, "margined-image path rejects " .. label)
end
local profile = string.char(0, 0, 0, 128) .. string.rep("\0", 12) .. "RGB "
    .. string.rep("\0", 16) .. "acsp" .. string.rep("\0", 88)
local profile_object = "<< /N 3 /Length " .. #profile
    .. " >>\nstream\n" .. profile .. "\nendstream"
local icc_target = os.tmpname()
local icc_book = Pdf:new():inspect_remote(descriptor(fixture{
    color = "[/ICCBased 7 0 R]", extra_objects = { profile_object },
}), "/icc.pdf", icc_target)
expect(icc_book ~= nil, "RGB ICCBased JPEG streams as an image")
local icc_file = assert(io.open(icc_target, "rb"))
local icc_jpeg = icc_file:read("*a"); icc_file:close(); os.remove(icc_target)
expect(icc_jpeg:find("ICC_PROFILE\0\1\1" .. profile, 1, true) ~= nil,
    "the extracted JPEG retains the PDF ICC profile")
expect(icc_book.index:get(1).pdf_image_offset == nil,
    "ICC JPEG must use the parser path rather than the direct Range-copy path")
local bad_icc = Pdf:new():inspect_remote(descriptor(fixture{
    color = "[/ICCBased 7 0 R]",
    extra_objects = { profile_object:gsub("/N 3", "/N 4") },
}), "/bad-icc.pdf")
expect(bad_icc == nil, "unsupported ICC component count is rejected")
local flate_icc = Pdf:new{
    decompress = function() return string.rep("x", 30000) end,
    encode_png = function() return true end,
}:inspect_remote(descriptor(fixture{
    flate = true, color = "[/ICCBased 7 0 R]",
    extra_objects = { profile_object },
}), "/flate-icc.pdf")
expect(flate_icc == nil, "ICC profile is not lost while converting Flate pixels to PNG")
for _, setting in ipairs({
    "0.5 g", "0.5 G", "0.2 0.4 0.6 rg", "0.2 0.4 0.6 RG",
    "0.1 0.2 0.3 0.4 k", "0.1 0.2 0.3 0.4 K",
}) do
    local content = "q " .. setting .. " 100 0 0 100 0 0 cm /Main Do Q"
    local value, error_code = Pdf:new():inspect_remote(descriptor(fixture{ content = content }),
        "/color-state.pdf")
    expect(value ~= nil and error_code == nil,
        "non-painting color state may precede a full-page image: " .. setting)
end
for _, setting in ipairs({ "2 0 0 rg", "0.2 0.4 rg", "/Pattern cs" }) do
    local content = "q " .. setting .. " 100 0 0 100 0 0 cm /Main Do Q"
    local value = Pdf:new():inspect_remote(descriptor(fixture{ content = content }),
        "/unsafe-state.pdf")
    expect(value == nil, "unsupported color state still fails closed: " .. setting)
end
strict._single_image_content = function() return nil, "pdf_object_read_failed" end
local unavailable, unavailable_reason = strict:inspect_remote(descriptor(fixture()), "/read-error.pdf")
expect(not unavailable and unavailable_reason == "pdf_object_read_failed",
    "strict errors other than pdf_page_not_image must not invoke compatibility")

for _, options in ipairs({
    {watermark=true,near=true}, {watermark=true,form=true}, {watermark=true,encrypted=true},
    {watermark=true,bad_mark=true},
    {watermark=true,page_extra="/Annots [99 0 R]"},
    {watermark=true,resources_extra="/Font << /F1 99 0 R >>"},
    {watermark=true,catalog_extra="/OpenAction 99 0 R"},
    {watermark=true,image_extra="/SMask 99 0 R"},
    {watermark=true,image_extra="/F (https://example.com/external)"},
    {watermark=true,filter="JPXDecode"},
    {watermark=true,content="q 100 0 0 100 0 0 cm /Main Do Q BT (x) Tj ET"},
    {watermark=true,content="q 100 0 0 100 0 0 cm /Main Do Q 0 0 1 1 re f"},
    {watermark=true,content="q 100 0 0 100 0 0 cm /Main Do /Main Do Q"},
    {flate=true,image_extra="/DecodeParms << /Predictor 12 >>"},
    {flate=true,color="/DeviceCMYK"},
    {flate=true,bits=16}, {flate=true,width=1000000},
}) do
    local rejected, err = Pdf:new():inspect_remote(descriptor(fixture(options)), "/unsafe.pdf")
    expect(not rejected and type(err)=="string", "ambiguous/unsafe PDF must be refused")
end
for _, options in ipairs({ {watermark=true,near=true}, {watermark=true,equal=true} }) do
    local value, err = Pdf:new():inspect_remote(descriptor(fixture(options)), "/ambiguous.pdf")
    expect(not value and err=="pdf_multiple_images", "equal and near-equal candidates have a stable ambiguity reason")
end
local corrupt = fixture{watermark=true}:gsub("4 0 obj", "9 0 obj", 1)
expect(not Pdf:new():inspect_remote(descriptor(corrupt),"/corrupt.pdf"), "corrupt object identity must fail")

-- The host has no FFI PNG encoder. Inject only that external boundary; the
-- production parser must supply exactly bounded pixels and probe the PNG file.
local png = string.char(137).."PNG\r\n"..string.char(26).."\n"
    .. string.char(0,0,0,13).."IHDR"..string.char(0,0,0,100,0,0,0,100,8,0,0,0,0,85,137,202,136)
    .. string.char(0,0,0,33,73,68,65,84,120,156,237,193,129,0,0,0,0,195,160,249,83,95,225,0,
        85,1,0,0,0,0,0,0,0,0,0,143,1,39,116,0,1,44,92,137,22)
    .. string.char(0,0,0,0).."IEND"..string.char(174,66,96,130)
for _, color in ipairs({ "/DeviceGray", "/DeviceRGB" }) do
    local components = color=="/DeviceGray" and 1 or 3
    local called = 0
    local flate = Pdf:new{ decompress=function(bytes,capacity)
        expect(bytes=="compressed" and capacity==10000*components,"Flate capacity equals bounded pixel size")
        return string.rep("x",capacity)
    end, encode_png=function(path,pixels,width,height,n)
        called=called+1
        expect(width==100 and height==100 and n==components and #pixels==10000*components,
            "encoder receives declared gray/RGB pixels")
        local out=assert(io.open(path,"wb")); out:write(png); out:close(); return true
    end }
    local value, err = flate:inspect_remote(descriptor(fixture{flate=true,color=color}),"/flate.pdf",target)
    os.remove(target)
    expect(value and called==1 and value.first_metadata.format=="png", "bounded Flate image streams as PNG: "..tostring(err))
    expect(value.index:get(1).pdf_page_object and not value.index:get(1).pdf_image_offset,
        "Flate remains lazy so an evicted opening page returns through the existing decoder, not raw JPEG Range copying")
end
for _, decode in ipairs({ function() return "short" end, function() error("broken zlib") end }) do
    local invalid = Pdf:new{decompress=decode,encode_png=function() error("must not encode invalid pixels") end}
    local value, err = invalid:inspect_remote(descriptor(fixture{flate=true}),"/bad-flate.pdf",target)
    os.remove(target)
    expect(not value and err=="pdf_image_decompress_failed", "bad Flate length/decoder exceptions fail closed")
end
for _, mode in ipairs({"corrupt","truncated","short","long","valid"}) do
    local bytes=fixture{watermark=true,mark_flate="small-flate-"..mode}
    local source=descriptor(bytes)
    local read_at=source.read_at
    local start=assert(bytes:find("small-flate-"..mode,1,true))-1
    local encodes,decodes=0,0
    if mode=="truncated" then
        source.read_at=function(offset,count)
            if offset==start then return nil end
            return read_at(offset,count)
        end
    end
    local parser=Pdf:new{decompress=function(encoded,capacity)
        decodes=decodes+1
        expect(encoded=="small-flate-"..mode and capacity==25,
            "every small Flate candidate is decoded with its exact bounded pixel capacity")
        if mode=="corrupt" then return nil,"invalid zlib stream" end
        return string.rep("x",mode=="short" and 24 or mode=="long" and 26 or 25)
    end,encode_png=function() encodes=encodes+1;error("unselected Flate must not be encoded") end}
    local value,err=parser:inspect_remote(source,"/watermark.pdf",target)
    os.remove(target)
    if mode=="valid" then
        expect(value and decodes==1,"valid bounded Flate watermark permits the dominant JPEG")
    else
        expect(not value and type(err)=="string",mode.." unselected Flate candidate rejects the whole page")
    end
    expect(encodes==0,"unselected Flate candidates are validated without PNG encoding")
end
print(("rebuild_0411_pdf_dominant_image_spec: %d checks"):format(checks))
return { fixture=fixture, descriptor=descriptor, jpeg=jpeg }
