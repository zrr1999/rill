#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import copy
import sys
import json
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import asr_eval as ASR
import asr_run_data as RUNS
import asr_perf as PERF
import asr_acceptance as ACCEPT


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.cases = {
            f"case-{i}": {"audio_sha256": f"{i:064x}", "split": "validation" if i < 40 else "development",
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
                "metrics": {metric: 100 for metric in RUNS.METRICS}}
            for i, identifier in enumerate(self.cases) for repetition in (1, 2, 3)
        }

    def test_unannotated_export_can_replay_but_cannot_claim_quality(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "corpus.json"
            path.write_text(json.dumps({"schema_version": 1, "cases": [{
                "id": "one", "split": "validation", "tags": ["unreviewed"], "references": {}}]}))
            self.assertEqual(RUNS.read_corpus(path, require_references=False)["one"]["references"], {})
            with self.assertRaisesRegex(ValueError, "missing is not silence"):
                RUNS.read_corpus(path, require_references=True)

    def compare(self, rows=None, **kwargs):
        return ASR.compare(self.cases, (self.header, self.rows),
                           (self.header, self.rows if rows is None else rows), **kwargs)

    def reports(self, rows=None):
        baseline = (self.header, self.rows)
        candidate = (self.header, self.rows if rows is None else rows)
        return self.compare(rows), PERF.compare(self.cases, baseline, candidate, "release_to_final_ms")

    def test_equal_performance_passes_but_does_not_prove_improvement(self):
        quality, performance = self.reports()
        self.assertEqual(quality["decision"], "pass")
        self.assertEqual(performance["decision"], "pass")
        self.assertEqual(ACCEPT.assess(quality, performance, "quality")["decision"], "pass")
        self.assertEqual(ACCEPT.assess(quality, performance, "performance")["decision"], "fail")
        improved = copy.deepcopy(self.rows)
        for row in improved.values():
            row["metrics"]["release_to_final_ms"] = 90
        self.assertEqual(ACCEPT.assess(*self.reports(improved), "performance")["decision"], "pass")

    def test_quality_does_not_require_performance_or_product_acceptance_corpus(self):
        self.header["evidence_kind"] = "synthetic"
        self.cases = {key: value for key, value in self.cases.items() if key in {"case-0", "case-1"}}
        self.rows = {key: value for key, value in self.rows.items() if key[0] in self.cases and key[2] == 1}
        for row in self.rows.values():
            row["metrics"] = {}
        self.assertEqual(self.compare()["decision"], "pass")
        self.assertNotIn("measurements", self.compare())

    def test_performance_without_references_and_quality_regression_are_independent(self):
        changed = copy.deepcopy(self.rows)
        for row in changed.values():
            row["metrics"]["release_to_final_ms"] = 80
        changed["case-0", "warm", 1]["texts"]["final"] = "删除 Rill 2026"
        quality, performance = self.reports(changed)
        self.assertEqual(quality["decision"], "fail")
        self.assertEqual(performance["decision"], "pass")
        self.assertEqual(ACCEPT.assess(quality, performance, "performance")["decision"], "fail")
        for case in self.cases.values():
            case["references"] = {}
        self.assertEqual(PERF.compare(self.cases, (self.header, self.rows),
                                     (self.header, changed), "release_to_final_ms")["decision"], "pass")
        with self.assertRaisesRegex(ValueError, "reference"):
            self.compare(changed)

    def test_negation_regression_cannot_be_hidden_by_other_correct_results(self):
        changed = copy.deepcopy(self.rows)
        changed["case-0", "warm", 1]["texts"]["final"] = "删除 Rill 2026"
        report = self.compare(changed)
        self.assertEqual(report["decision"], "fail")
        self.assertIn("case.case-0.final.critical_or_silence", report["regressions"])

    def test_worker_and_product_memory_scopes_cannot_be_compared(self):
        different = dict(self.header, memory_scope="worker_process_lifetime_peak_resident_bytes")
        with self.assertRaises(ValueError):
            PERF.compare(self.cases, (self.header, self.rows), (different, self.rows), "release_to_final_ms")

    def test_missing_measurement_is_unknown_not_zero(self):
        changed = copy.deepcopy(self.rows)
        del changed["case-0", "warm", 1]["metrics"]["peak_memory_bytes"]
        quality, report = self.reports(changed)
        self.assertEqual(report["decision"], "pass")
        self.assertEqual(quality["decision"], "pass")
        self.assertEqual(ACCEPT.assess(quality, report, "quality")["decision"], "incomplete")
        self.assertEqual(report["measurements"]["warm"]["peak_memory_bytes"]["candidate"]["n"], 119)

    def test_memory_only_comparison_cannot_satisfy_experiment_admission(self):
        for row in self.rows.values():
            row["metrics"] = {"peak_memory_bytes": 100}
        run = self.header, self.rows
        performance = PERF.compare(self.cases, run, run, "peak_memory_bytes")
        self.assertEqual(performance["decision"], "pass")
        report = ACCEPT.assess(self.compare(), performance, "quality")
        self.assertEqual(report["decision"], "incomplete")
        self.assertIn("latency_target_required", report["incomplete"])

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
        self.assertEqual(self.compare(changed)["decision"], "fail")
        self.header["evidence_kind"] = "synthetic"
        self.assertEqual(self.compare()["decision"], "pass")
        self.assertEqual(ACCEPT.assess(*self.reports(), "quality")["decision"], "incomplete")

    def test_zero_baseline_cannot_prove_improvement(self):
        for row in self.rows.values():
            row["metrics"]["release_to_final_ms"] = 0
        self.assertIn("warm.release_to_final_ms.zero_baseline",
                      ACCEPT.assess(*self.reports(), "performance")["incomplete"])

    def test_report_excludes_text_and_unknown_header_fields_and_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            header = dict(self.header, unexpected_text="PRIVATE CANARY")
            path.write_text("\n".join(json.dumps(value) for value in [header, *self.rows.values()]))
            run = RUNS.read_run(path, self.cases)
            report = ASR.compare(self.cases, run, run)
            RUNS.write_private(path, report)
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
                RUNS.read_run(path, self.cases)
            row["metrics"]["peak_memory_bytes"] = -1
            path.write_text("\n".join(json.dumps(x) for x in [self.header, row]))
            with self.assertRaises(ValueError):
                RUNS.read_run(path, self.cases)

    def test_stale_results_cannot_use_new_audio_and_references(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            path.write_text("\n".join(json.dumps(value) for value in [self.header, *self.rows.values()]))
            self.cases["case-0"]["audio_sha256"] = "f" * 64
            with self.assertRaisesRegex(ValueError, "current corpus"):
                RUNS.read_run(path, self.cases)
            with self.assertRaisesRegex(ValueError, "current corpus"):
                self.compare()

    def test_acceptance_rejects_reports_from_different_runs_or_corpora(self):
        quality, performance = self.reports()
        for field in ("candidate_run_sha256", "corpus_sha256", "split"):
            different = copy.deepcopy(performance)
            different[field] = "different"
            with self.assertRaisesRegex(ValueError, "different evidence"):
                ACCEPT.assess(quality, different, "quality")

    def test_a_cache_state_cannot_silently_omit_cases(self):
        for key, row in list(self.rows.items()):
            if key[0] == "case-0":
                self.rows[(key[0], "first_inference", key[2])] = dict(row, cache_state="first_inference")
        quality, performance = self.reports()
        self.assertIn("missing_cases", quality["incomplete"])
        self.assertIn("missing_cases", performance["incomplete"])

    def test_missing_target_and_time_origin_mismatch_are_explicit(self):
        changed = copy.deepcopy(self.rows)
        del changed["case-0", "warm", 1]["metrics"]["release_to_final_ms"]
        self.assertEqual(self.reports(changed)[1]["decision"], "incomplete")
        header = dict(self.header, preview_time_origin="different")
        with self.assertRaisesRegex(ValueError, "preview_time_origin"):
            PERF.compare(self.cases, (self.header, self.rows), (header, self.rows), "first_preview_ms")

    def test_exact_terms_and_silence(self):
        self.assertFalse(ASR.contains("20260", "2026"))
        self.assertFalse(ASR.contains("Rillish", "Rill"))
        self.assertTrue(ASR.contains("不要删除 Rill", "不要"))
        self.assertEqual(ASR.distance([], ASR.characters("嗯")), 1)
        self.assertEqual(RUNS.percentiles([]), {"n": 0, "p50": None, "p95": None})


if __name__ == "__main__":
    unittest.main()
