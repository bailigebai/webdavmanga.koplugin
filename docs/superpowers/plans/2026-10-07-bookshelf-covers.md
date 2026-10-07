# 漫画书架封面浏览 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 在漫画书架增加列表/封面切换，并在 Kindle 本地独立保存和管理目录、选图索引与封面缩略图。

**Architecture:** 复用 DirectoryStore、Cover、Loader、CoverGrid 和 Cache。书架专用的紧凑 JSON 索引存储、选图索引与缩略图适配器分成小模块；Cache 的全种类统一配额仅在书架实例开启，其他阅读路径不受影响。

**Tech Stack:** Lua 5.1、KOReader 原生图片渲染/PNG 编码、已有 json、Python/Lupa 规格运行器。无新增依赖。

**Spec:** `docs/superpowers/specs/2026-10-07-bookshelf-covers-design.md`（用户于2026-10-07确认并要求开始开发）。

## Global Constraints

- 默认列表，记忆列表/封面选择；封面沿用3/5列、完整等比缩小，不增强、不裁剪。
- 直属图片按数字自然排序优先；无直属图时只查下一层，空子目录继续下一兄弟，不递归。
- 专用根目录 `DataStorage:getDataDir() .. "/cache/webdavmanga-bookshelf"`；只存生成缓存，不能删除原漫画、凭据、历史或正文缓存。
- 默认最大200MB、触发150MB、保留100MB、10分钟检查；0≤保留<触发≤最大。
- 索引与缩略图共同受配额限制；保护当前屏幕、目录及发布文件，空间不足拒绝新增；仅加载可见卡片，切页/连接切换取消。
- WebDAV和本地目录书架；OPDS导航不改造成文件目录；纯归档/文档文件夹使用占位图。
- 新版本必须严格打包、提供相同ZIP副本，按既有授权同步GitHub；连接设备时备份并安装读回。

## Review Focus

- 临时源图、缩略图及索引共同写入时可能越过最大容量；应拒绝新增且无遗留临时文件。
- 用户切页或换连接后网络迟到结果；不能污染新界面、泄漏缓冲区或保留整张原图。
- 当前目录无图、首个子目录为空或失败；继续同层可用目录且不深入孙目录。
- 清理时当前屏幕和目录被保护；不能误删本地原图，保留量应显示实际使用。
- 目录刷新、断网、重启和视图切换；应更新旧封面、使用已有索引并保持位置和原有操作。

---

### Task 1: 独立存储和统一缓存配额

**Files:**
- Create: `webdavmanga.koplugin/webdavmanga/bookshelf_store.lua`
- Modify: `webdavmanga.koplugin/webdavmanga/cache.lua`, `settings.lua`
- Test: `spec/bookshelf_cache_spec.lua`

**Interfaces:**
- Produces: BookshelfStore:new{path, fs?, json?}; readSetting/saveSetting/flush/cache_index_size(entries)；原子JSON写入，损坏索引为空。
- Produces: Cache:new{unified_quota=true, store=BookshelfStore, ...}；total_size/cleanup_browse/publish/clear统一计目录、选图、缩略图及JSON登记表。
- Produces: Settings:get_bookshelf_cache()/set_bookshelf_cache(values), get_bookshelf_view()/set_bookshelf_view("list"|"covers")。

- [x] Step 1: 新规格断言默认200/150/100/10、非法关系拒绝、模式记忆、全类型LRU、保护项、JSON重启和损坏恢复、索引字节计入上限、发布失败不留part。
- [x] Step 2: 运行 `python scripts/run_lua_specs.py spec/bookshelf_cache_spec.lua`；Expected: 新接口缺失导致RED。
- [x] Step 3: 实现紧凑JSON存储和Cache opt-in统一配额，复用现有路径安全/保护/LRU；发布之前计算候选索引实际编码长度。
- [x] Step 4: 运行新规格和旧cache/cover_cache/stream_cache规格；Expected: 全部GREEN；全套测试输出存入任务工作区。
- [x] Step 5: 提交 `feat: add isolated bookshelf cache policy`，记录证据。

### Task 2: 封面发现、选图索引与缩略图

**Files:**
- Create: `webdavmanga.koplugin/webdavmanga/bookshelf_catalog.lua`, `bookshelf_loader.lua`
- Modify: `webdavmanga.koplugin/webdavmanga/cover.lua`, `ui_cover_grid.lua`
- Test: `spec/bookshelf_cover_spec.lua`, `spec/bookshelf_thumbnail_spec.lua`

**Interfaces:**
- Consumes: Task1 Cache/BookshelfStore与已有DirectoryStore、Loader、PageProcessor。
- Produces: BookshelfCatalog:new{cache, identity_provider, json?}; get_cover/set_cover/set_no_cover/invalidate(connection,path)；选图记录存为独立manifest，不存凭据。
- Produces: Cover:new{search_all_children=true, scheduler?}：直属首图，否则分批逐个子目录，仅深度1。
- Produces: BookshelfLoader:new{cache, loader, renderer?, processor?, identity}; cover_key(image), request_cover(generation,image,callbacks), cancel_cover_generation(generation), cancel_all()；PNG最长边受固定目标限制，临时源图生成后立即移除。
- Produces: CoverGrid支持可选loader:cover_key(image)和可见封面保护；旧实例接口不变。

- [x] Step 1: 新规格断言001/2/10、直属优先、首子为空继续、孙图不查、错误不永久阴性、选图重启/隔离/刷新、缩略图命中、不增强、源文件不删除、失败/取消/迟到任务释放资源。
- [x] Step 2: 运行两组新规格；Expected: RED。
- [x] Step 3: 实现上述小模块，沿用PageProcessor.process无LUT/crop生成PNG；保存etag/modified可用信息并纳入封面键。
- [x] Step 4: 运行新规格及cover、cover_grid、loader、目录相关规格，随后全套；Expected: GREEN。
- [x] Step 5: 提交 `feat: resolve and cache bookshelf thumbnails`，记录证据。

### Task 3: 书架视图、工具栏与缓存管理

**Files:**
- Create: `webdavmanga.koplugin/webdavmanga/bookshelf_toolbar.lua`, `ui_bookshelf_cache.lua`, `bookshelf.lua`（生命周期组装边界，见执行记录裁定）
- Modify: `webdavmanga.koplugin/webdavmanga/ui_browser.lua`, `ui_cover_grid.lua`, `ui_settings.lua`, `main.lua`
- Test: `spec/bookshelf_browser_spec.lua`, `spec/bookshelf_ui_spec.lua`

**Interfaces:**
- Consumes: Task1/2缓存、服务、加载器。
- Produces: 独立book_grid与book_directory_store注入Browser；show_library选择保存模式，列表与网格都在连接按钮旁切换视图。
- Produces: BookshelfToolbar.new(model,width)：KOReader native TitleBar/HorizontalGroup/IconButton组合，两个独立左侧点击区和退出。
- Produces: CoverGrid可选on_switch_connection/on_toggle_view/on_close/on_actions/initial_item_id；报告首可见位置，列表重开选择同一项目。
- Produces: UiBookshelfCache:new{settings,cache,ui?,on_changed?}:show()；容量/触发/保留/间隔、占用/封面数/索引、手动按规则清理和只清空书架缓存。
- Produces: main初始化专用根/实例/定时任务，连接切换和退出完整取消，现有缓存菜单新增入口。

- [x] Step 1: 新规格断言默认列表、切换记忆、同目录同项目、点进入长按动作、占位可点、原管理入口、顶部独立按钮、离线命中、缓存界面校验/保护、连接切换和退出取消。
- [x] Step 2: 运行新规格；Expected: RED。
- [x] Step 3: 按现有UI/生命周期实现最小接入；保持Reader使用旧DirectoryStore，书架浏览使用新DirectoryStore。
- [x] Step 4: 运行新规格及browser、导航、生命周期、菜单原生规格，再运行全套与Lua语法；Expected: GREEN。
- [x] Step 5: 提交 `feat: add cover browsing and bookshelf cache controls`，记录证据。

### Task 4: 审查、说明、安装包与交付

**Files:**
- Modify: README、插件漫画说明、_meta.lua/main版本、NOTICE、scripts/package_plugin.py与严格源清单。
- Create: 0.4.15版本规格、验证记录和release ZIP。

**Interfaces:**
- Consumes: Task1–3完成结果；版本0.4.15。
- Produces: 严格ZIP及相同副本；可审查的完整分支、验证记录、GitHub更新；有设备时安装核对。

- [ ] Step 1: 版本规格断言0.4.15、运行文件与说明包含新功能，严格清单无凭据/原漫画；先跑RED再修改版本/说明。
- [ ] Step 2: 全套测试+语法、构建两次一致、ZIP逐文件核对、git diff --check；Expected: 全部通过。
- [ ] Step 3: 使用executing-plans要求的独立最强模型审查整分支；重要问题单次TDD修复并跑全套。
- [ ] Step 4: 提交说明/验证/ZIP，将完成分支整合到main，按已有授权同步公共仓库；包副本SHA一致。
- [ ] Step 5: 检查设备；若连接，先备份插件、保留配置/密钥，再复制并完整读回；若未连接，明确仅安装未完成，交付ZIP与验收操作。
