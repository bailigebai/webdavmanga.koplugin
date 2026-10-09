# 每次交付前的原文件流式检查

正式打包必须携带通过的 `--stream-report`。报告绑定全部运行 Lua、原生库及检查脚本的 SHA-256；改了运行代码、版本或检查脚本后，必须重新验证。缺少任一原文件、页加载失败、完整图片解码失败、旧 EPUB 目录恢复失败、整本请求或旧报告都会阻止打包。

需要：Python 3.11+、`requirements-dev.txt` 中的 Lupa/Pillow、已有的 ARM Linux Docker 测试镜像（LuaJIT/libz），只读 KOReader 官方 runtime（含 ffi/archiver、JSON、lpeg），以及已复制的 Kindle libarchive 和 LFS。脚本不会安装镜像或修改设备配置。

在仓库根目录运行（路径换成自己的本地目录）：

```powershell
python scripts/run_stream_formats.py --samples <原文件目录> --runtime-root <KOReader-runtime目录> --device-libs <Kindle原生库目录> --image <已有ARM镜像> --report stream-report.json
python scripts/test_stream_release_gate.py
python scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin
python scripts/package_plugin.py --stream-report stream-report.json
```

默认使用用户的两份 RAR、EPUB、PDF、ZIP、7Z、AZW3 共七份测试原文件。其他文件名可用 `--fixtures fixtures.json`，格式为七项列表：`[{"label":"rar-big","kind":"rar","filename":"large.rar"}, ...]`。完整标签固定为 `rar-big`、`rar-small`、`epub`、`pdf`、`zip`、`7z`、`azw3`。EPUB 样本须含重复封面，才能复现旧目录缓存错误。原文件、runtime 和设备库不存入仓库或安装包。

实际执行 ARM LuaJIT 的 DocumentBridge → Cache → Loader，包括真实归档/XML/图片文档解析、原生 libarchive/LFS、进程结果序列化及发布缓存；测试每本首次打开、重复打开、前20页和末页（不足20页的全测），并用 Pillow 完整解码缓存图片。EPUB 另构造旧版重复路径目录缓存。输入只读，缓存和解码副本放入隔离临时目录，结束后回收。报告记录来源文件哈希、目录页数、请求次数、首屏与累计字节、原生库哈希和镜像ID。

边界：HTTP 返回由严格 Range 文件读取替身提供，调度与阅读窗口为替身；这不证明真实 Wi-Fi、HTTP 认证、服务器、触摸和墨水屏效果。并非穷尽每本的所有页或所有格式变种。固实 7Z 需要反复解码前缀，累计传输可能大于文件大小；不把“未请求整本”宣传为低流量。真机交付还应重启 KOReader、逐本打开和翻页，保留新增失败日志。
