local Cover = require("webdavmanga.cover")
local checks = 0
local function expect(value, message) checks = checks + 1; if not value then error(message) end end
local function index(entries)
    local calls = 0
    return { count=function() return #entries end, get=function(_,i) calls=calls+1; return entries[i] end,
        calls=function() return calls end }
end
local image = { name="002.jpg", path="/漫画/直/002.jpg", is_file=true }
local image_index = index({ image })
local hint = Cover.hint_for_directory{ images=image_index, folders=index({}) }
expect(hint.layout=="direct" and hint.image==image and image_index:calls()==1, "direct cover hint reads only index get(1)")
local chapter = { name="第1话", path="/漫画/章/第1话", is_folder=true }
local folder_index = index({ chapter }); local chapter_hint = Cover.hint_for_directory{ folders=folder_index, images=index({}) }
expect(chapter_hint.layout=="chapters" and chapter_hint.chapter==chapter and folder_index:calls()==1, "chapter cover hint reads only first chapter index entry")
local direct_dir = { folders=function() return index({}) end, images=function() return image_index end, close=function() end }
local chapter_dir = { folders=function() return index({}) end, images=function() return index({{name="001.jpg",path=chapter.path.."/001.jpg",is_file=true}}) end, close=function() end }
local manga_dir = { folders=function() return folder_index end, images=function() return index({}) end, close=function() end }
local dirs = { ["/漫画/直"] = direct_dir, ["/漫画/章"] = manga_dir, [chapter.path] = chapter_dir }
local store = { load=function(_,path,cb) local d=dirs[path]; if d then cb.on_ready(d) else cb.on_error({code="transport"}) end; return {cancel=function() end} end }
local stored={}; local library={get_cover=function(_,_,p) return stored[p] end,set_cover=function(_,_,p,i) stored[p]={manga_path=p,image=i}; return stored[p] end,set_no_cover=function(_,_,p) stored[p]={manga_path=p,none=true}; return stored[p] end}
local connection={server_url="https://nas",username="u",root_path="/漫画"}
local service=Cover:new{library=library,directory_store=store}
local ready; service:resolve(connection,{manga={name="直",path="/漫画/直",is_folder=true}},{on_ready=function(i) ready=i end})
expect(ready and ready.path==image.path,"direct manga cover resolves first indexed image")
local chapter_ready; service:resolve(connection,{manga={name="章",path="/漫画/章",is_folder=true}},{on_ready=function(i) chapter_ready=i end})
expect(chapter_ready and chapter_ready.path=="/漫画/章/第1话/001.jpg","chapter manga cover loads first chapter then first image")
expect(stored["/漫画/直"].image.password==nil and stored["/漫画/章"].image.password==nil,"cover persistence stores lightweight sanitized resources")

do
    local pending = {}
    local cached
    local deferred_store = {
        load = function(_, path, callbacks)
            local request = { callbacks = callbacks, canceled = false }
            pending[path] = request
            return { cancel = function() request.canceled = true end }
        end,
    }
    local deferred_library = {
        get_cover = function() return cached end,
        set_cover = function(_, _, path, value)
            cached = { manga_path = path, image = value }
            return cached
        end,
        set_no_cover = function() return true end,
    }
    local deferred = Cover:new{ library = deferred_library, directory_store = deferred_store }
    local record = { manga = { name = "延迟", path = "/漫画/延迟", is_folder = true } }
    deferred:resolve(connection, record, {})
    local first_request = pending[record.manga.path]
    cached = { manga_path = record.manga.path, image = image }
    local cached_ready
    deferred:resolve(connection, record, { on_ready = function(value) cached_ready = value end })
    expect(first_request.canceled and cached_ready and cached_ready.path == image.path,
        "a cached cover resolve must cancel an older discovery request")
end

do
    local pending = {}
    local deferred_store = {
        load = function(_, path, callbacks)
            local request = { callbacks = callbacks, canceled = false }
            pending[path] = request
            return { cancel = function() request.canceled = true end }
        end,
    }
    local deferred_library = {
        get_cover = function() return nil end,
        set_cover = function() return true end,
        set_no_cover = function() return true end,
    }
    local deferred = Cover:new{ library = deferred_library, directory_store = deferred_store }
    local record = { manga = { name = "嵌套", path = "/漫画/章", is_folder = true } }
    deferred:resolve(connection, record, {})
    pending[record.manga.path].callbacks.on_ready(manga_dir)
    local chapter_request = pending[chapter.path]
    deferred:cancel_all()
    expect(pending[record.manga.path].canceled and chapter_request.canceled,
        "canceling cover discovery must cancel both manga and chapter requests")
end

print(("cover_spec: %d checks"):format(checks))
