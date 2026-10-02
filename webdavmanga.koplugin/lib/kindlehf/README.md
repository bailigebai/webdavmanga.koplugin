# KindleHF 7Z 解码库

仅当 Kindle ARM 32 位 hard-float 的系统 libarchive 没有 LZMA 时，插件用此库读取 7Z/CB7。RAR 与其他格式使用系统原库。不会改写 KOReader 核心文件。

二进制：官方 KOReader `v2026.07.2-185-gdcf6e3b42_2026-09-20_kindlehf` ZIP 中原样提取的 `libs/libarchive.so.13`。
SHA256：`5d31b914b567f44a24fd3fca9bd9b3b4aad74704bd7cf06eada6cc48269b8e47`。
版本：libarchive 3.8.9，静态链接 liblzma 5.8.3。
依赖：设备现有 libc.so.6、libz.so.1、libzstd.so.1；ELF ARM EABI5 hard-float；GLIBC 2.4/2.6，与本次设备原库需求相同。

源码与构建：
- KOReader commit: https://github.com/koreader/koreader/tree/dcf6e3b426ffca0de52e543c725a8000ea64f105
- koreader-base commit: https://github.com/koreader/koreader-base/tree/9a8729713ab73f539b607af23ede6aa89d04cfed
- 构建及本地补丁：该 commit 的 thirdparty/libarchive 和 thirdparty/xz。
- 原始发行包：https://build.koreader.rocks/download/nightly/2026.07.2-185-gdcf6e3b42/koreader-kindlehf-v2026.07.2-185-gdcf6e3b42_2026-09-20.zip

上游项目来源和校验：
```json
[
  {
    "project": "libarchive",
    "url": "https://github.com/libarchive/libarchive/releases/download/v3.8.9/libarchive-3.8.9.tar.xz",
    "sha256": "888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde"
  },
  {
    "project": "xz",
    "url": "https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.xz",
    "sha256": "fff1ffcf2b0da84d308a14de513a1aa23d4e9aa3464d17e64b9714bfdd0bbfb6"
  }
]
```

许可证与版权见 THIRD_PARTY_NOTICES.txt、COPYING-KOReader。维护时必须重新固定来源、校验 ABI/依赖、用真实 7Z 检查系统库与附带库同时加载的路径，并更新 notices；不直接用主机系统库替换。
