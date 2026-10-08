# 缓存文件大小错误修复 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans；既有委派任务已授权直接执行，不提交、不发布、不安装设备。

**Goal:** 修复设备日志已证明的 WebDAV 书架 E0003 和 cleanup_browse 同源退出。

**Architecture:** 四处文件大小消费只读取 fs.size 的第一个返回值。维持缺少临时文件计为 0、辅助文件退回目录记录、文档大小未知和发布失败的现有规则。

**Tech Stack:** Lua 5.1、现有 Python/lupa 规格运行器、现有严格 ZIP 打包脚本。

**Spec:** 2026-10-08 本次委派修复需求；设备 crash.log 的 cache.lua:281 栈（原始日志留在本机，不入包）。

## Global Constraints

- 基线：v0.4.17，HEAD 331a41f1849282dcffbb119c5b2855b70a73684c，已有干净 linked worktree。
- 只改 WebDAV；不修改 MangaWeb、GrayDither、设备数据、凭据和公开发布。
- 不新增依赖，不更改预算、缓存清理/保护和文件安全规则。
- 版本与本地包同步为 0.4.18；严格124文件安装清单继续有效。

## 方案比较

| 方案 | 作用 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 只改默认 filesystem.size 适配器 | 屏蔽默认 lfs 错误返回值 | 注入的 fs 和未来适配器仍能触发四处错误 | 不推荐 |
| 四处先存局部 size，再 tonumber | 每个消费边界明确只取一个返回值 | 多四个局部变量 | 推荐；小、易读、测试覆盖所有入口 |
| 给书架/清理入口加 pcall | 避免错误逃出界面 | 大小错误仍在，目录加载与预算计算失败 | 不推荐 |

## Review Focus

- 未创建的活动 part：pending/total/write_budget/cleanup 返回正常结果。
- 目录扫描后临时辅助文件消失：保留 entry.size fallback。
- 文档存在检查后 stat 失败：保留现有未知大小行为；明确缺文件时仍移除索引。
- 发布 part 缺失：按既有 empty_part/rename_failed 返回，不产生伪成功。
- 正常数字大小及缓存安全/配额规则：现有功能规格保持通过。

### Task 1：复现并修复四处多返回值消费

**Files:** 修改 webdavmanga.koplugin/webdavmanga/cache.lua；新增 spec/rebuild_0418_cache_size_spec.lua。

- [x] 先写实际 Cache 的生产适配器和注入 fs 两条回归路径，模拟 nil,error。
- [x] 运行新规格；确认 RED 为 tonumber 第二参数错误，记录证据。
- [x] 四处明确接收一个局部大小值，再作现有 tonumber 与 fallback。
- [x] 新规格 GREEN，运行缓存、书架、目录、文档与全量回归/语法。

### Task 2：本地交付

**Files:** _meta.lua、main.lua、NOTICE、两份 README、scripts/package_plugin.py、版本规格、docs/releases/v0.4.18.md、docs/verification.md、docs/source-manifest.json。

- [x] 版本和说明同步，明确设备日志已确认此根因但真机回归未完成。
- [ ] 独立上下文审计由主代理接收 diff 后安排。
- [x] 严格脚本构建 v0.4.18 本地 ZIP 和 SHA256，核对解压内容，更新源码清单。
- [x] 回报命令、结果、验收方法与未验证项，不安装/发布/提交。

## 执行记录

- 首次基线未配置 KOREADER_FRONTEND，运行至 quadrant_fit 后因缺少测试素材停止；属于环境缺项，原命令和输出保留在 handoff/cache-size-0418-baseline.log。
- 官方frontend补齐后基线196组/108语法通过；新增回归RED复现四处错误，修复后22项GREEN；相关12组243项和108语法通过。
- 完整新回归196/197、108语法通过；唯一失败是原有512KiB CRC耗时3.057s大于3s。单独复跑原规格38项通过；不改变实现、阈值或掩盖完整运行失败。
- 本地包124文件/874527字节；SHA256 7dce1c8c3c23f42f81f17d5f2a3d676a5672cb92d65e861f3066c67cfb7961c1；解压215项/108语法、真实GrayDither契约687项通过。
- 独立审计由主代理安排，待回传意见；设备验证保持未完成。
