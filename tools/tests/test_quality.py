import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from rill_dev.evaluation import quality as evaluation
from rill_dev.evaluation import run_data as runs


class QualityEvaluationTests(unittest.TestCase):
    def test_fixed_corpora_keep_their_existing_contracts(self):
        for suite in evaluation.SUITES:
            cases = json.loads(evaluation.corpus_path(suite, {}).read_text())
            self.assertTrue(cases)
            evaluation.validate_cases(cases)
            self.assertEqual(len({case["id"] for case in cases}), len(cases))
            self.assertTrue(all(isinstance(case["expected"], str) for case in cases))
            self.assertTrue(all(len(case["transcript"].encode()) < 1000 for case in cases))
            if suite != "text-rewrite":
                self.assertEqual(len(cases), 40)
            if suite == "context-correction":
                self.assertTrue(all(len(case["screenText"].encode()) < 1000 for case in cases))
            if suite == "vocabulary-correction":
                self.assertEqual(
                    {case["category"] for case in cases},
                    {
                        "correction",
                        "identifier",
                        "preserve",
                        "rename",
                        "negation",
                        "numeric",
                        "injection",
                        "empty",
                    },
                )
                self.assertTrue(any(len(case["terms"]) > 50 for case in cases))

    def raw(self, suite, cases, *, mismatch=False):
        rows = []
        for identifier, mode, repetition in sorted(evaluation.expected_observations(suite, cases)):
            row = {
                "elapsedMilliseconds": 100,
                "output": "PRIVATE OUTPUT",
                "expected": "PRIVATE REFERENCE",
            }
            if suite == "text-rewrite":
                row.update(
                    sampleID=identifier,
                    contextual=mode == "contextual",
                    repetition=repetition,
                    matchesExpectedContent=not mismatch,
                    failed=False,
                )
            elif suite == "context-correction":
                row.update(
                    id=identifier,
                    mode=mode,
                    exactContentMatch=not mismatch,
                    fellBack=False,
                    attemptedRequest=True,
                )
            else:
                row.update(
                    id=identifier,
                    mode=mode,
                    repetition=repetition,
                    exactMatch=not mismatch,
                    category="negation",
                    fallback=False,
                    attemptedRequest=True,
                )
            rows.append(row)
        body = (
            rows
            if suite == "context-correction"
            else {"observations": rows, "skippedASRComparisons": []}
        )
        return {"model": "test-model", "providerFingerprint": "test-provider", "observations": body}

    def test_quality_policies_are_distinct_and_performance_has_no_implied_verdict(self):
        for suite in evaluation.SUITES:
            cases = [{"id": "one"}]
            quality, performance = evaluation.reports(
                suite, self.raw(suite, cases, mismatch=True), cases, {}, True
            )
            self.assertEqual(
                quality["decision"], "fail" if suite == "text-rewrite" else "not_assessed"
            )
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
        self.assertEqual(
            evaluation.reports("context-correction", raw, cases, {}, True)[0]["decision"],
            "incomplete",
        )

    def test_empty_input_is_not_a_zero_latency_provider_request(self):
        cases = [{"id": "one"}]
        raw = self.raw("context-correction", cases)
        for row in raw["observations"]:
            row.update(attemptedRequest=False, elapsedMilliseconds=0)
        performance = evaluation.reports("context-correction", raw, cases, {}, True)[1]
        for value in performance["measurements"].values():
            self.assertEqual(value, {"n": 0, "p50_ms": None, "p95_ms": None})

    def test_incomplete_asr_term_evidence_does_not_create_a_comparison_group(self):
        case = {
            "id": "one",
            "asrEvidence": {
                "terms": ["Rill"],
                "usedCount": 0,
                "omittedCount": 1,
                "provenance": "fixture",
            },
        }
        self.assertEqual(len(evaluation.expected_observations("vocabulary-correction", [case])), 6)

    def test_category_counts_expose_paired_improvements_and_regressions(self):
        cases = [
            {"id": name, "category": category}
            for name, category in (
                ("gain", "identifier"),
                ("loss", "negation"),
                ("both", "negation"),
                ("neither", "units"),
            )
        ]
        raw = self.raw("context-correction", cases)
        outcomes = {
            "gain": (False, True),
            "loss": (True, False),
            "both": (True, True),
            "neither": (False, False),
        }
        for row in raw["observations"]:
            row["category"] = "PRIVATE RAW CATEGORY"
            row["exactContentMatch"] = outcomes[row["id"]][row["mode"] == "references"]
        report = evaluation.reports("context-correction", raw, cases, {}, True)[0]
        self.assertEqual(report["decision"], "not_assessed")
        self.assertEqual(
            report["paired_comparisons"],
            [
                {
                    "baseline_mode": "text",
                    "candidate_mode": "references",
                    "expected_pairs": 4,
                    "paired": 4,
                    "improved": 1,
                    "regressed": 1,
                    "both_matched": 1,
                    "neither_matched": 1,
                    "unrequested_pairs": 0,
                    "incomplete_pairs": 0,
                }
            ],
        )
        self.assertEqual(
            report["quality"]["text"]["exact_matches"],
            report["quality"]["references"]["exact_matches"],
        )
        self.assertEqual(
            report["quality_by_category"]["references"]["negation"]["exact_matches"], 1
        )
        raw["observations"].reverse()
        self.assertEqual(evaluation.reports("context-correction", raw, cases, {}, True)[0], report)

    def test_pairing_never_borrows_another_repetition(self):
        cases = [{"id": "one", "category": "identifier"}]
        raw = self.raw("text-rewrite", cases)
        for row in raw["observations"]["observations"]:
            row["matchesExpectedContent"] = (
                (row["repetition"] == 1) != row["contextual"] if row["repetition"] < 3 else True
            )
        paired = evaluation.reports("text-rewrite", raw, cases, {}, True)[0]["paired_comparisons"][
            0
        ]
        self.assertEqual(
            (paired["paired"], paired["improved"], paired["regressed"], paired["both_matched"]),
            (3, 1, 1, 1),
        )

    def test_missing_duplicate_and_unknown_coordinates_are_not_scored(self):
        cases = [{"id": "one", "category": "negation"}]
        for change in ("missing", "duplicate", "unknown"):
            with self.subTest(change=change):
                raw = self.raw("context-correction", cases)
                if change == "missing":
                    raw["observations"].pop()
                elif change == "duplicate":
                    raw["observations"].append(
                        dict(raw["observations"][0], exactContentMatch=False)
                    )
                else:
                    raw["observations"].append(
                        dict(raw["observations"][0], id="PRIVATE ID", mode="PRIVATE MODE")
                    )
                quality, performance = evaluation.reports(
                    "context-correction", raw, cases, {}, True
                )
                self.assertEqual(quality["decision"], "incomplete")
                self.assertEqual(set(quality["quality"]), {"text", "references"})
                self.assertNotIn("PRIVATE", json.dumps([quality, performance]))
                self.assertEqual(
                    quality["paired_comparisons"][0]["incomplete_pairs"], change != "unknown"
                )
                if change == "duplicate":
                    mode = raw["observations"][0]["mode"]
                    self.assertEqual(quality["quality"][mode]["n"], 0)
                    self.assertEqual(performance["measurements"][mode]["n"], 0)

    def test_duplicate_coordinates_do_not_erase_observed_request_failure(self):
        cases = [{"id": "one", "category": "negation"}]
        raw = self.raw("context-correction", cases)
        raw["observations"].append(dict(raw["observations"][0], failed=True))
        quality, performance = evaluation.reports("context-correction", raw, cases, {}, True)
        self.assertEqual(quality["decision"], "fail")
        self.assertEqual(quality["run_status"], "incomplete")
        mode = raw["observations"][0]["mode"]
        self.assertEqual(quality["quality"][mode]["n"], 0)
        self.assertEqual(performance["measurements"][mode]["n"], 0)
        self.assertEqual(quality["paired_comparisons"][0]["incomplete_pairs"], 1)

    def test_rewrite_mode_cannot_replace_a_missing_or_invalid_contextual_flag(self):
        cases = [{"id": "one"}]
        for invalid in (None, "false", 0):
            with self.subTest(contextual=invalid):
                raw = self.raw("text-rewrite", cases)
                for row in raw["observations"]["observations"]:
                    row["mode"] = "contextual" if row.pop("contextual") else "ordinary"
                    if invalid is not None:
                        row["contextual"] = invalid
                quality, performance = evaluation.reports("text-rewrite", raw, cases, {}, True)
                self.assertEqual(quality["decision"], "incomplete")
                self.assertEqual(quality["paired_comparisons"][0]["paired"], 0)
                self.assertTrue(
                    all(value["n"] == 0 for value in performance["measurements"].values())
                )

    def test_unrequested_and_asymmetric_requests_have_no_implied_gain(self):
        cases = [{"id": "one", "category": "empty"}]
        raw = self.raw("context-correction", cases)
        for row in raw["observations"]:
            row.update(attemptedRequest=False, elapsedMilliseconds=0)
        report = evaluation.reports("context-correction", raw, cases, {}, True)[0]
        self.assertEqual(report["paired_comparisons"][0]["unrequested_pairs"], 1)
        self.assertEqual(report["paired_comparisons"][0]["paired"], 0)
        raw["observations"][0]["attemptedRequest"] = True
        report = evaluation.reports("context-correction", raw, cases, {}, True)[0]
        self.assertEqual(report["decision"], "incomplete")
        self.assertEqual(report["paired_comparisons"][0]["incomplete_pairs"], 1)

    def test_failed_requests_cannot_match_and_runner_failure_remains_incomplete(self):
        cases = [{"id": "one", "category": "negation"}]
        for suite in evaluation.SUITES:
            with self.subTest(suite=suite):
                raw = self.raw(suite, cases)
                rows = (
                    raw["observations"]
                    if suite == "context-correction"
                    else raw["observations"]["observations"]
                )
                rows[0]["failed"] = True
                quality, performance = evaluation.reports(suite, raw, cases, {}, False)
                self.assertEqual(quality["decision"], "fail")
                self.assertEqual(quality["run_status"], "incomplete")
                self.assertEqual(performance["run_status"], "incomplete")
                self.assertIn("runner_failed", quality["incomplete"])
                self.assertEqual(sum(value["failures"] for value in quality["quality"].values()), 1)
                self.assertEqual(
                    sum(
                        value["n"] - value["exact_matches"] for value in quality["quality"].values()
                    ),
                    1,
                )

    def test_python_independently_checks_exact_protected_literals(self):
        cases = [
            {
                "id": "one",
                "category": "identifier",
                "transcript": "café.txt user_id",
                "expected": "café.txt user_id",
                "protected_literals": ["café.txt", "user_id"],
            }
        ]
        for output in (
            "cafe\u0301.txt user_id",
            "café.txt userid",
            "café.txt USER_ID",
            "café.txt user_id user_id",
            None,
        ):
            with self.subTest(output=output):
                raw = self.raw("text-rewrite", cases)
                for row in raw["observations"]["observations"]:
                    row["output"] = output
                quality = evaluation.reports("text-rewrite", raw, cases, {}, True)[0]
                self.assertEqual(quality["decision"], "fail")
                self.assertTrue(
                    all(value["exact_matches"] == 0 for value in quality["quality"].values())
                )
        raw = self.raw("text-rewrite", cases)
        for row in raw["observations"]["observations"]:
            row["output"] = "café.txt user_id"
        self.assertEqual(
            evaluation.reports("text-rewrite", raw, cases, {}, True)[0]["decision"], "pass"
        )

    def test_invalid_literal_contract_fails_before_provider_runner(self):
        case = {"id": "one", "transcript": "café.txt", "expected": "café.txt"}
        for literals in (
            [""],
            ["missing"],
            ["café.txt", "café.txt"],
            "café.txt",
            ["cafe\u0301.txt"],
        ):
            with self.subTest(literals=literals), self.assertRaises(ValueError):
                evaluation.validate_cases([dict(case, protected_literals=literals)])

    def test_asr_pairs_and_skipped_count_come_from_complete_corpus_evidence(self):
        evidence = {"terms": ["Rill"], "usedCount": 1, "omittedCount": 0, "provenance": "fixture"}
        cases = [
            {"id": "complete", "category": "correction", "asrEvidence": evidence},
            {"id": "incomplete", "category": "correction"},
        ]
        raw = self.raw("vocabulary-correction", cases)
        raw["observations"]["skippedASRComparisons"] = ["PRIVATE ID", "PRIVATE BODY"]
        report = evaluation.reports("vocabulary-correction", raw, cases, {}, True)[0]
        self.assertEqual(report["skipped_asr_comparison_count"], 1)
        self.assertNotIn("skipped_asr_comparisons", report)
        self.assertEqual([pair["expected_pairs"] for pair in report["paired_comparisons"]], [6, 3])
        self.assertNotIn("PRIVATE", json.dumps(report))

    def test_new_summaries_do_not_echo_private_corpus_or_observation_fields(self):
        cases = [
            {
                "id": "PRIVATE_ID",
                "category": "PRIVATE_CATEGORY",
                "transcript": "PRIVATE_LITERAL",
                "expected": "PRIVATE_LITERAL",
                "protected_literals": ["PRIVATE_LITERAL"],
            }
        ]
        for suite in evaluation.SUITES:
            raw = self.raw(suite, cases)
            rows = (
                raw["observations"]
                if suite == "context-correction"
                else raw["observations"]["observations"]
            )
            for row in rows:
                row.update(output="PRIVATE_LITERAL", category="PRIVATE_RAW_CATEGORY")
            rows.append(
                dict(
                    rows[0],
                    id="PRIVATE_UNKNOWN_ID",
                    sampleID="PRIVATE_UNKNOWN_ID",
                    mode="PRIVATE_MODE",
                )
            )
            quality, performance = evaluation.reports(suite, raw, cases, {}, True)
            self.assertNotIn("PRIVATE", json.dumps([quality, performance]))
            self.assertTrue(
                all(
                    set(categories) <= {"other"}
                    for categories in quality["quality_by_category"].values()
                )
            )

    def test_missing_configuration_fails_before_any_provider_runner(self):
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(evaluation.subprocess, "run") as runner,
        ):
            with self.assertRaisesRegex(ValueError, "DEEPSEEK_API_KEY"):
                evaluation.run_llm("context-correction", Path("unused"))
            runner.assert_not_called()

    def test_source_identity_excludes_only_the_current_run_output(self):
        output = evaluation.ROOT / "private-run"
        with patch.object(
            evaluation.repository,
            "source_inputs",
            side_effect=[
                {"source.swift": "original"},
                {"source.swift": "original", "private-run/observations.json": "new observation"},
                {"source.swift": "changed", "private-run/observations.json": "new observation"},
            ],
        ):
            before = evaluation.source_fingerprint(output)
            self.assertEqual(before, evaluation.source_fingerprint(output))
            self.assertNotEqual(before, evaluation.source_fingerprint(output))

    def test_explicit_runner_uses_private_fresh_output_and_only_selected_suite(self):
        suite = "context-correction"
        cases = json.loads(evaluation.corpus_path(suite, {}).read_text())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run with spaces"

            def run(command, *, cwd, env):
                self.assertEqual(
                    command[-1], "RillQualityEvaluations.ContextualCorrectionEvaluationTests"
                )
                self.assertIn("test-domain", command)
                self.assertEqual(env["RILL_CONTEXT_LIVE_EVALUATION"], "1")
                self.assertNotIn("RILL_REWRITE_LIVE_EVALUATION", env)
                runs.write_private(Path(env["RILL_EVAL_OUTPUT"]), self.raw(suite, cases))
                return subprocess.CompletedProcess(command, 0)

            with (
                patch.dict(
                    os.environ,
                    {"DEEPSEEK_API_KEY": "test-only", "RILL_REWRITE_LIVE_EVALUATION": "1"},
                    clear=True,
                ),
                patch.object(evaluation.subprocess, "run", side_effect=run),
                patch.object(evaluation.repository, "revision", return_value="fixture-sha"),
                patch.object(
                    evaluation.repository, "source_inputs", return_value={"source": "digest"}
                ),
            ):
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
            cases = [
                {
                    "id": str(index),
                    "audio_sha256": str(index) * 64,
                    "split": "validation",
                    "references": {"raw": "Rill"},
                    "tags": ["fixture"],
                }
                for index in range(2)
            ]
            corpus = root / "corpus.json"
            corpus.write_text(json.dumps({"schema_version": 1, "cases": cases}))
            header = {
                name: "fixture"
                for name in (
                    "run_id",
                    "source_revision",
                    "source_digest",
                    "model_id",
                    "model_revision",
                    "configuration_digest",
                    "device",
                    "os_version",
                )
            }
            header.update(schema_version=1, evidence_kind="synthetic")
            rows = [
                {
                    "case_id": case["id"],
                    "audio_sha256": case["audio_sha256"],
                    "cache_state": "warm",
                    "repetition": 1,
                    "status": "ok",
                    "texts": {"raw": "Rill"},
                    "metrics": {"worker_request_ms": 100},
                }
                for case in cases
            ]
            run = root / "run.jsonl"
            run.write_text("\n".join(json.dumps(value) for value in [header, *rows]))
            for kind, script, extra in (
                ("quality", "rill-eval-quality", ["asr"]),
                ("performance", "rill-bench-asr", ["--target", "worker_request_ms"]),
            ):
                output = root / (kind + ".json")
                result = subprocess.run(
                    [
                        str(Path(sys.executable).parent / script),
                        *extra,
                        "--corpus",
                        str(corpus),
                        "--baseline",
                        str(run),
                        "--candidate",
                        str(run),
                        "--output",
                        str(output),
                    ],
                    cwd=root,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(output.read_text())["decision"], "pass")
            result = subprocess.run(
                [
                    str(Path(sys.executable).parent / "rill-accept-asr"),
                    "--quality-report",
                    str(root / "quality.json"),
                    "--performance-report",
                    str(root / "performance.json"),
                    "--goal",
                    "quality",
                    "--output",
                    str(root / "acceptance.json"),
                ],
                cwd=root,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root / "acceptance.json").read_text())
            self.assertEqual(report["decision"], "incomplete")
            self.assertIn("not_microphone_acceptance", report["incomplete"])
