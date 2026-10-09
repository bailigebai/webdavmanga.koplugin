"""Offline ARM integration gate; original books/runtime libraries are not bundled."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import stream_formats_contract as contract

ROOT = Path(__file__).resolve().parents[1]
# This user's seven regression originals. --fixtures permits another local manifest.
FIXTURES = (
    ("rar-big", "rar", "1.rar"), ("rar-small", "rar", "漫画测试.rar"),
    ("epub", "epub", "EPUBOrigin-源机型_第10卷 - 知道漫画补档.epub"),
    ("pdf", "pdf", "PDFOrigin-源机型_第10卷 - 知道漫画补档.pdf"),
    ("zip", "zip", "漫画测试11.zip"), ("7z", "7z", "漫画测试33.7z"),
    ("azw3", "azw3", "AZW3Origin-源机型_第10卷 - 知道漫画补档.azw3"),
)


def sha(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=Path, required=True)
    parser.add_argument("--runtime-root", type=Path, required=True)
    parser.add_argument("--device-libs", type=Path, required=True)
    parser.add_argument("--image", default="webdavmanga-kindlehf-offline:20260928")
    parser.add_argument("--plugin-root", type=Path, default=ROOT / "webdavmanga.koplugin")
    parser.add_argument("--fixtures", type=Path, help="JSON list: label, kind, filename (seven cases)")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    # Invalidate a previous PASS before even preparing inputs. A missing sample
    # or stopped Docker engine must never leave an old report usable for release.
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_bytes(b'{"schema":1,"passed":false}\n')
    from PIL import Image
    samples, runtime, libraries, plugin = (p.resolve() for p in
                                           (args.samples, args.runtime_root, args.device_libs, args.plugin_root))
    fixtures = json.loads(args.fixtures.read_text(encoding="utf-8")) if args.fixtures else [
        {"label": label, "kind": kind, "filename": filename} for label, kind, filename in FIXTURES]
    if len(fixtures) != 7 or {f["label"] for f in fixtures} != set(contract.REQUIRED_CASES):
        raise ValueError("Seven distinct sample labels required")
    if (len({f["filename"] for f in fixtures}) != 7 or
            any(f["kind"] != contract.CASE_KINDS[f["label"]] for f in fixtures)):
        raise ValueError("Each sample must have its required format and a distinct filename")
    hashes = {}
    for fixture in fixtures:
        name = fixture["filename"]
        if Path(name).name != name or "\\" in name or "/" in name:
            raise ValueError("Sample filenames must stay inside --samples")
        hashes[fixture["label"]] = sha(samples / name)
    native = {"archive": sha(libraries / "libarchive.so.13"),
              "lfs": sha(libraries / "libkoreader-lfs.so")}
    before = contract.runtime_fingerprint(plugin)
    check_before = contract.contract_fingerprint()
    runtime_before = contract.runtime_fingerprint(runtime)
    image_id = subprocess.check_output(["docker", "image", "inspect", args.image,
                                       "--format", "{{.Id}}"], text=True).strip()
    report = {"schema": 1, "passed": False, "version": contract.version(plugin),
              "runtime_sha256": before, "contract_sha256": check_before,
              "environment": {"architecture": "arm32", "image": image_id,
                              "koreader_runtime_sha256": runtime_before,
                              "native_libraries": native}, "cases": []}
    try:
        with tempfile.TemporaryDirectory(prefix="stream-formats-") as temporary:
            output = Path(temporary)
            # Lua string escaping uses only observed fixture names; JSON encodes Unicode as UTF-8.
            rows = ["{label=%s,kind=%s,filename=%s}" % tuple(json.dumps(f[key], ensure_ascii=False)
                    for key in ("label", "kind", "filename")) for f in fixtures]
            (output / "inputs.lua").write_bytes(("return {" + ",".join(rows) + "}\n").encode())
            command = ["docker", "run", "--rm", "--platform", "linux/arm/v7", "--network", "none"]
            for source, target, readonly in ((plugin, "/plugin", True), (runtime, "/runtime", True),
                (libraries, "/device", True), (samples, "/samples", True),
                (ROOT / "spec/contracts", "/checks", True), (output, "/output", False)):
                command += ["--mount", f"type=bind,source={source},target={target}" + (",readonly" if readonly else "")]
            command += ["-e", "LUA_PATH=/plugin/?.lua;/runtime/?.lua;/runtime/?/init.lua;;",
                        "-e", "LUA_CPATH=/runtime/?.so;;", image_id,
                        "luajit", "/checks/stream_formats_contract.lua"]
            subprocess.run(command, check=True)
            report["cases"] = json.loads((output / "native-results.json").read_text(encoding="utf-8"))
            for case in report["cases"]:
                case["source_sha256"] = hashes[case["label"]]
                for result in case["rounds"].values():
                    names = result.pop("images")
                    if len(names) != len(result["positions"]) or len(set(names)) != len(names):
                        raise ValueError("Cached image list differs from checked positions")
                    decoded = 0
                    for name in names:
                        if Path(name).name != name:
                            raise ValueError("Invalid cached image filename")
                        with Image.open(output / name) as image:
                            image.load()  # Full pixel decode, not just JPEG/PNG headers.
                            if image.width <= 0 or image.height <= 0:
                                raise ValueError("Empty cached image")
                        decoded += 1
                    result["decoded_images"] = decoded
        if (before != contract.runtime_fingerprint(plugin) or check_before != contract.contract_fingerprint() or
                runtime_before != contract.runtime_fingerprint(runtime) or
                any(sha(samples / f["filename"]) != hashes[f["label"]] for f in fixtures) or
                native != {"archive": sha(libraries / "libarchive.so.13"), "lfs": sha(libraries / "libkoreader-lfs.so")}):
            raise ValueError("Inputs changed during verification")
        report["passed"] = True
        contract.validate_report(report, plugin)
    except Exception:
        report["passed"] = False
        raise
    finally:
        report["checked_at"] = datetime.now(timezone.utc).isoformat()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes((json.dumps(report, indent=2) + "\n").encode())
    print("PASS: seven originals; cold/warm cache; EPUB legacy catalog; real ARM parsers and cached image decode")


if __name__ == "__main__":
    main()
