local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local Reader = require("webdavmanga.ui_reader")
local images = {}
for index = 1, 8 do
    images[index] = { name = ("%03d.jpg"):format(index), path = ("/%03d.jpg"):format(index) }
end
local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end
local index = {
    count = function() return #images end,
    get = function(_, number) return copy(images[number]) end,
    window = function(_, current, radius)
        local result = { first_index = math.max(1, current - radius) }
        for number = result.first_index, math.min(#images, current + radius) do
            result[#result + 1] = copy(images[number])
        end
        return result
    end,
}
local values = {
    direction = "normal", fit_mode = "page", image_prefetch_enabled = true,
    prefetch_count = 3, prefetch_first_pages = 10,
    prefetch_near_count = 7, prefetch_far_count = 7, prefetch_concurrency = 1,
    gray_enhance_enabled = true, gray_enhance_preset = "clear",
    gray_enhance_custom_presets = {}, tone_adjust_enabled = false,
    tone_adjust_preset = "original", tone_adjust_custom_presets = {},
    show_preprocess_success = true, animation_enabled = false,
    full_refresh_each_page = false, show_progress_bar = true,
    progress_bar_thickness = 1, split_enabled = false,
    split_min_ratio = 1.2, split_max_ratio = 2.2, split_cut_percent = 50,
    split_first_segment = "left", auto_crop_enabled = false,
    auto_crop_threshold = 242, auto_crop_max_percent = 15,
}
local status = {}
local shown = 0
local loader = {
    identity = "notice-test",
    prefetch_count_for = function() return 7 end,
    request = function(_, _, image, callbacks)
        callbacks.on_ready("/raw" .. image.path, false,
            { format = "jpeg", width = 1000, height = 1400 })
    end,
    cancel_generation = function() end,
}
local prepared = {
    request = function(_, _, image, _, callbacks)
        callbacks.on_ready("/prepared" .. image.path, false, {
            prepared = true, prepared_key = "prepared" .. image.path,
            format = "png", width = 600, height = 800,
        })
    end,
    prefetch = function(_, _, list, current, _, _, on_processed)
        shown = shown + 1
        for number = current + 1, #images do
            if on_processed then
                on_processed(list[number - list.first_index + 1] or images[number],
                    "/prepared/" .. tostring(number), false,
                    { prepared = true, prepared_key = "prepared/" .. tostring(number) })
            end
        end
    end,
    cache_key = function(_, image) return "prepared" .. image.path end,
    cancel_processing = function() end,
    cancel_generation = function() end,
}
local buffer = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
    viewport = function(self) return self end,
    free = function() end,
}
local shell = {
    get_content_size = function() return 600, 800 end,
    show_loading = function() return true end,
    show_page = function() return true end,
    show_error = function() return true end,
    show_status = function(_, message) status[#status + 1] = message end,
    close_now = function() return true end,
    free_buffer_later = function(_, value) return value:free() end,
}
local current_generation
local reader = Reader:new{
    loader = loader, prepared_pages = prepared,
    progress = {
        chapter_id = function() return "notice" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function() return true end,
    },
    state = {
        begin_chapter = function() current_generation = 1; return 1 end,
        is_current = function(_, generation) return generation == current_generation end,
        leave_chapter = function() current_generation = nil end,
    },
    settings = {
        get_connection = function() return {} end,
        get_reader = function() return values end,
        set_reader = function(_, next_values) values = next_values; return true end,
        flush = function() return true end,
    },
    cache = {
        key_for = function(_, identity, path) return identity .. "|" .. path end,
        set_protected = function() return true end,
        remove = function() return true end,
    },
    ui = {
        create_shell = function() return shell end,
        show_shell = function() return true end,
        schedule = function(_, callback) callback() end,
        show_info = function() end,
        close_shell = function() return true end,
    },
    render_image = {
        renderImageFile = function() return buffer end,
    },
    open_chapter = function() end,
    gray_enhance = {
        find = function() return { id = "clear", black = 40, white = 238, gamma = 1.2 } end,
        apply = function() return true end,
    },
}

expect(reader:open{ manga = {}, chapter = {}, chapter_index = index },
    "reader must open for the notice test")
expect(shown == 1, "the image prefetch callback must run")
expect(#status == 5 and status[1] == "处理图像成功",
    "only the next five processed pages must show the success status")

values.show_preprocess_success = false
reader:reload_settings(values)
status = {}
reader:request_page(1, "whole")
expect(#status == 0, "the success status switch must suppress the notice")

print(("rebuild_0377_preprocess_notice_spec: %d checks"):format(checks))
