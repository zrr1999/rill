#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run one explicit quality evaluation; ASR compares local runs, LLM suites call real providers."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import uuid

import asr_eval
import asr_run_data as runs
import build_driver

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "text-rewrite": ("TextRewrite", "TextRewriteEvaluationTests", "RILL_REWRITE_LIVE_EVALUATION",
                     ("OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_MODEL")),
    "vocabulary-correction": ("VocabularyCorrection", "VocabularyCorrectionEvaluationTests",
                              "RILL_VOCABULARY_LIVE_EVALUATION", ("DEEPSEEK_API_KEY",)),
    "context-correction": ("ContextCorrection", "ContextualCorrectionEvaluationTests",
                           "RILL_CONTEXT_LIVE_EVALUATION", ("DEEPSEEK_API_KEY",)),
}


def corpus_path(suite, environment):
    if suite == "vocabulary-correction" and environment.get("RILL_VOCABULARY_EVALUATION_CASES"):
        return Path(environment["RILL_VOCABULARY_EVALUATION_CASES"]).resolve()
    return ROOT / "Evals" / SUITES[suite][0] / "cases.json"


def source_fingerprint(output):
    # A custom run directory inside the checkout contains observations, not source.
    return runs.fingerprint({name: digest for name, digest in build_driver.source_inputs(ROOT).items()
                             if not (ROOT / name).is_relative_to(output.resolve())})


def expected_observations(suite, cases):
    expected = set()
    for case in cases:
        modes = ["text", "references"] if suite == "context-correction" else ["ordinary", "contextual"]
        if suite == "vocabulary-correction":
            modes = ["text", "fullVocabulary"]
            evidence = case.get("asrEvidence") or {}
            if (evidence.get("provenance", "").strip() and evidence.get("omittedCount") == 0
                    and evidence.get("usedCount") == len(evidence.get("terms", []))):
                modes.append("asrVocabulary")
        for mode in modes:
            for repetition in range(1, 2 if suite == "context-correction" else 4):
                expected.add((case["id"], mode, repetition))
    return expected


def reports(suite, raw, cases, identity, runner_succeeded):
    body = raw.get("observations", [])
    observations = body if isinstance(body, list) else body["observations"]
    values = []
    for row in observations:
        if suite == "text-rewrite":
            identifier, mode = row["sampleID"], "contextual" if row["contextual"] else "ordinary"
            matched = row["matchesExpectedContent"]
        else:
            identifier, mode = row["id"], row["mode"]
            matched = row["exactMatch"] if suite == "vocabulary-correction" else row["exactContentMatch"]
        elapsed = row["elapsedMilliseconds"]
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("Invalid provider timing.")
        values.append({"key": (identifier, mode, row.get("repetition", 1)), "mode": mode,
                       "matched": matched, "failed": row.get("failed", False),
                       "fallback": row.get("fallback", row.get("fellBack", False)),
                       "attempted": row.get("attemptedRequest", True), "elapsed": elapsed,
                       "category": row.get("category")})
    expected = expected_observations(suite, cases)
    complete = len(values) == len(expected) and {row["key"] for row in values} == expected
    quality, performance = {}, {}
    for mode in sorted({row["mode"] for row in values}):
        group = [row for row in values if row["mode"] == mode]
        # The vocabulary suite's established counts exclude empty, unrequested input.
        scored = [row for row in group if row["attempted"]] if suite == "vocabulary-correction" else group
        quality[mode] = {"n": len(scored), "exact_matches": sum(row["matched"] for row in scored),
                         "failures": sum(row["failed"] for row in scored),
                         "fallbacks": sum(row["fallback"] for row in scored)}
        if suite == "vocabulary-correction":
            quality[mode]["preservation_mismatches"] = sum(
                not row["matched"] and row["category"] not in {"correction", "identifier"} for row in scored)
        timings = sorted(row["elapsed"] for row in group if row["attempted"])
        performance[mode] = {"n": len(timings),
                             "p50_ms": timings[math.ceil(len(timings) * .5) - 1] if timings else None,
                             "p95_ms": timings[math.ceil(len(timings) * .95) - 1] if timings else None}
    failed = any(row["failed"] or (suite == "text-rewrite" and not row["matched"]) for row in values)
    incomplete = [] if complete else ["incomplete_observations"]
    if not runner_succeeded and not failed:
        incomplete.append("runner_failed")
    decision = "fail" if failed else "incomplete" if incomplete else "pass" if suite == "text-rewrite" else "not_assessed"
    common = dict(identity, schema_version=2, suite=suite, model=raw.get("model"),
                  provider_fingerprint=raw.get("providerFingerprint"),
                  expected_observations=len(expected), observations=len(values),
                  run_status="incomplete" if incomplete else "completed")
    quality_report = dict(common, kind="quality", decision=decision, quality=quality, incomplete=incomplete,
                          policy="all_expected_content_matches" if suite == "text-rewrite" else "report_only")
    if suite == "vocabulary-correction":
        quality_report["skipped_asr_comparisons"] = body.get("skippedASRComparisons", []) if isinstance(body, dict) else []
    performance_report = dict(common, kind="performance", decision="not_assessed",
                              measurement_scope="provider_request_including_fallback_not_end_to_end",
                              measurements=performance, incomplete=incomplete)
    return quality_report, performance_report


def run_llm(suite, output):
    environment = dict(os.environ)
    missing = [name for name in SUITES[suite][3] if not environment.get(name, "").strip()]
    if missing:
        raise ValueError("Missing evaluation configuration: " + ", ".join(missing))
    corpus = corpus_path(suite, environment)
    cases = json.loads(corpus.read_text())
    if not cases or len({case["id"] for case in cases}) != len(cases):
        raise ValueError("Evaluation cases must be nonempty and have unique IDs.")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(mode=0o700)
    identity = {"run_id": str(uuid.uuid4()), "started_at": datetime.now(timezone.utc).isoformat(),
                "source_revision": build_driver.capture(["git", "rev-parse", "HEAD"], ROOT).strip(),
                "source_digest": source_fingerprint(output),
                "corpus_sha256": hashlib.sha256(corpus.read_bytes()).hexdigest()}
    raw_path = output / "observations.json"
    for _, _, flag, _ in SUITES.values():
        environment.pop(flag, None)
    environment.update({SUITES[suite][2]: "1", "RILL_EVAL_OUTPUT": str(raw_path.resolve())})
    result = subprocess.run([str(ROOT / "scripts/preflight.sh"), "swift", "test-domain", "--filter",
                             "RillQualityEvaluations." + SUITES[suite][1]], cwd=ROOT, env=environment)
    raw = json.loads(raw_path.read_text()) if raw_path.exists() else {}
    unchanged = (identity["source_digest"] == source_fingerprint(output)
                 and identity["corpus_sha256"] == hashlib.sha256(corpus.read_bytes()).hexdigest())
    quality, performance = reports(suite, raw, cases, identity, result.returncode == 0 and unchanged)
    for report in (quality, performance):
        runs.write_private(output / "summaries" / (report["kind"] + "-report.json"), report)
    print(f"{suite} quality: {quality['decision']}; summaries: {output / 'summaries'}")
    return 0 if result.returncode == 0 and quality["decision"] in {"pass", "not_assessed"} else 2


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if arguments and arguments[0] == "asr":
        return asr_eval.main(arguments[1:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["asr", *SUITES])
    parser.add_argument("--output-dir", type=Path,
                        help="New private run directory; an existing directory is never overwritten")
    args = parser.parse_args(arguments)
    output = args.output_dir or ROOT / ".artifacts/evals" / args.suite / str(uuid.uuid4())
    try:
        return run_llm(args.suite, output)
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
