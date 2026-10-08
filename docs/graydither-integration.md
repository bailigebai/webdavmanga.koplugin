# 内置阅读器与 GrayDither 接入记录

本次从公开 WebDAV Manga 0.4.15 主线提交 `57151d385d6cbd71e1fce4cb92864f0507bf1aab` 实施。2026-10-08 再次匿名读取 GitHub 的 main 与该提交的元数据，仍为同一提交和 0.4.15；没有后续公开版本冲突。只修改独立开发工作树，未访问私有 WebDAV、设备设置或凭据。

## 实施边界

- 唯一新增运行模块 `webdavmanga/graydither_bridge.lua` 负责通过 `PluginLoader:getPluginInstance("graydither")` 探测可选能力、适配原 `set_reader` 保存路径并提供正文就绪条件。图像算法、刷新调度和设置界面全部留在 GrayDither，未复制到本插件。
- Shell 只接入正文的最终 `ImageWidget`。普通、拆页、适宽滚动、象限、长条连续和分格共享该位置。状态文字、加载/错误、嵌入设置、书架缩略图和对白气泡不接入算法。
- token 包含实际正文的阅读代次、图片序号、分片、适屏模式、纵向滚动、长条位置、象限及分格序号。自由分格额外包含成功绘制缓冲对应的视图、旋转、平移和缩放。`PanelSession` 把这些已成功渲染的选项作为 `on_panel` 第五参数传给 Reader，避免读到尚未提交的旧相机状态。渲染失败不发布新 token。
- 前景下载保留旧正文时也 `pause(true)`，正文成功发布前幂等 `resume()`；就绪条件排除待下载请求与长条忙状态。设置/休眠重建首屏基准，旋转/尺寸事件 reset，关闭 close。真实宿主 `CloseWidget` 事件退休共享会话，不重复运行整个阅读器退出事务。
- Reader 继续产生原生刷新/动画意图，Shell 在共享自动刷新有效时临时使用 partial 并暂停原页动画。源偏好不改；新正文 attach 失败时在同一 queued repaint 恢复原 full/动画。缺失、禁用、能力异常及已关闭的服务均保留原阅读路径。
- 灰度与自动全刷两个开关独立保存，默认 false；保存或 flush 失败会保留原值并由共享界面捕获。源码 Settings 现在也识别底层 `saveSetting` 明确返回 false 的拒绝结果。

## 可复跑验证

开发依赖为 `requirements-dev.txt` 的 Lupa 2.8。普通源回归使用 Lua 5.1；跨仓库真实绘制契约使用该包的 LuaJIT 2.1。测试只使用合成内存图片和假的下载、设备、调度/UI 外边界，未发网络请求。

在仓库根目录执行，路径参数换成自己的开发目录：

```powershell
$env:KOREADER_FRONTEND = "../koreader/frontend"
python scripts/run_lua_specs.py --all --syntax-root webdavmanga.koplugin
python scripts/run_graydither_contract.py --gray-root ../graydither
```

`KOREADER_FRONTEND` 用于已有适屏/象限测试的真实 ImageWidget。跨仓库 runner 会验证 GrayDither 的 `tests/fixtures/provenance.json` 全部固定文件哈希，加载其固定官方 ImageWidget、真实 BlitBuffer、实际灰度算法和 Session；官方 KOReader 参考提交为 `646b2e39e24a899016d38ef6dc47e3f7c429c8ba`，原生 C blitter 关闭。其余 Widget 容器、UI 调度和图片解码边界为测试替身，不能证明 MuPDF 滤镜或真实设备波形。

解压安装包后，可使用同一套规格核对交付字节：

```powershell
python scripts/run_lua_specs.py --all --plugin-root ./extracted/webdavmanga.koplugin --syntax-root ./extracted/webdavmanga.koplugin
python scripts/run_graydither_contract.py --gray-root ../graydither --plugin-root ./extracted/webdavmanga.koplugin
```

若 GrayDither 也用解压包，追加 `--gray-plugin-root ../gray-extracted/graydither.koplugin`。不要求任何绝对机器路径。

## 已取得的证据

- 原固定主线完整基线：192 组规格、107 个运行 Lua 文件语法通过。
- 最终源码与解压包各完整193组规格、108个运行Lua语法通过，均退出码0；接入专用76项、新版本/包合同32项通过。
- 真实跨仓库契约 687 项检查通过，包含每个绘出正文像素 `%17 == 0`、默认关闭原像素、源缓存字节不改、首次/重复 paint 不计、下载与预发布不计、加载保留、设置取消、真实象限最终适屏绘制、同分格 pan/zoom、失败渲染不计、源保存失败、真实共享菜单先返回正文再立即全刷、原 full/动画恢复、attach 故障同帧 full 恢复、CloseWidget/退出取消黑白阶段；实际长条 next() 跨图慢加载取消任务、保留旧 token/count、成功显示继续累积，加载期间保留正文的绘出灰度，末页无渲染不暂停。
- RED→GREEN 记录：初始默认值、共享菜单、拒绝保存、加载到正文接管、异常可选能力、真实下载期间暂停、同格相机变化、attach 失败同帧恢复、宿主关闭均先复现失败再修复。本地原始日志保留于兼容审计目录，未打包原始日志。
- 原有 CRC 性能检查在并行主机负载下曾出现 3.101s 和 3.018s，超出既有 3s 上限；阈值和 CRC 实现未改。固定原主线和接入代码的隔离 38 项及完整重跑均通过。该观察为主机性能边缘，不能当作设备性能保证。

未解决：Kindle 的触摸、真实全刷波形、黑白保持时长、残影、CPU/内存峰值仍需设备验收。16 级软件 Floyd–Steinberg 处理不等同于硬件 256 级灰度。
