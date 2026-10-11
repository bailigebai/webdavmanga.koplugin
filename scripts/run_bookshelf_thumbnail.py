"""Check actual ARM KOReader thumbnail pixels, bytes and warm-cache reuse."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from zipfile import ZipFile

from PIL import Image

from stream_formats_contract import runtime_fingerprint


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample-zip", type=Path, required=True)
    parser.add_argument("--runtime-root", type=Path, required=True,
                        help="Extracted official Kindle HF koreader directory")
    parser.add_argument("--runtime-zip", type=Path, required=True,
                        help="Official archive, checked against the supplied runtime")
    parser.add_argument("--support-runtime", type=Path, required=True,
                        help="Existing ARM contract runtime containing json.lua and lpeg.so")
    parser.add_argument("--output", type=Path, required=True,
                        help="New directory for decoded test files")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--image", default="webdavmanga-kindlehf-offline:20260928")
    args = parser.parse_args()
    plugin = ROOT / "webdavmanga.koplugin"
    fingerprint = runtime_fingerprint(plugin)
    native = args.runtime_root.resolve()
    # Bind the native renderer and libraries to their recorded official archive.
    with ZipFile(args.runtime_zip) as archive:
        for info in archive.infolist():
            if info.is_dir() or not info.filename.startswith(
                    ("koreader/frontend/", "koreader/ffi/", "koreader/libs/")):
                continue
            path = native / info.filename.removeprefix("koreader/")
            assert path.resolve().is_relative_to(native)
            assert path.read_bytes() == archive.read(info), info.filename
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    with ZipFile(args.sample_zip) as archive:
        member = next(name for name in archive.namelist()
                      if name.lower().endswith((".jpg", ".jpeg")))
        (output / "source.jpg").write_bytes(archive.read(member))
    with Image.open(output / "source.jpg") as image:
        image.load()
        width, height = image.size
    (output / "input.lua").write_text(
        f"return {{width={width},height={height}}}\n", encoding="utf-8")
    libraries = {path.name.split(".so")[0].removeprefix("lib"): "/native/libs/" + path.name
                 for path in sorted((native / "libs").glob("*.so*"))}
    (output / "libraries.lua").write_text(
        "return {" + ",".join(f'[{json.dumps(key)}]={json.dumps(value)}'
                             for key, value in libraries.items()) + "}\n", encoding="utf-8")
    command = ["docker", "run", "--rm", "--platform", "linux/arm/v7", "--network", "none"]
    for source, target in ((plugin, "/plugin"), (ROOT / "spec/contracts", "/checks"),
                           (native, "/native"), (args.support_runtime.resolve(), "/runtime"),
                           (output, "/output")):
        command += ["--mount", f"type=bind,source={source},target={target}"
                    + ("" if target == "/output" else ",readonly")]
    command += ["-e", "LUA_PATH=/plugin/?.lua;/runtime/?.lua;/native/?.lua;"
                "/native/frontend/?.lua;/native/common/?.lua;;",
                "-e", "LUA_CPATH=/runtime/?.so;/native/?.so;;",
                "-e", "LD_LIBRARY_PATH=/native/libs", args.image, "luajit",
                "/checks/bookshelf_thumbnail_native.lua"]
    subprocess.run(command, check=True)
    report = json.loads((output / "thumbnail-native-result.json").read_text(encoding="utf-8"))
    assert len(report["cases"]) == 3 and report["original_unchanged"] and report["background_subprocess"]
    for row in report["cases"]:
        with Image.open(output / row["file"]) as image:
            image.load()
            assert list(image.size) == [row["width"], row["height"]]
        assert row["warm_source_requests"] == 0
        row["fully_decoded"] = True
    assert runtime_fingerprint(plugin) == fingerprint, "Source changed during check"
    version = re.search(r'version\s*=\s*"([^"]+)"', (plugin / "_meta.lua").read_text()).group(1)
    report.update(version=version, passed=True, runtime_sha256=fingerprint,
                  source_sha256=sha256(output / "source.jpg"),
                  sample_zip_sha256=sha256(args.sample_zip),
                  reference_runtime_zip_sha256=sha256(args.runtime_zip),
                  test_sha256=sha256(ROOT / "spec/contracts/bookshelf_thumbnail_native.lua"),
                  runner_sha256=sha256(Path(__file__)),
                  limits="Offline ARM32 LuaJIT/QEMU, actual KOReader fork/pipe/reap and JPEG/scale/PNG. "
                  "Cache/client are IO boundaries; this is not measured Kindle loading speed.")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
