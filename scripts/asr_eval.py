#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Evaluate paired ASR text quality independently of time and memory measurements."""

from collections import defaultdict
import random
import re
import statistics
import unicodedata

import asr_run_data as runs

STAGES = ("raw", "vocabulary", "final")

def normalized(text):
    return unicodedata.normalize("NFC", text)

def characters(text):
    return [c for c in normalized(text) if not c.isspace()]

def words(text):
    # Keep Chinese characters as tokens; retain punctuation and word case.
    spaced = re.sub(r"([\u3400-\u9fff])", r" \1 ", normalized(text))
    return re.findall(r"\w+|[^\w\s]", spaced)

def distance(expected, actual):
    previous = list(range(len(actual) + 1))
    for i, left in enumerate(expected, 1):
        current = [i]
        for j, right in enumerate(actual, 1):
            current.append(min(previous[j] + 1, current[-1] + 1,
                               previous[j - 1] + (left != right)))
        previous = current
    return previous[-1]

def contains(text, term):
    haystack, needle = words(text), words(term)
    return bool(needle) and any(haystack[i:i + len(needle)] == needle
                               for i in range(len(haystack) - len(needle) + 1))

def summarize(rows, cases, stage):
    char_errors = char_count = word_errors = word_count = critical_errors = hallucinations = 0
    measured = 0
    for row in rows:
        case = cases[row["case_id"]]
        reference = case["references"].get(stage)
        actual = row.get("texts", {}).get(stage)
        if reference is None or actual is None:
            continue
        measured += 1
        char_errors += distance(characters(reference), characters(actual))
        char_count += len(characters(reference))
        word_errors += distance(words(reference), words(actual))
        word_count += len(words(reference))
        hallucinations += not characters(reference) and bool(characters(actual))
        critical_errors += sum(not contains(actual, term) for term in case.get("required_terms", []))
        critical_errors += sum(contains(actual, term) for term in case.get("forbidden_terms", []))
    return {"n": measured, "character_errors": char_errors, "characters": char_count,
            "cer": char_errors / char_count if char_count else None,
            "word_errors": word_errors, "words": word_count,
            "wer": word_errors / word_count if word_count else None,
            "critical_errors": critical_errors, "hallucinations": hallucinations}

def cer_difference_interval(pairs, cases):
    by_case = defaultdict(list)
    for before, after in pairs:
        reference = characters(cases[before["case_id"]]["references"]["raw"])
        if not reference:
            continue
        delta = (distance(reference, characters(after["texts"]["raw"]))
                 - distance(reference, characters(before["texts"]["raw"])))
        by_case[before["case_id"]].append((delta, len(reference)))
    groups = list(by_case.values())
    if len(groups) < 2:
        return None
    rng = random.Random(0)
    samples = []
    for _ in range(1000):
        selected = [rng.choice(groups) for _ in groups]
        samples.append(sum(statistics.mean(p[0] for p in group) for group in selected)
                       / sum(statistics.mean(p[1] for p in group) for group in selected))
    samples.sort()
    return [samples[24], samples[974]]


def compare(cases, baseline, candidate, split="validation"):
    keys = runs.paired_keys(cases, baseline, candidate, split)
    for identifier, _, _ in keys:
        if not isinstance(cases[identifier]["references"].get("raw"), str):
            raise ValueError("Quality comparison requires a human raw reference; missing is not silence.")
    before, after = baseline[1], candidate[1]
    report = runs.comparison_report("quality", cases, baseline, candidate, split, keys)
    successful = [key for key in keys if before[key]["status"] == after[key]["status"] == "ok"]
    regressions = ["failed_or_cancelled_runs"] if len(successful) != len(keys) else []
    incomplete = [] if report["coverage"]["complete"] else ["missing_cases"]
    groups = {"all": successful}
    for tag in sorted({tag for key in keys for tag in cases[key[0]]["tags"]}):
        groups[tag] = [key for key in successful if tag in cases[key[0]]["tags"]]
    quality = {}
    for group, selected in groups.items():
        quality[group] = {}
        for stage in STAGES:
            a = summarize([before[key] for key in selected], cases, stage)
            b = summarize([after[key] for key in selected], cases, stage)
            quality[group][stage] = {"baseline": a, "candidate": b}
            expected = sum(stage in cases[key[0]]["references"] for key in selected)
            if a["n"] != expected or b["n"] != expected:
                incomplete.append(f"{group}.{stage}.missing_output")
            for metric in ("character_errors", "word_errors", "critical_errors", "hallucinations"):
                if b[metric] > a[metric]:
                    regressions.append(f"{group}.{stage}.{metric}")
    interval = cer_difference_interval([(before[k], after[k]) for k in successful], cases)
    if interval is None or interval[1] > 0:
        incomplete.append("raw_cer_noninferiority_not_established")
    # Aggregate improvements may not hide a new critical error in one recording.
    for key in successful:
        for stage in STAGES:
            a, b = (summarize([side[key]], cases, stage) for side in (before, after))
            if b["critical_errors"] > a["critical_errors"] or b["hallucinations"] > a["hallucinations"]:
                regressions.append(f"case.{key[0]}.{stage}.critical_or_silence")
    report.update(quality=quality, raw_cer_delta_95_percent_interval=interval)
    return runs.decide(report, regressions, incomplete)


def main(arguments=None):
    args = runs.comparison_parser(__doc__).parse_args(arguments)
    return runs.save_comparison(args, compare, quality=True)


if __name__ == "__main__":
    raise SystemExit(main())
