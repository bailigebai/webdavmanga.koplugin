local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local Reader = require("webdavmanga.ui_reader")

local images = {
    { name = "001.jpg", path = "/001.jpg" },
    { name = "002.jpg", path = "/002.jpg" },
    { name = "003.jpg", path = "/003.jpg" },
    { name = "004.jpg", path = "/004.jpg" },
}
local function image_copy(image)
    local result = {}
    for key, value in pairs(image) do result[key] = value end
    return result
end
local index = {
    count = function() return #images end,
    get = function(_, number) return image_copy(images[number]) end,
    window = function()
        return {
            image_copy(images[1]), image_copy(images[2]),
            image_copy(images[3]), image_copy(images[4]),
        }
    end,
}
local reader_values = {
    direction = "normal", fit_mode = "width", image_prefetch_enabled = true,
    prefetch_count = 3, prefetch_first_pages = 10,
    prefetch_near_count = 3, prefetch_far_count = 1,
    animation_enabled = false, full_refresh_each_page = false,
    show_progress_bar = true, progress_bar_thickness = 1,
    split_enabled = false, split_min_ratio = 1.2, split_max_ratio = 2.2,
    split_cut_percent = 50, split_first_segment = "left",
    auto_crop_enabled = false, auto_crop_threshold = 242, auto_crop_max_percent = 15,
    gray_enhance_enabled = true, gray_enhance_preset = "clear",
    gray_enhance_custom_presets = {},
    tone_adjust_enabled = true, tone_adjust_preset = "original",
    tone_adjust_custom_presets = {},
}

local raw_requests, raw_prefetches, prepared_requests = 0, 0, 0
local prepared_prefetches, processing_cancels = 0, 0
local requested_profiles, profile_inputs, protected, render_sizes, messages = {}, {}, {}, {}, {}
local controls
local live_gray_calls = 0
local defer_prepared_requests = false
local loader = {
    identity = "server",
    prefetch_count_for = function() return 3 end,
    request = function(_, _, image, callbacks)
        raw_requests = raw_requests + 1
        callbacks.on_ready("/raw" .. image.path, false, {
            format = "jpeg", width = image.width, height = image.height,
        })
    end,
    prefetch = function() raw_prefetches = raw_prefetches + 1 end,
    cancel_generation = function() end,
}
local prepared = {
    request = function(_, _, image, profile_provider, callbacks)
        prepared_requests = prepared_requests + 1
        profile_inputs[#profile_inputs + 1] = type(profile_provider)
        image.width, image.height = 1000, 2000
        local profile = type(profile_provider) == "function"
            and profile_provider(image) or profile_provider
        requested_profiles[#requested_profiles + 1] = profile
        if defer_prepared_requests then return end
        callbacks.on_ready("/prepared" .. image.path .. ".png", false, {
            prepared = true, processing_error = "lut_failed", format = "png",
            width = profile.target_width, height = profile.target_height,
            prepared_key = "derived|" .. image.path .. "|" .. profile.id,
        })
    end,
    prefetch = function(_, _, list, current, profile_provider, on_profile_ready)
        prepared_prefetches = prepared_prefetches + 1
        for index = 2, #list do
            list[index].width, list[index].height = 1000, 2000
            local profile = profile_provider(list[index])
            expect(type(profile) == "table" and current == 1,
                "reader prefetch must propagate the same processing profile")
            if on_profile_ready then on_profile_ready(list[index], profile) end
        end
    end,
    cache_key = function(_, image, profile)
        return "derived|" .. image.path .. "|" .. profile.id
    end,
    cancel_processing = function() processing_cancels = processing_cancels + 1 end,
    cancel_generation = function() end,
}

local buffer = {
    getWidth = function(self) return self.width end,
    getHeight = function(self) return self.height end,
    viewport = function(self) return self end,
    free = function() end,
}
local shell = {
    get_content_size = function() return 600, 800 end,
    show_loading = function() return true end,
    show_page = function() return true end,
    show_error = function() return true end,
    close_now = function() return true end,
    free_buffer_later = function(_, value) return value:free() end,
}
local current_generation
local reader = Reader:new{
    loader = loader,
    prepared_pages = prepared,
    progress = {
        chapter_id = function() return "chapter" end,
        resolve = function() return { index = 1, segment = "whole" } end,
        save = function() return true end,
    },
    state = {
        begin_chapter = function() current_generation = 7; return 7 end,
        is_current = function(_, generation) return generation == current_generation end,
        leave_chapter = function() current_generation = nil end,
    },
    settings = {
        get_connection = function() return {} end,
        get_reader = function() return reader_values end,
        set_reader = function(_, values) reader_values = values; return true end,
        flush = function() return true end,
    },
    cache = {
        key_for = function(_, identity, path) return identity .. "|" .. path end,
        set_protected = function(_, keys) protected = keys; return true end,
        remove = function() return true end,
    },
    ui = {
        create_shell = function() return shell end,
        show_shell = function() return true end,
        show_info = function(_, message) messages[#messages + 1] = message end,
        show_controls = function(_, model) controls = model; return true end,
        schedule = function(_, callback) callback() end,
        close_shell = function() return true end,
    },
    render_image = {
        renderImageFile = function(_, _, _, width, height)
            render_sizes[#render_sizes + 1] = { width, height }
            buffer.width, buffer.height = width, height
            return buffer
        end,
    },
    gray_enhance = {
        find = function() return { id = "clear", black = 40, white = 238, gamma = 1.2 } end,
        apply = function() live_gray_calls = live_gray_calls + 1; return true end,
    },
    open_chapter = function() end,
}

expect(reader:open{ manga = {}, chapter = {}, chapter_index = index },
    "reader must open through the prepared-page adapter")
expect(prepared_requests == 1 and raw_requests == 0
    and prepared_prefetches == 1 and raw_prefetches == 0,
    "current and prefetched pages must use PreparedPages instead of raw Loader calls")
expect(profile_inputs[1] == "function",
    "manifest pages without dimensions must resolve their profile after the raw page is ready")
expect(requested_profiles[1] and requested_profiles[1].lut
    and requested_profiles[1].target_width == render_sizes[1][1]
    and requested_profiles[1].target_height == render_sizes[1][2],
    "prepared PNG dimensions must be decoded without a second resize")
expect(live_gray_calls == 0,
    "page display must not run the gray LUT again on the UI path")
local protected_text = table.concat(protected, "\n")
expect(protected_text:find("derived|", 1, true) ~= nil,
    "cache protection must retain the processed page alongside its raw source")
expect(protected_text:find("derived|/004.jpg", 1, true) ~= nil,
    "cache protection must cover every prepared page in the active prefetch window")
expect(#messages == 1 and messages[1]:find("lut_failed", 1, true),
    "a processing fallback must show its diagnostic once")
reader:toggle_controls("root")
local tone_action
for _, action in ipairs(controls.actions or {}) do
    if action.text == "亮度与对比度" then tone_action = action; break end
end
expect(tone_action and type(tone_action.callback) == "function",
    "reader settings must expose a compact brightness and contrast submenu")

reader:reload_settings(reader_values)
expect(processing_cancels == 1 and prepared_requests == 2 and #messages == 1,
    "settings reload must cancel old processing, rebuild the page, and suppress repeat warnings")
expect(reader:set_tone_adjust_enabled(false) == true
    and reader.reader_settings.tone_adjust_enabled == false,
    "the reader must persist the independent tone-adjust switch")

defer_prepared_requests = true
local before_deferred = prepared_requests
reader:request_page(2, "whole")
local obsolete_serial = reader.pending_request and reader.pending_request.serial
reader:reload_settings(reader_values)
expect(prepared_requests == before_deferred + 2
    and reader.pending_request and reader.pending_request.serial ~= obsolete_serial,
    "settings changes must replace an in-flight processed-page request")

print(("rebuild_0376_reader_preprocess_spec: %d checks"):format(checks))
