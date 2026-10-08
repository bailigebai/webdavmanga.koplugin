"""Exercise the real WebDAV reader against an independently checked GrayDither tree.

Example (from this repository):
  python scripts/run_graydither_contract.py --gray-root ../gray
Lupa 2.8 with its LuaJIT 2.1 runtime is required. No device files or network are used.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gray-root", required=True, type=Path,
                        help="GrayDither source tree with scripts/run_tests.py and pinned fixtures")
    parser.add_argument("--plugin-root", type=Path, default=ROOT / "webdavmanga.koplugin",
                        help="WebDAV runtime tree; may be extracted from the release ZIP")
    parser.add_argument("--gray-plugin-root", type=Path,
                        help="optional GrayDither runtime tree extracted from its release ZIP")
    args = parser.parse_args()
    gray_root = args.gray_root.resolve()
    gray_plugin = (args.gray_plugin_root or gray_root / "graydither.koplugin").resolve()
    for item in json.loads((gray_root / "tests/fixtures/provenance.json").read_text(encoding="utf-8")):
        path = gray_root / item["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise SystemExit("Fixture hash mismatch: " + str(path))
    module = importlib.util.spec_from_file_location("gray_test_runner", gray_root / "scripts/run_tests.py")
    runner = importlib.util.module_from_spec(module)
    module.loader.exec_module(runner)
    lua = runner.runtime(plugin_root=gray_plugin)
    lua.globals().SOURCE_PLUGIN = args.plugin_root.resolve().as_posix()
    lua.execute('package.path=SOURCE_PLUGIN.."/?.lua;"..package.path')
    os.chdir(ROOT)
    path = ROOT / "spec/contracts/graydither_reader_contract.lua"
    lua.execute(path.read_text(encoding="utf-8"), name="@" + path.as_posix())
    print(lua.eval("jit.version") + "; pinned real ImageWidget/BlitBuffer; C blitter disabled; no network")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
