#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("asr_benchmark", Path(__file__).parents[1] / "asr_benchmark.py")
ASR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASR)


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.cases = {
            f"case-{i}": {"split": "validation" if i < 40 else "development",
                          "references": {stage: "不要删除 Rill 2026" for stage in ASR.STAGES},
                          "tags": ["negative", "mixed"], "required_terms": ["不要", "2026"]}
            for i in range(120)
        }
        self.header = {key: "test" for key in (
            "run_id", "source_revision", "source_digest", "model_id", "model_revision",
            "configuration_digest", "device", "os_version")}
        self.header.update(schema_version=1, evidence_kind="microphone")
        self.rows = {
            (identifier, "warm", repetition): {
                "case_id": identifier, "cache_state": "warm", "repetition": repetition,
                "audio_sha256": f"{i:064x}", "status": "ok",
                "texts": {stage: "不要删除 Rill 2026" for stage in ASR.STAGES},
                "metrics": {metric: 100 for metric in ASR.METRICS}}
            for i, identifier in enumerate(self.cases) for repetition in (1, 2, 3)
        }

    def compare(self, rows=None, **kwargs):
        return ASR.compare(self.cases, (self.header, self.rows),
                           (self.header, self.rows if rows is None else rows), **kwargs)

    def test_quality_identity_is_eligible_but_not_a_performance_gain(self):
        self.assertEqual(self.compare()["decision"], "eligible")
        self.assertEqual(self.compare(purpose="performance")["decision"], "reject")
        improved = copy.deepcopy(self.rows)
        for row in improved.values():
            row["metrics"]["release_to_final_ms"] = 90
        self.assertEqual(self.compare(improved, purpose="performance")["decision"], "eligible")

    def test_negation_regression_cannot_be_hidden_by_other_correct_results(self):
        changed = copy.deepcopy(self.rows)
        changed["case-0", "warm", 1]["texts"]["final"] = "删除 Rill 2026"
        report = self.compare(changed)
        self.assertEqual(report["decision"], "reject")
        self.assertIn("case.case-0.final.critical_or_silence", report["regressions"])

    def test_worker_and_product_memory_scopes_cannot_be_compared(self):
        different = dict(self.header, memory_scope="worker_process_lifetime_peak_resident_bytes")
        with self.assertRaises(ValueError):
            ASR.compare(self.cases, (self.header, self.rows), (different, self.rows))

    def test_missing_measurement_is_unknown_not_zero(self):
        changed = copy.deepcopy(self.rows)
        del changed["case-0", "warm", 1]["metrics"]["peak_memory_bytes"]
        report = self.compare(changed)
        self.assertEqual(report["decision"], "incomplete")
        self.assertEqual(report["measurements"]["warm"]["peak_memory_bytes"]["candidate"]["n"], 119)

    def test_changed_audio_and_missing_repetition_cannot_be_paired(self):
        changed = copy.deepcopy(self.rows)
        changed["case-0", "warm", 1]["audio_sha256"] = "f" * 64
        with self.assertRaises(ValueError):
            self.compare(changed)
        del changed["case-0", "warm", 1]
        with self.assertRaises(ValueError):
            self.compare(changed)

    def test_failures_are_preserved_and_synthetic_is_not_microphone_acceptance(self):
        changed = copy.deepcopy(self.rows)
        changed["case-0", "warm", 1]["status"] = "failed"
        self.assertEqual(self.compare(changed)["decision"], "reject")
        self.header["evidence_kind"] = "synthetic"
        self.assertEqual(self.compare()["decision"], "incomplete")

    def test_zero_baseline_cannot_prove_improvement(self):
        for row in self.rows.values():
            row["metrics"]["release_to_final_ms"] = 0
        self.assertIn("warm.release_to_final_ms.zero_baseline",
                      self.compare(purpose="performance")["incomplete"])

    def test_report_excludes_text_and_unknown_header_fields_and_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            header = dict(self.header, unexpected_text="PRIVATE CANARY")
            path.write_text("\n".join(json.dumps(value) for value in [header, *self.rows.values()]))
            run = ASR.read_run(path, self.cases)
            report = ASR.compare(self.cases, run, run)
            ASR.write_private(path, report)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            content = path.read_text()
            self.assertNotIn("PRIVATE CANARY", content)
            self.assertNotIn("不要删除", content)

    def test_duplicate_repetitions_and_invalid_metrics_fail(self):
        row = next(iter(self.rows.values()))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            path.write_text("\n".join(json.dumps(x) for x in [self.header, row, row]))
            with self.assertRaises(ValueError):
                ASR.read_run(path, self.cases)
            row["metrics"]["peak_memory_bytes"] = -1
            path.write_text("\n".join(json.dumps(x) for x in [self.header, row]))
            with self.assertRaises(ValueError):
                ASR.read_run(path, self.cases)

    def test_exact_terms_and_silence(self):
        self.assertFalse(ASR.contains("20260", "2026"))
        self.assertFalse(ASR.contains("Rillish", "Rill"))
        self.assertTrue(ASR.contains("不要删除 Rill", "不要"))
        self.assertEqual(ASR.distance([], ASR.characters("嗯")), 1)
        self.assertEqual(ASR.percentiles([]), {"n": 0, "p50": None, "p95": None})


if __name__ == "__main__":
    unittest.main()
