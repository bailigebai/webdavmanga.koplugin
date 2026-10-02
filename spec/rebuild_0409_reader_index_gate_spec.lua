local Reader = require("webdavmanga.ui_reader")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local items = {}
for index = 1, 5 do items[index] = { name = index .. ".jpg", path = "/" .. index .. ".jpg" } end
local chapter_index = {
    count = function() return #items end,
    get = function(_, index) return items[index] end,
}
local info, picker, next_chapter, saves = nil, nil, 0, 0
local state = { complete = false, total_pages = 12 }
local reader = setmetatable({
    context = { chapter_index = chapter_index, stream_state = state,
        manga = { name = "comic", path = "/comic" },
        chapter = { name = "book", path = "/comic/book.epub" },
        source_context = {} },
    position = { index = 5, segment = "whole" },
    current_segments = { "whole" },
    fit_mode = "page",
    ui = {
        show_info = function(_, message) info = message; return true end,
        show_page_picker = function(_, model) picker = model; return true end,
    },
    shell = {},
    chapter_id = "chapter",
    progress = { save = function() saves = saves + 1; return true end },
    settings = { get_connection = function() return {} end },
    _ask_next_chapter = function() next_chapter = next_chapter + 1; return true end,
}, { __index = Reader })

reader:show_page_picker()
expect(info == "页面目录正在加载，完成后可跳转" and picker == nil,
    "jump picker must remain disabled while the full index is loading")

info = nil
reader:next_page()
expect(info == "正在加载后续页面" and next_chapter == 0,
    "known page five must not be mistaken for the chapter end")
reader:_checkpoint(5, "whole", items[5])
expect(saves == 0, "a partial index must not overwrite a later saved reading position")

state.complete = true
info, picker = nil, nil
reader:show_page_picker()
expect(picker and picker.value_max == 5 and info == nil,
    "jump picker must recover after background indexing completes")
reader:next_page()
expect(next_chapter == 1, "normal chapter-end behavior must recover after completion")
reader:_checkpoint(5, "whole", items[5])
expect(saves == 1, "progress checkpoints must recover after index completion")

print(("rebuild_0409_reader_index_gate_spec: %d checks"):format(checks))
