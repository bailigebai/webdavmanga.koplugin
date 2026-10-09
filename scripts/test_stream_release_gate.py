"""The release gate must reject missing, incomplete and stale native checks."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import stream_formats_contract as gate


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plugin = Path(self.temp.name)
        (self.plugin / "_meta.lua").write_bytes(b'return { version = "0.4.19" }')
        self.report = {
            "schema": 1, "passed": True, "version": "0.4.19",
            "runtime_sha256": gate.runtime_fingerprint(self.plugin),
            "contract_sha256": gate.contract_fingerprint(),
            "environment": {"architecture": "arm32", "koreader_runtime_sha256": "c" * 64,
                            "native_libraries": {"archive": "a" * 64, "lfs": "b" * 64}},
            "cases": [{"label": label, "kind": gate.CASE_KINDS[label], "source_sha256": f"{i:064x}",
                       "page_count": 21, "full_file_requests": 0,
                       "rounds": {mode: {"positions": list(range(1, 22)), "decoded_images": 21}
                                  for mode in (("cold", "warm", "legacy") if label == "epub" else ("cold", "warm"))}}
                      for i, label in enumerate(gate.REQUIRED_CASES)],
        }

    def test_complete_report_accepts_exact_runtime(self):
        gate.validate_report(self.report, self.plugin)

    def test_rejects_missing_fixture_and_failed_decode(self):
        for alter in (lambda r: r["cases"].pop(),
                      lambda r: r["cases"][0]["rounds"]["cold"].update(decoded_images=0),
                      lambda r: r["cases"][0].update(full_file_requests=1),
                      lambda r: r["cases"][0].update(kind="epub"),
                      lambda r: r["cases"][0].update(source_sha256="invalid"),
                      lambda r: r["cases"][0].update(source_sha256=r["cases"][1]["source_sha256"]),
                      lambda r: r["cases"][0]["rounds"].pop("warm"),
                      lambda r: r["cases"][2]["rounds"].pop("legacy")):
            report = copy.deepcopy(self.report)
            alter(report)
            with self.assertRaises(ValueError):
                gate.validate_report(report, self.plugin)

    def test_rejects_runtime_or_contract_changed_since_test(self):
        (self.plugin / "page.lua").write_bytes(b"return false")
        with self.assertRaises(ValueError):
            gate.validate_report(self.report, self.plugin)
        report = copy.deepcopy(self.report)
        report["runtime_sha256"] = gate.runtime_fingerprint(self.plugin)
        report["contract_sha256"] = "stale"
        with self.assertRaises(ValueError):
            gate.validate_report(report, self.plugin)

    def test_failed_preflight_invalidates_previous_success(self):
        path = self.plugin / "old-report.json"
        path.write_bytes(json.dumps(self.report).encode())
        command = [sys.executable, str(gate.ROOT / "scripts/run_stream_formats.py"),
                   "--samples", str(self.plugin), "--runtime-root", str(self.plugin),
                   "--device-libs", str(self.plugin), "--report", str(path)]
        failed = subprocess.run(command, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"FileNotFoundError", failed.stderr)
        self.assertIs(json.loads(path.read_bytes())["passed"], False)
        with self.assertRaises(ValueError):
            gate.validate_report(json.loads(path.read_bytes()), self.plugin)

    def test_missing_image_dependency_also_invalidates_success(self):
        path = self.plugin / "dependency-report.json"
        path.write_bytes(json.dumps(self.report).encode())
        command = [sys.executable, "-S", str(gate.ROOT / "scripts/run_stream_formats.py"),
                   "--samples", str(self.plugin), "--runtime-root", str(self.plugin),
                   "--device-libs", str(self.plugin), "--report", str(path)]
        failed = subprocess.run(command, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"ModuleNotFoundError", failed.stderr)
        self.assertIs(json.loads(path.read_bytes())["passed"], False)


if __name__ == "__main__":
    unittest.main()
