# 三种分格与设置导航实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复漫画设置逐层显示，移除截图，完善旋转与自适应识别，并加入来自 MangaWeb 的独立 Web 分格，完成验证和安装包交付。
**Architecture:** 设置仍使用现有 Shell 和原生编辑器，维护直接父页面与关闭令牌；三种识别策略共用 PanelSource、PanelSession、PanelView。模式互斥单独放入无 UI 依赖的策略模块；自动阈值采用有界灰度统计辅助模块，不修改显示原图。
**Tech Stack:** Lua 5.1/LuaJIT、KOReader BlitBuffer/Leptonica、现有 Python/Lupa/Pillow 和离线 ARM Docker 环境；无新增产品依赖。
**Spec:** `docs/superpowers/specs/2026-10-13-panel-modes-settings-design.md`，用户已确认；本会话由主代理顺序实施，最后独立审查。

状态：用户于 2026-10-13 回复“计划符合，开始实施”，按本会话顺序执行。预计发布 v0.4.31，发布日使用实际完成日期。

## Global Constraints

- 基线 v0.4.30 / `e68c4236c45a19c84ea6b3f2a7a8faa4bfefcfcf`；复用 `E:\jiankong\webdav-manga-handoff\worktrees\panel-reading`、`codex/panel-experience`。
- 三个字段 `panel_zoom_enabled`、`dynamic_panel_zoom_enabled`、`web_panel_zoom_enabled` 两两互斥；显式启用者生效，关闭当前模式不自动开启另一模式。
- 每个内层设置有“返回上一级”；父页隐藏；保留不透明漫画背景和完整退出能力；保存失败不覆盖旧值。
- 删除插件截图入口、实现与说明；不改 KOReader 自身截图、网络协议、封面策略、许可证或售价。
- 保留智能默认阈值 40、动态默认阈值 50、动态最小宽高 12.5%、连通性 8、64 格上限。
- Web 来源固定为 MangaWeb v0.8.91 / `f9e8364efbeccdcebc3bfd9498c93b4d1bbb2673`；只提取算法，保留版权及来源清单。
- 自动识别默认关闭；有效阈值限定为基准的 50%～150% 且 1～254；智能采样最长边 480，动态最长边 960。
- 不重新下载本页，不修改原图，不重新开启已关闭的显示处理；不可靠检测显示整页，下一页继续分格。
- 最多拥有当前/下一格两份渲染结果；显示借用解除后才释放，不发布迟到回调。
- 分格翻页继续只用经典或原生/已安装 Swipe Animation，不新增逐帧动画。
- 每次交付重新验证七份原始漫画文件、严格 Range、实际像素解码及新版运行时散列，并同步本地 ZIP。

## Review Focus

1. 数值框取消、键盘关闭、外部增强/前光编辑器返回：只显示当前设置，直接父页恢复，关闭插件不重新打开旧页（Task 1）。
2. 全局与本漫画配置相反、损坏配置多个模式开启、长按保存失败：仍只有一个会话，事务失败保留旧设置和画面（Task 3 / 5）。
3. 灰底浅线、黑底白线、空白页和对白跨框：自动识别不能以格数增加替代完整性判断（Task 4）。
4. 旋转中退出、屏幕布局拒绝、预渲染执行中改参数：不得读已释放缓冲、发布旧格或锁死背景（Task 2 / 5）。
5. 新模块漏包、旧报告复用、源码在验证后改变：严格发布门禁拒绝生成可发布安装包（Task 6）。

## 验证环境与命令约定

在工作区运行；PowerShell 变量不复用系统保留名称：

```powershell
$taskPy = 'E:\jiankong\webdav-manga-handoff\.venv\Scripts\python.exe'
$env:KOREADER_FRONTEND = 'E:\jiankong\webdav-manga-handoff\upstream-inspection\bookshelf-native-runtime-20261011\koreader\frontend'
$taskEvidence = Join-Path 'E:\jiankong\webdav-manga-handoff\verification-runs' ('panel-modes-' + [guid]::NewGuid().ToString('N'))
$taskPanelOutput = Join-Path $taskEvidence 'panel-native'
$taskPanelReport = Join-Path $taskEvidence 'panel-analysis.json'
$taskStreamReport = Join-Path $taskEvidence 'stream-formats.json'
$taskArchive = 'downloads/webdavmanga.koplugin-v0.4.31-panel-modes-settings.zip'
& $taskPy scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin
& $taskPy -m unittest discover -s scripts -p test_stream_release_gate.py
```

每个任务先运行指定新增规格取得真实 RED，再实现并运行 GREEN 和相邻回归，最后提交该任务涉及的确切文件。不得因纯 Lua CRC 计时波动放宽原有 3 秒测试门槛。所有新日志使用新目录，不覆盖历史通过报告。

## Task 1：设置父页隐藏、直接返回及截图移除

**Files:** 修改 `webdavmanga.koplugin/webdavmanga/ui_reader.lua`、`ui_reader_shell.lua`、`ui_settings.lua`、`ui_registry.lua`（仅在原生窗口所有权需要时）、`main.lua`、`reader_help.lua`；新增 `spec/settings_hierarchy_spec.lua`；修改 `spec/rebuild_0422_panel_tools_spec.lua`。

**Interfaces:** `ReaderShell:show_number_input(model)` 增加 `model.on_return()`，保存或返回时先关闭输入/键盘再调用；`ReaderShell:suspend_controls()` 返回恢复函数，使用不含父级按钮的漫画底图，恢复需检查 Shell 仍有效。全局编辑器使用同样的开始/结束边界，内部页面切换不得触发外层结束。继续使用 `dialog_epoch`、UiRegistry 和现有安全回调。

- [x] RED：`settings_hierarchy_spec` 通过真实 Shell 和默认 UiSettings 适配器验证数字框下无父按钮；选择页/灰度/对比度/样本路径/预览/前光/帮助逐层返回；保存与取消准确回到直接父页；退出与迟到回调不会重开页面；布局失败恢复旧页。
- [x] RED：将旧截图测试改为 `assert(reader.save_panel_screenshot == nil and shell.save_panel_screenshot == nil)`，实际菜单中无“当前视图截图”；保留独立设备旋转与手势断言。

新增窗口测试的关键断言如下，使用现有 `spec/helpers/reader_quadrant_host.lua` 创建 reader，并注入原生输入窗口边界：

```lua
assert(shell:show_number_input{title='识别强度', value=40, on_save=function() return true end})
assert(shell.current_model.kind ~= 'controls', '数值输入下方必须隐藏父级按钮')
assert(reader.save_panel_screenshot == nil and shell.save_panel_screenshot == nil)
```

- [x] 运行 `& $taskPy scripts/run_lua_specs.py spec/settings_hierarchy_spec.lua spec/rebuild_0422_panel_tools_spec.lua`，确认新需求失败原因匹配上述缺口。
- [x] GREEN：沿用同一 Shell 切换内层控制；打开外部编辑器时隐藏控制页、保持不透明底图。所有内层增加“返回上一级”；保存/取消/用户关闭统一走返回路径，退出令牌防止恢复已关闭阅读器。删除两层截图实现、菜单入口和对应帮助文案。
- [x] 验证新增规格，以及 `settings_transition_spec`、`settings_preview_widget_spec`、`settings_session_exit_spec`、`reader_exit_spec`、`rebuild_0423_plugin_exit_spec`、`plugin_background_spec`、`ui_background_spec`。
- [x] 提交：`fix: hide parent settings and remove panel screenshot`；任务交付物可独立验收。

## Task 2：菜单位置、指定设备旋转与动态状态

**Files:** 修改 `ui_reader.lua`、`ui_reader_shell.lua`、`ui_settings.lua`、`main.lua`、`reader_help.lua`；新增 `spec/panel_controls_layout_spec.lua`；更新原旋转规格。

**Interfaces:** `ReaderShell:rotate_device(degrees)` 接收且仅接收 0/90/180/270，映射到 KOReader 0/1/2/3，成功返回 true；`Reader:rotate_panel_device(degrees)` 保持物理页、重新计算屏幕尺寸并按当前模式恢复。阅读首页设备旋转子页返回首页；`panel_view` 和 `panel_advanced` 都返回 `panel`。

- [x] RED：真实菜单模型检查“更多分格设置”属于 `panel`，不属于 `panel_view`；四角度发送对应 `SetRotationMode` 事件；选择已处于的角度不重复重建或下载；设备旋转与内容旋转独立。
- [x] RED：动态 `_show_panel` 成功后 `status_text` 无“动态面板”和原识别提示，错误仍可见；上一个模式的状态不会残留。旋转失败、退出中旋转和触摸区域重新计算有断言。
- [x] 运行 `& $taskPy scripts/run_lua_specs.py spec/panel_controls_layout_spec.lua`，记录 RED。
- [x] GREEN：将设备旋转放到阅读设置首页，明确四个角度；全局设置入口同样可调用宿主旋转，不写入分格内容旋转值。调整直接父路由；动态进入提示改为中性短暂识别文字，成功清理模式状态，使用现有局部刷新。
- [x] 验证新增菜单规格及 `rebuild_0422_panel_tools_spec`、`rebuild_0424_dynamic_reader_spec`、`rebuild_0426_grid_reader_spec`、`panel_native_animation_spec`、`rebuild_0425_menu_bands_spec`、`rebuild_0422_bubble_priority_spec`。
- [x] 提交：`feat: expose device orientation and simplify panel controls`。

## Task 3：三模式策略、Web 提取及动态数值 schema

**Files:** 新增 `webdavmanga.koplugin/webdavmanga/panel_modes.lua`、`web_panel_zoom.lua`、`web_panel_analysis.lua`、`web_panel_components.lua`；修改 `dynamic_panel_zoom.lua`、`settings.lua`、`ui_settings.lua`、`ui_reader.lua`、`NOTICE`；新增 `docs/provenance/mangaweb-panels.json`、`spec/panel_modes_spec.lua`、`spec/web_panel_source_spec.lua`、`spec/dynamic_panel_parameters_spec.lua`。

**Interfaces:** `Modes.active(values)` 返回 `intelligent` / `dynamic` / `web` / nil；`Modes.enabled(values)` 返回 boolean；`Modes.resolve(values, previous, changed)` 规范化完整配置；`Modes.override(patch)` 补足显式启用的另外两个 false。冲突无明确改动时固定优先 Web、动态、智能；仅用于损坏配置恢复。策略不能依赖 UI。

`Web.fields/normalize/validate/items/request/detect/sort` 对应现有 Dynamic 接口；Web request 转换为来源的 `strength_percent/min_area_permille/frame_min/dialogue_distance_percent`。来源 analysis/components 只替换命名空间及明确的数组/几何引用。动态新增阈值整数 1～254 默认 50、最小边百分比数值 2～50 默认 12.5；schema 数值项提供 `integer` 属性区分整数与有限小数。

- [x] RED：三模式每两种启用顺序、全局与漫画覆盖、关闭不跳模式、损坏配置优先级、默认与按漫画保存失败回滚；阈值 1/37/50/254 可用，0/255/37.5 拒绝；最小边 2/12.5/50 可用，NaN/无穷/越界拒绝。
- [x] RED：Web 默认与固定来源在浅线、独立小格、边框严格度、溢出对白、复杂排序样本的结果深度一致；调强度与对白距离真实改变来源入参；只恢复四项，视图/顺序/启用不变。基础数组及几何复用，不重复复制。

```lua
local Modes = require('webdavmanga.panel_modes')
local values = {panel_zoom_enabled=true, dynamic_panel_zoom_enabled=true, web_panel_zoom_enabled=true}
Modes.resolve(values, nil, 'web_panel_zoom_enabled')
assert(Modes.active(values) == 'web' and not values.panel_zoom_enabled and not values.dynamic_panel_zoom_enabled)
values.web_panel_zoom_enabled=false
assert(Modes.active(values) == nil, '关闭不得自动切换')
```

- [x] 运行 `& $taskPy scripts/run_lua_specs.py spec/panel_modes_spec.lua spec/web_panel_source_spec.lua spec/dynamic_panel_parameters_spec.lua`，确认 RED。
- [x] GREEN：提取来源算法并保存原哈希、替换规则及版权；把原 Dynamic 负责的互斥迁到 Modes，并迁移全部启用判断/全局和漫画覆盖入口。保留原数值默认行为；全局表单和漫画控件共用同一校验 schema。
- [x] 验证新规格及 `settings_spec`、`rebuild_0422_panel_options_spec`、`rebuild_0424_dynamic_panel_spec`、`panel_detector_spec`、`panel_precision_spec`；GitHub 仍为固定提交时才声称采用最新版。
- [x] 提交：`feat: add independent web panels and three mode policy`。

## Task 4：有界自动识别与真实参数生效

**Files:** 新增 `webdavmanga.koplugin/webdavmanga/panel_detection_profile.lua`；修改 `panel_analysis.lua`、`panel_detector.lua`、`panel_options.lua`、`dynamic_panel_zoom.lua`、`settings.lua`、`ui_reader.lua`、`ui_settings.lua`；新增 `spec/panel_auto_detection_spec.lua`，扩展 Task 3 动态参数规格。

**Interfaces:** `Profile.threshold(gray_histogram, background, baseline)` 接收 0～255 灰度计数及已确定背景值，返回整数有效阈值；使用相对背景差直方图的类间方差最大化分离，取最优平台中点，限制为基准 50%～150% 和 1～254；空/均匀/无法分离时返回基准。不拥有缓冲、不依赖 UI。

上下界取 `max(1, ceil(baseline*0.5))` 和 `min(254, floor(baseline*1.5))`，确保奇数基准下整数结果仍严格符合设计范围。

新增 `panel_auto_detection_enabled=false`、`dynamic_panel_auto_detection_enabled=false`；策略 request 传递 `auto_detection`、`detection_threshold`，动态额外传递 `min_side_percent`。原生 `connected_components(raster, threshold, connectivity, options)` 允许第四参数，原调用仍默认 50/8。

- [x] RED：白底 255/浅线 217、灰底 180/浅线 150、黑底 0/白框 255、均匀灰和噪点样本；自动关闭原框/顺序一致，自动开启阈值实际改变且不写回 40/50；2～50 最小边百分比实际影响候选过滤。
- [x] RED：巨大虚拟页像素读取有界，借用 BB 不释放，失败清理所有原生 PIX/BOX；对话溢出范围仍保护且不改变排序框；最大候选 64 不能开放或截取前 64 格。

```lua
local Profile = require('webdavmanga.panel_detection_profile')
assert(Profile.threshold({[255]=2000,[217]=2000},255,40) == 20)
assert(Profile.threshold({[180]=4000},180,50) == 50, '均匀页保留手动基准')
```

- [x] 运行 `& $taskPy scripts/run_lua_specs.py spec/panel_auto_detection_spec.lua spec/dynamic_panel_parameters_spec.lua`，确认 RED。
- [x] GREEN：在已有采样阶段收集统计，智能识别维持 480 上限；动态在 960 上限内按背景差构造原生识别输入。关闭自动时走原行为；开启后仅改变检测的本页阈值。设置位于设计指定高级子页，每页有直接返回。
- [x] 评估一次“弱线补充识别”：只对主检测不可靠的页面进行一次低阈值尝试；真实页及边框/对白保护证据证明改善才加入独立默认关闭选项。不能证明则记录“不加入”及原因，不扩大成无界阈值遍历。
- [x] 验证新增规格及 `panel_precision_spec`、`panel_gutters_spec`、`rebuild_0412_panel_analysis_spec`、`rebuild_0424_dynamic_panel_spec`；记录有效阈值和对白完整性，不能仅报格数。
- [x] 提交：`feat: adapt panel detection to page contrast`。

## Task 5：三模式接入、原图重识别与生命周期

**Files:** 修改 `ui_reader.lua`、`panel_session.lua`、`ui_settings.lua`、`reader_help.lua`；新增 `spec/panel_mode_reader_spec.lua`、`spec/panel_redetection_spec.lua`；扩展 `panel_session_spec`、`panel_memory_spec`。

**Interfaces:** `PanelSession:redetect(request_changes, commit, rollback)` 复用当前 handle 取得 raster，事务重建布局，从首格发布，成功返回 true；不再次调用 source.open。Reader 按 Modes.active 选择智能、Dynamic 或 Web，所有模式复用现有 PanelSession 工厂与手势/跨页路由。检测选项保存调用 redetect；显示选项继续调用 configure；模式变化安全解除旧借用后重建会话。

- [x] RED：切换三模式只存在一个会话，首格/末格跨物理页及章节行为保留；未识别页整页显示后下一页继续；Web 三视图和顺序/导航真正在读图时生效。
- [x] RED：连续参数修改使用当前本地原图，`source.open` 次数不增；保存失败、渲染失败、发布拒绝回滚旧参数及布局；预渲染迟到、关闭中调参、旋转中退出，缓冲恰好释放一次且显示器不借用已释放内存。
- [x] 运行 `& $taskPy scripts/run_lua_specs.py spec/panel_mode_reader_spec.lua spec/panel_redetection_spec.lua`，确认 RED。
- [x] GREEN：实现 redetect 的候选布局/设置/发布事务和 token 检查；整页回退通过既有 Reader detach 边界。增加 Web 菜单及识别四项恢复按钮；两种自动能力菜单返回正确父级。读取现有保存的本漫画配置，保持原物理页。
- [x] 验证新规格及 `panel_session_spec`、`panel_memory_spec`、`rebuild_0414_panel_continuation_spec`、`panel_settings_reload_spec`、三视图/原生动画/退出/手势和背景规格。
- [x] 提交：`feat: integrate panel modes with safe local redetection`。

## Task 6：真实运行时验证、严格打包与交付

**Files:** 扩展 `scripts/run_panel_analysis.py`、`spec/contracts/panel_analysis_native.lua`、`spec/contracts/dynamic_panel_native.lua`；修改 `scripts/package_contract.py`、`scripts/package_plugin.py`、版本 metadata/main/README/NOTICE；新增当前版本 release 规格、发布说明、来源清单和新验证报告。`stream_formats_contract` 的严格要求不放宽。

**Interfaces:** ARM 分格报告包含三种策略及使用的 options、合成样本预期、实际框、对白保护范围、有效阈值、耗时、缓冲/原生分配清理和模块散列。原文件报告继续使用 `stream_formats_contract.validate_report(report, plugin)`；新文件进入 package_contract.REQUIRED。

- [ ] RED：打包契约拒绝漏掉新模块、过期版本/源哈希报告；Web 来源样本预期只在对应模式断言，不把智能格数硬套给另外两种。
- [ ] GREEN：版本统一为 0.4.31，新增模块全部纳入严格文件清单；更新三模式帮助和截图移除说明。发布日和 ZIP 文件名用实际完成日期，历史报告保留。
- [ ] 运行全量 Lua/语法与 6 项门禁命令；新增门禁测试如有则统计实际数量。所有失败须查明，不忽略产品测试。
- [ ] 运行 ARM 分格：`& $taskPy scripts/run_panel_analysis.py --samples 'E:\测试' --runtime-root 'E:\jiankong\webdav-manga-handoff\upstream-inspection\bookshelf-native-runtime-20261011\koreader' --support-runtime 'E:\jiankong\webdav-manga-handoff\upstream-inspection\official-nightly-runtime' --output $taskPanelOutput --report $taskPanelReport`；同时运行扩展后的动态原生契约，证明真实 Leptonica 释放。
- [ ] 运行七原文件：`& $taskPy scripts/run_stream_formats.py --samples 'E:\测试' --runtime-root 'E:\jiankong\webdav-manga-handoff\upstream-inspection\official-nightly-runtime' --device-libs 'E:\jiankong\webdav-manga-handoff\device-diagnostics\2026-10-01\connected-readback' --report $taskStreamReport`；七项 cold/warm 及 EPUB legacy 必须通过、全本请求为 0。
- [ ] 整个功能分支进行一次新的独立审查；处理确认的问题后只重跑受影响检查，最后审核设计全部八条需求及交付门禁。不把合成检测结果称为真实 Kindle 精准度已验收。
- [ ] 生成包：`& $taskPy scripts/package_plugin.py $taskArchive --stream-report $taskStreamReport`；逐字节校验、解包运行相关规格、生成 SHA256 和实际源码清单。
- [ ] 提交：`release: ship panel modes and settings navigation v0.4.31`。发布前读取 GitHub 当前 main，只有可正常快进时整合；不覆盖未评审的外部提交。
- [ ] 按既有授权更新公开仓库和 GitHub Release，上传同一 ZIP 与 SHA256；读取 Release 附件并下载校验。同步提供本地安装压缩包和当前代码绝对路径。仅设备当前确实可访问时才安装并逐文件读回核对。

## 需求覆盖与完成判断

设计需求 1/2 → Task 1；需求 3/5/6 → Task 2；需求 8 → Task 3/5；需求 4 → Task 3/4/5；需求 7 → Task 4/5。所有任务均受 Task 6 的实际打包和七文件门禁约束。

当前仅设计和实施计划文档已整理。任何复选框必须有本轮代码、测试或外部状态证据才勾选；未实现功能、未通过门禁、安装包未交付均不得报告目标完成。
