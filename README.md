# KOReader WebDAV 漫画插件

当前源码：**0.4.11，2026-10-01 RAR/OPDS 修复包**。

通过 WebDAV、OPDS 和本地文件进入漫画书架与阅读器，支持图片型 EPUB、受限图片型 PDF、ZIP/CBZ、RAR/CBR、7Z/CB7、TAR/CBT 等容器。具体格式与设备限制见 [插件说明](webdavmanga.koplugin/README.md)。

## 安装

下载 [最新安装 ZIP](releases/webdavmanga.koplugin-v0.4.11-20261001-rar-opds-repair.zip)，解压后把 `webdavmanga.koplugin` 文件夹放入 KOReader 的 `plugins/` 目录，再完全退出并重启 KOReader。覆盖前备份原插件；账号和服务器地址在设备的插件设置中填写。

## 当前修复

- EPUB：同一封面出现多次时保留阅读页序并使用独立缓存编号。
- PDF/RAR：在能够核对当前连接归属时恢复缺少旧标记的起始页缓存；归属冲突和并发变化仍拒绝。
- RAR：前三页验证后开始阅读，后台继续目录，减少首屏请求次数。
- KindleHF 7Z：核心缺少 LZMA 时使用插件自带的固定版本官方解码库。
- OPDS：详情目录继续导航，实际章节才进入章节解析，错误提示使用固定类别。

## 开发与验证

需要 Python 3.11 或以上；Lua 5.1 测试运行时由 `lupa` 提供。在仓库根目录执行：

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.venv\Scripts\python.exe scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin
.venv\Scripts\python.exe scripts/package_plugin.py
```

Linux/macOS 将 Python 路径改为 `.venv/bin/python`。打包输出在 `dist/`，文件清单、敏感内容、原生库哈希和双次构建一致性会自动校验。`releases/` 保留已交付设备的安装 ZIP；后续源码变更须同步提供新包。

## 验收与限制

本地测试不能替代真实 WebDAV/OPDS 服务器和 Kindle 的界面验收。安装后测试 EPUB/PDF/RAR 前 20 页、PDF 再次打开、7Z 全部页，以及 OPDS 从系列进入章节。RAR/OPDS 最近修复的实机重测仍待确认，OPDS 截图所用服务类型尚未确认。

固实 7Z 后续页面可能反复解码压缩前缀，流量和速度取决于文件结构。任意复杂、加密或损坏 PDF/归档并非都支持；整本下载需要明确确认。授权服务部署和私有签名材料不包含在本项目。

## 来源与许可证

这是从已交付源码快照建立的新仓库，旧 Git 历史缺失，不能证明旧分支提交 `e961b68`。插件内容与已安装 ZIP 逐文件一致，见 [源码清单](docs/source-manifest.json)。

原生库来源、固定哈希和完整第三方许可证见 [KindleHF 库说明](webdavmanga.koplugin/lib/kindlehf/README.md)、`THIRD_PARTY_NOTICES.txt` 和 `COPYING-KOReader`。本次导入没有新增插件整体许可证声明。
