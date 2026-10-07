local Errors = require("webdavmanga.errors")
local AutoCrop = require("webdavmanga.auto_crop")
local GrayEnhance = require("webdavmanga.gray_enhance")
local ToneAdjust = require("webdavmanga.tone_adjust")
local NativeImageFilter = require("webdavmanga.native_image_filter")
local DialogKeyboard = require("webdavmanga.dialog_keyboard")
local SafeCallback = require("webdavmanga.safe_callback")
local UiRegistry = require("webdavmanga.ui_registry")
local ReaderHelp = require("webdavmanga.reader_help")

local UiSettings = {}
UiSettings.__index = UiSettings

local MB = 1024 * 1024
local GB = 1024 * MB

local function copy_table(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function validation_message(code)
    local messages = {
        invalid_server_url = "请输入以 http:// 或 https:// 开头的 WebDAV 地址。",
        invalid_root_path = "请输入 WebDAV 根目录。",
        invalid_local_path = "请输入有效的 Kindle 本地漫画目录。",
        missing_source = "连接不存在，可能已被删除。",
        last_source = "至少保留一个连接。",
        invalid_direction = "翻页方向只能是 normal 或 manga。",
        invalid_prefetch_count = "预加载页数必须是 0 到 10 的整数。",
        invalid_prefetch_first_pages = "前段预加载边界必须是 1 到 100 的整数。",
        invalid_prefetch_near_count = "前段预加载页数必须是 0 到 10 的整数。",
        invalid_prefetch_far_count = "后段预加载页数必须是 0 到 10 的整数。",
        invalid_prefetch_concurrency = "预加载并发数只能是 1、2 或 3。",
        invalid_image_prefetch_enabled = "图片预加载开关设置无效。",
        invalid_range_streaming_enabled = "HTTP Range 流式加载开关设置无效。",
        invalid_image_engine = "漫画引擎只能选择默认引擎或无痕引擎。",
        invalid_cache_limit = "缓存上限必须是 16 到 4096 MB 的整数。",
        invalid_cover_cache_limit = "封面缓存上限必须是 16 到 4096 MB 的整数。",
        invalid_offline_root = "整部漫画保存目录必须位于 /mnt/us 下。",
        invalid_offline_limit = "整部漫画缓存上限必须是 1 到 20 GB 的整数。",
        invalid_offline_refresh = "进度刷新间隔必须是 1 到 60 秒的整数。",
        invalid_browse_cache_total = "浏览缓存总大小必须是 16 到 32768 MB 的整数。",
        invalid_browse_cache_trigger = "浏览缓存触发大小必须是 16 到 32768 MB 的整数。",
        invalid_browse_cache_trigger_range = "浏览缓存触发大小不能超过总大小。",
        invalid_browse_cache_retain = "浏览缓存保留大小必须是 0 到 32768 MB 的整数。",
        invalid_browse_cache_retain_range = "浏览缓存保留大小必须小于触发大小。",
        invalid_browse_cache_interval = "浏览缓存检查间隔必须是 1 到 1440 分钟的整数。",
        invalid_browse_total = "浏览缓存总大小设置无效。",
        invalid_browse_trigger = "浏览缓存触发大小设置无效。",
        invalid_browse_trigger_range = "浏览缓存触发大小不能超过总大小。",
        invalid_browse_retain = "浏览缓存保留大小设置无效。",
        invalid_browse_retain_range = "浏览缓存保留大小必须小于触发大小。",
        invalid_browse_interval = "浏览缓存检查间隔设置无效。",
        invalid_fit_mode = "显示模式只能是 page（整页）、width（适宽）或 match（调整匹配）。",
        invalid_opds_url = "OPDS 地址必须是 HTTP 或 HTTPS 链接。",
        invalid_gray_enhance_enabled = "去灰增强总开关必须为开启或关闭。",
        invalid_tone_adjust_enabled = "亮度与对比度总开关必须为开启或关闭。",
        invalid_panel_toggle = "智能分格开关设置无效。",
        invalid_bubble_zoom = "气泡放大设置无效：选择长按或点按，倍率为1.5、2或3倍。",
        invalid_panel_standard_margin = "普通分格边距只能选择 0%、2%、5% 或 10%。",
        invalid_panel_hold_margin = "自由缩放边距只能选择 2%、5%、10%、15% 或 20%。",
        invalid_panel_initial_zoom = "自由缩放倍率只能选择 1.0、1.2、1.5 或 2.0 倍。",
        reader_settings_write_failed = "阅读设置保存失败，已恢复原设置，请重试。",
        invalid_gray_preset = "去灰增强预设无效，请检查黑点、白点和伽马值。",
        invalid_gray_sample_path = "样本目录必须是 Kindle 本地绝对路径。",
        missing_gray_preset = "自定义预设不存在，可能已被删除。",
        cannot_edit_builtin_gray_preset = "原图、清晰、强力为内置预设，不能直接修改。",
        cannot_delete_builtin_gray_preset = "内置预设不能删除。",
        invalid_tone_preset = "亮度与对比度预设无效。",
        invalid_tone_sample_path = "亮度与对比度样本目录必须是 Kindle 本地绝对路径。",
        invalid_kopt_sample_path = "KOReader 图像处理样本目录必须是 Kindle 本地绝对路径。",
        invalid_preprocess_success_setting = "处理图像成功提示设置无效。",
        missing_tone_preset = "自定义亮度与对比度预设不存在。",
        cannot_edit_builtin_tone_preset = "原图为内置预设，不能直接修改。",
        cannot_delete_builtin_tone_preset = "原图预设不能删除。",
        gray_sample_directory_unreadable = "样本目录无法读取，请检查路径。",
        gray_sample_not_found = "样本目录中没有支持的图片。",
        gray_sample_not_image = "指定样本文件不是支持的图片格式。",
        gray_sample_filesystem_unavailable = "当前 KOReader 无法读取本地样本目录。",
        invalid_progress_bar_setting = "顶部进度条设置无效。",
        invalid_progress_bar_thickness = "进度条厚度必须是 1 到 4 倍的整数。",
        invalid_full_refresh_setting = "每页完全刷新设置无效。",
        invalid_auto_crop_enabled = "自动裁白边设置无效。",
        invalid_auto_crop_threshold = "白边识别强度必须是 0 到 100 的整数百分比。",
        invalid_auto_crop_max_percent = "自动裁白边比例必须是 0 到 30 的整数。",
        invalid_split_enabled = "宽幅图切分设置无效。",
        invalid_split_min_ratio = "宽幅图最小比例必须是 1.00 到 4.00 的数字。",
        invalid_split_max_ratio = "宽幅图最大比例必须是 1.00 到 4.00 的数字。",
        invalid_split_ratio_range = "宽幅图最小比例必须小于最大比例。",
        invalid_split_cut_percent = "宽幅图切分位置必须是 10 到 90 的整数。",
        invalid_split_first_segment = "宽图拆分首屏只能选择左边或右边。",
        invalid_grid_columns = "网格列数只能是 3 列或 5 列。",
        invalid_animation_enabled = "翻页动画开关设置无效。",
        invalid_frontlight_intensity = "前光强度必须是设备支持范围内的整数。",
        invalid_frontlight_warmth = "色温必须是 0 到 100 的整数百分比。",
        frontlight_unavailable = "当前设备无法调整前光。",
        warmth_unavailable = "当前设备不支持色温调整。",
        invalid_port = "端口必须是 1 到 65535 的整数。",
        invalid_nodeshare_url = "请输入完整的组网 WebDAV 地址，例如 http://组网IP:5005。",
        nodeshare_unavailable = "当前环境无法检测节点小宝 TCP 组网连接。",
        tcp_unavailable = "当前 KOReader 无法创建 TCP 检测连接。",
        tcp_unreachable = "TCP 端口无法连接。请确认 Kindle 已接入节点小宝组网，并检查组网地址和 WebDAV 端口。",
    }
    return messages[code] or "设置值无效，请检查后重试。"
end

local function nodeshare_message(err)
    local code = type(err) == "table" and tostring(err.code or "") or ""
    return validation_message(code ~= "" and code or "tcp_unreachable")
end

local function to_boolean(value)
    if type(value) == "boolean" then return value end
    local lowered = tostring(value or ""):lower()
    if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "是" then
        return true
    end
    if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "否" then
        return false
    end
    return value
end

local function normalize_reader(values, current)
    local fit_mode = tostring(values.fit_mode or "")
    -- Accept both persisted identifiers and the labels shown by the compact
    -- settings panels. Unknown values remain untouched for normal validation.
    local fit_aliases = {
        ["整页"] = "page", ["显示：整页"] = "page",
        ["适宽"] = "width", ["显示：适宽"] = "width",
        ["调整匹配"] = "match", ["显示：调整匹配"] = "match",
    }
    fit_mode = fit_aliases[fit_mode] or fit_mode
    local show_progress_bar = to_boolean(values.show_progress_bar)
    if type(show_progress_bar) ~= "boolean" then
        show_progress_bar = current.show_progress_bar ~= false
    end
    local full_refresh_each_page = to_boolean(values.full_refresh_each_page)
    if type(full_refresh_each_page) ~= "boolean" then
        full_refresh_each_page = current.full_refresh_each_page == true
    end
    local progress_bar_thickness = tonumber(values.progress_bar_thickness)
    if not progress_bar_thickness then
        progress_bar_thickness = tonumber(current.progress_bar_thickness) or 1
    end
    local auto_crop_strength = tonumber(values.auto_crop_strength)
    local auto_crop_threshold
    if values.auto_crop_strength == nil then
        auto_crop_threshold = tonumber(values.auto_crop_threshold)
            or tonumber(current.auto_crop_threshold) or 242
    elseif auto_crop_strength and auto_crop_strength == math.floor(auto_crop_strength)
        and auto_crop_strength >= 0 and auto_crop_strength <= 100 then
        auto_crop_threshold = AutoCrop.threshold_from_strength(auto_crop_strength)
    else
        -- Keep an explicitly invalid value invalid so Settings can return the
        -- clear range error instead of silently accepting it.
        auto_crop_threshold = 199
    end
    local gray_enhance_enabled = values.gray_enhance_enabled
    if gray_enhance_enabled == nil then
        gray_enhance_enabled = current.gray_enhance_enabled == true
    else
        gray_enhance_enabled = to_boolean(gray_enhance_enabled)
    end
    local tone_adjust_enabled = values.tone_adjust_enabled
    if tone_adjust_enabled == nil then
        tone_adjust_enabled = current.tone_adjust_enabled == true
    else
        tone_adjust_enabled = to_boolean(tone_adjust_enabled)
    end
    local show_preprocess_success = values.show_preprocess_success
    if show_preprocess_success == nil then
        show_preprocess_success = current.show_preprocess_success ~= false
    else
        show_preprocess_success = to_boolean(show_preprocess_success)
    end
    return {
        direction = tostring(values.direction or ""),
        prefetch_count = tonumber(values.prefetch_count),
        prefetch_first_pages = tonumber(values.prefetch_first_pages),
        prefetch_near_count = tonumber(values.prefetch_near_count),
        prefetch_far_count = tonumber(values.prefetch_far_count),
        prefetch_concurrency = tonumber(values.prefetch_concurrency),
        image_prefetch_enabled = to_boolean(values.image_prefetch_enabled),
        range_streaming_enabled = to_boolean(values.range_streaming_enabled),
        cache_limit_mb = current.cache_limit_mb,
        fit_mode = fit_mode,
        gray_enhance_enabled = gray_enhance_enabled,
        gray_enhance_preset = tostring(values.gray_enhance_preset
            or current.gray_enhance_preset or "original"),
        gray_enhance_custom_presets = GrayEnhance.sanitize_custom_presets(
            values.gray_enhance_custom_presets or current.gray_enhance_custom_presets),
        gray_enhance_sample_path = values.gray_enhance_sample_path == nil
            and (current.gray_enhance_sample_path or "")
            or values.gray_enhance_sample_path,
        tone_adjust_enabled = tone_adjust_enabled,
        tone_adjust_preset = tostring(values.tone_adjust_preset
            or current.tone_adjust_preset or "original"),
        tone_adjust_custom_presets = ToneAdjust.sanitize_custom_presets(
            values.tone_adjust_custom_presets or current.tone_adjust_custom_presets),
        tone_adjust_sample_path = values.tone_adjust_sample_path == nil
            and (current.tone_adjust_sample_path or "")
            or values.tone_adjust_sample_path,
        panel_zoom_enabled = values.panel_zoom_enabled,
        bubble_zoom_enabled = values.bubble_zoom_enabled == nil and current.bubble_zoom_enabled
            or values.bubble_zoom_enabled ~= nil and to_boolean(values.bubble_zoom_enabled),
        bubble_zoom_trigger = values.bubble_zoom_trigger or current.bubble_zoom_trigger,
        bubble_zoom_scale = tonumber(values.bubble_zoom_scale or current.bubble_zoom_scale),
        panel_show_adjacent = values.panel_show_adjacent,
        panel_standard_margin_percent = values.panel_standard_margin_percent,
        panel_hold_margin_percent = values.panel_hold_margin_percent,
        panel_initial_zoom = values.panel_initial_zoom,
        panel_experimental_sort = values.panel_experimental_sort,
        show_preprocess_success = show_preprocess_success,
        show_progress_bar = show_progress_bar,
        progress_bar_thickness = progress_bar_thickness,
        full_refresh_each_page = full_refresh_each_page,
        auto_crop_enabled = to_boolean(values.auto_crop_enabled),
        auto_crop_threshold = auto_crop_threshold,
        auto_crop_max_percent = tonumber(values.auto_crop_max_percent),
        split_enabled = to_boolean(values.split_enabled),
        split_min_ratio = tonumber(values.split_min_ratio),
        split_max_ratio = tonumber(values.split_max_ratio),
        split_cut_percent = tonumber(values.split_cut_percent),
        split_first_segment = tostring(values.split_first_segment
            or current.split_first_segment or "left"),
        grid_columns = tonumber(values.grid_columns),
        animation_enabled = to_boolean(values.animation_enabled),
    }
end

local function is_connection_shape_valid(values)
    local server_url = tostring(values.server_url or ""):match("^%s*(.-)%s*$")
    local root_path = tostring(values.root_path or ""):match("^%s*(.-)%s*$")
    if not server_url:match("^https?://[^/]+") then return nil, "invalid_server_url" end
    if root_path == "" then return nil, "invalid_root_path" end
    return true
end

local function source_display_url(source)
    local url = tostring(source.server_url or "")
    if source.kind ~= "opds" then return url .. (source.root_path or "") end
    local scheme, authority = url:match("^(https?://)([^/?#]+)")
    return scheme and (scheme .. authority:gsub("^.*@", "")) or "OPDS"
end

local function default_ui()
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")
    local registry = UiRegistry:new(UIManager)

    local adapter = { dialog_epoch = 0 }
    local function show_dialog_keyboard(dialog)
        return DialogKeyboard.show(dialog)
    end
    local function guarded(label, callback, fallback)
        local wrapped = SafeCallback.wrap(adapter, label, callback, fallback)
        return function(...)
            local result = wrapped(...)
            -- Dialog buttons must consume the input even when validation or
            -- persistence returns false and intentionally keeps the dialog
            -- open.
            return result == nil and true or (result == false and true or result)
        end
    end
    function adapter:show_info(message, timeout)
        UIManager:show(InfoMessage:new{ text = message, timeout = timeout or 3 })
    end
    function adapter:show_reader_help(text)
        local TextViewer = require("ui/widget/textviewer")
        registry:show(TextViewer:new{
            title = "漫画阅读说明", text = text, fullscreen = true, covers_fullscreen = true,
        })
        return true
    end
    function adapter:show_busy(message)
        local widget = InfoMessage:new{ text = message }
        registry:show(widget)
        return { close = function() registry:close(widget) end }
    end
    function adapter:confirm(model)
        registry:show(ConfirmBox:new{
            text = model.text,
            ok_text = model.ok_text or "确定",
            cancel_text = model.cancel_text or "取消",
            ok_callback = guarded("confirm settings action", model.on_confirm),
        })
    end
    function adapter:show_sources(model)
        local sources = model.sources or {}
        local sources_per_page = 6
        local page_count = math.max(1, math.ceil(#sources / sources_per_page))
        local initial_page = 1
        for index, source in ipairs(sources) do
            if source.id == model.active_id then
                initial_page = math.floor((index - 1) / sources_per_page) + 1
                break
            end
        end

        local relay_help = table.concat({
            "适用场景\n",
            "公司电脑已经通过节点小宝访问 NAS，但连接公司电脑热点的 Kindle 不能直接访问组网地址。此时需要让公司电脑转发一个热点侧 TCP 端口。\n",
            "连接链路\n",
            "Kindle → 公司电脑热点端口 → 节点小宝组网 → NAS\n",
            "地址示例\n",
            "NAS 的节点小宝地址：100.66.1.10:5005\n",
            "公司电脑热点地址：192.168.137.1:15005\n",
            "插件中仍选择“添加节点小宝 TCP 组网”，服务器地址填写：http://192.168.137.1:15005。用户名、密码和漫画根目录继续填写 NAS 的 WebDAV 信息。不要把 NAS 密码发给 AI。\n",
            "可发给公司电脑 Codex / AI 的提示词\n",
            "请帮我配置 Windows 电脑热点 TCP 中继：让连接此电脑热点的设备访问 192.168.137.1:15005 时，TCP 流量原样转发到节点小宝组网地址 100.66.1.10:5005。请先检测热点网卡实际 IPv4 地址和目标端口连通性，再使用 Windows 自带 portproxy 配置固定端口转发，并只为当前热点网段添加入站防火墙规则。完成后显示检查命令、测试结果和精确撤销命令。不要修改 HTTP/WebDAV 报文，不要记录 WebDAV 密码。\n",
            "排错顺序\n",
            "1. 公司电脑先确认能访问 http://100.66.1.10:5005。\n",
            "2. 确认 Kindle 已连接公司电脑热点，热点网关通常是 192.168.137.1。\n",
            "3. 在电脑检查 15005 端口监听、防火墙规则和 portproxy 配置。\n",
            "4. 插件测试失败时，核对地址必须是 http://电脑热点IP:中继端口，不能直接填 100.66.1.10。\n",
            "撤销\n",
            "请让配置中继的 Codex / AI 按它创建时给出的精确命令，删除对应 portproxy 条目和专用防火墙规则。不要删除其他端口转发或防火墙规则。",
        }, "\n")
        local pc_webdav_help = table.concat({
            "拍照后文字识别  将下面内容发送给豆包",
            "",
            "请帮我配置这台 Windows 电脑的热点和 WebDAV，让其他设备连接电脑热点后，能访问电脑里的文件。",
            "",
            "1. 检查并开启电脑热点，设置名称为 `PC-Share`，生成一个随机强密码。",
            "2. 询问我要共享哪个文件夹，只共享这个文件夹，不共享整个磁盘。",
            "3. 配置 WebDAV，用户名设为 `davuser`，另外生成一个随机强密码，与热点密码不同，禁止匿名访问。",
            "4. 默认允许浏览、读取和下载文件；上传、修改、删除权限先问我。",
            "5. 优先使用已有工具；需要安装软件时，先告知软件名称并确认。防火墙只允许热点网段访问，不关闭防火墙，不开放公网。",
            "6. 获取电脑热点的实际 IP 地址和 WebDAV 端口，不要使用猜测的地址。",
            "7. 配置完成后，把以下信息整理给我，密码不要省略：",
            "   - 热点名称和密码",
            "   - WebDAV 完整地址（包含协议、IP、端口和必要路径）",
            "   - WebDAV 用户名和密码",
            "   - 已共享的文件夹及读写权限",
            "8. 指导我在另一台设备上连接热点，填写 WebDAV 信息，并实际打开一个文件验证。",
            "",
            "如果使用 HTTP，提前说明传输未加密。电脑断网时能否开启热点，需要实际检查。最后告诉我日常如何开启、关闭，以及休眠或重启后如何恢复。",
        }, "\n")

        local show_page
        show_page = function(page)
            page = math.max(1, math.min(page_count, tonumber(page) or 1))
            local dialog
            local buttons = {}
            local source_row
            local first_index = (page - 1) * sources_per_page + 1
            local last_index = math.min(#sources, first_index + sources_per_page - 1)
            for index = first_index, last_index do
                local current = sources[index]
                local marker = current.id == model.active_id and "● " or "○ "
                local kind_label = current.kind == "local"
                    and "Kindle 本地目录"
                    or (current.kind == "nodeshare" and "节点小宝 TCP 组网"
                        or (current.kind == "opds" and "OPDS 目录"
                            or "普通 WebDAV 直连"))
                local detail = current.kind == "local"
                    and (kind_label .. "\n" .. (current.local_path or current.root_path or ""))
                    or (kind_label .. "\n" .. source_display_url(current))
                if not source_row or #source_row == 2 then
                    source_row = {}
                    buttons[#buttons + 1] = source_row
                end
                source_row[#source_row + 1] = {
                    text = marker .. current.name .. "\n" .. detail,
                    callback = guarded("select WebDAV source", function()
                        registry:close(dialog)
                        return model.on_select(current.id)
                    end),
                }
            end

            if page_count > 1 then
                local navigation = {}
                if page > 1 then
                    navigation[#navigation + 1] = {
                        text = "上一页",
                        callback = guarded("previous WebDAV source page", function()
                            registry:close(dialog)
                            show_page(page - 1)
                        end),
                    }
                end
                if page < page_count then
                    navigation[#navigation + 1] = {
                        text = "下一页",
                        callback = guarded("next WebDAV source page", function()
                            registry:close(dialog)
                            show_page(page + 1)
                        end),
                    }
                end
                buttons[#buttons + 1] = navigation
            end

            buttons[#buttons + 1] = {
                {
                    text = "普通 WebDAV 直连",
                    callback = guarded("add WebDAV source", function()
                        registry:close(dialog)
                        return model.on_add()
                    end),
                },
                {
                    text = "添加 Kindle 本地目录",
                    callback = guarded("add Kindle local source", function()
                        registry:close(dialog)
                        if model.on_add_local then return model.on_add_local() end
                        return true
                    end),
                },
            }
            buttons[#buttons + 1] = {{
                text = "新增 OPDS 连接",
                callback = guarded("add OPDS source", function()
                    registry:close(dialog)
                    return model.on_add_opds()
                end),
            }}
            buttons[#buttons + 1] = {{ text = "OPDS 指针与封面",
                callback = guarded("OPDS pointer settings", function()
                    registry:close(dialog)
                    return model.on_opds_storage()
                end) }}
            buttons[#buttons + 1] = {{
                text = "电脑热点和 WebDAV 说明",
                callback = guarded("show PC hotspot and WebDAV help", function()
                    local TextViewer = require("ui/widget/textviewer")
                    registry:close(dialog)
                    registry:show(TextViewer:new{
                        title = "电脑热点与 WebDAV 配置说明",
                        text = pc_webdav_help,
                        fullscreen = true,
                        covers_fullscreen = true,
                        text_type = "webdavmanga_pc_webdav_help",
                        text_types = {
                            webdavmanga_pc_webdav_help = {
                                monospace_font = false,
                                font_size = 16,
                                justified = false,
                            },
                        },
                    })
                    return true
                end),
            }}
            if model.on_nodeshare then
                buttons[#buttons + 1] = {
                    {
                        text = "添加节点小宝 TCP 组网",
                        callback = guarded("open NodeShare TCP settings", function()
                            registry:close(dialog)
                            return model.on_nodeshare()
                        end),
                    },
                    {
                        text = "热点 TCP 中继说明",
                        callback = guarded("show hotspot TCP relay help", function()
                            local TextViewer = require("ui/widget/textviewer")
                            registry:close(dialog)
                            registry:show(TextViewer:new{
                                title = "电脑热点 TCP 中继说明",
                                text = relay_help,
                                fullscreen = true,
                            })
                        end),
                    },
                }
            end
            local memory_selected = model.image_engine == "memory"
            buttons[#buttons + 1] = {
                {
                    text = memory_selected and "○ 默认引擎" or "● 默认引擎",
                    callback = guarded("select default image engine", function()
                        registry:close(dialog)
                        return model.on_image_engine("default")
                    end),
                },
                {
                    text = memory_selected and "● 无痕引擎" or "○ 无痕引擎",
                    callback = guarded("select memory image engine", function()
                        registry:close(dialog)
                        return model.on_image_engine("memory")
                    end),
                },
                {
                    text = "说明",
                    callback = guarded("show image engine help", function()
                        return model.on_image_engine_help()
                    end),
                },
            }
            local management = {}
            if model.on_cover_cache then
                management[#management + 1] = {
                    text = "管理封面缓存",
                    callback = guarded("open cover cache settings", function()
                        registry:close(dialog)
                        return model.on_cover_cache()
                    end),
                }
            end
            if model.active_id then
                management[#management + 1] = {
                    text = "编辑当前连接",
                    callback = guarded("edit WebDAV source", function()
                        registry:close(dialog)
                        return model.on_edit(model.active_id)
                    end),
                }
            end
            if #management > 0 then buttons[#buttons + 1] = management end
            local license_status = type(model.license_status) == "function"
                and model.license_status() or {}
            local license_label = license_status and license_status.authorized
                and "增值版授权（已激活）" or "增值版授权（未激活）"
            buttons[#buttons + 1] = {{
                text = license_label,
                callback = guarded("open premium license", function()
                    registry:close(dialog)
                    return model.on_license and model.on_license() or true
                end),
            }}
            local closing = {}
            if model.active_id then
                closing[#closing + 1] = {
                    text = "删除当前连接",
                    callback = guarded("delete WebDAV source", function()
                        registry:close(dialog)
                        return model.on_delete(model.active_id)
                    end),
                }
            end
            closing[#closing + 1] = {
                text = "关闭",
                callback = guarded("close WebDAV sources", function()
                    registry:close(dialog)
                    if model.on_back then return model.on_back() end
                end),
            }
            buttons[#buttons + 1] = closing

            local title = page_count > 1
                and ("WebDAV 连接（%d / %d）"):format(page, page_count)
                or "WebDAV 连接"
            dialog = ButtonDialog:new{ title = title, buttons = buttons }
            registry:show(dialog)
        end
        show_page(initial_page)
    end
    function adapter:show_license(model)
        model = model or {}
        local dialog
        local progress
        local closed = false
        local function close_progress()
            if progress then registry:close(progress) end
            progress = nil
        end
        local function close_dialog()
            if closed then return end
            closed = true
            if type(model.cancel_activation) == "function" then
                pcall(model.cancel_activation)
            end
            close_progress()
            if dialog then registry:close(dialog) end
            if model.on_close then model.on_close() end
        end
        local status = type(model.status) == "function" and model.status() or {}
        local subtitle = status.authorized and "当前设备已激活，可离线使用。"
            or "首次激活需要联网；激活成功后可离线使用。"
        subtitle = "插件售价50元。\n" .. subtitle
        local function clear_local_authorization()
            local current = type(model.status) == "function" and model.status() or {}
            if current.authorized ~= true then
                adapter:show_info("当前未激活，无需清除。")
                return true
            end
            adapter:confirm{
                text = "确认清除这台设备保存的增值版授权？\n\n清除后会立即恢复未激活状态，不会删除阅读历史、缓存、分类、评分或其他设置。",
                ok_text = "继续",
                on_confirm = function()
                    adapter:confirm{
                        text = "再次确认：仅清除本机授权凭证。服务器上的设备绑定不会解除；同一设备可使用原密钥重新激活。",
                        ok_text = "确认清除",
                        on_confirm = function()
                            if type(model.clear_local) ~= "function" then
                                adapter:show_info("清除本机授权失败，请重试。")
                                return false
                            end
                            local ok, cleared, error_code = pcall(model.clear_local)
                            if not ok or cleared ~= true then
                                adapter:show_info(error_code == "save_failed"
                                    and "清除本机授权失败，请检查存储空间后重试。"
                                    or "清除本机授权失败，请重试。")
                                return false
                            end
                            close_dialog()
                            adapter:show_info("本机授权已清除，增值功能已锁定。")
                            return true
                        end,
                    }
                    return true
                end,
            }
            return true
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = "WebDAV 漫画增值版授权",
            subtitle = subtitle,
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {{ description = "授权密钥（XXXX-XXXX-XXXX）", text = "" }},
            buttons = {
                {{ text = "清除本机授权（测试）",
                    callback = guarded("clear local premium license", clear_local_authorization) }},
                {
                { text = "取消", id = "close", callback = guarded("cancel premium license", close_dialog) },
                { text = "激活", callback = guarded("activate premium license", function()
                    if progress then return true end
                    local values = dialog:getFields()
                    local key = values and values[1] or ""
                    if type(model.activate) ~= "function" then
                        adapter:show_info("授权服务尚未初始化。")
                        return false
                    end
                    progress = ButtonDialog:new{
                        title = "正在验证授权密钥…",
                        buttons = {{
                            {
                                text = "取消验证",
                                callback = guarded("cancel premium activation", function()
                                    if type(model.cancel_activation) == "function" then
                                        pcall(model.cancel_activation)
                                    end
                                    close_progress()
                                    adapter:show_info("已取消授权验证。")
                                    return true
                                end),
                            },
                        }},
                    }
                    registry:show(progress)
                    return model.activate(key, function(ok, result)
                        close_progress()
                        if ok then
                            adapter:show_info("授权成功，增值功能已解锁。")
                            if model.on_result then model.on_result(true, result) end
                            close_dialog()
                        else
                            adapter:show_info(model.error_message
                                and model.error_message(result)
                                or ("授权失败：" .. tostring(result or "service_unavailable")))
                            if model.on_result then model.on_result(false, result) end
                        end
                    end)
                end), },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
        return dialog
    end
    function adapter:show_local_connection(model)
        local dialog
        local function fields()
            local values = dialog:getFields()
            return { name = values[1], local_path = values[2], kind = "local" }
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.is_new and "添加 Kindle 本地目录" or "本地漫画目录设置",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {
                { description = "目录名称", text = model.values.name or "", hint = "例如：USB 漫画" },
                { description = "Kindle 本地目录", text = model.values.local_path or "", hint = "/mnt/us/Comics" },
            },
            buttons = {{
                { text = "取消", id = "close", callback = guarded("close local source", function()
                    registry:close(dialog)
                end) },
                { text = "测试", callback = guarded("test local source", function()
                    return model.on_test(fields())
                end) },
                { text = "保存", callback = guarded("save local source", function()
                    if model.on_save(fields()) then registry:close(dialog) end
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
    end
    function adapter:show_opds_storage(model)
        local values = copy_table(model.values)
        local show_form
        show_form = function()
            local dialog
            local function toggle(key)
                values.opds_pointer_root = dialog:getFields()[1]
                values[key] = not values[key]
                registry:close(dialog)
                show_form()
            end
            dialog = MultiInputDialog:new{
                title = "OPDS 指针与封面", fullscreen = true, condensed = true,
                subtitle = "关闭封面保存只影响今后的获取，不删除已有封面。修改目录不会移动旧指针。",
                fields = {{ description = "OPDS 指针目录（完整路径）", text = values.opds_pointer_root }},
                buttons = {
                    {{text="按服务器建立子目录：" .. (values.opds_pointer_per_server and "开启" or "关闭"),
                        callback=function() toggle("opds_pointer_per_server") end}},
                    {{text="保存系列封面：" .. (values.opds_cover_enabled and "开启" or "关闭"),
                        callback=function() toggle("opds_cover_enabled") end}},
                    {{text="取消",callback=function() registry:close(dialog) end},
                     {text="保存设置",callback=function()
                         values.opds_pointer_root = dialog:getFields()[1]
                         if model.on_save(values) then registry:close(dialog) end
                     end}},
                },
            }
            registry:show(dialog)
        end
        show_form()
    end
    function adapter:show_opds_connection(model)
        local dialog
        local function fields()
            local values = dialog:getFields()
            return {
                kind = "opds", name = values[1], server_url = values[2],
                server_kind = values[3], username = values[4], password = values[5],
            }
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.is_new and "新增 OPDS 连接" or "编辑 OPDS 连接",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {
                { description = "连接名称", text = model.values.name or "", hint = "例如：家庭 Komga" },
                { description = "OPDS 地址", text = model.values.server_url or "", hint = "https://server.example/opds" },
                { description = "服务器类型", text = model.values.server_kind or "auto", hint = "auto / kavita / suwayomi / komga" },
                { description = "用户名", text = model.values.username or "" },
                { description = "密码", text = model.values.password or "", text_type = "password" },
            },
            buttons = {{
                { text = "取消", id = "close", callback = guarded("close OPDS source", function()
                    if model.on_close then model.on_close() end
                    registry:close(dialog)
                end) },
                { text = "测试", callback = guarded("test OPDS source", function()
                    return model.on_test(fields())
                end) },
                { text = "保存", callback = guarded("save OPDS source", function()
                    if model.on_save(fields()) then registry:close(dialog) end
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
    end
    function adapter:show_connection(model)
        model = model or { values = {} }
        local draft = copy_table(model.values)
        for _, key in ipairs({ "name", "server_url", "username", "password", "root_path" }) do
            if draft[key] == nil then draft[key] = "" end
        end

        local function update_draft(dialog, keys)
            local values = dialog and dialog:getFields() or {}
            for index, key in ipairs(keys) do
                draft[key] = values[index] == nil and "" or values[index]
            end
        end

        local show_first_step
        local show_second_step

        show_first_step = function()
            local dialog
            local keys = { "name", "server_url", "username" }
            dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
                title = (model.title or (model.is_new and "新建 WebDAV 连接"
                    or "WebDAV 连接设置")) .. "（1/2）",
                fullscreen = true,
                condensed = true,
                enter_callback = function()
                    DialogKeyboard.hide(dialog)
                    return true
                end,
                fields = {
                    { description = "连接名称", text = draft.name, hint = "例如：主 NAS" },
                    { description = model.server_label or "服务器地址", text = draft.server_url,
                        hint = model.server_hint or "https://nas.example/dav" },
                    { description = "用户名", text = draft.username, hint = "WebDAV 用户名" },
                },
                buttons = {{
                    { text = "取消", id = "close", callback = guarded("close connection settings", function()
                        registry:close(dialog)
                    end) },
                    { text = "下一步", callback = guarded("continue connection settings", function()
                        update_draft(dialog, keys)
                        registry:close(dialog)
                        show_second_step()
                        return true
                    end) },
                }},
            }, function() return dialog end))
            registry:show(dialog)
            show_dialog_keyboard(dialog)
        end

        show_second_step = function()
            local dialog
            local keys = { "password", "root_path" }
            dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
                title = (model.title or (model.is_new and "新建 WebDAV 连接"
                    or "WebDAV 连接设置")) .. "（2/2）",
                fullscreen = true,
                condensed = true,
                enter_callback = function()
                    DialogKeyboard.hide(dialog)
                    return true
                end,
                fields = {
                    { description = "密码", text = draft.password, hint = "WebDAV 密码", text_type = "password" },
                    { description = "WebDAV 根目录", text = draft.root_path, hint = "/" },
                },
                buttons = {{
                    { text = "返回", id = "close", callback = guarded("return connection settings", function()
                        update_draft(dialog, keys)
                        registry:close(dialog)
                        show_first_step()
                        return true
                    end) },
                    { text = "测试", callback = guarded("test connection settings", function()
                        update_draft(dialog, keys)
                        return model.on_test(copy_table(draft))
                    end) },
                    { text = "保存", callback = guarded("save connection settings", function()
                        update_draft(dialog, keys)
                        if model.on_save(copy_table(draft)) then registry:close(dialog) end
                    end) },
                }},
            }, function() return dialog end))
            registry:show(dialog)
            show_dialog_keyboard(dialog)
        end

        show_first_step()
    end
    function adapter:show_nodeshare_connection(model)
        model = model or {}
        model.title = model.is_new and "新建节点小宝 TCP 组网" or "节点小宝 TCP 组网设置"
        model.server_label = "组网 WebDAV 地址"
        model.server_hint = "例如 http://100.64.1.2:5005"
        return self:show_connection(model)
    end
    function adapter:show_reader(model)
        self.dialog_epoch = self.dialog_epoch + 1
        local dialog_epoch = self.dialog_epoch
        model = model or { values = {} }
        model.values = copy_table(model.values)
        local root_dialog

        local function close(widget)
            if widget then pcall(registry.close, registry, widget) end
        end

        local function text_value(value)
            if value == nil then return "" end
            return tostring(value)
        end

        local on_off = {
            { value = true, text = "开启" },
            { value = false, text = "关闭" },
        }
        local function number_choices(values, suffix)
            local choices = {}
            for _, value in ipairs(values) do
                choices[#choices + 1] = { value = value, text = tostring(value) .. (suffix or "") }
            end
            return choices
        end
        local gray_presets = model.gray_presets
            or GrayEnhance.all_presets(model.values.gray_enhance_custom_presets)
        local gray_choices = {}
        for _, preset in ipairs(gray_presets) do
            gray_choices[#gray_choices + 1] = {
                value = preset.id,
                text = preset.name,
            }
        end
        local tone_presets = model.tone_presets
            or ToneAdjust.all_presets(model.values.tone_adjust_custom_presets)
        local tone_choices = {}
        for _, preset in ipairs(tone_presets) do
            tone_choices[#tone_choices + 1] = { value = preset.id, text = preset.name }
        end
        local sections = {
            {
                key = "reading", title = "阅读翻页", summary = "方向、预加载、刷新",
                items = {
                    { key = "direction", title = "翻页方向", choices = {
                        { value = "normal", text = "普通方向" },
                        { value = "manga", text = "日漫反向" },
                    } },
                    { key = "animation_enabled", title = "翻页动画", choices = on_off },
                    { key = "full_refresh_each_page", title = "每页完全刷新", choices = on_off },
                    { key = "show_preprocess_success", title = "显示处理成功提示", choices = on_off },
                },
            },
            {
                key = "network", title = "网络加载", summary = "Range 分段、预加载",
                items = {
                    { key = "range_streaming_enabled", title = "HTTP Range 分段加载",
                        choices = on_off },
                    { key = "prefetch_first_pages", title = "前段预加载边界",
                        description = "请输入 1 到 100 的整数页" },
                    { key = "prefetch_near_count", title = "前段预加载页数",
                        description = "请输入 0 到 10 的整数" },
                    { key = "prefetch_far_count", title = "后段预加载页数",
                        description = "请输入 0 到 10 的整数" },
                    { key = "prefetch_concurrency", title = "预加载并发数", choices = {
                        { value = 1, text = "1 路（省内存）" },
                        { value = 2, text = "2 路（推荐）" },
                        { value = 3, text = "3 路（更快）" },
                    } },
                    { key = "image_prefetch_enabled", title = "图片预加载",
                        description = "只对图片章节生效；关闭后不再后台下载后续图片",
                        choices = on_off },
                },
            },
            {
                key = "display", title = "图片显示", summary = "长条、适配、背景、进度条",
                items = {
                    {key = "bubble_zoom_enabled", title = "气泡放大", choices = on_off},
                    {key = "bubble_zoom_trigger", title = "气泡触发手势", choices = {
                        {value = "hold", text = "单指长按"}, {value = "tap", text = "单指点按（替代正文点按翻页）"},
                    }},
                    {key = "bubble_zoom_scale", title = "气泡放大倍率", choices = number_choices({1.5,2,3}," 倍")},
                    { key = "fit_mode", title = "显示模式", choices = {
                        { value = "page", text = "整页" },
                        { value = "width", text = "适宽" },
                        { value = "match", text = "调整匹配" },
                        { value = "webtoon", text = "长条连续阅读" },
                    } },
                    { key = "display_background", title = "阅读背景", choices = {
                        {value="auto",text="自动黑白"}, {value="white",text="白色"}, {value="black",text="黑色"},
                    } },
                    { key = "webtoon_smart_enabled", title = "长条智能翻屏", choices = on_off },
                    { key = "webtoon_overlap_percent", title = "长条翻屏重叠", choices = number_choices({0,5,10,15,20},"%") },
                    { key = "webtoon_fit_percent", title = "长条最多适高", choices = number_choices({0,5,10,15},"%") },
                    { key = "webtoon_margin_percent", title = "长条左右总边距", choices = number_choices({0,5,10,15,20},"%") },
                    { key = "show_progress_bar", title = "顶部进度条", choices = on_off },
                    { key = "progress_bar_thickness", title = "进度条厚度", choices = {
                        { value = 1, text = "1 倍（细）" },
                        { value = 2, text = "2 倍" },
                        { value = 3, text = "3 倍" },
                        { value = 4, text = "4 倍（粗）" },
                    } },
                },
            },
            {
                key = "split", title = "宽图拆分", summary = "比例范围、左右切分",
                items = {
                    { key = "split_enabled", title = "宽图拆分", choices = on_off },
                    { key = "split_min_ratio", title = "最小宽高比",
                        description = "请输入 1.00 到 4.00 的数字" },
                    { key = "split_max_ratio", title = "最大宽高比",
                        description = "请输入 1.00 到 4.00 的数字" },
                    { key = "split_cut_percent", title = "左右切分位置",
                        description = "请输入 10 到 90 的整数百分比" },
                    { key = "split_first_segment", title = "拆分首屏", choices = {
                        { value = "left", text = "先显示左边" },
                        { value = "right", text = "先显示右边" },
                    } },
                },
            },
            {
                key = "panel", title = "智能分格阅读默认值", summary = "仅默认引擎；视图、旋转、顺序、导航",
                items = {
                    { key = "panel_zoom_enabled", title = "智能分格", choices = on_off },
                    { key = "panel_view", title = "分格视图", choices = {
                        { value = "context", text = "保留周边" },{ value = "cut", text = "独立格" },{ value = "free", text = "自由视图" },
                    } },
                    { key = "panel_rotation", title = "只旋转分格图片", choices = number_choices({0,90,180,270},"°") },
                    { key = "panel_navigation", title = "分格导航", choices = {
                        { value = "horizontal", text = "左右" },{ value = "vertical", text = "上下" },
                    } },
                    { key = "panel_reverse_navigation", title = "反向操作", choices = on_off },
                    { key = "panel_order", title = "分格顺序", choices = {
                        { value = "follow", text = "跟随整页方向" },
                        { value = "normal", text = "左到右" },
                        { value = "manga", text = "右到左" },
                    } },
                    { key = "panel_show_adjacent", title = "显示相邻内容", choices = on_off },
                    { key = "panel_standard_margin_percent", title = "普通分格边距",
                        choices = number_choices({ 0, 2, 5, 10 }, "%") },
                    { key = "panel_hold_margin_percent", title = "自由缩放边距",
                        choices = number_choices({ 2, 5, 10, 15, 20 }, "%") },
                    { key = "panel_initial_zoom", title = "自由缩放倍率",
                        choices = number_choices({ 1.0, 1.2, 1.5, 2.0 }, " 倍") },
                },
            },
            {
                key = "crop", title = "裁切白边", summary = "识别强度、最大比例",
                items = {
                    { key = "auto_crop_enabled", title = "自动裁白边", choices = on_off },
                    { key = "auto_crop_strength", title = "白边识别强度",
                        description = "请输入 0 到 100 的整数，越大裁切越强" },
                    { key = "auto_crop_max_percent", title = "最大裁切比例",
                        description = "请输入每侧 0 到 30 的整数百分比" },
                },
            },
            {
                key = "gray_enhance", title = "漫画去灰增强",
                summary = "原图、清晰、强力与自定义",
                items = {
                    { key = "gray_enhance_enabled", title = "去灰增强总开关", choices = on_off },
                    { key = "gray_enhance_preset", title = "增强预设",
                        choices = gray_choices },
                    { key = "gray_enhance_manage", title = "自定义预设",
                        action = model.on_open_gray_settings,
                        value_text = function()
                            return "添加 black / white / gamma"
                        end },
                },
            },
            {
                key = "tone_adjust", title = "亮度与对比度",
                summary = "低开销 LUT 与自定义预设",
                items = {
                    { key = "tone_adjust_enabled", title = "亮度与对比度总开关",
                        choices = on_off },
                    { key = "tone_adjust_preset", title = "调整预设",
                        choices = tone_choices },
                    { key = "tone_adjust_manage", title = "自定义预设",
                        action = model.on_open_tone_settings,
                        value_text = function() return "添加亮度 / 对比度" end },
                },
            },
            {
                key = "other", title = "其他显示", summary = "封面网格列数",
                items = {
                    { key = "grid_columns", title = "书架封面列数", choices = {
                        { value = 5, text = "每排 5 本" },
                        { value = 3, text = "每排 3 本" },
                    } },
                },
            },
        }

        local function after_close(widget, callback)
            close(widget)
            local function continue_if_current()
                if adapter.dialog_epoch ~= dialog_epoch then return false end
                callback()
                return true
            end
            if type(UIManager.nextTick) == "function" then
                local ok, result = pcall(UIManager.nextTick, UIManager, continue_if_current)
                if ok and result ~= false then return true end
            end
            continue_if_current()
            return true
        end

        local function current_text(field)
            if type(field.value_text) == "function" then
                local ok, value = pcall(field.value_text)
                if ok then return tostring(value or "") end
            end
            local value = model.values[field.key]
            for _, choice in ipairs(field.choices or {}) do
                if choice.value == value then return choice.text end
            end
            return text_value(value)
        end

        local function persist(field, value)
            local merged = copy_table(model.values)
            merged[field.key] = value
            if model.on_save(merged) then
                model.values = merged
                return true
            end
            return false
        end

        local show_root, show_section

        local function show_field(section, field)
            local dialog
            if type(field.action) == "function" then
                return after_close(dialog, field.action)
            end
            if field.choices then
                local buttons, row = {}, {}
                for _, choice in ipairs(field.choices) do
                    local current = choice
                    row[#row + 1] = {
                        text = current.text,
                        callback = guarded("save " .. field.key, function()
                            if not persist(field, current.value) then return false end
                            return after_close(dialog, function() show_section(section) end)
                        end),
                    }
                    if #row == 2 then buttons[#buttons + 1] = row; row = {} end
                end
                local cancel = {
                    text = "取消",
                    callback = guarded("cancel " .. field.key, function()
                        return after_close(dialog, function() show_section(section) end)
                    end),
                }
                if #row == 1 then
                    row[#row + 1] = cancel
                    buttons[#buttons + 1] = row
                else
                    buttons[#buttons + 1] = { cancel }
                end
                dialog = ButtonDialog:new{
                    title = field.title,
                    width_factor = 0.92,
                    buttons = buttons,
                }
                registry:show(dialog)
                return true
            end

            dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
                title = field.title,
                fullscreen = true,
                condensed = true,
                enter_callback = function()
                    DialogKeyboard.hide(dialog)
                    return true
                end,
                fields = {{
                    description = field.description,
                    text = current_text(field),
                    input_type = "number",
                }},
                buttons = {{
                    { text = "取消", id = "close", callback = guarded(
                        "cancel " .. field.key, function()
                            return after_close(dialog, function() show_section(section) end)
                        end) },
                    { text = "保存", callback = guarded(
                        "save " .. field.key, function()
                            local input = dialog:getFields()
                            if not persist(field, input and input[1]) then return false end
                            return after_close(dialog, function() show_section(section) end)
                        end) },
                }},
            }, function() return dialog end))
            registry:show(dialog)
            show_dialog_keyboard(dialog)
            return true
        end

        show_section = function(section)
            local dialog
            local buttons, row = {}, {}
            for _, item in ipairs(section.items) do
                local field = item
                row[#row + 1] = {
                    text = field.title .. "\n当前：" .. current_text(field),
                    callback = guarded("open " .. field.key, function()
                        return after_close(dialog, function() show_field(section, field) end)
                    end),
                }
                if #row == 2 then buttons[#buttons + 1] = row; row = {} end
            end
            local back = {
                text = "返回设置首页",
                callback = guarded("back from " .. section.key, function()
                    return after_close(dialog, show_root)
                end),
            }
            if #row == 1 then
                row[#row + 1] = back
                buttons[#buttons + 1] = row
            else
                buttons[#buttons + 1] = { back }
            end
            dialog = ButtonDialog:new{
                title = section.title,
                width_factor = 0.94,
                buttons = buttons,
            }
            registry:show(dialog)
        end

        show_root = function()
            local buttons, row = {}, {}
            for _, section in ipairs(sections) do
                local current = section
                row[#row + 1] = {
                    text = current.title .. "\n" .. current.summary,
                    callback = guarded("open " .. current.key .. " settings", function()
                        return after_close(root_dialog, function() show_section(current) end)
                    end),
                }
                if #row == 2 then buttons[#buttons + 1] = row; row = {} end
            end
            local finish = {
                text = "完成",
                callback = guarded("close reader settings", function()
                    close(root_dialog)
                    return true
                end),
            }
            if #row == 1 then
                buttons[#buttons + 1] = row
                row = {}
            end
            local destinations = {}
            if type(model.on_open_history) == "function" then
                destinations[#destinations + 1] = {
                    text = "阅读历史",
                    callback = guarded("open history from settings", function()
                        return after_close(root_dialog, model.on_open_history)
                    end),
                }
            end
            if type(model.on_open_category_shelf) == "function" then
                destinations[#destinations + 1] = {
                    text = "漫画分类架",
                    callback = guarded("open category shelf from settings", function()
                        return after_close(root_dialog, model.on_open_category_shelf)
                    end),
                }
            end
            if #destinations > 0 then buttons[#buttons + 1] = destinations end
            if #row == 1 then
                row[#row + 1] = finish
                buttons[#buttons + 1] = row
            else
                buttons[#buttons + 1] = { finish }
            end
            root_dialog = ButtonDialog:new{
                title = "漫画阅读设置",
                width_factor = 0.94,
                buttons = buttons,
            }
            registry:show(root_dialog)
        end

        local initial_section
        for _, section in ipairs(sections) do
            if section.key == model.initial_section then
                initial_section = section
                break
            end
        end
        if initial_section then show_section(initial_section) else show_root() end
    end
    function adapter:show_gray_settings(model)
        model = model or { presets = {} }
        local dialog
        local function close()
            if dialog then registry:close(dialog); dialog = nil end
        end
        local function close_then(callback)
            close()
            if type(callback) ~= "function" then return true end
            if type(UIManager.nextTick) == "function" then
                local ok, result = pcall(UIManager.nextTick, UIManager, callback)
                if ok and result ~= false then return true end
            end
            return callback()
        end
        local buttons = {{
            { text = "去灰增强总开关：" .. (model.enabled == true and "开启" or "关闭"),
                callback = guarded("toggle gray enhancement", function()
                    return close_then(model.on_toggle)
                end) },
        }}
        for _, preset in ipairs(model.presets or {}) do
            local current = preset
            local detail
            if current.id == "original" then
                detail = "不处理"
            else
                detail = ("black=%s  white=%s  gamma=%.2f"):format(
                    tostring(current.black), tostring(current.white), tonumber(current.gamma) or 0)
            end
            local selected = current.id == model.selected_id and "● " or "○ "
            buttons[#buttons + 1] = {{
                text = selected .. tostring(current.name) .. "\n" .. detail,
                callback = guarded("select gray preset", function()
                    close()
                    if model.on_select then return model.on_select(current.id) end
                    return true
                end),
            }}
        end
        buttons[#buttons + 1] = {{
            text = "新增自定义预设",
            callback = guarded("add gray preset", function()
                close()
                return model.on_add and model.on_add() or true
            end),
        }}
        buttons[#buttons + 1] = {{
            text = "设置样本目录\n" .. (model.sample_path or "未设置"),
            callback = guarded("set gray sample path", function()
                close()
                return model.on_sample_path and model.on_sample_path() or true
            end),
        }}
        buttons[#buttons + 1] = {{
            text = "预览当前预设",
            callback = guarded("preview gray preset", function()
                return close_then(model.on_preview)
            end),
        }}
        if model.selected_id and tostring(model.selected_id):match("^custom%-") then
            buttons[#buttons + 1] = {{
                text = "编辑当前自定义预设",
                callback = guarded("edit selected gray preset", function()
                    close()
                    return model.on_edit and model.on_edit(model.selected_id) or true
                end),
            }}
            buttons[#buttons + 1] = {{
                text = "删除当前自定义预设",
                callback = guarded("delete selected gray preset", function()
                    close()
                    return model.on_delete and model.on_delete(model.selected_id) or true
                end),
            }}
        end
        buttons[#buttons + 1] = {{
            text = "关闭",
            callback = guarded("close gray settings", close),
        }}
        dialog = ButtonDialog:new{ title = "漫画去灰增强", width_factor = 0.94, buttons = buttons }
        registry:show(dialog)
        return true
    end
    function adapter:show_gray_preset_editor(model)
        model = model or { values = {} }
        local values = copy_table(model.values)
        local dialog
        local function fields()
            local input = dialog:getFields() or {}
            return {
                name = input[1] or "",
                black = input[2] or "",
                white = input[3] or "",
                gamma = input[4] or "",
            }
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.is_new and "新增去灰增强预设" or "编辑去灰增强预设",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {
                { description = "预设名称", text = values.name or "", hint = "例如：淡灰纸张" },
                { description = "black 黑点（0-254）", text = tostring(values.black or "40"), input_type = "number" },
                { description = "white 白点（1-255）", text = tostring(values.white or "238"), input_type = "number" },
                { description = "gamma 伽马（0.10-5.00）", text = tostring(values.gamma or "1.20"), input_type = "number" },
            },
            buttons = {{
                { text = "取消", id = "close", callback = guarded("cancel gray preset editor", function()
                    registry:close(dialog)
                    return true
                end) },
                { text = "保存", callback = guarded("save gray preset editor", function()
                    local result = model.on_save and model.on_save(fields())
                    if result then registry:close(dialog) end
                    return true
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
        return true
    end
    function adapter:show_tone_settings(model)
        model = model or { presets = {} }
        local dialog
        local function close()
            if dialog then registry:close(dialog); dialog = nil end
        end
        local function close_then(callback)
            close()
            if type(callback) ~= "function" then return true end
            if type(UIManager.nextTick) == "function" then
                local ok, result = pcall(UIManager.nextTick, UIManager, callback)
                if ok and result ~= false then return true end
            end
            return callback()
        end
        local buttons = {{
            { text = "亮度与对比度总开关：" .. (model.enabled == true and "开启" or "关闭"),
                callback = guarded("toggle tone adjustment", function()
                    return close_then(model.on_toggle)
                end) },
        }}
        for _, preset in ipairs(model.presets or {}) do
            local current = preset
            local detail = current.id == "original" and "不处理"
                or ("亮度=%s  对比度=%s"):format(
                    tostring(current.brightness), tostring(current.contrast))
            buttons[#buttons + 1] = {{
                text = (current.id == model.selected_id and "● " or "○ ")
                    .. tostring(current.name) .. "\n" .. detail,
                callback = guarded("select tone preset", function()
                    close()
                    return model.on_select and model.on_select(current.id) or true
                end),
            }}
        end
        buttons[#buttons + 1] = {{
            text = "新增自定义预设",
            callback = guarded("add tone preset", function()
                close()
                return model.on_add and model.on_add() or true
            end),
        }}
        buttons[#buttons + 1] = {{
            text = "设置样本目录\n" .. (model.sample_path or "未设置"),
            callback = guarded("set tone sample path", function()
                close()
                return model.on_sample_path and model.on_sample_path() or true
            end),
        }}
        buttons[#buttons + 1] = {{
            text = "预览当前预设",
            callback = guarded("preview tone preset", function()
                return close_then(model.on_preview)
            end),
        }}
        if model.selected_id and tostring(model.selected_id):match("^custom%-%d+$") then
            buttons[#buttons + 1] = {{
                text = "编辑当前自定义预设",
                callback = guarded("edit selected tone preset", function()
                    close()
                    return model.on_edit and model.on_edit(model.selected_id) or true
                end),
            }}
            buttons[#buttons + 1] = {{
                text = "删除当前自定义预设",
                callback = guarded("delete selected tone preset", function()
                    close()
                    return model.on_delete and model.on_delete(model.selected_id) or true
                end),
            }}
        end
        buttons[#buttons + 1] = {{
            text = "关闭",
            callback = guarded("close tone settings", close),
        }}
        dialog = ButtonDialog:new{
            title = "亮度与对比度", width_factor = 0.94, buttons = buttons,
        }
        registry:show(dialog)
        return true
    end
    function adapter:show_tone_preset_editor(model)
        model = model or { values = {} }
        local values = copy_table(model.values)
        local dialog
        local function fields()
            local input = dialog:getFields() or {}
            return {
                name = input[1] or "",
                brightness = input[2] or "",
                contrast = input[3] or "",
            }
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.is_new and "新增亮度与对比度预设" or "编辑亮度与对比度预设",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {
                { description = "预设名称", text = values.name or "", hint = "例如：清晰纸张" },
                { description = "亮度（-100 到 100）",
                    text = tostring(values.brightness or "0"), input_type = "number" },
                { description = "对比度（0 到 200，100 为原图）",
                    text = tostring(values.contrast or "100"), input_type = "number" },
            },
            buttons = {{
                { text = "取消", id = "close", callback = guarded(
                    "cancel tone preset editor", function()
                        registry:close(dialog)
                        return true
                    end) },
                { text = "保存", callback = guarded("save tone preset editor", function()
                    local result = model.on_save and model.on_save(fields())
                    if result then registry:close(dialog) end
                    return true
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
        return true
    end
    function adapter:show_gray_sample_path(model)
        model = model or { value = "" }
        local dialog
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = "设置灰度增强样本目录",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {{
                description = "Kindle 本地绝对路径",
                text = model.value or "",
                hint = "/mnt/us/Books/Samples",
            }},
            buttons = {{
                { text = "取消", id = "close", callback = guarded("cancel gray sample path", function()
                    registry:close(dialog)
                    return true
                end) },
                { text = "保存", callback = guarded("save gray sample path", function()
                    local input = dialog:getFields() or {}
                    local result = model.on_save and model.on_save(input[1] or "")
                    if result then registry:close(dialog) end
                    return true
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
        return true
    end
    function adapter:show_tone_sample_path(model)
        model = model or { value = "" }
        local stage = model.stage or "tone sample path"
        local dialog
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = model.title or "设置亮度与对比度样本目录",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = {{
                description = "Kindle 本地绝对路径",
                text = model.value or "",
                hint = "/mnt/us/Books/Samples",
            }},
            buttons = {{
                { text = "取消", id = "close", callback = guarded(
                    "cancel " .. stage, function()
                        registry:close(dialog)
                        return true
                    end) },
                { text = "保存", callback = guarded("save " .. stage, function()
                    local input = dialog:getFields() or {}
                    local result = model.on_save and model.on_save(input[1] or "")
                    if result then registry:close(dialog) end
                    return true
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
        return true
    end
    function adapter:show_kopt_sample_path(model)
        model = copy_table(model)
        model.title = "设置 KOReader 图像处理样本目录"
        model.stage = "KOReader image sample path"
        return self:show_tone_sample_path(model)
    end
    function adapter:show_filter_preview(model)
        model = model or {}
        local loaded, dependencies = pcall(function()
            local Device = require("device")
            return {
                Blitbuffer = require("ffi/blitbuffer"),
                Button = require("ui/widget/button"),
                CenterContainer = require("ui/widget/container/centercontainer"),
                Device = Device,
                FrameContainer = require("ui/widget/container/framecontainer"),
                Font = require("ui/font"),
                Geom = require("ui/geometry"),
                ImageWidget = require("ui/widget/imagewidget"),
                InputContainer = require("ui/widget/container/inputcontainer"),
                LineWidget = require("ui/widget/linewidget"),
                OverlapGroup = require("ui/widget/overlapgroup"),
                Screen = Device.screen,
                TextWidget = require("ui/widget/textwidget"),
                TitleBar = require("ui/widget/titlebar"),
                UIManager = require("ui/uimanager"),
                VerticalGroup = require("ui/widget/verticalgroup"),
                VerticalSpan = require("ui/widget/verticalspan"),
                HorizontalGroup = require("ui/widget/horizontalgroup"),
            }
        end)
        if not loaded or not dependencies.Screen then
            if model.on_close then model.on_close() end
            self:show_info(model.unavailable_message or "当前 KOReader 不支持图像预览。")
            return false
        end
        local InputContainer = dependencies.InputContainer
        local Preview = InputContainer:extend{
            -- Keep this as a normal fullscreen window so KOReader can route
            -- hardware Back and the close command to the preview itself.
            modal = false,
            fullscreen = true,
            covers_fullscreen = true,
        }
        local close_preview
        function Preview:init()
            self.dimen = dependencies.Screen:getSize()
            local width, height = self.dimen.w, self.dimen.h
            local face = dependencies.Font:getFace("smallinfofont")
                or dependencies.Font:getFace("cfont")
            local image_width = math.max(1, math.floor(width / 2))
            local function image(buffer, left_half)
                local displayed = buffer
                if buffer and type(buffer.viewport) == "function" then
                    local source_width = image_width * 2
                    if type(buffer.getWidth) == "function" then
                        local width_ok, width_value = pcall(buffer.getWidth, buffer)
                        if width_ok and tonumber(width_value) then
                            source_width = tonumber(width_value)
                        end
                    end
                    local half_width = math.max(1, math.floor(source_width / 2))
                    local source_height = height
                    if type(buffer.getHeight) == "function" then
                        local height_ok, height_value = pcall(buffer.getHeight, buffer)
                        if height_ok and tonumber(height_value) then
                            source_height = tonumber(height_value)
                        end
                    end
                    local called, viewport = pcall(buffer.viewport, buffer,
                        left_half and 0 or half_width, 0, half_width, source_height)
                    if called and viewport then displayed = viewport end
                end
                return dependencies.CenterContainer:new{
                    dimen = dependencies.Geom:new{ w = image_width, h = height },
                    dependencies.ImageWidget:new{
                        image = displayed,
                        image_disposable = false,
                        scale_factor = 1,
                    },
                }
            end
            local images = dependencies.HorizontalGroup:new{ align = "center",
                image(model.before_buffer, true), image(model.after_buffer, false),
            }
            local before_label = dependencies.TextWidget:new{ text = "原图", face = face }
            local after_label = dependencies.TextWidget:new{ text = "增强后", face = face }
            if model.before_label then before_label.text = model.before_label end
            if model.after_label then after_label.text = model.after_label end
            local labels = dependencies.HorizontalGroup:new{
                dependencies.CenterContainer:new{
                    dimen = dependencies.Geom:new{ w = image_width, h = 30 },
                    dependencies.FrameContainer:new{
                        margin = 0, padding = 2, bordersize = 0,
                        background = dependencies.Blitbuffer.COLOR_WHITE,
                        before_label,
                    },
                },
                dependencies.CenterContainer:new{
                    dimen = dependencies.Geom:new{ w = image_width, h = 30 },
                    dependencies.FrameContainer:new{
                        margin = 0, padding = 2, bordersize = 0,
                        background = dependencies.Blitbuffer.COLOR_WHITE,
                        after_label,
                    },
                },
            }
            local divider = dependencies.CenterContainer:new{
                dimen = dependencies.Geom:new{ w = width, h = height },
                dependencies.LineWidget:new{
                    dimen = dependencies.Geom:new{ w = 1, h = height },
                    background = dependencies.Blitbuffer.COLOR_BLACK,
                },
            }
            local return_button = dependencies.Button:new{
                text = "返回",
                text_font_face = "cfont",
                text_font_size = 24,
                width = math.min(240, math.max(1, width - 24)),
                height = math.max(64, math.floor(height * 0.10)),
                margin = 0,
                padding = 10,
                bordersize = 2,
                -- Preview:init runs before close_preview is assigned. Resolve
                -- the upvalue at tap time so the button never captures nil.
                callback = function() return close_preview and close_preview() end,
            }
            local return_size = return_button:getSize()
            local bottom_return = dependencies.VerticalGroup:new{
                dependencies.VerticalSpan:new{
                    width = math.max(1, height - return_size.h - 4),
                },
                dependencies.CenterContainer:new{
                    dimen = dependencies.Geom:new{ w = width, h = return_size.h },
                    return_button,
                },
            }
            self[1] = dependencies.OverlapGroup:new{
                dimen = dependencies.Geom:new{ w = width, h = height },
                dependencies.CenterContainer:new{
                    dimen = dependencies.Geom:new{ w = width, h = height },
                    images,
                },
                divider,
                labels,
                bottom_return,
            }
        end
        function Preview:onBack() return close_preview() end
        function Preview:onClose() return close_preview() end
        local widget = Preview:new{}
        local closed = false
        close_preview = function()
            if closed then return true end
            closed = true
            registry:close(widget)
            if model.on_close then pcall(model.on_close) end
            return true
        end
        registry:show(widget)
        dependencies.UIManager:setDirty(widget, "full")
        return { close = close_preview }
    end
    function adapter:show_gray_preview(model)
        model = model or {}
        model.unavailable_message = model.unavailable_message
            or "当前 KOReader 不支持灰度样本预览。"
        return self:show_filter_preview(model)
    end
    function adapter:show_tone_preview(model)
        model = model or {}
        model.unavailable_message = model.unavailable_message
            or "当前 KOReader 不支持亮度与对比度样本预览。"
        return self:show_filter_preview(model)
    end
    function adapter:show_kopt_preview(model)
        model = model or {}
        model.unavailable_message = model.unavailable_message
            or "当前 KOReader 不支持原生图像处理预览。"
        return self:show_filter_preview(model)
    end
    function adapter:show_light(model)
        local dialog
        local fields = {
            { description = ("前光强度（%d-%d）"):format(
                model.values.intensity_min, model.values.intensity_max),
                text = tostring(model.values.intensity), input_type = "number" },
        }
        if model.values.has_warmth then
            fields[#fields + 1] = {
                description = "色温（0 冷白 - 100 暖黄）",
                text = tostring(model.values.warmth), input_type = "number",
            }
        end
        local function values()
            local input = dialog:getFields()
            return { intensity = tonumber(input[1]), warmth = tonumber(input[2]) }
        end
        dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
            title = "前光与色温",
            fullscreen = true,
            condensed = true,
            enter_callback = function()
                DialogKeyboard.hide(dialog)
                return true
            end,
            fields = fields,
            buttons = {{
                { text = "取消", id = "close", callback = guarded("close light settings", function()
                    registry:close(dialog)
                end) },
                { text = "保存", callback = guarded("save light settings", function()
                    if model.on_save(values()) then registry:close(dialog) end
                end) },
            }},
        }, function() return dialog end))
        registry:show(dialog)
        show_dialog_keyboard(dialog)
    end
    function adapter:show_cache(model)
        local dialog
        local is_cover = model.kind == "cover"
        local is_stream = model.kind == "stream"
        local function edit_browse_policy()
            if is_cover or type(model.on_set_browse_policy) ~= "function" then
                return false
            end
            local policy_dialog
            pcall(registry.close, registry, dialog)
            policy_dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
                title = is_stream and "流式阅读缓存管理" or "浏览缓存管理",
                fullscreen = true,
                condensed = true,
                enter_callback = function()
                    DialogKeyboard.hide(policy_dialog)
                    return true
                end,
                fields = {
                    { description = "总大小 MB（16-32768 整数）",
                        text = tostring(model.browse_total_mb or 5120), input_type = "number" },
                    { description = "触发清理 MB（不超过总大小）",
                        text = tostring(model.browse_trigger_mb or 3072), input_type = "number" },
                    { description = "清理后保留 MB（小于触发大小）",
                        text = tostring(model.browse_retain_mb or 1024), input_type = "number" },
                    { description = "检查间隔分钟（1-1440）",
                        text = tostring(model.browse_interval_minutes or 10), input_type = "number" },
                },
                buttons = {{
                    { text = "取消", id = "close", callback = guarded(
                        "close browse cache policy input", function()
                            registry:close(policy_dialog)
                            adapter:show_cache(model)
                        end) },
                    { text = "保存", callback = guarded(
                        "save browse cache policy", function()
                            local values = policy_dialog:getFields()
                            local policy = {
                                total_mb = tonumber(values[1]),
                                trigger_mb = tonumber(values[2]),
                                retain_mb = tonumber(values[3]),
                                interval_minutes = tonumber(values[4]),
                            }
                            if model.on_set_browse_policy(policy) then
                                registry:close(policy_dialog)
                                for key, value in pairs(policy) do
                                    model["browse_" .. key] = value
                                end
                                adapter:show_cache(model)
                            end
                        end) },
                }},
            }, function() return policy_dialog end))
            registry:show(policy_dialog)
            show_dialog_keyboard(policy_dialog)
            return true
        end
        local function edit_limit()
            local limit_dialog
            local save_limit = is_cover and model.on_set_limit or model.on_set_limit
            -- Do not leave the cache panel underneath its numeric editor. A
            -- number dialog must own the top of the KOReader widget stack so
            -- the keyboard and the Back key are deterministic.
            pcall(registry.close, registry, dialog)
            limit_dialog = MultiInputDialog:new(DialogKeyboard.with_top_button({
                title = "修改缓存上限",
                fullscreen = true,
                condensed = true,
                enter_callback = function()
                    DialogKeyboard.hide(limit_dialog)
                    return true
                end,
                fields = {{
                    description = "缓存上限 MB（16-4096 整数）",
                    text = tostring(model.limit_mb), input_type = "number",
                }},
                buttons = {{
                    { text = "取消", id = "close", callback = guarded("close cache limit input", function()
                        registry:close(limit_dialog)
                        adapter:show_cache(model)
                    end) },
                    { text = "保存", callback = guarded("save cache limit input", function()
                        local values = limit_dialog:getFields()
                        if type(save_limit) == "function" and save_limit(values[1]) then
                            registry:close(limit_dialog)
                            registry:close(dialog)
                            model.limit_mb = tonumber(values[1]) or model.limit_mb
                            adapter:show_cache(model)
                        end
                    end) },
                }},
            }, function() return limit_dialog end))
            registry:show(limit_dialog)
            show_dialog_keyboard(limit_dialog)
        end
        dialog = ButtonDialog:new{
            title = is_cover
                and ("封面缓存：%.1f MB（%d 张）\n独立缓存上限 %.0f MB")
                    :format(model.used_mb, model.count or 0, model.limit_mb)
                or is_stream
                and ("流式阅读缓存：%.1f / %.0f MB\nKindle 剩余空间：%.1f MB\n缓存目录：%s")
                    :format(model.used_mb, model.limit_mb, model.available_mb or 0,
                        model.stream_cache_path or "/mnt/us/koreader/cache/webdavmanga")
                or ("图片缓存索引：%.1f / %.0f MB（使用中 %.1f MB）\n封面缓存：%.1f MB（%d 张）\n整部漫画缓存：%.1f MB")
                    :format(model.used_mb, model.limit_mb, model.protected_mb,
                        model.cover_mb or 0, model.cover_count or 0,
                        model.offline_used_mb or 0),
            buttons = is_cover and {
                {{ text = "修改封面缓存上限", callback = guarded("edit cover cache limit", edit_limit) }},
                {{ text = "清理封面缓存（释放空间）", callback = guarded("request cover cache clear", function()
                    model.on_clear()
                end) }},
                {{ text = "关闭", callback = guarded("close cover cache settings", function() registry:close(dialog) end) }},
            } or is_stream and {
                {{ text = "修改流式缓存策略", callback = guarded(
                    "edit stream cache policy", edit_browse_policy) }},
                {{ text = "手动清理流式缓存", callback = guarded(
                    "clear stream cache", function()
                        if model.on_clear then return model.on_clear() end
                    end) }},
                {{ text = "关闭", callback = guarded("close stream cache settings", function()
                    registry:close(dialog)
                end) }},
            } or {
                {{ text = "修改缓存上限", callback = guarded("edit cache limit", edit_limit) }},
                {{ text = "流式阅读缓存", callback = guarded(
                    "open stream cache settings", function()
                        registry:close(dialog)
                        if model.on_stream_cache then return model.on_stream_cache() end
                    end) }},
                {{ text = "整部漫画缓存", callback = guarded(
                    "open whole manga cache", function()
                        registry:close(dialog)
                        if model.on_offline_cache then return model.on_offline_cache() end
                    end) }},
                {{text="漫画书架封面缓存",enabled=model.on_bookshelf_cache~=nil,
                    callback=guarded("open bookshelf cache settings",function()
                        registry:close(dialog)
                        if model.on_bookshelf_cache then return model.on_bookshelf_cache() end
                    end)}},
                {{ text = "清空图片缓存（仅索引）", callback = guarded("request cache clear", function() model.on_clear() end) }},
                {{ text = "删除插件图片缓存文件", callback = guarded(
                    "request page cache file clear", function()
                        if model.on_delete_page_files then return model.on_delete_page_files() end
                    end) }},
                {{ text = "管理封面缓存", callback = guarded("open cover cache settings", function()
                    registry:close(dialog)
                    if model.on_cover_cache then return model.on_cover_cache() end
                end) }},
                {{ text = "关闭", callback = guarded("close cache settings", function() registry:close(dialog) end) }},
            },
        }
        registry:show(dialog)
    end
    function adapter:show_offline_cache(model)
        model = model or {}
        local status = model.status or {}
        local finished = math.max(0, tonumber(status.downloaded) or 0)
            + math.max(0, tonumber(status.cached) or 0)
            + math.max(0, tonumber(status.failed) or 0)
        local total = math.max(finished, tonumber(status.total) or 0)
        local state_labels = {
            idle = "空闲", scanning = "正在扫描", running = "正在缓存", complete = "已完成",
            canceled = "已取消", space = "空间不足，已停止",
            limit = "超过缓存上限，已停止", error = "操作失败", empty = "未找到图片",
        }
        local state = state_labels[tostring(status.status or "idle")] or "未知"
        if status.running and total > 0 then
            state = ("正在缓存 %d / %d 页（失败 %d）"):format(
                finished, total, math.max(0, tonumber(status.failed) or 0))
        elseif status.running then
            state = "正在读取漫画目录"
        end
        local manga_line = model.manga_name and model.manga_name ~= ""
            and ("\n本漫画：%s，已保存 %.1f MB"):format(
                model.manga_name, model.manga_mb or 0) or ""
        local dialog
        local buttons = {}
        if status.running then
            buttons[#buttons + 1] = {{ text = "刷新进度", callback = guarded(
                "refresh whole manga cache", function()
                    registry:close(dialog)
                    return model.on_refresh and model.on_refresh()
                end) }}
            buttons[#buttons + 1] = {{ text = "取消当前缓存", callback = guarded(
                "cancel whole manga cache", function()
                    registry:close(dialog)
                    local result = model.on_cancel and model.on_cancel()
                    if model.on_refresh then model.on_refresh() end
                    return result
                end) }}
        elseif model.on_start then
            buttons[#buttons + 1] = {{ text = "开始缓存整部漫画", callback = guarded(
                "start whole manga cache", function()
                    registry:close(dialog)
                    return model.on_start()
                end) }}
        end
        if not status.running and model.on_retry then
            buttons[#buttons + 1] = {{ text = "重试未完成页面", callback = guarded(
                "retry whole manga cache", function()
                    registry:close(dialog)
                    return model.on_retry()
                end) }}
        end
        if not status.running then
            buttons[#buttons + 1] = {{ text = "修改进度刷新间隔", callback = guarded(
                "edit offline refresh interval", function()
                    local input
                    input = MultiInputDialog:new(DialogKeyboard.with_top_button({
                        title = "进度刷新间隔",
                        fullscreen = true,
                        condensed = true,
                        enter_callback = function()
                            DialogKeyboard.hide(input)
                            return true
                        end,
                        fields = {{
                            description = "刷新间隔（秒，1-60 整数）",
                            text = tostring(model.refresh_seconds or 15), input_type = "number",
                        }},
                        buttons = {{
                            { text = "取消", id = "close", callback = guarded(
                                "close offline refresh input", function() registry:close(input) end) },
                            { text = "保存", callback = guarded(
                                "save offline refresh input", function()
                                    local values = input:getFields()
                                    if model.on_set_refresh and model.on_set_refresh(values[1]) then
                                        registry:close(input)
                                        if model.on_refresh then model.on_refresh() end
                                    end
                                end) },
                        }},
                    }, function() return input end))
                    registry:show(input)
                    show_dialog_keyboard(input)
                    return true
                end) }}
            buttons[#buttons + 1] = {{ text = "修改保存目录", callback = guarded(
                "edit whole manga root", function()
                    local input
                    local function edit_limit()
                        local limit_input
                        registry:close(input)
                        limit_input = MultiInputDialog:new(DialogKeyboard.with_top_button({
                            title = "整部漫画缓存上限",
                            fullscreen = true,
                            condensed = true,
                            enter_callback = function()
                                DialogKeyboard.hide(limit_input)
                                return true
                            end,
                            fields = {{
                                description = "缓存上限 GB（1-20 整数）",
                                text = tostring(model.limit_gb or 5), input_type = "number",
                            }},
                            buttons = {{
                                { text = "取消", id = "close", callback = guarded(
                                    "close whole manga limit input", function()
                                        registry:close(limit_input)
                                        if model.on_refresh then model.on_refresh() end
                                    end) },
                                { text = "保存", callback = guarded(
                                    "save whole manga limit input", function()
                                        local values = limit_input:getFields()
                                        if model.on_set_limit and model.on_set_limit(values[1]) then
                                            registry:close(limit_input)
                                            if model.on_refresh then model.on_refresh() end
                                        end
                                    end) },
                            }},
                        }, function() return limit_input end))
                        registry:show(limit_input)
                        show_dialog_keyboard(limit_input)
                        return true
                    end
                    registry:close(dialog)
                    input = MultiInputDialog:new(DialogKeyboard.with_top_button({
                        title = "整部漫画保存目录",
                        fullscreen = true,
                        condensed = true,
                        enter_callback = function()
                            DialogKeyboard.hide(input)
                            return true
                        end,
                        fields = {{
                            description = "Kindle 本地目录（必须位于 /mnt/us）",
                            text = tostring(model.root or "/mnt/us/Books/WebDAVManga"),
                        }},
                        buttons = {{
                            { text = "取消", id = "close", callback = guarded(
                                "close whole manga root input", function()
                                    registry:close(input)
                                    if model.on_refresh then model.on_refresh() end
                                end) },
                            { text = "修改缓存上限", callback = guarded(
                                "edit whole manga limit", edit_limit) },
                            { text = "保存", callback = guarded(
                                "save whole manga root input", function()
                                    local values = input:getFields()
                                    if model.on_set_root and model.on_set_root(values[1]) then
                                        registry:close(input)
                                        if model.on_refresh then model.on_refresh() end
                                    end
                                end) },
                        }},
                    }, function() return input end))
                    registry:show(input)
                    show_dialog_keyboard(input)
                    return true
                end) }}
        end
        buttons[#buttons + 1] = {{ text = "关闭", callback = guarded(
            "close whole manga cache", function() registry:close(dialog) end) }}
        dialog = ButtonDialog:new{
            title = ("整部漫画缓存\n目录：%s\n全部已保存：%.1f MB%s\nKindle：已用 %.1f / %.1f MB，剩余 %.1f MB\n安全保留：%.0f MB｜进度刷新间隔：%d 秒｜任务：%s")
                :format(tostring(model.root or ""), model.offline_used_mb or 0,
                    manga_line, model.used_mb or 0, model.total_mb or 0,
                    model.available_mb or 0, model.reserve_mb or 5 * 1024,
                    tonumber(model.refresh_seconds) or 15, state),
            buttons = buttons,
        }
        registry:show(dialog)
        return dialog
    end
    function adapter:show_about(model)
        local dialog
        dialog = ButtonDialog:new{
            title = "关于",
            buttons = {{
                { text = model.actions[1].text,
                    callback = guarded("show version information", model.actions[1].callback) },
                { text = model.actions[2].text,
                    callback = guarded("run image format diagnostics", model.actions[2].callback) },
                { text = "关闭", callback = guarded("close about dialog", function() registry:close(dialog) end) },
            }},
        }
        registry:show(dialog)
    end
    function adapter:close_all()
        self.dialog_epoch = self.dialog_epoch + 1
        return registry:close_all()
    end
    return adapter
end

local function default_network_manager()
    local ok, manager = pcall(require, "ui/network/manager")
    if ok then return manager end
    return { willRerunWhenConnected = function() return false end }
end

function UiSettings:new(deps)
    deps = deps or {}
    local object = setmetatable({}, self)
    object.settings = assert(deps.settings, "settings is required")
    object.client_factory = assert(deps.client_factory, "client factory is required")
    object.opds_client_factory = deps.opds_client_factory
    object.open_source_shelf = deps.open_source_shelf
    object.async = assert(deps.async, "async adapter is required")
    object.cache = assert(deps.cache, "cache is required")
    object.offline_cache = deps.offline_cache
    object.offline_manager = deps.offline_manager
    object.bookshelf_ui=deps.bookshelf_ui
    object.identity_provider = deps.identity_provider or function() return "" end
    object.lighting = deps.lighting
    object.ui = deps.ui or default_ui()
    object.error_reporter = deps.error_reporter
    object.on_connection_saved = deps.on_connection_saved
    object.on_offline_root_saved = deps.on_offline_root_saved
    object.on_reader_saved = deps.on_reader_saved
    object.open_history = deps.open_history
    object.open_category_shelf = deps.open_category_shelf
    object.close_reader_controls = deps.close_reader_controls
    object.network_manager = deps.network_manager or default_network_manager()
    object.nodeshare = deps.nodeshare
    object.license = deps.license
    object.scheduler = deps.scheduler
    object.render_image = deps.render_image
    object.native_image_filter = deps.native_image_filter or NativeImageFilter
    object.sample_image_finder = deps.sample_image_finder
        or GrayEnhance.first_image_in_directory
    object.gray_preview_cleanup = nil
    if not object.scheduler then
        local ok, manager = pcall(require, "ui/uimanager")
        if ok then object.scheduler = manager end
    end
    return object
end

function UiSettings:_callback(label, callback, fallback)
    return SafeCallback.wrap(self.error_reporter or self.ui, label, callback, fallback)
end

function UiSettings:show_license(model)
    model = model or {}
    local request = copy_table(model)
    request.status = request.status or function()
        if self.license and type(self.license.status) == "function" then
            local ok, value = pcall(self.license.status, self.license)
            if ok and type(value) == "table" then return value end
        end
        return { authorized = false, error_code = "service_unavailable" }
    end
    request.activate = request.activate or function(key, callback)
        if not self.license then
            if callback then callback(false, "service_unavailable") end
            return false
        end
        if type(self.license.prepare_activation) == "function"
            and type(self.license.request_activation) == "function"
            and type(self.license.commit_activation) == "function"
            and self.async and type(self.async.run) == "function" then
            local prepared_ok, prepared, prepare_error = pcall(
                self.license.prepare_activation, self.license, key)
            if not prepared_ok or type(prepared) ~= "table" then
                if callback then callback(false,
                    prepared_ok and prepare_error or "service_unavailable") end
                return false
            end
            local license = self.license
            local canceled = false
            local run_ok, handle = pcall(self.async.run, function()
                local request_ok, receipt, request_error = pcall(
                    license.request_activation, license, prepared)
                if not request_ok then return { error = "service_unavailable" } end
                if type(receipt) ~= "table" then
                    return { error = request_error or "service_unavailable" }
                end
                return { receipt = receipt }
            end, function(async_ok, result)
                if canceled then return end
                if not async_ok or type(result) ~= "table" then
                    if callback then callback(false, "service_unavailable") end
                    return
                end
                if type(result.receipt) ~= "table" then
                    if callback then callback(false,
                        result.error or "service_unavailable") end
                    return
                end
                local commit_ok, committed, commit_result = pcall(
                    license.commit_activation, license, result.receipt, prepared)
                if not commit_ok or committed ~= true then
                    if callback then callback(false,
                        commit_ok and commit_result or "service_unavailable") end
                    return
                end
                if callback then callback(true, commit_result) end
            end, { timeout = 30, max_payload_bytes = 8192 })
            if not run_ok or type(handle) ~= "table" then
                if callback then callback(false, "service_unavailable") end
                return false
            end
            return {
                cancel = function()
                    if canceled then return end
                    canceled = true
                    if type(handle.cancel) == "function" then
                        pcall(handle.cancel, handle)
                    end
                end,
            }
        end
        if type(self.license.activate) ~= "function" then
            if callback then callback(false, "service_unavailable") end
            return false
        end
        local ok, result = pcall(self.license.activate, self.license, key, callback)
        if not ok then
            if callback then callback(false, "service_unavailable") end
            return false
        end
        return result
    end
    request.clear_local = request.clear_local or function()
        if not self.license or type(self.license.clear_local) ~= "function" then
            return false, "save_failed"
        end
        local ok, cleared, error_code = pcall(self.license.clear_local, self.license)
        if not ok or cleared ~= true then return false, error_code or "save_failed" end
        return true
    end
    request.error_message = request.error_message or function(reason)
        return Errors.message{ code = "license", reason = reason }
    end
    request.on_close = request.on_close or function() end
    local activation_in_flight = false
    local activation_handle
    local activation_generation = 0
    local activate = request.activate
    request.activate = function(key, callback)
        if activation_in_flight then return false end
        activation_in_flight = true
        activation_generation = activation_generation + 1
        local generation = activation_generation
        local function finish(ok, result)
            if generation ~= activation_generation then return end
            if ok then
                if activation_handle then activation_in_flight = false end
                activation_handle = nil
            else
                activation_in_flight = false
                activation_handle = nil
            end
            if callback then return callback(ok, result) end
        end
        local ok, result = pcall(activate, key, finish)
        if not ok then
            activation_in_flight = false
            activation_handle = nil
            if callback then callback(false, "service_unavailable") end
            return false
        end
        if activation_in_flight and generation == activation_generation
            and type(result) == "table" then
            activation_handle = result
        end
        return result
    end
    request.cancel_activation = function()
        if not activation_in_flight then return false end
        activation_generation = activation_generation + 1
        activation_in_flight = false
        local handle = activation_handle
        activation_handle = nil
        if handle and type(handle.cancel) == "function" then
            pcall(handle.cancel, handle)
        end
        return true
    end
    if self.ui and type(self.ui.show_license) == "function" then
        return self.ui:show_license(request)
    end
    if self.ui and type(self.ui.show_info) == "function" then
        self.ui:show_info("当前界面适配器不支持授权设置。")
    end
    return false
end

function UiSettings:_invalidate_opds_test(lifecycle)
    lifecycle = lifecycle or self.opds_test_lifecycle
    if not lifecycle then return end
    lifecycle.generation = lifecycle.generation + 1
    local handle, busy = lifecycle.handle, lifecycle.busy
    lifecycle.handle, lifecycle.busy = nil, nil
    if handle and type(handle.cancel) == "function" then handle:cancel() end
    if busy and type(busy.close) == "function" then busy.close() end
end

function UiSettings:close_all()
    if self.bookshelf_ui then self.bookshelf_ui:close_all() end
    if self.opds_test_lifecycle then
        self.opds_test_lifecycle.closed = true
        self:_invalidate_opds_test()
        self.opds_test_lifecycle = nil
    end
    self:_release_gray_preview()
    if self.ui and type(self.ui.close_all) == "function" then
        local ok, result = pcall(self.ui.close_all, self.ui)
        return ok and result ~= false
    end
    return true
end

function UiSettings:_run_nodeshare_connection_test(values)
    if not self.nodeshare or type(self.nodeshare.probe) ~= "function" then
        self.ui:show_info(validation_message("nodeshare_unavailable"))
        return false
    end
    local endpoint, endpoint_error = self.nodeshare:parse_endpoint(
        values and values.server_url)
    if not endpoint then
        self.ui:show_info(nodeshare_message(endpoint_error))
        return false
    end
    local valid, validation_error = is_connection_shape_valid(values)
    if not valid then
        self.ui:show_info(validation_message(validation_error))
        return false
    end

    local start = self:_callback("start NodeShare TCP test", function()
        local busy = self.ui:show_busy("正在检测 TCP 组网并验证 WebDAV…")
        self.async.run(function()
            local reachable, tcp_error = self.nodeshare:probe(values.server_url)
            if not reachable then
                return { ok = false, stage = "tcp", error = tcp_error }
            end
            local ok, webdav_error = self.client_factory(values):test_connection()
            return { ok = ok == true, stage = "webdav", error = webdav_error }
        end, self:_callback("finish NodeShare TCP test", function(async_ok, result, async_error)
            if busy and busy.close then busy.close() end
            if not async_ok then
                self.ui:show_info(Errors.message{ code = "transport", detail = async_error })
            elseif result and result.ok then
                self.ui:show_info("TCP 组网与 WebDAV 连接均成功。")
            elseif result and result.stage == "tcp" then
                self.ui:show_info(nodeshare_message(result.error))
            else
                self.ui:show_info(Errors.message(result and result.error))
            end
        end))
    end)
    local deferred = SafeCallback.call(self.error_reporter or self.ui,
        "NodeShare TCP test network gate", function()
            return self.network_manager:willRerunWhenConnected(start)
        end, false)
    if deferred then return true end
    start()
    return true
end

function UiSettings:_show_nodeshare_connection_dialog(on_saved, source_id, is_new)
    if not self.nodeshare or type(self.nodeshare.parse_endpoint) ~= "function"
        or type(self.ui.show_nodeshare_connection) ~= "function" then
        self.ui:show_info(validation_message("nodeshare_unavailable"))
        return false
    end
    local current = source_id and self.settings:get_source(source_id) or {}
    current = current or {}
    self.ui:show_nodeshare_connection{
        values = {
            name = current.name or "",
            kind = "nodeshare",
            server_url = current.server_url or "http://",
            username = current.username or "",
            password = current.password or "",
            root_path = current.root_path or "/",
        },
        is_new = is_new == true,
        on_test = self:_callback("test NodeShare TCP connection", function(input)
            input.kind = "nodeshare"
            return self:_run_nodeshare_connection_test(input)
        end, false),
        on_save = self:_callback("save NodeShare TCP connection", function(input)
            input = input or {}
            local endpoint, endpoint_error = self.nodeshare:parse_endpoint(input.server_url)
            if not endpoint then
                self.ui:show_info(nodeshare_message(endpoint_error))
                return false
            end
            input.kind = "nodeshare"
            input.nodeshare = self.nodeshare.metadata(endpoint)
            local ok, err
            if is_new and type(self.settings.add_source) == "function" then
                ok, err = self.settings:add_source(input)
            elseif source_id and type(self.settings.set_source) == "function" then
                ok, err = self.settings:set_source(source_id, input)
            else
                ok, err = self.settings:set_connection(input)
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            local active_id = type(self.settings.get_active_source_id) == "function"
                and self.settings:get_active_source_id() or nil
            if is_new or not source_id or source_id == active_id then
                if self.on_connection_saved then
                    self.on_connection_saved(self.settings:get_connection())
                end
            end
            self.ui:show_info("节点小宝 TCP 组网连接已保存。")
            if on_saved then on_saved() end
            return true
        end, false),
    }
    return true
end

function UiSettings:_run_connection_test(values)
    if values and values.kind == "local" then
        local local_path = tostring(values.local_path or ""):match("^%s*(.-)%s*$")
        if local_path == "" or local_path:sub(1, 1) ~= "/" then
            self.ui:show_info(validation_message("invalid_local_path"))
            return false
        end
        local start = self:_callback("start local connection test", function()
            local busy = self.ui:show_busy("正在测试 Kindle 本地目录…")
            self.async.run(function()
                local ok, err = self.client_factory(values):test_connection()
                return { ok = ok == true, error = err }
            end, self:_callback("finish local connection test", function(async_ok, result, async_error)
                if busy and busy.close then busy.close() end
                if not async_ok then
                    self.ui:show_info(Errors.message({ code = "local_path", detail = async_error }))
                elseif result and result.ok then
                    self.ui:show_info("本地目录可用。")
                else
                    self.ui:show_info(Errors.message(result and result.error))
                end
            end))
        end)
        start()
        return true
    end
    local valid, validation_error = is_connection_shape_valid(values)
    if not valid then
        self.ui:show_info(validation_message(validation_error))
        return false
    end
    local start = self:_callback("start connection test", function()
        local busy = self.ui:show_busy("正在测试 WebDAV 连接…")
        self.async.run(function()
            local ok, err = self.client_factory(values):test_connection()
            return { ok = ok == true, error = err }
        end, self:_callback("finish connection test", function(async_ok, result, async_error)
            if busy and busy.close then busy.close() end
            if not async_ok then
                self.ui:show_info(Errors.message{ code = "transport", detail = async_error })
            elseif result and result.ok then
                self.ui:show_info("连接成功。")
            else
                self.ui:show_info(Errors.message(result and result.error))
            end
        end))
    end)
    local deferred = SafeCallback.call(self.error_reporter or self.ui, "connection test network gate", function()
        return self.network_manager:willRerunWhenConnected(start)
    end, false)
    if deferred then return true end
    start()
    return true
end

function UiSettings:_run_opds_connection_test(values, on_detected, lifecycle, generation)
    local function is_current()
        return not lifecycle or (not lifecycle.closed
            and lifecycle.generation == generation)
    end
    local url = tostring(values.server_url or ""):match("^%s*(.-)%s*$"):gsub("/+$", "")
    if not url:match("^https?://[^/]+") then
        self.ui:show_info(validation_message("invalid_opds_url"))
        return false
    end
    if type(self.opds_client_factory) ~= "function" then
        self.ui:show_info("OPDS 客户端未初始化。")
        return false
    end
    local start = self:_callback("start OPDS connection test", function()
        if not is_current() then return false end
        local busy = self.ui:show_busy("正在测试 OPDS 连接…")
        if lifecycle then lifecycle.busy = busy end
        local settled = false
        local handle = self.async.run(function()
            local client = self.opds_client_factory(values)
            local feed, err = client:fetch(url, {
                username = values.username, password = values.password,
            })
            if not feed then return { error = err } end
            if feed.is_atom_feed ~= true or type(feed.entries) ~= "table"
                or #feed.entries == 0 then
                return { error = "empty_opds_feed" }
            end
            return { ok = true, server_kind = feed.server_kind }
        end, self:_callback("finish OPDS connection test", function(async_ok, result, async_error)
            settled = true
            if not is_current() then return false end
            if lifecycle then lifecycle.handle, lifecycle.busy = nil, nil end
            if busy and busy.close then busy.close() end
            if not async_ok then
                self.ui:show_info(Errors.message{ code = "transport", detail = async_error })
            elseif result and result.ok then
                local kind = result.server_kind
                if kind ~= "kavita" and kind ~= "suwayomi" and kind ~= "komga" then
                    kind = values.server_kind
                end
                if kind ~= "kavita" and kind ~= "suwayomi" and kind ~= "komga" then
                    kind = "auto"
                end
                if on_detected then on_detected(kind) end
                self.ui:show_info("OPDS 连接成功。")
            elseif result and result.error == "empty_opds_feed" then
                self.ui:show_info("OPDS 返回空目录或非 Atom Feed。")
            else
                self.ui:show_info(Errors.message(result and result.error))
            end
        end))
        if lifecycle and not settled and is_current() then lifecycle.handle = handle end
    end)
    local deferred = SafeCallback.call(self.error_reporter or self.ui,
        "OPDS connection test network gate", function()
            return self.network_manager:willRerunWhenConnected(start)
        end, false)
    if deferred then return true end
    start()
    return true
end

function UiSettings:_show_opds_connection_dialog(on_saved, source_id, is_new)
    if type(self.ui.show_opds_connection) ~= "function" then
        self.ui:show_info("当前 KOReader 界面适配器不支持 OPDS 连接。")
        return false
    end
    local current = source_id and self.settings:get_source(source_id) or {}
    local values = {
        kind = "opds", name = current.name or "",
        server_url = current.server_url or "",
        server_kind = current.server_kind or "auto",
        username = current.username or "", password = current.password or "",
    }
    local detected_kind, tested_identity
    if self.opds_test_lifecycle then
        self.opds_test_lifecycle.closed = true
        self:_invalidate_opds_test()
    end
    local lifecycle = { generation = 0, closed = false }
    self.opds_test_lifecycle = lifecycle
    local function invalidate()
        self:_invalidate_opds_test(lifecycle)
    end
    local active_id = self.settings:get_active_source_id()
    self.ui:show_opds_connection{
        values = values, is_new = is_new == true,
        on_close = self:_callback("close OPDS connection", function()
            if lifecycle.closed then return true end
            lifecycle.closed = true
            invalidate()
            if self.opds_test_lifecycle == lifecycle then
                self.opds_test_lifecycle = nil
            end
            return true
        end, false),
        on_test = self:_callback("test OPDS connection", function(input)
            if lifecycle.closed then return false end
            invalidate()
            tested_identity, detected_kind = nil, nil
            local generation = lifecycle.generation
            local identity = table.concat({ tostring(input.server_url or ""),
                tostring(input.username or ""), tostring(input.password or "") }, "\0")
            return self:_run_opds_connection_test(input, function(kind)
                tested_identity, detected_kind = identity, kind
            end, lifecycle, generation)
        end, false),
        on_save = self:_callback("save OPDS connection", function(input)
            if lifecycle.closed then return false end
            invalidate()
            input.kind = "opds"
            local identity = table.concat({ tostring(input.server_url or ""),
                tostring(input.username or ""), tostring(input.password or "") }, "\0")
            if identity == tested_identity then input.server_kind = detected_kind end
            local ok, err
            if is_new then
                ok, err = self.settings:add_source(input)
            else
                ok, err = self.settings:set_source(source_id, input)
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            lifecycle.closed = true
            if self.opds_test_lifecycle == lifecycle then
                self.opds_test_lifecycle = nil
            end
            self.settings:flush()
            if (is_new or source_id == active_id) and self.on_connection_saved then
                self.on_connection_saved(self.settings:get_connection())
            end
            self.ui:show_info("OPDS 连接已保存。")
            if on_saved then on_saved() end
            return true
        end, false),
    }
    return true
end

function UiSettings:_show_connection_dialog(on_saved, source_id, is_new)
    local current = source_id and self.settings:get_source(source_id)
        or self.settings:get_connection()
    current = current or {}
    local values = {
        name = current.name or "",
        kind = current.kind,
        nodeshare = current.nodeshare,
        server_url = current.server_url or "",
        username = current.username or "",
        password = current.password or "",
        root_path = current.root_path or "",
    }
    local active_id = type(self.settings.get_active_source_id) == "function"
        and self.settings:get_active_source_id() or nil
    self.ui:show_connection{
        values = values,
        is_new = is_new == true,
        on_test = self:_callback("test connection", function(input)
            return self:_run_connection_test(input)
        end, false),
        on_save = self:_callback("save connection", function(input)
            local ok, err
            if is_new and type(self.settings.add_source) == "function" then
                ok, err = self.settings:add_source(input)
            elseif source_id and type(self.settings.set_source) == "function" then
                ok, err = self.settings:set_source(source_id, input)
            else
                ok, err = self.settings:set_connection(input)
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            local affects_active = is_new or not source_id or source_id == active_id
            if affects_active and self.on_connection_saved then
                self.on_connection_saved(input)
            end
            self.ui:show_info("连接设置已保存。")
            if on_saved then on_saved() end
            return true
        end, false),
    }
end

function UiSettings:_show_local_connection_dialog(on_saved, source_id, is_new)
    if type(self.ui.show_local_connection) ~= "function" then
        self.ui:show_info("当前 KOReader 界面适配器不支持 Kindle 本地目录。")
        return false
    end
    local current = source_id and self.settings:get_source(source_id)
        or self.settings:get_connection()
    current = current or {}
    local values = {
        name = current.name or "",
        local_path = current.local_path or current.root_path or "",
    }
    self.ui:show_local_connection{
        values = values,
        is_new = is_new == true,
        on_test = self:_callback("test local connection", function(input)
            input.kind = "local"
            return self:_run_connection_test(input)
        end, false),
        on_save = self:_callback("save local connection", function(input)
            input.kind = "local"
            local ok, err
            if is_new and type(self.settings.add_local_source) == "function" then
                ok, err = self.settings:add_local_source(input)
            elseif source_id and type(self.settings.set_local_source) == "function" then
                ok, err = self.settings:set_local_source(source_id, input)
            elseif type(self.settings.add_local_source) == "function" then
                ok, err = self.settings:add_local_source(input)
            else
                ok, err = nil, "invalid_local_path"
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            local active_id = type(self.settings.get_active_source_id) == "function"
                and self.settings:get_active_source_id() or nil
            if is_new or not source_id or source_id == active_id then
                if self.on_connection_saved then
                    self.on_connection_saved(self.settings:get_connection())
                end
            end
            self.ui:show_info("本地目录已保存。")
            if on_saved then on_saved() end
            return true
        end, false),
    }
end

function UiSettings:_show_sources(on_saved)
    local sources = self.settings:get_sources()
    local active_id = self.settings:get_active_source_id()
    self.ui:show_sources{
        sources = sources,
        active_id = active_id,
        on_opds_storage = self:_callback("OPDS pointer settings", function()
            local reader = self.settings:get_reader()
            self.ui:show_opds_storage{values=reader, on_save=function(values)
                local root = trim(values.opds_pointer_root):gsub("\\", "/")
                if not (root:sub(1,1) == "/" or root:match("^%a:/"))
                    or root:find("[%z\1-\31\127<>\"|?*]")
                    or ("/" .. root .. "/"):find("/../",1,true) then
                    self.ui:show_info("请输入有效的完整指针目录路径。")
                    return false
                end
                return self:_persist_reader_settings{
                    opds_pointer_root=root, opds_pointer_per_server=values.opds_pointer_per_server,
                    opds_cover_enabled=values.opds_cover_enabled,
                }
            end}
            return true
        end, false),
        license_status = function()
            if self.license and type(self.license.status) == "function" then
                local ok, value = pcall(self.license.status, self.license)
                if ok and type(value) == "table" then return value end
            end
            return { authorized = false }
        end,
        on_license = self:_callback("open premium license", function()
            return self:show_license{ on_close = function()
                if on_saved then on_saved() end
            end }
        end, false),
        image_engine = self.settings:get_reader().image_engine,
        on_image_engine = self:_callback("select image engine", function(image_engine)
            local reader = copy_table(self.settings:get_reader())
            reader.image_engine = image_engine
            if not self:_persist_reader_settings(reader) then return false end
            self:_show_sources(on_saved)
            return true
        end, false),
        on_image_engine_help = self:_callback("show image engine help", function()
            self.ui:show_info("无痕引擎可用于普通 WebDAV 图片和 Kindle 本地图片，不写入正文页面缓存；智能分格仅支持默认引擎。PDF、EPUB、CBZ、MOBI 等文档格式仍自动使用默认引擎。")
            return true
        end, false),
        on_select = self:_callback("select WebDAV source", function(source_id)
            local ok, err = self.settings:select_source(source_id)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            if self.on_connection_saved then
                self.on_connection_saved(self.settings:get_connection())
            end
            if on_saved then on_saved() end
            if self.settings:get_connection().kind == "opds" then
                local open = self.open_source_shelf or self.open_category_shelf
                if type(open) == "function" then return open() end
            end
            return true
        end, false),
        on_add = self:_callback("add WebDAV source", function()
            self:_show_connection_dialog(on_saved, nil, true)
            return true
        end, false),
        on_add_local = self:_callback("add Kindle local source", function()
            self:_show_local_connection_dialog(on_saved, nil, true)
            return true
        end, false),
        on_add_opds = self:_callback("add OPDS source", function()
            return self:_show_opds_connection_dialog(on_saved, nil, true)
        end, false),
        on_nodeshare = self:_callback("open NodeShare TCP settings", function()
            return self:_show_nodeshare_connection_dialog(on_saved, nil, true)
        end, false),
        on_cover_cache = self:_callback("open cover cache settings", function()
            return self:show_cover_cache()
        end, false),
        on_edit = self:_callback("edit WebDAV source", function(source_id)
            local source = self.settings:get_source(source_id)
            if source and source.kind == "local" then
                self:_show_local_connection_dialog(on_saved, source_id, false)
            elseif source and source.kind == "opds" then
                self:_show_opds_connection_dialog(on_saved, source_id, false)
            elseif source and source.kind == "nodeshare" then
                self:_show_nodeshare_connection_dialog(on_saved, source_id, false)
            else
                self:_show_connection_dialog(on_saved, source_id, false)
            end
            return true
        end, false),
        on_delete = self:_callback("delete WebDAV source", function(source_id)
            local source = self.settings:get_source(source_id)
            if not source then
                self.ui:show_info(validation_message("missing_source"))
                return false
            end
            self.ui:confirm{
                text = "删除连接“" .. source.name .. "”？不会删除远程文件。",
                on_confirm = self:_callback("confirm WebDAV source deletion", function()
                    local was_active = source_id == active_id
                    local ok, err = self.settings:remove_source(source_id)
                    if not ok then
                        self.ui:show_info(validation_message(err))
                        return false
                    end
                    self.settings:flush()
                    if was_active and self.on_connection_saved then
                        self.on_connection_saved(self.settings:get_connection())
                    end
                    self:_show_sources(on_saved)
                    return true
                end, false),
            }
            return true
        end, false),
    }
end

function UiSettings:show_connection(on_saved)
    if type(self.ui.show_sources) == "function"
        and type(self.settings.get_sources) == "function" then
        -- Keep every source type reachable before the first source is saved.
        return self:_show_sources(on_saved)
    end
    return self:_show_connection_dialog(on_saved, nil, false)
end

function UiSettings:show_reader(initial_section)
    local current = self.settings:get_reader()
    local form_values = copy_table(current)
    form_values.auto_crop_threshold = nil
    form_values.auto_crop_strength = AutoCrop.strength_from_threshold(
        current.auto_crop_threshold)
    self.ui:show_reader{
        values = form_values,
        initial_section = initial_section,
        gray_presets = self.settings:get_gray_presets(),
        tone_presets = self.settings:get_tone_presets(),
        on_open_gray_settings = self:_callback("open gray enhancement settings", function()
            return self:show_gray_settings()
        end, false),
        on_open_tone_settings = self:_callback("open tone adjustment settings", function()
            return self:show_tone_settings()
        end, false),
        on_open_history = type(self.open_history) == "function"
            and self:_callback("open history from settings", self.open_history, false) or nil,
        on_open_category_shelf = type(self.open_category_shelf) == "function"
            and self:_callback("open category shelf from settings",
                self.open_category_shelf, false) or nil,
        on_save = self:_callback("save reader settings", function(values)
            local normalized = normalize_reader(values, current)
            if not self:_persist_reader_settings(normalized) then return false end
            self.ui:show_info("阅读设置已保存。")
            return true
        end, false),
    }
end

function UiSettings:_persist_reader_settings(values)
    local previous = self.settings:get_reader()
    local wrote = false
    local called, saved, err = pcall(function()
        local ok, reason = self.settings:set_reader(values)
        if not ok then return false, reason end
        wrote = true
        if self.settings:flush() == false then return false, "reader_settings_write_failed" end
        return true
    end)
    if not called or not saved then
        -- set_reader changes the in-memory store before flush can fail.
        if wrote then
            pcall(function()
                self.settings:set_reader(previous)
                self.settings:flush()
            end)
        end
        if not called then error(saved) end
        self.ui:show_info(validation_message(err or "reader_settings_write_failed"))
        return false
    end
    self:_notify_reader_saved(self.settings:get_reader())
    return true
end

function UiSettings:_notify_reader_saved(values)
    if type(self.on_reader_saved) == "function" then
        pcall(self.on_reader_saved, values)
    end
end

function UiSettings:_release_gray_preview()
    local cleanup = self.gray_preview_cleanup
    self.gray_preview_cleanup = nil
    if cleanup then pcall(cleanup) end
end

function UiSettings:_preset_save_result(ok, err)
    if not ok then
        self.ui:show_info(validation_message(err))
        return false
    end
    self.settings:flush()
    self:_notify_reader_saved(self.settings:get_reader())
    return true
end

function UiSettings:_show_gray_editor(preset_id, is_new)
    if type(self.ui.show_gray_preset_editor) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持自定义去灰预设。")
        return false
    end
    local values
    if is_new then
        values = { name = "自定义预设", black = 40, white = 238, gamma = 1.20 }
    else
        local preset = GrayEnhance.find(preset_id,
            self.settings:get_reader().gray_enhance_custom_presets)
        if not preset then
            self.ui:show_info(validation_message("missing_gray_preset"))
            return false
        end
        values = {
            name = preset.name,
            black = preset.black,
            white = preset.white,
            gamma = preset.gamma,
        }
    end
    self.ui:show_gray_preset_editor{
        values = values,
        is_new = is_new == true,
        on_save = self:_callback("save gray enhancement preset", function(input)
            local ok, err
            if is_new then
                ok, err = self.settings:add_gray_preset(input)
            else
                ok, err = self.settings:update_gray_preset(preset_id, input)
            end
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info("去灰增强预设已保存。")
            self:show_gray_settings()
            return true
        end, false),
    }
    return true
end

function UiSettings:_show_gray_sample_path()
    if type(self.ui.show_gray_sample_path) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持样本目录设置。")
        return false
    end
    local current = self.settings:get_reader().gray_enhance_sample_path or ""
    self.ui:show_gray_sample_path{
        value = current,
        on_save = self:_callback("save gray sample path", function(path)
            local ok, err = self.settings:set_gray_sample_path(path)
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info(path == "" and "已清除灰度样本目录。" or "灰度样本目录已保存。")
            self:show_gray_settings()
            return true
        end, false),
    }
    return true
end

function UiSettings:_show_tone_sample_path()
    if type(self.ui.show_tone_sample_path) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持样本目录设置。")
        return false
    end
    local current = self.settings:get_reader().tone_adjust_sample_path or ""
    self.ui:show_tone_sample_path{
        value = current,
        on_save = self:_callback("save tone sample path", function(path)
            local ok, err = self.settings:set_tone_sample_path(path)
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info(path == "" and "已清除亮度与对比度样本目录。"
                or "亮度与对比度样本目录已保存。")
            self:show_tone_settings()
            return true
        end, false),
    }
    return true
end

function UiSettings:show_kopt_sample_path(on_saved)
    if type(self.ui.show_kopt_sample_path) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持样本目录设置。")
        return false
    end
    local current = self.settings:get_reader().kopt_sample_path or ""
    self.ui:show_kopt_sample_path{
        value = current,
        on_save = self:_callback("save KOReader image sample path", function(path)
            local previous = self.settings:get_reader().kopt_sample_path or ""
            local ok, err = self.settings:set_kopt_sample_path(path)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            if type(self.settings.flush) == "function"
                and self.settings:flush() == false then
                self.settings:set_kopt_sample_path(previous)
                self.ui:show_info(validation_message("reader_settings_write_failed"))
                return false
            end
            self.ui:show_info(path == "" and "已清除 KOReader 图像处理样本目录。"
                or "KOReader 图像处理样本目录已保存。")
            if type(on_saved) == "function" then return on_saved() ~= false end
            return true
        end, false),
    }
    return true
end

function UiSettings:show_kopt_preview()
    local reader = self.settings:get_reader()
    if reader.kopt_filter_enabled ~= true then
        self.ui:show_info("请先开启 KOReader 图像处理总开关。")
        return false
    end
    if type(self.ui.show_kopt_preview) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持原生图像处理预览。")
        return false
    end
    local sample_path = reader.kopt_sample_path or ""
    if sample_path == "" then
        self.ui:show_info("请先设置 KOReader 图像处理样本目录。")
        return false
    end
    local found, first, find_error = pcall(self.sample_image_finder, sample_path)
    if not found or not first then
        self.ui:show_info(validation_message(find_error or "gray_sample_not_found"))
        return false
    end
    local renderer = self.render_image
    if not renderer then
        local loaded, module = pcall(require, "ui/renderimage")
        if loaded then renderer = module; self.render_image = module end
    end
    if not renderer or type(renderer.renderImageFile) ~= "function" then
        self.ui:show_info("当前 KOReader 无法解码图像处理样本。")
        return false
    end
    local target_w, target_h = 560, 760
    local device_ok, device = pcall(require, "device")
    if device_ok and device and device.screen and type(device.screen.getSize) == "function" then
        local size = device.screen:getSize()
        target_w = math.max(160, math.floor(tonumber(size.w) or 1236))
        target_h = math.max(240, math.floor(tonumber(size.h) or 1648))
    end
    self:_release_gray_preview()
    local rendered, before = pcall(renderer.renderImageFile, renderer,
        first, false, target_w, target_h)
    if not rendered or not before then
        self.ui:show_info("样本图片无法解码。")
        return false
    end
    local profile = {
        target_width = target_w,
        target_height = target_h,
        contrast = reader.kopt_contrast_enabled == true
            and reader.kopt_contrast or 1,
        white_threshold_enabled = reader.kopt_white_threshold_enabled == true,
        white_threshold = reader.kopt_white_threshold,
        dewatermark = reader.kopt_dewatermark == true,
        background_cleanup = reader.kopt_background_cleanup == true,
    }
    local processed, after = pcall(
        self.native_image_filter.process, first, profile)
    if not processed or not after then
        if before.free then pcall(before.free, before) end
        self.ui:show_info("KOReader 图像处理预览失败，原图未修改。")
        return false
    end
    local released = false
    self.gray_preview_cleanup = function()
        if released then return end
        released = true
        if before.free then pcall(before.free, before) end
        if after.free then pcall(after.free, after) end
    end
    local shown, handle = pcall(self.ui.show_kopt_preview, self.ui, {
        path = first,
        before_buffer = before,
        after_buffer = after,
        before_label = "调整前",
        after_label = reader.kopt_dithering == true
            and "调整后（抖动在翻页时生效）" or "调整后",
        on_close = function() self:_release_gray_preview() end,
    })
    if not shown or not handle then
        self:_release_gray_preview()
        if not shown and self.error_reporter
            and type(self.error_reporter.report) == "function" then
            self.error_reporter:report("KOReader 图像处理预览", handle)
        else
            pcall(self.ui.show_info, self.ui, "KOReader 图像处理预览界面打开失败。")
        end
        return false
    end
    return true
end

function UiSettings:_show_filter_preview(kind)
    local reader = self.settings:get_reader()
    local is_gray = kind == "gray"
    local enabled = is_gray and reader.gray_enhance_enabled == true
        or (not is_gray and reader.tone_adjust_enabled == true)
    local sample_path = is_gray and reader.gray_enhance_sample_path
        or reader.tone_adjust_sample_path
    local show_preview = is_gray and self.ui.show_gray_preview
        or self.ui.show_tone_preview
    if not enabled then
        self.ui:show_info(is_gray and "去灰增强已关闭。"
            or "亮度与对比度已关闭。")
        return false
    end
    if type(show_preview) ~= "function" then
        self.ui:show_info(is_gray and "当前 KOReader 不支持灰度样本预览。"
            or "当前 KOReader 不支持亮度与对比度样本预览。")
        return false
    end
    sample_path = sample_path or ""
    if sample_path == "" then
        self.ui:show_info(is_gray and "请先设置灰度增强样本目录。"
            or "请先设置亮度与对比度样本目录。")
        return false
    end
    local first, find_error = GrayEnhance.first_image_in_directory(sample_path)
    if not first then
        self.ui:show_info(validation_message(find_error or "gray_sample_not_found"))
        return false
    end
    local renderer = self.render_image
    if not renderer then
        local loaded, module = pcall(require, "ui/renderimage")
        if loaded then renderer = module; self.render_image = module end
    end
    if not renderer or type(renderer.renderImageFile) ~= "function" then
        self.ui:show_info(is_gray and "当前 KOReader 无法解码灰度样本。"
            or "当前 KOReader 无法解码亮度与对比度样本。")
        return false
    end
    local target_w, target_h = 560, 760
    local device_ok, device = pcall(require, "device")
    if device_ok and device and device.screen and type(device.screen.getSize) == "function" then
        local size = device.screen:getSize()
        target_w = math.max(160, math.floor(tonumber(size.w) or 1236))
        target_h = math.max(240, math.floor(tonumber(size.h) or 1648))
    end
    local function render()
        local called, buffer = pcall(renderer.renderImageFile, renderer,
            first, false, target_w, target_h)
        if not called or not buffer then return nil, called and "empty" or buffer end
        return buffer
    end
    self:_release_gray_preview()
    local before = render()
    if not before then
        self.ui:show_info("样本图片无法解码。")
        return false
    end
    local after = render()
    if not after then
        if before.free then pcall(before.free, before) end
        self.ui:show_info("样本图片无法创建对比副本。")
        return false
    end
    local preset = is_gray and GrayEnhance.find(reader.gray_enhance_preset,
        reader.gray_enhance_custom_presets)
        or ToneAdjust.find(reader.tone_adjust_preset, reader.tone_adjust_custom_presets)
    local enhanced, enhance_error, diagnostic
    if is_gray then
        enhanced, enhance_error, diagnostic = GrayEnhance.apply(after, preset)
    else
        local lut = ToneAdjust.build_lut(preset)
        if lut then enhanced, enhance_error, diagnostic = GrayEnhance.apply_lut(after, lut, false)
        else enhanced, enhance_error = false, "invalid_tone_preset" end
    end
    if enhanced == false then
        if before.free then pcall(before.free, before) end
        if after.free then pcall(after.free, after) end
        local reason = is_gray and GrayEnhance.error_message(enhance_error)
            or "亮度与对比度参数无效"
        if self.error_reporter then
            self.error_reporter:report(is_gray and "gray_enhance_preview" or "tone_adjust_preview",
                { code = enhance_error, detail = diagnostic }, { reason = reason })
        else
            self.ui:show_info((is_gray and "去灰预览失败，原图未修改。\n"
                or "亮度与对比度预览失败，原图未修改。\n") .. reason)
        end
        return false
    end
    local released = false
    self.gray_preview_cleanup = function()
        if released then return end
        released = true
        if before and before.free then pcall(before.free, before) end
        if after and after.free then pcall(after.free, after) end
    end
    local handle = show_preview(self.ui, {
        path = first, preset = preset, before_buffer = before, after_buffer = after,
        before_label = "调整前", after_label = "调整后",
        on_close = function() self:_release_gray_preview() end,
    })
    if not handle then self:_release_gray_preview(); return false end
    return true
end

function UiSettings:_show_gray_preview()
    return self:_show_filter_preview("gray")
end

function UiSettings:_show_tone_preview()
    return self:_show_filter_preview("tone")
end

function UiSettings:show_gray_settings()
    if type(self.ui.show_gray_settings) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持漫画去灰增强设置。")
        return false
    end
    local reader = self.settings:get_reader()
    local custom = reader.gray_enhance_custom_presets or {}
    self.ui:show_gray_settings{
        enabled = reader.gray_enhance_enabled == true,
        presets = self.settings:get_gray_presets(),
        selected_id = reader.gray_enhance_preset,
        sample_path = reader.gray_enhance_sample_path or "",
        on_toggle = self:_callback("toggle gray enhancement", function()
            local current = self.settings:get_reader()
            local ok = self:_persist_reader_settings{
                gray_enhance_enabled = current.gray_enhance_enabled ~= true,
            }
            if not ok then return false end
            return self:show_gray_settings()
        end, false),
        on_select = self:_callback("select gray enhancement preset", function(preset_id)
            local ok, err = self.settings:set_gray_preset(preset_id)
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info("去灰增强预设已保存，总开关保持不变。")
            return true
        end, false),
        on_add = self:_callback("add gray enhancement preset", function()
            return self:_show_gray_editor(nil, true)
        end, false),
        on_edit = self:_callback("edit gray enhancement preset", function(preset_id)
            return self:_show_gray_editor(preset_id, false)
        end, false),
        on_delete = self:_callback("delete gray enhancement preset", function(preset_id)
            local preset = GrayEnhance.find(preset_id, custom)
            if not preset then
                self.ui:show_info(validation_message("missing_gray_preset"))
                return false
            end
            self.ui:confirm{
                text = "删除自定义预设“" .. tostring(preset.name) .. "”？",
                ok_text = "删除",
                on_confirm = self:_callback("confirm delete gray preset", function()
                    local ok, err = self.settings:remove_gray_preset(preset_id)
                    if not self:_preset_save_result(ok, err) then return false end
                    self.ui:show_info("自定义去灰预设已删除。")
                    self:show_gray_settings()
                    return true
                end, false),
            }
            return true
        end, false),
        on_sample_path = self:_callback("open gray sample path", function()
            return self:_show_gray_sample_path()
        end, false),
        on_preview = self:_callback("preview gray enhancement", function()
            return self:_show_gray_preview()
        end, false),
    }
    return true
end

function UiSettings:_show_tone_editor(preset_id, is_new)
    if type(self.ui.show_tone_preset_editor) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持自定义亮度与对比度预设。")
        return false
    end
    local values
    if is_new then
        values = { name = "自定义预设", brightness = 0, contrast = 100 }
    else
        local reader = self.settings:get_reader()
        local preset = ToneAdjust.find(preset_id, reader.tone_adjust_custom_presets)
        if not preset then
            self.ui:show_info(validation_message("missing_tone_preset"))
            return false
        end
        values = {
            name = preset.name,
            brightness = preset.brightness,
            contrast = preset.contrast,
        }
    end
    self.ui:show_tone_preset_editor{
        values = values,
        is_new = is_new == true,
        on_save = self:_callback("save tone adjustment preset", function(input)
            local ok, err
            if is_new then ok, err = self.settings:add_tone_preset(input)
            else ok, err = self.settings:update_tone_preset(preset_id, input) end
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info("亮度与对比度预设已保存。")
            self:show_tone_settings()
            return true
        end, false),
    }
    return true
end

function UiSettings:show_tone_settings()
    if type(self.ui.show_tone_settings) ~= "function" then
        self.ui:show_info("当前 KOReader 不支持亮度与对比度设置。")
        return false
    end
    local reader = self.settings:get_reader()
    local custom = reader.tone_adjust_custom_presets or {}
    self.ui:show_tone_settings{
        enabled = reader.tone_adjust_enabled == true,
        presets = self.settings:get_tone_presets(),
        selected_id = reader.tone_adjust_preset,
        sample_path = reader.tone_adjust_sample_path or "",
        on_toggle = self:_callback("toggle tone adjustment", function()
            local current = self.settings:get_reader()
            if not self:_persist_reader_settings{
                tone_adjust_enabled = current.tone_adjust_enabled ~= true,
            } then return false end
            return self:show_tone_settings()
        end, false),
        on_select = self:_callback("select tone adjustment preset", function(preset_id)
            local ok, err = self.settings:set_tone_preset(preset_id)
            if not self:_preset_save_result(ok, err) then return false end
            self.ui:show_info("亮度与对比度预设已保存，总开关保持不变。")
            return true
        end, false),
        on_add = self:_callback("add tone adjustment preset", function()
            return self:_show_tone_editor(nil, true)
        end, false),
        on_edit = self:_callback("edit tone adjustment preset", function(preset_id)
            return self:_show_tone_editor(preset_id, false)
        end, false),
        on_delete = self:_callback("delete tone adjustment preset", function(preset_id)
            local preset = ToneAdjust.find(preset_id, custom)
            if not preset then
                self.ui:show_info(validation_message("missing_tone_preset"))
                return false
            end
            self.ui:confirm{
                text = "删除自定义预设“" .. tostring(preset.name) .. "”？",
                ok_text = "删除",
                on_confirm = self:_callback("confirm delete tone preset", function()
                    local ok, err = self.settings:remove_tone_preset(preset_id)
                    if not self:_preset_save_result(ok, err) then return false end
                    self.ui:show_info("自定义亮度与对比度预设已删除。")
                    self:show_tone_settings()
                    return true
                end, false),
            }
            return true
        end, false),
        on_sample_path = self:_callback("open tone sample path", function()
            return self:_show_tone_sample_path()
        end, false),
        on_preview = self:_callback("preview tone adjustment", function()
            return self:_show_tone_preview()
        end, false),
    }
    return true
end

function UiSettings:show_light()
    if not self.lighting or type(self.lighting.get) ~= "function"
        or type(self.ui.show_light) ~= "function" then
        self.ui:show_info(validation_message("frontlight_unavailable"))
        return false
    end
    local state = self.lighting:get()
    if not state or state.supported ~= true then
        self.ui:show_info(validation_message("frontlight_unavailable"))
        return false
    end
    self.ui:show_light{
        values = state,
        on_save = self:_callback("save frontlight settings", function(values)
            local intensity = tonumber(values and values.intensity)
            if not intensity or intensity ~= math.floor(intensity)
                or intensity < state.intensity_min or intensity > state.intensity_max then
                self.ui:show_info(validation_message("invalid_frontlight_intensity"))
                return false
            end
            local warmth
            if state.has_warmth then
                warmth = tonumber(values and values.warmth)
                if not warmth or warmth ~= math.floor(warmth)
                    or warmth < state.warmth_min or warmth > state.warmth_max then
                    self.ui:show_info(validation_message("invalid_frontlight_warmth"))
                    return false
                end
            end
            local ok, err = self.lighting:set_intensity(intensity)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            if state.has_warmth then
                ok, err = self.lighting:set_warmth(warmth)
                if not ok then
                    self.ui:show_info(validation_message(err))
                    return false
                end
            end
            self.ui:show_info("前光与色温已调整。")
            return true
        end, false),
    }
    return true
end

function UiSettings:show_bookshelf_cache()
    if self.bookshelf_ui then return self.bookshelf_ui:show() end
    return false
end
function UiSettings:show_cache()
    local kind_size = type(self.cache.kind_size) == "function"
        and self.cache:kind_size("cover") or 0
    local kind_count = type(self.cache.kind_count) == "function"
        and self.cache:kind_count("cover") or 0
    local total_size = self.cache:total_size()
    local stream_size = type(self.cache.stream_size) == "function"
        and self.cache:stream_size()
        or (type(self.cache.browse_size) == "function" and self.cache:browse_size() or 0)
    local offline_stats = { offline_bytes = 0 }
    if self.offline_cache and type(self.offline_cache.stats) == "function" then
        local ok, result = pcall(self.offline_cache.stats, self.offline_cache)
        if ok and type(result) == "table" then offline_stats = result end
    end
    local browse_policy = type(self.settings.get_browse_cache) == "function"
        and self.settings:get_browse_cache() or {
            total_mb = self.cache.limit_bytes / MB,
            trigger_mb = self.cache.limit_bytes / MB,
            retain_mb = 0,
            interval_minutes = 10,
        }
    self.ui:show_cache{
        kind = "page",
        used_mb = math.max(0, total_size - kind_size) / MB,
        limit_mb = self.cache.limit_bytes / MB,
        cover_limit_mb = (tonumber(self.cache.cover_limit_bytes)
            or self.cache.limit_bytes) / MB,
        protected_mb = self.cache:protected_size() / MB,
        cover_mb = kind_size / MB,
        cover_count = kind_count,
        offline_used_mb = math.max(0, tonumber(offline_stats.offline_bytes) or 0) / MB,
        stream_used_mb = stream_size / MB,
        stream_available_mb = math.max(0, tonumber(offline_stats.available_bytes) or 0) / MB,
        stream_cache_path = "/mnt/us/koreader/cache/webdavmanga",
        browse_total_mb = browse_policy.total_mb,
        browse_trigger_mb = browse_policy.trigger_mb,
        browse_retain_mb = browse_policy.retain_mb,
        browse_interval_minutes = browse_policy.interval_minutes,
        on_cover_cache = self:_callback("open cover cache settings", function()
            return self:show_cover_cache()
        end, false),
        on_offline_cache = self:_callback("open whole manga cache", function()
            return self:show_offline_cache()
        end, false),
        on_stream_cache = self:_callback("open stream cache settings", function()
            return self:show_stream_cache()
        end, false),
        on_bookshelf_cache=self.bookshelf_ui and self:_callback("open bookshelf cache settings",function()
            return self:show_bookshelf_cache()
        end,false) or nil,
        on_set_limit = self:_callback("set cache limit", function(limit_mb)
            local parsed_limit = tonumber(limit_mb)
            if parsed_limit == nil then
                self.ui:show_info(validation_message("invalid_cache_limit"))
                return false
            end
            local values = copy_table(self.settings:get_reader())
            values.cache_limit_mb = parsed_limit
            local ok, err = self.settings:set_reader(values)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            self.cache:set_limit_bytes(values.cache_limit_mb * MB)
            return true
        end, false),
        on_set_cover_limit = self:_callback("set cover cache limit", function(limit_mb)
            local parsed_limit = tonumber(limit_mb)
            if parsed_limit == nil then
                self.ui:show_info(validation_message("invalid_cover_cache_limit"))
                return false
            end
            local values = copy_table(self.settings:get_reader())
            values.cover_cache_limit_mb = parsed_limit
            local ok, err = self.settings:set_reader(values)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            if type(self.cache.set_cover_limit_bytes) == "function" then
                local cache_ok, cache_err = self.cache:set_cover_limit_bytes(
                    values.cover_cache_limit_mb * MB)
                if not cache_ok then
                    self.ui:show_info(validation_message(cache_err))
                    return false
                end
            end
            return true
        end, false),
        on_set_browse_policy = self:_callback("set browse cache policy", function(values)
            values = values or {}
            local ok, err = self.settings:set_browse_cache(values)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            if type(self.cache.set_browse_policy) == "function" then
                local cache_ok, cache_err = self.cache:set_browse_policy{
                    total_bytes = values.total_mb * MB,
                    trigger_bytes = values.trigger_mb * MB,
                    retain_bytes = values.retain_mb * MB,
                    check_interval_seconds = values.interval_minutes * 60,
                }
                if not cache_ok then
                    self.ui:show_info(validation_message(cache_err))
                    return false
                end
                self.cache:cleanup_browse(true)
            end
            self.ui:show_info("浏览缓存策略已保存。")
            return true
        end, false),
        on_clear = self:_callback("open cache clear confirmation", function()
            self.ui:confirm{
                text = "确定清空漫画图片缓存索引吗？不会删除 NAS、Kindle 或本机缓存图片文件。阅读进度不会被删除。",
                ok_text = "清空",
                on_confirm = self:_callback("clear image cache", function()
                    local clear_index = self.cache.clear_except_kind_index
                    local cleared, retained
                    if type(clear_index) == "function" then
                        cleared, retained = self.cache:clear_except_kind_index("cover")
                    else
                        -- Never fall back to the legacy physical cleanup here:
                        -- this button is explicitly index-only.
                        cleared, retained = true, 0
                    end
                    if cleared == false then
                        self.ui:show_info("图片缓存索引清理失败，请稍后重试。")
                    elseif retained and retained > 0 then
                        self.ui:show_info(("图片缓存索引已清理，保留正在阅读的 %.1f MB；图片文件未删除。")
                            :format(retained / MB))
                    else
                        self.ui:show_info("图片缓存索引已清空，图片文件未删除；阅读进度已保留。")
                    end
                end),
            }
        end),
        on_delete_page_files = self:_callback("open page cache file clear confirmation", function()
            self.ui:confirm{
                text = "确定删除 /mnt/us/koreader/cache/webdavmanga 中的插件图片缓存文件吗？不会删除封面、PDF/MOBI、整本离线漫画、NAS 或 Kindle 原图；正在阅读的页面会保留。",
                ok_text = "删除缓存",
                on_confirm = self:_callback("clear page cache files", function()
                    local cleared, summary = self.cache:clear_page_files()
                    summary = summary or {}
                    local removed = math.max(0, tonumber(summary.removed_files) or 0)
                    local freed = math.max(0, tonumber(summary.freed_bytes) or 0) / MB
                    local retained = math.max(0, tonumber(summary.retained_bytes) or 0) / MB
                    local failed = math.max(0, tonumber(summary.failed) or 0)
                    if not cleared then
                        self.ui:show_info(("图片缓存文件部分清理失败：已删除 %d 个，释放 %.1f MB，失败 %d 个；保留正在阅读的 %.1f MB。")
                            :format(removed, freed, failed, retained))
                    else
                        self.ui:show_info(("图片缓存文件已清理：删除 %d 个，释放 %.1f MB；保留正在阅读的 %.1f MB。")
                            :format(removed, freed, retained))
                    end
                end),
            }
        end),
    }
end

function UiSettings:show_stream_cache()
    local policy = type(self.cache.stream_policy) == "function"
        and self.cache:stream_policy()
        or self.cache:browse_policy()
    local size = type(self.cache.stream_size) == "function"
        and self.cache:stream_size()
        or self.cache:browse_size()
    local available_bytes = 0
    if self.offline_cache and type(self.offline_cache.stats) == "function" then
        local ok, stats = pcall(self.offline_cache.stats, self.offline_cache)
        if ok and type(stats) == "table" then
            available_bytes = tonumber(stats.available_bytes) or 0
        end
    end
    local total_bytes = tonumber(policy.total_bytes) or self.cache.limit_bytes
    local model = {
        kind = "stream",
        used_mb = math.max(0, tonumber(size) or 0) / MB,
        limit_mb = total_bytes / MB,
        available_mb = math.max(0, available_bytes) / MB,
        stream_cache_path = "/mnt/us/koreader/cache/webdavmanga",
        browse_total_mb = total_bytes / MB,
        browse_trigger_mb = (tonumber(policy.trigger_bytes) or total_bytes) / MB,
        browse_retain_mb = (tonumber(policy.retain_bytes) or 0) / MB,
        browse_interval_minutes = math.max(1,
            math.floor((tonumber(policy.check_interval_seconds) or 600) / 60)),
    }
    model.on_set_browse_policy = self:_callback("set stream cache policy", function(values)
        values = values or {}
        local ok, err = self.settings:set_browse_cache(values)
        if not ok then
            self.ui:show_info(validation_message(err))
            return false
        end
        self.settings:flush()
        local cache_ok, cache_err = self.cache:set_stream_policy{
            total_bytes = values.total_mb * MB,
            trigger_bytes = values.trigger_mb * MB,
            retain_bytes = values.retain_mb * MB,
            check_interval_seconds = values.interval_minutes * 60,
        }
        if not cache_ok then
            self.ui:show_info(validation_message(cache_err))
            return false
        end
        self.cache:cleanup_stream(true)
        self.ui:show_info("流式阅读缓存策略已保存。")
        return true
    end, false)
    model.on_clear = self:_callback("clear stream cache", function()
        local clear = function()
            local ok, summary = self.cache:clear_stream_cache()
            summary = summary or {}
            if not ok then
                self.ui:show_info(("流式阅读缓存部分清理失败：释放 %.1f MB，保留 %.1f MB。")
                    :format((tonumber(summary.freed_bytes) or 0) / MB,
                        (tonumber(summary.retained_bytes) or 0) / MB))
            else
                self.ui:show_info(("流式阅读缓存已清理：释放 %.1f MB；正在阅读页面保留 %.1f MB。")
                    :format((tonumber(summary.freed_bytes) or 0) / MB,
                        (tonumber(summary.retained_bytes) or 0) / MB))
            end
            return true
        end
        if type(self.ui.confirm) == "function" then
            self.ui:confirm{
                text = "确定清理流式阅读缓存吗？只清理 page/manifest；不会删除封面、完整 PDF/MOBI 或原始漫画文件。",
                ok_text = "清理缓存",
                on_confirm = self:_callback("confirm stream cache clear", clear),
            }
            return true
        end
        return clear()
    end, false)
    self.ui:show_cache(model)
    return true
end

local function offline_error_message(code)
    if type(code) == "table" then return Errors.message(code) end
    local messages = {
        busy = "已有整部漫画缓存任务正在运行。",
        invalid_manga = "漫画目录无效，无法开始缓存。",
        missing_connection = "当前连接不可用，请先检查连接设置。",
        invalid_offline_root = "整部漫画保存目录必须位于 /mnt/us 下。",
        reserve_space = "继续缓存会使 Kindle 剩余空间低于 1 GB，任务已停止。",
        disk_usage = "无法读取 Kindle 剩余空间，已停止缓存以保护存储。",
        make_path_failed = "无法创建整部漫画保存目录。",
        invalid_remote_path = "漫画图片路径无效。",
        invalid_offline_plan = "整部漫画缓存路径校验失败。",
        unvalidated = "下载的图片未通过完整性检查。",
    }
    return messages[tostring(code or "")] or ("整部漫画缓存失败：" .. tostring(code or "未知错误"))
end

local function offline_completion_message(summary)
    summary = summary or {}
    local downloaded = math.max(0, tonumber(summary.downloaded) or 0)
    local cached = math.max(0, tonumber(summary.cached) or 0)
    local failed = math.max(0, tonumber(summary.failed) or 0)
    if summary.status == "complete" and failed == 0 then
        return ("整部漫画缓存完成：新增 %d 页，已有 %d 页。"):format(downloaded, cached)
    elseif summary.status == "complete" then
        local detail = summary.last_error
            and ("\n最后错误：" .. offline_error_message(summary.last_error)) or ""
        return (("整部漫画部分完成：新增 %d 页，已有 %d 页，失败 %d 页。可在缓存管理中重试。")
            :format(downloaded, cached, failed)) .. detail
    elseif summary.status == "space" then
        return offline_error_message("reserve_space")
    elseif summary.status == "limit" then
        local detail = type(summary.detail) == "table" and summary.detail or {}
        return ("缓存任务已取消：现有缓存 %.2f GB，本次尚需 %.2f GB，总上限 %.2f GB。")
            :format(math.max(0, tonumber(detail.used_bytes) or 0) / GB,
                math.max(0, tonumber(detail.required_bytes) or 0) / GB,
                math.max(0, tonumber(detail.limit_bytes) or 0) / GB)
    elseif summary.status == "empty" then
        return "该目录及其章节中没有可缓存的图片。"
    elseif summary.status == "canceled" then
        return "整部漫画缓存已取消，已完成的页面会保留。"
    elseif summary.status == "error" then
        return offline_error_message(summary.detail or summary.last_error)
    end
    return offline_error_message(summary.detail or summary.last_error)
end

function UiSettings:_start_offline_cache(manga)
    if not self.offline_manager or type(self.offline_manager.start) ~= "function" then
        self.ui:show_info("整部漫画缓存尚未初始化。")
        return false
    end
    if type(manga) ~= "table" or type(manga.path) ~= "string" then
        self.ui:show_info(offline_error_message("invalid_manga"))
        return false
    end
    self.last_offline_manga = copy_table(manga)
    self.ui:show_info("已开始缓存整部漫画。可在“缓存管理 → 整部漫画缓存”查看进度或取消。", 3)
    local handle, err = self.offline_manager:start(manga, {
        on_progress = function(summary) self.offline_latest_summary = summary end,
        on_complete = function(summary)
            self.offline_latest_summary = summary
            self.ui:show_info(offline_completion_message(summary))
        end,
    })
    if not handle then
        self.ui:show_info(offline_error_message(err))
        return false
    end
    return true
end

function UiSettings:show_offline_cache(manga)
    if not self.offline_cache or type(self.offline_cache.stats) ~= "function"
        or not self.offline_manager or type(self.offline_manager.status) ~= "function"
        or type(self.ui.show_offline_cache) ~= "function" then
        self.ui:show_info("整部漫画缓存尚未初始化。")
        return false
    end
    local selected = manga and copy_table(manga) or nil
    local identity_ok, identity = pcall(self.identity_provider)
    if not identity_ok then identity = "" end
    local stats_ok, stats = pcall(self.offline_cache.stats, self.offline_cache,
        identity, selected and selected.path or nil)
    if not stats_ok or type(stats) ~= "table" then
        self.ui:show_info("无法读取整部漫画缓存空间信息。")
        return false
    end
    local status_ok, status = pcall(self.offline_manager.status, self.offline_manager)
    if not status_ok or type(status) ~= "table" then
        status = { running = false, status = "error", detail = "status" }
    end
    local last = self.last_offline_manga
    local can_retry = not status.running and last
        and ((tonumber(status.failed) or 0) > 0
            or status.status == "space" or status.status == "error"
            or status.status == "canceled")
    local model = {
        root = stats.root or self.settings:get_offline_root(),
        limit_gb = type(self.settings.get_offline_limit_gb) == "function"
            and self.settings:get_offline_limit_gb() or 5,
        refresh_seconds = type(self.settings.get_offline_refresh_seconds) == "function"
            and self.settings:get_offline_refresh_seconds() or 15,
        offline_used_mb = math.max(0, tonumber(stats.offline_bytes) or 0) / MB,
        manga_mb = math.max(0, tonumber(stats.manga_bytes) or 0) / MB,
        total_mb = math.max(0, tonumber(stats.total_bytes) or 0) / MB,
        used_mb = math.max(0, tonumber(stats.used_bytes) or 0) / MB,
        available_mb = math.max(0, tonumber(stats.available_bytes) or 0) / MB,
        reserve_mb = math.max(0, tonumber(stats.reserve_bytes) or 0) / MB,
        manga_name = selected and selected.name or nil,
        status = copy_table(status),
        on_refresh = self:_callback("refresh whole manga cache status", function()
            return self:show_offline_cache(selected)
        end, false),
        on_set_root = self:_callback("set whole manga root", function(value)
            local previous_root = self.settings:get_offline_root()
            local ok, err = self.settings:set_offline_root(value)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            local flushed_ok, flushed = pcall(self.settings.flush, self.settings)
            if not flushed_ok or flushed == false then
                self.settings:set_offline_root(previous_root)
                self.ui:show_info("整部漫画保存目录未能保存，请重试。")
                return false
            end
            if previous_root ~= self.settings:get_offline_root() and self.on_offline_root_saved then
                self.on_offline_root_saved()
            end
            self.ui:show_info("整部漫画保存目录已更新。")
            return true
        end, false),
        on_set_limit = self:_callback("set whole manga cache limit", function(value)
            local previous_limit = type(self.settings.get_offline_limit_gb) == "function"
                and self.settings:get_offline_limit_gb() or nil
            local requested = tonumber(value)
            local latest_ok, latest = pcall(self.offline_cache.stats, self.offline_cache,
                identity, selected and selected.path or nil)
            local available = latest_ok and type(latest) == "table"
                and tonumber(latest.available_bytes) or 0
            local reserve = latest_ok and type(latest) == "table"
                and tonumber(latest.reserve_bytes) or 0
            local maximum = math.floor((available - reserve) / GB)
            if available <= 0 or reserve < 5 * GB or maximum < 1
                or requested == nil or requested ~= math.floor(requested)
                or requested > maximum then
                self.ui:show_info("空间不足：整部缓存上限必须至少给 Kindle 保留 5 GB。")
                return false
            end
            local setter = self.settings.set_offline_limit_gb
            local ok, err
            if type(setter) == "function" then
                ok, err = setter(self.settings, value)
            else
                err = "invalid_offline_limit"
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            local flushed_ok, flushed = pcall(self.settings.flush, self.settings)
            if not flushed_ok or flushed == false then
                if previous_limit ~= nil and type(setter) == "function" then
                    pcall(setter, self.settings, previous_limit)
                end
                self.ui:show_info("整部漫画缓存上限保存失败，请重试。")
                return false
            end
            self.ui:show_info("整部漫画缓存上限已更新。")
            return true
        end, false),
        on_set_refresh = self:_callback("set offline refresh interval", function(value)
            local previous_refresh = type(self.settings.get_offline_refresh_seconds) == "function"
                and self.settings:get_offline_refresh_seconds() or nil
            local setter = self.settings.set_offline_refresh_seconds
            local ok, err
            if type(setter) == "function" then
                ok, err = setter(self.settings, value)
            else
                err = "invalid_offline_refresh"
            end
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            local flushed_ok, flushed = pcall(self.settings.flush, self.settings)
            if not flushed_ok or flushed == false then
                if previous_refresh ~= nil and type(setter) == "function" then
                    pcall(setter, self.settings, previous_refresh)
                end
                self.ui:show_info("进度刷新间隔保存失败，请重试。")
                return false
            end
            return true
        end, false),
    }
    if status.running then
        model.on_cancel = self:_callback("cancel whole manga cache", function()
            local canceled = self.offline_manager:cancel()
            if not canceled then self.ui:show_info("当前没有可取消的缓存任务。") end
            return canceled
        end, false)
    elseif selected then
        model.on_start = self:_callback("start whole manga cache", function()
            return self:_start_offline_cache(selected)
        end, false)
    end
    if can_retry then
        model.on_retry = self:_callback("retry whole manga cache", function()
            return self:_start_offline_cache(last)
        end, false)
    end
    self.ui:show_offline_cache(model)
    return true
end

function UiSettings:show_cover_cache()
    if not self.ui or type(self.ui.show_cache) ~= "function" then
        return false
    end
    local used = type(self.cache.kind_size) == "function"
        and self.cache:kind_size("cover") or 0
    local count = type(self.cache.kind_count) == "function"
        and self.cache:kind_count("cover") or 0
    self.ui:show_cache{
        kind = "cover",
        used_mb = used / MB,
        count = count,
        limit_mb = (tonumber(self.cache.cover_limit_bytes)
            or self.cache.limit_bytes) / MB,
        on_set_limit = self:_callback("set cover cache limit", function(limit_mb)
            local parsed_limit = tonumber(limit_mb)
            if parsed_limit == nil then
                self.ui:show_info(validation_message("invalid_cover_cache_limit"))
                return false
            end
            local values = copy_table(self.settings:get_reader())
            values.cover_cache_limit_mb = parsed_limit
            local ok, err = self.settings:set_reader(values)
            if not ok then
                self.ui:show_info(validation_message(err))
                return false
            end
            self.settings:flush()
            local cache_ok, cache_err = self.cache:set_cover_limit_bytes(
                values.cover_cache_limit_mb * MB)
            if not cache_ok then
                self.ui:show_info(validation_message(cache_err))
                return false
            end
            return true
        end, false),
        protected_mb = 0,
        on_clear = self:_callback("open cover cache clear confirmation", function()
            self.ui:confirm{
                text = "确定清理封面缓存吗？只删除插件生成的封面缓存，不会删除 NAS、Kindle 或本机原图。",
                ok_text = "清理",
                on_confirm = self:_callback("clear cover cache", function()
                    local clear_index = self.cache.clear_kind_cache
                    local cleared, retained
                    if type(clear_index) == "function" then
                        cleared, retained = self.cache:clear_kind_cache("cover")
                    else
                        cleared, retained = true, 0
                    end
                    if cleared == false then
                        self.ui:show_info("封面缓存清理失败，请稍后重试。")
                    elseif retained and retained > 0 then
                        self.ui:show_info(("封面缓存已清理，保留 %.1f MB 活动缓存。")
                            :format(retained / MB))
                    else
                        self.ui:show_info("封面缓存已清理，缓存文件已删除；远程和本地原图未删除。")
                    end
                end),
            }
        end),
    }
    return true
end

function UiSettings:show_reader_help()
    if type(self.ui.show_reader_help) ~= "function" then return false end
    return self.ui:show_reader_help(ReaderHelp) ~= false
end

function UiSettings:show_about(version, diagnostics)
    self.ui:show_about{
        actions = {
            {text = "漫画阅读说明", callback = self:_callback("show manga instructions", function()
                return self:show_reader_help()
            end)},
            {
                text = "版本与说明",
                callback = self:_callback("show version information", function()
                    self.ui:show_info("WebDAV 漫画 " .. tostring(version)
                        .. "\n远程目录浏览与流式漫画阅读插件")
                end),
            },
            {
                text = "图片格式兼容性检测",
                callback = self:_callback("run image format diagnostics", function()
                    self.ui:show_info(diagnostics.summary(diagnostics:run()))
                end),
            },
        },
    }
end

return UiSettings
