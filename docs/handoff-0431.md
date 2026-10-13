# WebDAV Manga 0.4.31 开发交接

完整源码仓库：`E:\jiankong\webdavmanga.koplugin`；当前功能开发工作区：`E:\jiankong\webdav-manga-handoff\worktrees\panel-reading`，分支`codex/panel-experience`。插件核心在仓库内`webdavmanga.koplugin/`，测试在`spec/`，验证/打包在`scripts/`。运行代码提交`4a8afe5e0f0a0b05ef2c4f159d945a7797d94b3a`；最后发布的源码清单和安装ZIP指纹见`docs/source-manifest.json`。

本轮用户已确认设计与实施计划：`docs/superpowers/specs/2026-10-13-panel-modes-settings-design.md`和`docs/superpowers/plans/2026-10-13-panel-modes-settings.md`。用户明确要求删除插件分格截图按钮与功能；不修改KOReader自带截图。三种分格互斥，默认关闭自动匹配；算法以当前代码和固定来源为准，不用旧设备记忆猜测。

关键模块：`ui_reader`负责阅读和设置路由，`ui_reader_shell`负责窗口/布局所有权，`ui_settings`负责全局原生编辑器；`panel_modes`负责互斥；`panel_session`负责当前/下一格、原图重识别与事务；`panel_detector/panel_analysis/panel_detection_profile`负责原生与智能识别；`web_panel_zoom/web_panel_analysis/web_panel_components`负责固定MangaWeb0.8.91识别。固定来源及许可证见`docs/provenance/mangaweb-panels.json`和插件`NOTICE`。

每次更新先跑全量Lua、严格打包及七原文件流式门禁，最后改了运行字节必须重跑报告。不能用整本下载替代流式成功，不能用合成图格数证明真实对白完整。审查与全部实施裁决见`docs/implementation-0431.md`。参考本版`docs/verification.md`、`docs/panel-analysis-0431.json`、`docs/stream-formats-0431.json`。Python/Lupa/Pillow、ARM Docker及官方KOReader运行时路径见实施计划。新电脑需重新准备运行环境与本地原始测试文件；安装包与源码不含原始漫画或凭据。

本地原始回归文件：`E:\测试`。设备设置、授权密钥、账号和正文缓存不在代码包中，迁移时由用户另外保管。测试七份原文件：两RAR、ZIP、7Z、EPUB、PDF、AZW3。

新电脑首条消息：
“继续开发webdavmanga.koplugin。先阅读README、docs/handoff-0431.md、docs/verification.md及当前源码清单，确认本地版本和Git状态。以真实代码/日志为准，先复现再修改。保留三模式互斥、原图不处理、设置逐级返回、插件背景可退出、对白点击优先和七格式严格流式门禁。复杂页识别准确度及Kindle触摸/墨水屏效果仍需要真实设备验收。每次交付同步安装ZIP与SHA256。”
