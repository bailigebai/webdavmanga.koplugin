# Suwayomi OPDS 修复执行规划

> 使用 superpowers:executing-plans 按阶段执行；本次由当前代理实施和复核。

**目标：** 修复用户 Kindle 的 `ambiguous_server`，按 Suwayomi 官方协议完成系列、章节详情和 PSE 页面读取。

**事实来源：** 用户确认 Suwayomi；设备日志三个 `chapter_resolve reason=ambiguous_server`。官方 README 地址 `/api/opds/v1.2`，FeedBuilderInternal 的作者为 Suwayomi，OpdsEntryBuilder 使用章节 URN、`subsection` + `type=entry` 的详情链接及 `/api/v1/manga/.../page/{pageNumber}`。

**架构：** OPDS 地址规则集中在 opds_url；完整路由覆盖其内部的短路由，真正不同的作者或独立路由冲突继续拒绝。详情入口按 Atom 链接类型区分章节与系列，不覆盖父级系列归属。无新依赖，Lua 5.1。

**方案比较：**

| 方案 | 影响 | 判断 |
| --- | --- | --- |
| 连接手动设 Suwayomi | 可临时绕过自动识别，但默认行为仍错误 | 仅临时办法 |
| 删除所有冲突检查 | 改动少，但会接受不匹配服务与错误章节 | 不采用 |
| 完整路由识别及真实协议回归 | 修根因，保留冲突检查与既有驱动边界 | 采用 |

**约束：** 不改用户凭据、核心程序、其它格式及原生库；每次交付同步 ZIP，安装前备份，安装后完整读回。真实阅读由用户拔除 USB 后验收，不将桌面结果当实机成功。

## 阶段 1：协议回归和最小修复

文件：opds_url.lua、opds_driver.lua、opds_drivers/{suwayomi,kavita,komga}.lua、opds_parser.lua、ui_opds.lua；新增 spec/rebuild_0411_suwayomi_protocol_spec.lua。

- [x] 构造符合官方字段的系列、章节目录、元数据和 PSE 测试；在旧实现确认错误。
- [x] 修正嵌套路由识别，支持官方和已有 Suwayomi 地址，保留查询/片段排除及真实冲突拒绝。
- [x] 保留官方 `v1.2` 协议段，仍脱敏 Kavita 密钥；`type=entry` 详情保持父级系列身份。
- [x] 验证自动及显式 Suwayomi，从系列到元数据、首张和末张请求；检查无封面、代理前缀、编码路径、取消/过时异步等既有规格。

## 阶段 2：复核和交付

- [x] 全量 Lua 规格及语法检查；复核完整差异、身份与请求边界。
- [x] 更新说明和来源清单，严格校验 109 文件、原生库固定哈希及两次打包一致性。
- [x] Kindle 备份后只替换改变文件，完整读回核对；准备交付新 ZIP。
- [x] 保存本地验证记录并准备已授权私有仓库的增量上传流程；上传结果由本机 `github-suwayomi-upload-verification-20261002.json` 记录。不上传设备日志和凭据。

## 复核重点

- 官方路由中包含 Kavita/Komga 子串不能造成冲突；两个独立服务信号仍报冲突。
- 有作者、无作者、代理和编码路径必须一致。
- 无 PSE 的章节详情不能被当作新的系列。
- 保存的官方协议版本段不能被当成密钥替换；真正密钥仍脱敏。
- 同一章节的元数据验证、首末页零基编号和取消行为仍符合既有协议。

## 执行记录

设备日志保存在本机 handoff/device-diagnostics/2026-10-02-094651-opds-conflict，不进入仓库。

独立审计发现相关协议边界，纳入原目标：公开 `lang` 参数需要保留以恢复持久化导航；官方同步冲突详情需要让用户选择本地/远程位置；在章节目录第2页选择后，指针应保存当前分页URL，不能退回第1页。先增加失败测试再修复；仅放行2~3 ASCII语言字母及有界连字符子段，异常值仍脱敏。元数据多选不默认选第一项，同一规范化章节ID不能形成重复邻居，新详情替换旧目录时推进generation。针对协议的325项检查已通过。
