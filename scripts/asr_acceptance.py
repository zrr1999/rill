#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Apply the ASR experiment admission policy to matching quality and performance reports."""

import argparse
import json
from pathlib import Path

import asr_run_data as runs


def assess(quality, performance, goal):
    if goal not in {"quality", "performance"}:
        raise ValueError("Unknown experiment goal.")
    for report, kind in ((quality, "quality"), (performance, "performance")):
        if report.get("schema_version") != 2 or report.get("kind") != kind or report.get("suite") != "asr":
            raise ValueError(f"Expected an ASR {kind} report at schema version 2.")
        if report.get("decision") not in {"pass", "fail", "incomplete"}:
            raise ValueError("Report has no comparison decision.")
    identity = ("baseline", "candidate", "corpus_sha256", "baseline_run_sha256",
                "candidate_run_sha256", "split", "paired_results", "coverage")
    for field in identity:
        if field not in quality or field not in performance or quality[field] != performance[field]:
            raise ValueError(f"Reports describe different evidence: {field}.")
    regressions, incomplete = [], []
    for report in (quality, performance):
        regressions.extend(f"{report['kind']}.{reason}" for reason in report["regressions"])
        incomplete.extend(f"{report['kind']}.{reason}" for reason in report["incomplete"])
        if report["decision"] == "fail":
            regressions.append(f"{report['kind']}.comparison_failed")
        elif report["decision"] == "incomplete":
            incomplete.append(f"{report['kind']}.comparison_incomplete")
    coverage = quality["coverage"]
    if quality["split"] != "validation":
        incomplete.append("held_out_validation_required")
    if coverage["corpus_cases"] < 120 or coverage["split_cases"] < 40:
        incomplete.append("insufficient_corpus")
    if not coverage["complete"]:
        incomplete.append("missing_cases")
    if coverage["minimum_repetitions"] < 3:
        incomplete.append("insufficient_repetitions")
    if any(quality[side]["evidence_kind"] != "microphone" for side in ("baseline", "candidate")):
        incomplete.append("not_microphone_acceptance")
    target = performance["target"]
    if target == "peak_memory_bytes":
        incomplete.append("latency_target_required")
    for state, expected in coverage["results_by_cache_state"].items():
        measurements = performance["measurements"][state]
        for metric in {target, "peak_memory_bytes"}:
            pair = measurements[metric]
            if any(pair[side]["n"] != expected or pair[side]["p95"] is None
                   for side in ("baseline", "candidate")):
                incomplete.append(f"{state}.{metric}.missing_measurement")
        if goal == "performance":
            pair = measurements[target]
            before, after = pair["baseline"]["p95"], pair["candidate"]["p95"]
            if before is None or after is None:
                continue
            if before == 0:
                incomplete.append(f"{state}.{target}.zero_baseline")
            elif after > before * .9:
                regressions.append(f"{state}.{target}.improvement_below_10_percent")
    result = {key: quality[key] for key in identity}
    result.update(schema_version=2, kind="acceptance", suite="asr", goal=goal,
                  scope="asr_experiment_admission_not_release_acceptance",
                  quality_decision=quality["decision"], performance_decision=performance["decision"])
    return runs.decide(result, regressions, incomplete)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quality-report", type=Path, required=True)
    parser.add_argument("--performance-report", type=Path, required=True)
    parser.add_argument("--goal", choices=("quality", "performance"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = assess(json.loads(args.quality_report.read_text()),
                    json.loads(args.performance_report.read_text()), args.goal)
    runs.write_private(args.output, report)
    print(f"ASR experiment admission: {report['decision']}")
    return 0 if report["decision"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
