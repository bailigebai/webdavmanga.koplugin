"""Bind local, original-file stream verification to the runtime being packaged."""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CASES = ("rar-big", "rar-small", "epub", "pdf", "zip", "7z", "azw3")
CASE_KINDS = {label: ("rar" if label.startswith("rar-") else label) for label in REQUIRED_CASES}


def digest_files(files):
    digest = hashlib.sha256()
    for name, body in sorted(files):
        digest.update(name.encode() + b"\0" + hashlib.sha256(body).digest())
    return digest.hexdigest()


def runtime_members_fingerprint(members: dict[str, bytes]) -> str:
    return digest_files((name, body) for name, body in members.items()
                        if Path(name).suffix == ".lua" or ".so" in Path(name).name)


def runtime_fingerprint(plugin: Path) -> str:
    return runtime_members_fingerprint({p.relative_to(plugin).as_posix(): p.read_bytes()
                                       for p in plugin.rglob("*") if p.is_file()})


def contract_fingerprint() -> str:
    return digest_files((name, (ROOT / name).read_bytes()) for name in (
        "scripts/stream_formats_contract.py", "scripts/run_stream_formats.py",
        "spec/contracts/stream_formats_contract.lua"))


def version(plugin: Path) -> str:
    match = re.search(rb'\bversion\s*=\s*"([^"]+)"', (plugin / "_meta.lua").read_bytes())
    if not match:
        raise ValueError("Missing plugin version")
    return match.group(1).decode()


def validate_report(report: dict, plugin: Path) -> None:
    if (report.get("schema") != 1 or report.get("passed") is not True or
            report.get("version") != version(plugin) or
            report.get("runtime_sha256") != runtime_fingerprint(plugin) or
            report.get("contract_sha256") != contract_fingerprint()):
        raise ValueError("Stream report is failed or stale; rerun scripts/run_stream_formats.py")
    environment = report.get("environment", {})
    libraries = environment.get("native_libraries", {})
    if (environment.get("architecture") != "arm32" or
            not re.fullmatch(r"[0-9a-f]{64}", environment.get("koreader_runtime_sha256", "")) or
            any(not re.fullmatch(r"[0-9a-f]{64}", libraries.get(name, ""))
                for name in ("archive", "lfs"))):
        raise ValueError("Stream report lacks ARM native provenance")
    cases = report.get("cases", [])
    if len(cases) != len(REQUIRED_CASES) or {c.get("label") for c in cases} != set(REQUIRED_CASES):
        raise ValueError("All seven original samples are required")
    if len({c.get("source_sha256") for c in cases}) != len(REQUIRED_CASES):
        raise ValueError("Seven distinct original samples are required")
    for case in cases:
        if (case.get("kind") != CASE_KINDS[case["label"]] or
                not re.fullmatch(r"[0-9a-f]{64}", case.get("source_sha256", ""))):
            raise ValueError("Invalid original format/identity: " + case["label"])
        count = case.get("page_count", 0)
        if not isinstance(count, int) or count < 1 or case.get("full_file_requests") != 0:
            raise ValueError("Stream verification failed: " + case["label"])
        expected = set(range(1, min(20, count) + 1)) | {count}
        shelf = case.get("bookshelf", {})
        if (shelf.get("decoded_images") != 1 or shelf.get("warm_range_requests") != 0
                or shelf.get("first_page_matches_reading") is not True):
            raise ValueError("Missing persisted readable bookshelf cover: " + case["label"])
        required = ("cold", "warm", "legacy") if case["label"] == "epub" else ("cold", "warm")
        for mode in required:
            result = case.get("rounds", {}).get(mode, {})
            if (set(result.get("positions", [])) != expected or
                    len(result.get("positions", [])) != len(expected) or
                    result.get("decoded_images") != len(expected)):
                raise ValueError("Missing readable pages: " + case["label"] + "/" + mode)
