#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import asr_benchmark
import product_path_benchmark as host


class HostEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "run.jsonl"
        self.header = {key: "fixture" for key in (
            "run_id", "source_revision", "source_digest", "model_id", "model_revision",
            "configuration_digest", "device", "os_version")}
        self.header.update(schema_version=1, evidence_kind="synthetic",
                           measurement_scope="host_replay_isolated_output", evidence_validation="pending")
        self.cases = {"one": {"audio_sha256": "0" * 64, "references": {"raw": ""}, "tags": ["silence"], "split": "validation"}}
        self.row = {"case_id": "one", "cache_state": "warm", "repetition": 1,
                    "audio_sha256": "0" * 64, "status": "ok", "texts": {"raw": ""}, "metrics": {}}

    def write(self):
        host.create_report(self.path, self.header)
        with self.path.open("a") as output:
            output.write(json.dumps(self.row) + "\n")

    def test_pending_invalid_and_warmup_are_not_comparable(self):
        self.write()
        for state in ("pending", "invalid"):
            host.validate_report_identity(self.path, state)
            with self.assertRaisesRegex(ValueError, "not validated"):
                asr_benchmark.read_run(self.path, self.cases)
        self.path.unlink()
        self.header.update(evidence_validation="passed", analysis_role="warmup")
        self.write()
        with self.assertRaisesRegex(ValueError, "cannot be scored"):
            asr_benchmark.read_run(self.path, self.cases)

    def test_validation_preserves_rows_and_private_permissions(self):
        self.write()
        original_rows = self.path.read_text().splitlines()[1:]
        self.assertEqual(host.finish_reports([self.path], self.cases, "warm", 1), 0)
        self.assertEqual(self.path.read_text().splitlines()[1:], original_rows)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            host.create_report(self.path, self.header)

    def test_failed_recognition_is_nonzero_without_inventing_silence(self):
        self.row.update(status="failed", texts={})
        self.write()
        self.assertEqual(host.finish_reports([self.path], self.cases, "warm", 1), 2)
        _, rows = asr_benchmark.read_run(self.path, self.cases)
        self.assertEqual(rows["one", "warm", 1]["texts"], {})

    def test_wrong_cache_state_invalidates_even_when_row_count_matches(self):
        self.write()
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            host.finish_reports([self.path], self.cases, "first_inference", 1)
        self.assertEqual(json.loads(self.path.read_text().splitlines()[0])["evidence_validation"], "invalid")


if __name__ == "__main__":
    unittest.main()
