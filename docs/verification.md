# 验证记录

## 2026-10-02 OPDS 加载与长条显示

本次截图是根目录加载失败，不能沿用此前章节 `ambiguous_server` 的根因。已完整读取723347字节设备日志，未找到本次目录失败的具体分类。按设备保存的两个 Suwayomi 地址分别进行无代理、同源、只读请求，均得到 `ConnectionRefusedError`，没有获得目录响应。探测结果只记录类别；地址、响应正文、配置及原始日志不进入仓库。真实服务状态与根目录恢复仍待确认。

参考代码固定为 [opdsforcomic dcd99df6](https://github.com/hugo1120/opdsforcomic.koplugin/tree/dcd99df6079d7598c9fe5958ed7c53061f5fe86b)、[Kamare b85ab0a8](https://github.com/fpammer/kamare.koplugin/tree/b85ab0a81d4a36780659629a6a421914253aff6b) 和 [smart-webtoon 13913e5c](https://github.com/QQRush/smart-webtoon-scroll.koplugin/tree/13913e5c0d2dae01a29eabc71850540581e58c85)。前者使用 KOReader 联网入口；Kamare 使用 Kavita API，其接入不能直接用作 Suwayomi OPDS。smart-webtoon 的行为参考为空白分隔与连续翻屏，其树未提供许可证，因此没有复制其源码；独立实现还避免了向前吸附越过未显示内容的风险。联网、ImageWidget、Blitbuffer 和缩放所有权契约另核对 [KOReader 固定源码](https://github.com/koreader/koreader/tree/896dd63e363adf0ac9ce6a81bff76638c42c1044) 及其 base 修订 fe41d7698ad8a6a7caf794d9b601229009a34053。

- OPDS 缺口先以固定旧提交945da2ab复现：Ui 丢弃 Async 的第三错误参数，Client 丢弃传输 status，且请求缺少联网入口。新增规格先失败再修复；最终39项验证联网等待/重复/取消/过期回调，以及证书、超时、拒绝连接、响应超限和后台故障安全分类。
- 长条 Session 的95项检查验证不同宽度跨图合成、白黑分隔、重叠与留白、完整屏章末、必需邻图失败重试、拒绝显示、晚到缓冲释放、最多两张源缓存和失败跳图历史。真实 Reader/Settings/Progress 接入规格验证加载器串行取图、成功显示才更新进度、图内归一化续读，以及全部输入/屏幕缓冲恰好释放一次。
- 新上下文只读审查发现并修复：旧普通/PreparedPages 回调覆盖长条、象限/分格未退出、本地 OPDS 继续丢失比例、失败seek提前清历史；再次复核发现并修复全局设置重载绕过互斥及首次长条尚未显示时切换停住。测试均观察失败再修复，最后复核未遗留相关范围的阻断项。
- 审查后最终全量运行170个Lua规格、94个Lua文件语法检查，退出码0。最终日志保存在本机 `opds-webtoon-final-specs-20261002.log`。没有放宽既有测试断言。
- 严格110文件清单、敏感内容扫描、固定官方原生库哈希、ZIP逐文件一致和两次构建字节一致性全部通过。新安装ZIP为 `releases/webdavmanga.koplugin-v0.4.11-20261002-opds-webtoon.zip`，826462字节，SHA256 `05F040F9D421ED58250D2BD938ABFAA02DF8225E6D792108228A8BA1503126A8`；交付目录同时保留一份。
- 首次安装前再次核对时设备已从 Windows 列表消失，该次未修改设备文件。设备安装须完整备份旧109文件，替换11个旧文件并增加1个模块，再完整读回110文件；以本机安装报告为证据。

验收：确认 Suwayomi 服务运行且浏览器能打开相同 OPDS 地址；完全退出并重启 KOReader，刷新目录、进入系列/章节、检查首图和连续翻页。在“漫画阅读设置 → 图片显示”选择“长条连续”，检查跨图屏幕、前后翻、失败重试、继续阅读和切回整页。

未解决：真实服务器返回及Kindle显示未验证；本机被拒绝连接不能证明Kindle端相同原因。空白检测是采样启发式；极长图片按目标像素预算降采样可能模糊；原生解码临时内存峰值尚未测量。一屏超过64个极短图片片段时明确失败。之前RAR修复的实机验收不属于本次运行证据。

## 2026-10-02 Suwayomi OPDS 修复

用户确认服务为 Suwayomi，Kindle 新增日志三次记录固定类别 `ambiguous_server`。原始日志仅保存在本机，未加入仓库。

官方协议来源为 [Suwayomi README](https://github.com/Suwayomi/Suwayomi-Server/blob/54d3761bb34fdaa93fcee7cbbb849c9e2f9354ce/README.md) 及同一修订的 OPDS `FeedBuilderInternal.kt`、`OpdsEntryBuilder.kt`：完整地址 `/api/opds/v1.2`、Suwayomi feed 作者、章节详情 `subsection` + Atom `type=entry`、章节 URN 和零基 PSE 页面地址。新增夹具为依照协议构造的虚构数据，没有复制设备服务器响应。

- 新增 `rebuild_0411_suwayomi_protocol_spec.lua`：旧实现复现地址冲突、版本段被脱敏及详情分类错误；审计后补测语言标签、同步进度选择和分页目录恢复，逐项观察失败再修复；修复后 325 个检查通过。
- 覆盖自动/显式 Suwayomi、直接 PSE/元数据 PSE、父级系列保持、首末页请求、无作者/代理/编码地址、真实信号冲突及查询/片段排除；另验证持久化目录恢复、本地/远程位置保留、详情不变成重复章节邻居、返回后旧回调失效及第2页选章后的分页URL保持。
- 审计后的最终全量回归：166 个 Lua 规格、93 个 Lua 文件语法检查通过，退出码 0。最终源码运行日志为本机 `upstream-inspection/full-suite-20261002-suwayomi-release.log`，其中协议规格325项；没有修改代码后沿用旧结果。
- 独立只读代码审查通过；审查者另跑18套 OPDS 规格、93文件语法并核对差异，未发现仍需阻塞交付的问题。
- 初次全量和单独重测中，既有 ZIP CRC 性能规格超过 3 秒阈值（3.030s / 3.214s）；没有修改 CRC 代码或放宽断言，后续完整重测通过。
- 确定性打包：严格 109 文件清单、敏感内容、固定官方原生库 SHA256 和两次构建字节一致性检查通过。
- 新包 SHA256：`4715C8971B5E79E97AF9F90062FA6F6996B6D3A8F5A6C5F2E2D7054C55CAA05F`。
- 2026-10-02 10:14（Asia/Shanghai）安装到已连接 Kindle：完整备份109文件后仅替换8个变化文件，完整读回109文件与新ZIP全部一致，无缺失、额外或哈希差异。没有修改连接凭据、KOReader核心或缓存。备份及读回报告仅留在本机。

桌面测试验证目录解析及页面请求，尚不能证明用户服务器实际返回图片、Kindle 显示和连续翻页成功。安装后请完全退出并重启 KOReader，刷新 Suwayomi 目录，从系列重新选择章节，检查首张和连续翻页。RAR 最近修复仍待实机阅读反馈。

## 初始源码导入验证（2026-10-02）

本次只整理独立 GitHub 项目。插件版本保持 0.4.11，插件功能文件未修改。

## 已执行

- 109 个插件文件与 2026-10-01 RAR/OPDS 已交付 ZIP 逐字节一致。
- 在本仓库根目录执行 `python scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin`：165 个 Lua 规格、93 个 Lua 文件语法检查通过，退出码 0。
- 迁移测试只适配三处旧目录路径；断言未修改。其它插件和历史版本专用发布规格没有加入本项目。
- `python scripts/package_plugin.py` 检查严格文件清单、敏感内容和官方原生库固定哈希，并验证两次构建字节一致。
- 新生成 ZIP 与已交付 ZIP 字节一致：109 文件、817,035 字节。
- ZIP SHA256：`A597C5FEE39EE3D61BB3627E12F48119946172AEA9D8D94D2488D887935D8F5B`。

## 未覆盖的验收

这里的桌面测试使用测试夹具模拟部分网络、文件系统、异步与阅读器边界，不能替代真实服务器或墨水屏设备。

2026-10-01 修复包已在 Kindle 完整读回核对过 109 个文件；用户确认其他格式可以打开，但最后一次 RAR/OPDS 修复仍待实机重测反馈。导入时 OPDS 实际服务类型尚未确认；后续证据和修复见上文。

本次没有重新执行 ARM 模拟测试。之前的 ARM 原文件提取证据不作为本次新运行结果；没有将设备原始日志、缓存索引或凭据上传。

旧 Git 工作树链接已失效，原历史没有恢复。本仓库的首个提交来自当前已验证源码快照，不能当作旧提交 e961b68 的历史恢复。
