local M = {}

function M.license(reason, detail)
    return { code = "license", reason = tostring(reason or "unknown"), detail = detail }
end

function M.http(code, status)
    return { code = "http", http_status = tonumber(code), detail = status }
end

function M.transport(detail)
    local lowered = tostring(detail or ""):lower()
    local is_tls = lowered:find("tls", 1, true) ~= nil
        or lowered:find("certificate", 1, true) ~= nil
    local code = is_tls and "tls" or "transport"
    return { code = code, detail = detail }
end

function M.decode(detail)
    return { code = "decode", detail = detail }
end

function M.image_decode(detail, source_kind)
    return {
        code = "decode",
        detail = detail,
        resource_kind = "image",
        source_kind = source_kind,
    }
end

function M.empty(kind)
    return { code = "empty", kind = kind }
end

function M.storage(detail)
    return { code = "storage", detail = detail }
end

function M.invalid_path()
    return { code = "invalid_path" }
end

function M.local_path(detail)
    return { code = "local_path", detail = detail }
end

function M.document(stage, detail)
    return { code = "document", stage = stage, detail = detail }
end

-- Only these program-owned codes may cross the stream diagnostic boundary.
-- A pattern such as [a-z_]+ would also admit user names and remote filenames.
local stream_reasons = {}
for code in ([[
    ok stream_failed page_adapter_unavailable range_unavailable range_request_failed range_timeout
    range_length_mismatch range_past_eof content_range_missing content_range_mismatch
    invalid_range_offset invalid_range_length transport tls http storage invalid_path
    invalid_remote_size invalid_remote_mobi_size invalid_remote_zip_size invalid_remote_pdf_size
    invalid_remote_mupdf_size invalid_archive_index invalid_remote_mobi_index invalid_mupdf_index
    mupdf_remote_unavailable mupdf_inspection_failed pdf_inspection_failed
    archive_entry_invalid archive_entry_mismatch archive_entry_missing archive_entry_too_large
    archive_entry_unavailable archive_extract_failed archive_header_failed archive_image_invalid
    archive_no_images archive_read_failed archive_skip_failed archive_too_many_entries archive_write_failed
    archive_seek_unavailable archive_encrypted archive_codec_unsupported archive_truncated archive_range_read_failed
    encrypted_mobi epub_container_missing epub_continuation_invalid epub_continuation_too_large
    epub_continuation_write_failed epub_drm epub_metadata_too_large epub_not_image_book
    invalid_archive_source invalid_first_resource invalid_mobi_page invalid_mobi_path
    unknown_image_signature extension_signature_mismatch
    invalid_record_offset invalid_record_table invalid_remote_archive invalid_remote_mobi_page
    invalid_remote_mobi invalid_remote_pdf libarchive_callback_unavailable
    libarchive_extract_unavailable libarchive_next_unavailable libarchive_open_failed
    libarchive_reader_unavailable libarchive_unavailable missing_mobi_header
    mobi_header_read_failed mobi_record_table_read_failed mobi_resource_read_failed not_image_mobi not_mobi
    encrypted_document corrupt_document open_failed target_open_failed write_failed
    pdf_catalog_invalid pdf_encrypted pdf_first_page_invalid pdf_header_invalid
    pdf_image_dimensions_invalid pdf_image_filter_unsupported pdf_image_invalid
    pdf_image_length_unsupported pdf_image_range_invalid pdf_image_read_failed pdf_image_write_failed
    pdf_no_image pdf_multiple_images pdf_object_dictionary_missing pdf_object_missing pdf_object_read_failed
    pdf_object_stream_decompress_failed pdf_object_stream_filter_unsupported pdf_object_stream_invalid
    pdf_object_stream_member_invalid pdf_object_stream_member_missing pdf_object_stream_read_failed
    pdf_object_stream_too_large pdf_object_too_large pdf_page_count_mismatch pdf_page_count_too_large
    pdf_page_not_image pdf_page_tree_invalid pdf_pages_missing pdf_resources_missing pdf_root_missing
    pdf_startxref_missing pdf_tail_read_failed pdf_trailer_invalid pdf_trailer_missing pdf_xobject_missing
    pdf_xref_decompress_failed pdf_xref_filter_unsupported pdf_xref_invalid pdf_xref_length_mismatch
    pdf_xref_length_unsupported pdf_xref_read_failed pdf_xref_stream_unsupported pdf_xref_too_large
    tar_entry_invalid tar_entry_out_of_range tar_entry_too_large tar_header_invalid tar_image_invalid
    tar_no_images tar_read_failed tar_size_mismatch tar_too_many_entries
    zip_archiver_unavailable zip_crc_mismatch zip_directory_invalid zip_directory_too_large zip_encrypted
    zip_entry_invalid zip_entry_too_large zip_eocd_missing zip_extract_failed zip_image_invalid
    zip_local_header_invalid zip_local_offset_invalid zip_multidisk_unsupported zip_name_too_long
    zip_no_images zip_read_failed zip_size_mismatch zip_unsupported_method zip_write_failed zip64_unsupported
]]):gmatch("%S+") do stream_reasons[code] = true end

function M.stream_reason(value)
    if value == "async timeout" then return "range_timeout" end
    if type(value) == "table" then
        if value.code == "decode" or value.code == "document" then
            return M.stream_reason(value.detail)
        end
        value = value.code
    end
    return type(value) == "string" and stream_reasons[value] and value or "stream_failed"
end

local stream_formats = {
    pdf = true, epub = true, mobi = true, azw = true, azw3 = true,
    cbz = true, zip = true, cbt = true, tar = true,
    cbr = true, rar = true, cb7 = true, ["7z"] = true,
    xps = true, djvu = true, djv = true,
}
local stream_stages = {
    range_probe = true, pdf_index = true, zip_directory = true,
    epub_container = true, epub_spine = true, first_page = true, fallback = true,
}

function M.stream_stage(format, reason)
    local code = M.stream_reason(reason)
    if code == "transport" or code == "tls" or code == "http" or code == "archive_range_read_failed"
        or code:find("range_", 1, true) == 1
        or code:find("content_range_", 1, true) == 1 then return "range_probe" end
    if format == "pdf" and code:find("pdf_", 1, true) == 1 then return "pdf_index" end
    if code:find("zip_", 1, true) == 1 then return "zip_directory" end
    if code == "epub_container_missing" then return "epub_container" end
    if code:find("epub_", 1, true) == 1 then return "epub_spine" end
    if code:find("image", 1, true) then return "first_page" end
    return "fallback"
end

function M.stream(format, stage, reason)
    format = stream_formats[format] and format or "document"
    stage = stream_stages[stage] and stage or "fallback"
    reason = M.stream_reason(reason)
    return { code = "document", stage = "stream", format = format,
        stream_stage = stage, reason = reason, detail = format .. ":" .. reason }
end

function M.message(err)
    err = type(err) == "table" and err or { code = "unknown" }
    if err.code == "license" then
        local messages = {
            invalid_key = "密钥无效，请检查输入内容。",
            key_bound_to_other_device = "该密钥已绑定到其他设备。",
            rate_limited = "授权请求过于频繁，请稍后重试。",
            origin_not_allowed = "当前网络来源不被允许。",
            method_not_allowed = "请求方法不被允许。",
            service_unavailable = "授权服务暂时不可用，请稍后重试。",
            https_required = "授权连接必须使用 HTTPS。",
            dns_failed = "无法解析授权服务器地址，请检查网络。",
            timeout = "授权请求超时，请稍后重试。",
            tls_failed = "授权服务器证书验证失败，请检查系统时间和网络。",
            invalid_json = "授权服务返回的数据无效，请稍后重试。",
            invalid_response = "授权服务返回的数据不完整，请稍后重试。",
            response_too_large = "授权服务响应过大，已停止处理。",
            request_too_large = "授权请求过大，已停止发送。",
            redirect_rejected = "授权服务拒绝重定向，请检查服务地址。",
            invalid_request = "授权请求参数无效。",
            invalid_key_format = "密钥格式不正确，请输入 12 位短密钥。",
            invalid_key_character = "密钥包含不支持的字符，请检查输入内容。",
            device_id_unavailable = "无法读取或保存设备标识，请检查存储空间。",
            hash_unavailable = "当前 KOReader 缺少授权摘要能力。",
            hash_failed = "授权摘要计算失败，请重新启动 KOReader 后重试。",
            invalid_key_id = "授权服务返回的密钥标识不一致。",
            invalid_product = "授权不属于当前漫画插件。",
            invalid_device_id = "授权与当前设备不匹配。",
            invalid_signature = "授权签名验证失败，未解锁增值功能。",
            missing_verifier = "当前安装包缺少授权验签组件，请重新安装完整插件。",
            save_failed = "授权已验证，但本地保存失败，请检查存储空间。",
            http_error = "授权服务返回错误，请稍后重试。",
        }
        return messages[err.reason or err.error] or "授权服务返回错误，请稍后重试。"
    elseif err.code == "http" then
        if err.http_status == 401 then
            return "WebDAV 用户名或密码错误。"
        elseif err.http_status == 403 then
            return "WebDAV 账号没有访问该目录的权限。"
        elseif err.http_status == 404 then
            return "WebDAV 地址、漫画目录或远程文件不存在。"
        end
        return "WebDAV 服务器返回错误（HTTP " .. tostring(err.http_status or "未知") .. "）。"
    elseif err.code == "tls" then
        return "HTTPS 证书验证失败，请检查证书和 Kindle 系统时间。"
    elseif err.code == "transport" then
        return "网络连接失败或 WebDAV 服务器暂时不可用。"
    elseif err.code == "decode" then
        local detail = tostring(err.detail or ""):lower()
        if detail == "encrypted_document" then
            return "该漫画文档已加密，插件无法按页读取，将尝试交给 KOReader 原生阅读器。"
        elseif detail == "corrupt_document" then
            return "漫画文档损坏或无法解析，请检查文件完整性后重试。"
        elseif detail == "range_unavailable" then
            return "服务器不支持可靠的 HTTP Range，将切换为完整下载。"
        end
        if err.resource_kind == "image" and err.source_kind == "remote"
            and detail:find("mobi", 1, true) then
            return "远程 MOBI 图片记录读取失败，请检查文件完整性和 HTTP Range 支持后重试。"
        end
        if err.resource_kind == "image" and err.source_kind == "local" then
            return "Kindle 本地图片无法解码，请检查文件是否完整且格式受支持。"
        elseif err.resource_kind == "image" then
            return "WebDAV 图片下载不完整或无法解码，请重试；仍失败请检查图片文件和 HTTP Range 支持。"
        elseif err.detail == "extension_signature_mismatch" then
            if err.source_kind == "local" then
                return "图片扩展名与实际格式不一致，无法按文件名解码。"
            end
            return "远程图片扩展名与实际格式不一致，已拒绝加载。"
        end
        if err.source_kind == "local" then
            return "Kindle 本地图片或目录无法解码，请检查文件是否完整且格式受支持。"
        end
        return "WebDAV 目录响应无法解析，服务器可能不兼容。"
    elseif err.code == "empty" then
        if err.kind == "images" then return "该章节没有支持的图片。" end
        if err.kind == "chapters" then return "该目录没有支持的图片或章节文件夹。" end
        return "当前目录中没有子文件夹。"
    elseif err.code == "storage" then
        if err.detail == "cache_limit" or err.detail == "page_exceeds_cache_limit" then
            return "该图片大于缓存上限，请在阅读设置中调高缓存容量。"
        end
        return "缓存写入失败，请清理空间或调整缓存设置。"
    elseif err.code == "invalid_path" then
        return "远程路径超出 WebDAV 根目录，已阻止访问。"
    elseif err.code == "local_path" then
        return "Kindle 本地漫画目录不可用，请确认目录存在且未超出所选根目录。"
    elseif err.code == "document" then
        if err.stage == "stream" then
            if err.stream_stage then
                local reason = M.stream_reason(err.reason)
                if reason == "archive_encrypted" then return "该漫画压缩包已加密，无法按页流式读取；请先解密。未下载整本文件。" end
                if reason == "archive_codec_unsupported" then return "当前设备不支持该压缩包的压缩方式，无法流式读取；未下载整本文件。" end
                if reason == "archive_seek_unavailable" then return "当前设备不支持 7Z 随机定位，无法流式读取；未下载整本文件。" end
                if reason == "archive_truncated" then return "该漫画压缩包不完整或已损坏，请检查文件完整性；未下载整本文件。" end
                if reason == "range_timeout" then return "文档流式读取请求超时，请稍后重试；未下载整本文件。" end
                if reason == "transport" then return "网络无法连接到文档服务器，流式读取尚未开始；未下载整本文件。" end
                if reason == "tls" then return "文档服务器 TLS 证书验证失败，请检查证书和 Kindle 时间；未下载整本文件。" end
                if reason == "http" then return "文档服务器返回 HTTP 错误，无法继续流式读取；未下载整本文件。" end
                if err.stream_stage == "range_probe" then return "服务器没有返回可靠的 HTTP Range（206/Content-Range），无法流式打开；未下载整本文件。" end
                if err.stream_stage == "pdf_index" then return "PDF 结构不兼容或索引损坏，无法按图片页流式打开；未下载整本文件。" end
                if err.stream_stage == "zip_directory" then return "EPUB 的 ZIP 目录损坏或压缩方式不受支持；未下载整本文件。" end
                if err.stream_stage == "epub_container" then return "EPUB 缺少有效的 container.xml 或 OPF 路径；未下载整本文件。" end
                if err.stream_stage == "epub_spine" then return "EPUB 的 manifest/spine 不是可识别的单图片漫画结构；未下载整本文件。" end
                if err.stream_stage == "first_page" then return "文档第一页不是可解码的漫画图片；未下载整本文件。" end
            end
            local detail = tostring(err.detail or "")
            if detail:find(":libarchive_unavailable", 1, true)
                or detail:find(":libarchive_open_failed", 1, true)
                or detail:find(":libarchive_callback_unavailable", 1, true) then
                return "当前设备的 KOReader 缺少 RAR/7z 流式读取能力；可以选择完整下载后再打开。"
            elseif detail:find(":unknown_image_signature", 1, true)
                or detail:find(":extension_signature_mismatch", 1, true) then
                return "该压缩包的图片内容无效或与扩展名不符，无法流式读取；可以选择完整下载后再打开。"
            elseif detail:find(":tar_too_many_entries", 1, true)
                or detail:find(":archive_too_many_entries", 1, true)
                or detail:find(":zip_directory_too_large", 1, true) then
                return "该漫画压缩包条目过多，已超过安全解析上限；请拆分压缩包后重试。"
            elseif detail:find(":zip_encrypted", 1, true)
                or detail:find(":epub_drm", 1, true) then
                return "该漫画压缩包已加密，插件无法按页流式读取；请先解密或选择完整下载。"
            elseif detail:find(":zip_no_images", 1, true)
                or detail:find(":tar_no_images", 1, true)
                or detail:find(":archive_no_images", 1, true) then
                return "该压缩包中没有找到受支持的漫画图片。"
            end
            if detail:find(":range_", 1, true)
                or detail:find(":content_range_", 1, true) then
                return "服务器没有返回可靠的 HTTP Range（206/Content-Range），无法流式打开该文档；未下载整本文件。"
            elseif detail:find(":zip_unsupported_method", 1, true) then
                return "该压缩包使用了当前设备不支持的压缩方式；可以选择完整下载后再打开。"
            elseif detail:find(":encrypted_mobi", 1, true) then
                return "该电子书已加密，插件无法按页流式读取；可以选择完整下载后再打开。"
            elseif detail:find(":not_mobi", 1, true) or detail:find(":not_image_mobi", 1, true) then
                return "该电子书不是可识别的图片型 MOBI/AZW 容器；可以选择完整下载后再打开。"
            elseif detail:find("pdf:", 1, true) then
                return "该 PDF 不是插件可直接流式解析的图片型 PDF；可以选择完整下载后继续使用 WebDAV 漫画阅读器打开。"
            end
            if detail:find(":mupdf_remote_unavailable", 1, true) then
                return "当前 KOReader 的 MuPDF 未提供远程文档接口，无法流式打开该 PDF/漫画文档；需要支持远程 MuPDF 的 KOReader 引擎。"
            elseif detail:find(":range_unavailable", 1, true)
                or detail:find(":content_range_", 1, true) then
                return "服务器没有返回可靠的 HTTP Range（206/Content-Range），无法流式打开该文档；未下载整本文件。"
            elseif detail:find("epub:epub_not_image_book", 1, true) then
                return "该 EPUB 不是可识别的图片漫画结构，无法按页流式打开；未下载整本文件。"
            elseif detail:find("epub:", 1, true) then
                return "EPUB 流式解析失败（" .. detail:sub(6) .. "），未下载整本文件。"
            end
            return "文档流式打开失败（" .. detail .. "），未下载整本文件。"
        end
        if err.stage == "staging" then
            return "文档下载未完成，无法打开漫画书籍。请检查网络或缓存空间后重试。"
        elseif err.stage == "native" then
            return "KOReader 当前无法打开此文档格式。请确认格式受支持。"
        end
        return "漫画文档打开失败，请稍后重试。"
    end
    return "未知错误，请返回上一页后重试。"
end

return M
