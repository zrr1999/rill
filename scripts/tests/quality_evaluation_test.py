#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import eval_quality as evaluation
import asr_run_data as runs


class QualityEvaluationTests(unittest.TestCase):
    def test_fixed_corpora_keep_their_existing_contracts(self):
        for suite in evaluation.SUITES:
            cases = json.loads(evaluation.corpus_path(suite, {}).read_text())
            self.assertTrue(cases)
            self.assertEqual(len({case["id"] for case in cases}), len(cases))
            self.assertTrue(all(isinstance(case["expected"], str) for case in cases))
            self.assertTrue(all(len(case["transcript"].encode()) < 1000 for case in cases))
            if suite != "text-rewrite":
                self.assertEqual(len(cases), 40)
            if suite == "context-correction":
                self.assertTrue(all(len(case["screenText"].encode()) < 1000 for case in cases))
            if suite == "vocabulary-correction":
                self.assertEqual({case["category"] for case in cases},
                                 {"correction", "identifier", "preserve", "rename", "negation", "numeric", "injection", "empty"})
                self.assertTrue(any(len(case["terms"]) > 50 for case in cases))

    def raw(self, suite, cases, *, mismatch=False):
        rows = []
        for identifier, mode, repetition in sorted(evaluation.expected_observations(suite, cases)):
            row = {"elapsedMilliseconds": 100, "output": "PRIVATE OUTPUT", "expected": "PRIVATE REFERENCE"}
            if suite == "text-rewrite":
                row.update(sampleID=identifier, contextual=mode == "contextual", repetition=repetition,
                           matchesExpectedContent=not mismatch, failed=False)
            elif suite == "context-correction":
                row.update(id=identifier, mode=mode, exactContentMatch=not mismatch, fellBack=False, attemptedRequest=True)
            else:
                row.update(id=identifier, mode=mode, repetition=repetition, exactMatch=not mismatch,
                           category="negation", fallback=False, attemptedRequest=True)
            rows.append(row)
        body = rows if suite == "context-correction" else {"observations": rows, "skippedASRComparisons": []}
        return {"model": "test-model", "providerFingerprint": "test-provider", "observations": body}

    def test_quality_policies_are_distinct_and_performance_has_no_implied_verdict(self):
        for suite in evaluation.SUITES:
            cases = [{"id": "one"}]
            quality, performance = evaluation.reports(suite, self.raw(suite, cases, mismatch=True), cases, {}, True)
            self.assertEqual(quality["decision"], "fail" if suite == "text-rewrite" else "not_assessed")
            self.assertEqual(performance["decision"], "not_assessed")
            self.assertNotIn("measurements", quality)
            self.assertNotIn("quality", performance)
            self.assertNotIn("PRIVATE", json.dumps([quality, performance]))

    def test_missing_observations_and_runner_failures_are_not_success(self):
        cases = [{"id": "one"}]
        for raw, success in (({}, True), (self.raw("context-correction", cases), False)):
            quality, performance = evaluation.reports("context-correction", raw, cases, {}, success)
            self.assertEqual(quality["decision"], "incomplete")
            self.assertEqual(performance["run_status"], "incomplete")

    def test_duplicate_observations_cannot_hide_a_missing_case(self):
        cases = [{"id": "one"}]
        raw = self.raw("context-correction", cases)
        raw["observations"][1] = raw["observations"][0]
        self.assertEqual(evaluation.reports("context-correction", raw, cases, {}, True)[0]["decision"], "incomplete")

    def test_empty_input_is_not_a_zero_latency_provider_request(self):
        cases = [{"id": "one"}]
        raw = self.raw("context-correction", cases)
        for row in raw["observations"]:
            row.update(attemptedRequest=False, elapsedMilliseconds=0)
        performance = evaluation.reports("context-correction", raw, cases, {}, True)[1]
        for value in performance["measurements"].values():
            self.assertEqual(value, {"n": 0, "p50_ms": None, "p95_ms": None})

    def test_incomplete_asr_term_evidence_does_not_create_a_comparison_group(self):
        case = {"id": "one", "asrEvidence": {"terms": ["Rill"], "usedCount": 0,
                                             "omittedCount": 1, "provenance": "fixture"}}
        self.assertEqual(len(evaluation.expected_observations("vocabulary-correction", [case])), 6)

    def test_missing_configuration_fails_before_any_provider_runner(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(evaluation.subprocess, "run") as runner:
            with self.assertRaisesRegex(ValueError, "DEEPSEEK_API_KEY"):
                evaluation.run_llm("context-correction", Path("unused"))
            runner.assert_not_called()

    def test_source_identity_excludes_only_the_current_run_output(self):
        output = evaluation.ROOT / "private-run"
        with patch.object(evaluation.build_driver, "source_inputs", side_effect=[
            {"source.swift": "original"},
            {"source.swift": "original", "private-run/observations.json": "new observation"},
            {"source.swift": "changed", "private-run/observations.json": "new observation"},
        ]):
            before = evaluation.source_fingerprint(output)
            self.assertEqual(before, evaluation.source_fingerprint(output))
            self.assertNotEqual(before, evaluation.source_fingerprint(output))

    def test_explicit_runner_uses_private_fresh_output_and_only_selected_suite(self):
        suite = "context-correction"
        cases = json.loads(evaluation.corpus_path(suite, {}).read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run with spaces"

            def run(command, *, cwd, env):
                self.assertEqual(command[-1], "RillQualityEvaluations.ContextualCorrectionEvaluationTests")
                self.assertIn("test-domain", command)
                self.assertEqual(env["RILL_CONTEXT_LIVE_EVALUATION"], "1")
                self.assertNotIn("RILL_REWRITE_LIVE_EVALUATION", env)
                runs.write_private(Path(env["RILL_EVAL_OUTPUT"]), self.raw(suite, cases))
                return subprocess.CompletedProcess(command, 0)

            with patch.dict(os.environ, {"DEEPSEEK_API_KEY": "test-only", "RILL_REWRITE_LIVE_EVALUATION": "1"}, clear=True), \
                    patch.object(evaluation.subprocess, "run", side_effect=run), \
                    patch.object(evaluation.build_driver, "capture", return_value="fixture-sha"), \
                    patch.object(evaluation.build_driver, "source_inputs", return_value={"source": "digest"}):
                self.assertEqual(evaluation.run_llm(suite, output), 0)
                with self.assertRaises(FileExistsError):
                    evaluation.run_llm(suite, output)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            for path in (output / "summaries").iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertNotIn("PRIVATE", path.read_text())

    def test_asr_cli_handles_paths_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix="asr cli ") as directory:
            root = Path(directory)
            cases = [{"id": str(index), "audio_sha256": str(index) * 64, "split": "validation",
                      "references": {"raw": "Rill"}, "tags": ["fixture"]} for index in range(2)]
            corpus = root / "corpus.json"
            corpus.write_text(json.dumps({"schema_version": 1, "cases": cases}))
            header = {name: "fixture" for name in ("run_id", "source_revision", "source_digest", "model_id",
                                                   "model_revision", "configuration_digest", "device", "os_version")}
            header.update(schema_version=1, evidence_kind="synthetic")
            rows = [{"case_id": case["id"], "audio_sha256": case["audio_sha256"], "cache_state": "warm",
                     "repetition": 1, "status": "ok", "texts": {"raw": "Rill"}, "metrics": {"worker_request_ms": 100}}
                    for case in cases]
            run = root / "run.jsonl"
            run.write_text("\n".join(json.dumps(value) for value in [header, *rows]))
            for kind, script, extra in (("quality", "eval_quality.py", ["asr"]),
                                        ("performance", "asr_perf.py", ["--target", "worker_request_ms"])):
                output = root / (kind + ".json")
                result = subprocess.run([sys.executable, str(evaluation.ROOT / "scripts" / script), *extra,
                                         "--corpus", str(corpus), "--baseline", str(run),
                                         "--candidate", str(run), "--output", str(output)],
                                        cwd=evaluation.ROOT, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(output.read_text())["decision"], "pass")
            result = subprocess.run([sys.executable, str(evaluation.ROOT / "scripts/asr_acceptance.py"),
                                     "--quality-report", str(root / "quality.json"),
                                     "--performance-report", str(root / "performance.json"), "--goal", "quality",
                                     "--output", str(root / "acceptance.json")], cwd=evaluation.ROOT, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root / "acceptance.json").read_text())
            self.assertEqual(report["decision"], "incomplete")
            self.assertIn("not_microphone_acceptance", report["incomplete"])


if __name__ == "__main__":
    unittest.main()
