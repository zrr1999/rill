#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compare paired ASR performance using an explicit metric and a 5% regression budget."""

import asr_run_data as runs


def compare(cases, baseline, candidate, target, split="validation"):
    if target not in runs.METRICS:
        raise ValueError("Unknown performance target.")
    keys = runs.paired_keys(cases, baseline, candidate, split, performance=True)
    before, after = baseline[1], candidate[1]
    report = runs.comparison_report("performance", cases, baseline, candidate, split, keys)
    successful = [key for key in keys if before[key]["status"] == after[key]["status"] == "ok"]
    regressions = ["failed_or_cancelled_runs"] if len(successful) != len(keys) else []
    incomplete = [] if report["coverage"]["complete"] else ["missing_cases"]
    measurements = {}
    for state in sorted({key[1] for key in keys}):
        selected = [key for key in successful if key[1] == state]
        measurements[state] = {}
        for metric in runs.METRICS:
            pairs = [(before[key]["metrics"][metric], after[key]["metrics"][metric])
                     for key in selected if metric in before[key].get("metrics", {})
                     and metric in after[key].get("metrics", {})]
            a = runs.percentiles([pair[0] for pair in pairs])
            b = runs.percentiles([pair[1] for pair in pairs])
            measurements[state][metric] = {"baseline": a, "candidate": b}
            if metric == target and (not pairs or len(pairs) != len(selected)):
                incomplete.append(f"{state}.{metric}.missing_measurement")
            if pairs and b["p95"] > a["p95"] * 1.05:
                regressions.append(f"{state}.{metric}.budget")
    report.update(target=target, regression_budget_percent=5, measurements=measurements)
    return runs.decide(report, regressions, incomplete)


def main():
    parser = runs.comparison_parser(__doc__)
    parser.add_argument("--target", choices=runs.METRICS, required=True)
    args = parser.parse_args()
    return runs.save_comparison(args, compare, target=args.target)


if __name__ == "__main__":
    raise SystemExit(main())
