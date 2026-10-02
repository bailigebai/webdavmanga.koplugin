local M = {}

local ORDERED = { "jpg", "jpeg", "png", "webp", "gif", "tif", "tiff", "svg" }
local DOCUMENT_ORDERED = {
    "pdf", "mobi", "azw", "azw3", "epub", "cbz", "cbr", "cb7", "cbt", "rar", "7z",
    "djvu", "djv", "fb2", "fb3", "pdb", "prc", "doc", "docm",
    "docx", "odt", "rtf", "txt", "htm", "html", "xhtml", "xml",
    "chm", "tcr", "pptx", "xlsx", "xps", "tar", "zip",
}
local SUPPORTED = {}
for _, extension in ipairs(ORDERED) do SUPPORTED[extension] = true end
local DOCUMENTS = {}
for _, extension in ipairs(DOCUMENT_ORDERED) do DOCUMENTS[extension] = true end

function M.list()
    local copy = {}
    for index, extension in ipairs(ORDERED) do copy[index] = extension end
    return copy
end

function M.document_extensions()
    local copy = {}
    for index, extension in ipairs(DOCUMENT_ORDERED) do copy[index] = extension end
    return copy
end

function M.extension(name)
    local extension = tostring(name or ""):match("%.([^./\\]+)$")
    return extension and extension:lower() or nil
end

function M.extension_for_format(format)
    format = tostring(format or ""):lower():gsub("^%.", "")
    if format == "jpeg" or format == "jpg" then return "jpg" end
    if format == "tiff" or format == "tif" then return "tif" end
    if SUPPORTED[format] then return format end
    return nil
end

function M.is_supported(name)
    local extension = M.extension(name)
    return extension ~= nil and SUPPORTED[extension] == true
end

function M.is_image(name)
    return M.is_supported(name)
end

function M.is_document(name)
    local extension = M.extension(name)
    return extension ~= nil and DOCUMENTS[extension] == true
end

return M
