-- File visibility only. ReaderUI interception owns every normal pointer open.
local Document = { provider = "webdavmanga-meguru", provider_name = "WebDAV Manga" }
function Document:new() return nil end
return Document
