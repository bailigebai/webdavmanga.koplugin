# 分格识别与原生动画调整计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 提高复杂分格识别，并允许输入精确阈值；分格翻页只使用宿主动画。
**Architecture:** 保留已有独立框线识别和对白保护。仅当已有检测不能拆开页面时，使用 Meguru 的递归轴向/斜向沟槽检测；所有输出通过现有覆盖保护和排序。阅读器只发布最终格图，动画由宿主屏幕刷新承担。
**Tech Stack:** Lua 5.1/LuaJIT、KOReader 现有 BlitBuffer；无新依赖。
**Spec:** 用户本轮要求；参考 Meguru 8ed689e920d6175ddbbe82ddb900d1b091101dd8 与 Swipe Animation 59dce480c38538976325f7ebc0831e36bc4c6ed4，原文存于 handoff/upstream-inspection/panel-refinement-20261012。

## Global Constraints
- 保持 Panel Cut、Pan & Zoom、Free View、旋转、对白保护、未识别整页后继续等已有能力。
- 阈值支持 1–254 整数，默认40；数字越小，淡线识别越强，同时更易把纸张噪点当作内容。
- 分格动画：经典（无动画）或原生/已安装 Swipe Animation；不另写帧动画，不覆盖 KOReader 核心文件。
- 保持借用页缓冲所有权、候选/扫描内存上限；失败安全回退整页。
- 每次交付验证 ZIP、RAR、7Z、EPUB、PDF、AZW3 流式样本；公开发布附同一ZIP及SHA256。

## Review Focus
- 非整数、NaN、边界数值与本书/默认配置持久化。
- 淡边框与纸张灰底，斜沟槽不能把对白拆成格。
- 大图、过多候选、空白页及未识别后下一页继续。
- 图像分配释放、设置中途关闭，不可留下定时动画。
- 不支持原生动画/只有软件补丁时安全退化，不影响全刷/抖动管理。

## Task 1：精确识别阈值
Files: panel_options.lua、settings.lua、ui_reader.lua、ui_settings.lua；新spec。
- [x] RED：37/41可持久化，0/255/小数拒绝，数字输入本书/默认生效。
- [x] GREEN：统一数值schema校验和输入控件，保留原有背景设置。
- [x] 运行配置及生命周期回归。

## Task 2：复杂沟槽识别
Files: panel_analysis.lua、panel_components.lua及新增panel_gutters.lua（只承载 Meguru 递归沟槽算法）、NOTICE；新spec。
- [x] RED：斜向沟槽、窄缝/淡线及跨框对白样本。
- [x] GREEN：复用现有单格/失败时的递归沟槽补充；保护框和排序框分离。
- [x] 合成样本、真实样本原生ARM检测及内存上限回归；记录准确度证据与局限。

## Task 3：宿主动画与交付
Files: panel_options.lua、ui_reader.lua、ui_reader_shell.lua、panel_session.lua/panel_transition.lua（删除弃用的自绘动画路径）、现有相关spec与文档。
- [x] RED：切格只一次最终发布、原生方向正确、软件补丁检测、不支持时经典。
- [x] GREEN：统一宿主动画开关；面板动画页面只保留翻页动画项，识别/导航在原设置。
- [x] 独立审查、全量规格、7格式原生流式、打包校验、GitHub发布；设备存在则安装。

## Decisions / Evidence
- 用户已授权开发/发布；本轮沿用现有隔离工作树 codex/panel-experience，基线 f74ef15。
- 面板UI澄清待答；如未答，保留当前视图/旋转控制，只将“过渡效果与性能”收整为分格翻页动画，以免删除已有明确要求的能力。
- 原生/Swipe接口都采用 Screen:setSwipeAnimations / setSwipeDirection，软件模式必须同时存在补丁标志与UIManager动画实现。

- Task1完成：精确输入RED（值1无法保存）→GREEN，3个配置规格通过。
- Task2完成：无框画面RED（no_panels）→GREEN；斜窄沟槽RED（被粗投影预筛漏掉）→以多独立框线体证据允许斜向扫描。已有对白保护10项回归通过。
- Task3实现：移除自绘帧模块，原生/完整软件补丁能力检查，final-only切格/失败保留原图/自由视图生命周期规格通过。
- ARM验证：5个已知结果合成样本和16张本地真实漫画页，共21例；真实BlitBuffer借用未释放，最大检测CPU耗时0.597秒（ARM模拟器，不代表真机墙钟耗时）。真实页的精准分格仍须用户验收。
- Ruling: 未收到可选面板UI澄清，保留已有视图/旋转/导航按钮，只收整动画设置子页面。理由是此前用户明确要求这些能力，删除会超范围；若理解不同可再收整菜单，不影响检测器。

- 独立审查发现1项P2：日漫切格方向与整页方向相反。真实Session RED已复现，按self.direction反转并补齐LTR/RTL×next/previous四种断言，聚焦3套规格GREEN。无未解决的已确认P1/P2。

- 交付门禁完成：226/226、113Lua、6门禁、21ARM分格、7原文件流式、129包文件逐字节及解包37规格。发布/安装外部状态以GitHub与设备读回报告为准。
