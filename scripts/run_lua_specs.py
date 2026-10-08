from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from lupa import LuaError
from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = ROOT / "webdavmanga.koplugin"
SMART_AMBIENT_ROOT = ROOT / "smartambientlight.koplugin"

# Explicit ownership: unprefixed and rebuild_* suites exercise WebDAV Manga.
OTHER_PLUGIN_PREFIXES = {"inkgomoku_": "inkgomoku.koplugin", "mangaweb_": "mangaweb.koplugin"}


def select_specs(paths, plugin_name: str, version: str | None):
    if plugin_name == "webdavmanga.koplugin" and not re.fullmatch(r"\d+\.\d+\.\d+", version or ""):
        raise ValueError("WebDAV Manga version is required for --all release ownership")
    current_release = "rebuild_" + (version or "").replace(".", "") + "_release_spec.lua"
    selected, excluded = [], []
    for path in paths:
        path = str(path).replace("\\", "/")
        name = Path(path).name
        if not path.startswith("spec/") or not name.endswith("_spec.lua"):
            continue
        owner = next((owner for prefix, owner in OTHER_PLUGIN_PREFIXES.items() if name.startswith(prefix)),
                     "webdavmanga.koplugin")
        reason = None
        if owner != plugin_name:
            reason = "separate plugin, outside " + plugin_name + " runtime"
        elif plugin_name == "webdavmanga.koplugin" and name.endswith("_release_spec.lua") and name != current_release:
            reason = "historical version-specific release contract replaced by " + version + "; functional suites remain required"
        if reason:
            excluded.append({"path": path, "reason": reason})
        else:
            selected.append(path)
    return selected, excluded


def lua_path(path: Path) -> str:
    return path.resolve().as_posix().replace("'", "\\'")


def new_runtime(plugin_root: Path = PLUGIN_ROOT) -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    module_root = lua_path(plugin_root)
    smart_ambient_root = lua_path(SMART_AMBIENT_ROOT)
    lua.execute(
        "package.path = '%s/?.lua;%s/?/init.lua;%s/?.lua;%s/?/init.lua;' .. package.path"
        % (module_root, module_root, smart_ambient_root, smart_ambient_root)
    )
    lua.globals().TEST_PLUGIN_ROOT = plugin_root.resolve().as_posix()
    lua.globals().TEST_REPO_ROOT = ROOT.as_posix()
    return lua


def run_spec(path: Path, plugin_root: Path = PLUGIN_ROOT) -> None:
    lua = new_runtime(plugin_root)
    source = path.read_text(encoding="utf-8")
    lua.execute(source, name=f"@{path.as_posix()}")


def syntax_check(root: Path, plugin_root: Path = PLUGIN_ROOT) -> int:
    files = sorted(root.rglob("*.lua"))
    for path in files:
        lua = new_runtime(plugin_root)
        escaped = lua_path(path)
        lua.execute("assert(loadfile('%s'))" % escaped)
    print(f"Lua syntax: {len(files)} files passed")
    return len(files)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("specs", nargs="*", type=Path)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--syntax-root", type=Path)
    parser.add_argument("--plugin-root", type=Path, default=PLUGIN_ROOT)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plugin_root = args.plugin_root
    if not plugin_root.is_absolute():
        plugin_root = ROOT / plugin_root
    specs = list(args.specs)
    if args.all:
        version = None
        if plugin_root.name == "webdavmanga.koplugin":
            metadata = (plugin_root / "_meta.lua").read_text(encoding="utf-8")
            match = re.search(r'\bversion\s*=\s*"([^"]+)"', metadata)
            version = match.group(1) if match else None
        paths = ["spec/" + path.name for path in sorted((ROOT / "spec").glob("*_spec.lua"))]
        selected, excluded = select_specs(paths, plugin_root.name, version)
        specs = [Path(path) for path in selected]
        for item in excluded:
            print("NOT APPLICABLE: " + item["path"] + " — " + item["reason"])
    if not specs and args.syntax_root is None:
        raise SystemExit("select one or more specs, --all, or --syntax-root")

    passed = 0
    try:
        for raw_path in specs:
            path = raw_path if raw_path.is_absolute() else ROOT / raw_path
            print(f"==> {path.relative_to(ROOT).as_posix()}")
            run_spec(path, plugin_root)
            passed += 1
        if args.syntax_root is not None:
            root = args.syntax_root
            if not root.is_absolute():
                root = ROOT / root
            syntax_check(root, plugin_root)
    except (LuaError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if specs:
        print(f"Lua specs: {passed} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
