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


def validate_cases(cases):
    if (not cases or any(not isinstance(case.get("id"), str) or not case["id"] for case in cases)
            or len({case["id"] for case in cases}) != len(cases)):
        raise ValueError("Evaluation cases must be nonempty and have unique IDs.")
    for case in cases:
        literals = case.get("protected_literals", [])
        if (not isinstance(literals, list)
                or any(not isinstance(value, str) or not value for value in literals)
                or len(set(literals)) != len(literals)
                or any(value not in case.get("transcript", "") or value not in case.get("expected", "")
                       for value in literals)):
            raise ValueError("Protected literals must be unique nonempty strings present in the input and expectation.")


def protected_literals_match(case, output):
    literals = case.get("protected_literals", [])
    return not literals or (isinstance(output, str) and all(
        output.count(value) == case["expected"].count(value) for value in literals))


def quality_counts(rows, suite):
    result = {"n": len(rows), "exact_matches": sum(row["matched"] for row in rows),
              "failures": sum(row["failed"] for row in rows),
              "fallbacks": sum(row["fallback"] for row in rows)}
    if suite == "vocabulary-correction":
        result["preservation_mismatches"] = sum(
            not row["matched"] and row["category"] not in {"correction", "identifier"} for row in rows)
    return result


def paired_comparisons(suite, expected, indexed):
    modes = {"text-rewrite": [("ordinary", "contextual")],
             "context-correction": [("text", "references")],
             "vocabulary-correction": [("text", "fullVocabulary"), ("text", "asrVocabulary")]}
    comparisons = []
    for baseline, candidate in modes[suite]:
        pairs = sorted((identifier, repetition) for identifier, mode, repetition in expected
                       if mode == baseline and (identifier, candidate, repetition) in expected)
        if not pairs:
            continue
        counts = dict(baseline_mode=baseline, candidate_mode=candidate, expected_pairs=len(pairs), paired=0,
                      improved=0, regressed=0, both_matched=0, neither_matched=0,
                      unrequested_pairs=0, incomplete_pairs=0)
        for identifier, repetition in pairs:
            before = indexed.get((identifier, baseline, repetition))
            after = indexed.get((identifier, candidate, repetition))
            if before is None or after is None or before["attempted"] != after["attempted"]:
                counts["incomplete_pairs"] += 1
            elif not before["attempted"]:
                counts["unrequested_pairs"] += 1
            else:
                counts["paired"] += 1
                outcome = {(False, True): "improved", (True, False): "regressed",
                           (True, True): "both_matched", (False, False): "neither_matched"}
                counts[outcome[before["matched"], after["matched"]]] += 1
        comparisons.append(counts)
    return comparisons


def reports(suite, raw, cases, identity, runner_succeeded):
    body = raw.get("observations", [])
    observations = body if isinstance(body, list) else body["observations"]
    expected = expected_observations(suite, cases)
    by_id = {case["id"]: case for case in cases}
    # Only the repository's public category names may become uploaded summary keys.
    fixed_cases = json.loads((ROOT / "Evals" / SUITES[suite][0] / "cases.json").read_text())
    categories = {case["category"] for case in fixed_cases}
    grouped = {}
    for row in observations:
        identifier = row.get("sampleID" if suite == "text-rewrite" else "id")
        if suite == "text-rewrite":
            contextual = row.get("contextual")
            mode = ("contextual" if contextual else "ordinary") if type(contextual) is bool else None
        else:
            mode = row.get("mode")
        repetition = row.get("repetition", 1)
        if not isinstance(identifier, str) or not isinstance(mode, str) or type(repetition) is not int:
            continue
        key = identifier, mode, repetition
        if key not in expected:
            continue
        matched = row["matchesExpectedContent"] if suite == "text-rewrite" else row[
            "exactMatch" if suite == "vocabulary-correction" else "exactContentMatch"]
        failed = row.get("failed", False)
        fallback = row.get("fallback", row.get("fellBack", False))
        attempted = row.get("attemptedRequest", True)
        if any(type(value) is not bool for value in (matched, failed, fallback, attempted)):
            raise ValueError("Invalid provider observation flags.")
        elapsed = row["elapsedMilliseconds"]
        if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("Invalid provider timing.")
        case = by_id[identifier]
        if suite == "text-rewrite":
            matched = matched and protected_literals_match(case, row.get("output"))
        category = case.get("category")
        value = {"mode": mode, "matched": matched and not failed, "failed": failed,
                 "fallback": fallback, "attempted": attempted, "elapsed": elapsed,
                 "category": category if category in categories else "other"}
        grouped.setdefault(key, []).append(value)
    # An ambiguous coordinate contributes no score or timing, even if its rows agree.
    indexed = {key: rows[0] for key, rows in grouped.items() if len(rows) == 1}
    values = list(indexed.values())
    paired = paired_comparisons(suite, expected, indexed)
    complete = (len(observations) == len(expected) and set(indexed) == expected
                and not any(pair["incomplete_pairs"] for pair in paired))
    quality, by_category, performance = {}, {}, {}
    for mode in sorted({mode for _, mode, _ in expected}):
        group = [row for row in values if row["mode"] == mode]
        # The vocabulary suite's established counts exclude empty, unrequested input.
        scored = [row for row in group if row["attempted"]] if suite == "vocabulary-correction" else group
        quality[mode] = quality_counts(scored, suite)
        by_category[mode] = {category: quality_counts([row for row in scored if row["category"] == category], suite)
                             for category in sorted({row["category"] for row in scored})}
        timings = sorted(row["elapsed"] for row in group if row["attempted"])
        performance[mode] = {"n": len(timings),
                             "p50_ms": timings[math.ceil(len(timings) * .5) - 1] if timings else None,
                             "p95_ms": timings[math.ceil(len(timings) * .95) - 1] if timings else None}
    known_failure = any(row["failed"] for rows in grouped.values() for row in rows)
    failed = known_failure or any(suite == "text-rewrite" and not row["matched"] for row in values)
    incomplete = [] if complete else ["incomplete_observations"]
    if not runner_succeeded:
        incomplete.append("runner_failed")
    decision = "fail" if failed else "incomplete" if incomplete else "pass" if suite == "text-rewrite" else "not_assessed"
    common = dict(identity, schema_version=2, suite=suite, model=raw.get("model"),
                  provider_fingerprint=raw.get("providerFingerprint"),
                  expected_observations=len(expected), observations=len(observations),
                  run_status="incomplete" if incomplete else "completed")
    quality_report = dict(common, kind="quality", decision=decision, quality=quality,
                          quality_by_category=by_category, paired_comparisons=paired, incomplete=incomplete,
                          policy="all_expected_content_matches" if suite == "text-rewrite" else "report_only")
    if suite == "vocabulary-correction":
        eligible = {identifier for identifier, mode, _ in expected if mode == "asrVocabulary"}
        quality_report["skipped_asr_comparison_count"] = len(cases) - len(eligible)
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
    validate_cases(cases)
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
