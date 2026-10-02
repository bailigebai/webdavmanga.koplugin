"""Package the current WebDAV Manga source with its strict file contract."""

from __future__ import annotations

import hashlib
import os
import re
import sys
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / "webdavmanga.koplugin"
DESTINATION = REPO / "dist" / "webdavmanga.koplugin-v0.4.11.zip"
sys.path.insert(0, str(REPO / "scripts"))
import package_contract as contract  # noqa: E402


def source_members() -> dict[str, bytes]:
    contract.VERSION = "0.4.11"
    contract.REQUIRED = set(contract.REQUIRED) | {"webdavmanga/pdf_image_stream.lua"}
    contract.REQUIRED |= {"lib/kindlehf/" + name for name in
                          ("libarchive.so.13", "README.md", "THIRD_PARTY_NOTICES.txt", "COPYING-KOReader")}
    members: dict[str, bytes] = {}
    for path in PLUGIN.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink in plugin source: {path}")
        if path.is_file():
            name = path.relative_to(PLUGIN).as_posix()
            members[name] = path.read_bytes()
    if set(members) != contract.REQUIRED:
        raise ValueError(
            f"source inventory differs: missing={sorted(contract.REQUIRED - set(members))}; "
            f"extra={sorted(set(members) - contract.REQUIRED)}"
        )
    for name, body in members.items():
        if name == "lib/kindlehf/libarchive.so.13":
            if hashlib.sha256(body).hexdigest() != "5d31b914b567f44a24fd3fca9bd9b3b4aad74704bd7cf06eada6cc48269b8e47":
                raise ValueError("native decoder differs from the verified official binary")
        else:
            contract.validate_content(name, body)
    for name, pattern in (
        ("_meta.lua", rb'\bversion\s*=\s*"([^"]+)"'),
        ("main.lua", rb'\blocal\s+VERSION\s*=\s*"([^"]+)"'),
    ):
        if re.findall(pattern, members[name]) != [b"0.4.11"]:
            raise ValueError(f"{name} has an unexpected version")
    if "版本：0.4.11".encode() not in members["README.md"]:
        raise ValueError("README version does not match")
    if b"version 0.4.11" not in members["NOTICE"]:
        raise ValueError("NOTICE version does not match")
    return members


def build(path: Path, members: dict[str, bytes]) -> None:
    with ZipFile(path, "w") as archive:
        for name in sorted(members):
            info = ZipInfo("webdavmanga.koplugin/" + name, date_time=contract.FIXED_TIMESTAMP)
            info.create_system = 3
            info.external_attr = contract.PERMISSIONS
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, members[name], compress_type=ZIP_DEFLATED, compresslevel=9)


def inspect(path: Path, members: dict[str, bytes]) -> None:
    expected = ["webdavmanga.koplugin/" + name for name in sorted(members)]
    with ZipFile(path) as archive:
        if archive.namelist() != expected:
            raise ValueError("ZIP inventory or order differs from source")
        for info in archive.infolist():
            name = info.filename.removeprefix("webdavmanga.koplugin/")
            if (
                info.is_dir()
                or info.date_time != contract.FIXED_TIMESTAMP
                or info.external_attr != contract.PERMISSIONS
                or info.create_system != 3
                or info.compress_type != ZIP_DEFLATED
                or info.extra
                or info.comment
            ):
                raise ValueError(f"unexpected ZIP metadata: {name}")
            if archive.read(info) != members[name]:
                raise ValueError(f"ZIP content differs from source: {name}")


def main() -> None:
    destination = Path(sys.argv[1]) if len(sys.argv) == 2 else DESTINATION
    members = source_members()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="webdavmanga-package-", dir=destination.parent) as temporary:
        first = Path(temporary) / "first.zip"
        second = Path(temporary) / "second.zip"
        build(first, members)
        build(second, members)
        inspect(first, members)
        inspect(second, members)
        if first.read_bytes() != second.read_bytes():
            raise ValueError("two builds are not byte-identical")
        os.replace(first, destination)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest().upper()
    print(f"OK: {destination}")
    print(f"SHA256: {digest}")
    print(f"Members: {len(members)}")
    print("Source: filesystem snapshot; Git revision not verified")


if __name__ == "__main__":
    main()
