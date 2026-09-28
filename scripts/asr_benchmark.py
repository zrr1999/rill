#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Compare paired, explicitly collected ASR runs without exporting their text."""

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import statistics
import tempfile
import unicodedata


STAGES = ("raw", "vocabulary", "final")
METRICS = ("first_preview_ms", "stable_preview_ms", "release_to_final_ms",
           "release_to_saved_ms", "release_to_paste_posted_ms", "worker_request_ms",
           "worker_inference_ms", "peak_memory_bytes", "model_prepare_ms",
           "stream_prepare_ms", "preview_retire_ms", "worker_first_hypothesis_ms",
           "worker_first_confirmed_ms", "host_replay_to_final_ms",
           "host_replay_to_saved_ms", "host_replay_to_isolated_dispatch_ms")
CACHE_STATES = {"cold_process", "cold_model", "first_inference", "warm", "idle_recovery"}


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


def percentiles(values):
    values = sorted(values)
    return {"n": len(values),
            "p50": statistics.median(values) if values else None,
            "p95": values[math.ceil(.95 * len(values)) - 1] if values else None}


def read_corpus(path, *, require_references=True):
    document = json.loads(path.read_text())
    if document.get("schema_version") != 1:
        raise ValueError("Unsupported corpus schema.")
    cases = {}
    for case in document["cases"]:
        identifier = case["id"]
        if identifier in cases or case["split"] not in {"development", "validation"}:
            raise ValueError("Duplicate case or invalid split.")
        if not isinstance(case.get("references"), dict) or not case.get("tags"):
            raise ValueError("Every case needs a references object and scenario tags.")
        if require_references and not isinstance(case["references"].get("raw"), str):
            raise ValueError("Quality comparison requires a human raw reference for every case; missing is not silence.")
        if any(not isinstance(value, str) for value in case["references"].values()):
            raise ValueError("References must be text.")
        cases[identifier] = case
    return cases


def read_run(path, cases):
    lines = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not lines or lines[0].get("schema_version") != 1:
        raise ValueError("Missing run header.")
    if (lines[0].get("measurement_scope") == "host_replay_isolated_output"
            and lines[0].get("evidence_validation") != "passed"):
        raise ValueError("Host replay identity was not validated; this report cannot be compared.")
    if lines[0].get("analysis_role") == "warmup":
        raise ValueError("Warmup observations are retained separately and cannot be scored.")
    identity_keys = ("run_id", "source_revision", "source_digest", "model_id", "model_revision",
                "configuration_digest", "device", "os_version", "evidence_kind")
    header = {key: lines[0].get(key) for key in identity_keys}
    for key in identity_keys:
        if not isinstance(header.get(key), str) or not header[key]:
            raise ValueError(f"Missing run identity: {key}.")
    if header["evidence_kind"] not in {"microphone", "synthetic", "public_fixture"}:
        raise ValueError("Unknown evidence kind.")
    for key in ("measurement_scope", "memory_scope", "preview_time_origin"):
        if key in lines[0]:
            value = lines[0][key]
            if not isinstance(value, str) or not value:
                raise ValueError(f"Invalid measurement scope: {key}.")
            header[key] = value
    rows = {}
    audio_ids = {}
    for row in lines[1:]:
        identifier = row["case_id"]
        if identifier not in cases or row["cache_state"] not in CACHE_STATES:
            raise ValueError("Unknown case or cache state.")
        if type(row["repetition"]) is not int or row["repetition"] < 1:
            raise ValueError("Repetitions must be positive integers.")
        digest = row["audio_sha256"]
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError("Invalid audio identity.")
        if digest != cases[identifier].get("audio_sha256"):
            raise ValueError("Result audio does not match the current corpus.")
        if identifier in audio_ids and audio_ids[identifier] != digest:
            raise ValueError("A case changed audio between repetitions.")
        audio_ids[identifier] = digest
        key = (identifier, row["cache_state"], row["repetition"])
        if key in rows:
            raise ValueError("Duplicate result; selecting the best repetition is forbidden.")
        if row["status"] not in {"ok", "failed", "cancelled"}:
            raise ValueError("Unknown result status.")
        if row["status"] == "ok" and not isinstance(row.get("texts", {}).get("raw"), str):
            raise ValueError("Successful recognition must include raw text, including silence.")
        for value in row.get("texts", {}).values():
            if not isinstance(value, str):
                raise ValueError("Stage output must be text.")
        for metric, value in row.get("metrics", {}).items():
            if metric not in METRICS or type(value) not in {int, float} or not math.isfinite(value) or value < 0:
                raise ValueError("Invalid measurement; omit unavailable metrics.")
        rows[key] = row
    return header, rows


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


def compare(cases, baseline, candidate, target="release_to_final_ms", split="validation", purpose="quality"):
    before_header, before = baseline
    after_header, after = candidate
    if set(before) != set(after):
        raise ValueError("Paired runs must contain the same cases, cache states and repetitions.")
    for field in ("device", "os_version", "evidence_kind", "measurement_scope", "memory_scope", "preview_time_origin"):
        if before_header.get(field) != after_header.get(field):
            raise ValueError(f"Incomparable run identity: {field}.")
    for key in before:
        if before[key]["audio_sha256"] != cases[key[0]].get("audio_sha256"):
            raise ValueError("Result audio does not match the current corpus.")
        if before[key]["audio_sha256"] != after[key]["audio_sha256"]:
            raise ValueError("Paired runs must use identical audio bytes.")
    keys = sorted(key for key in before if cases[key[0]]["split"] == split)
    if not keys:
        raise ValueError("No results for the selected split.")
    regressions, incomplete = [], []
    successful = [key for key in keys if before[key]["status"] == after[key]["status"] == "ok"]
    if len(successful) != len(keys):
        regressions.append("failed_or_cancelled_runs")
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
    measurements = {}
    for state in sorted({key[1] for key in keys}):
        selected = [key for key in successful if key[1] == state]
        measurements[state] = {}
        for metric in METRICS:
            pairs = [(before[k]["metrics"][metric], after[k]["metrics"][metric])
                     for k in selected if metric in before[k].get("metrics", {})
                     and metric in after[k].get("metrics", {})]
            a, b = percentiles([p[0] for p in pairs]), percentiles([p[1] for p in pairs])
            measurements[state][metric] = {"baseline": a, "candidate": b}
            if len(pairs) != len(selected) and metric in {target, "peak_memory_bytes"}:
                incomplete.append(f"{state}.{metric}.missing_measurement")
            if pairs:
                limit = .9 if metric == target and purpose == "performance" else 1.05
                if metric == target and purpose == "performance" and a["p95"] == 0:
                    incomplete.append(f"{state}.{metric}.zero_baseline")
                if b["p95"] > a["p95"] * limit:
                    regressions.append(f"{state}.{metric}.budget")
    expected_cases = {key for key, case in cases.items() if case["split"] == split}
    if {key[0] for key in keys} != expected_cases:
        incomplete.append("missing_cases")
    if len(cases) < 120 or len(expected_cases) < 40:
        incomplete.append("insufficient_corpus")
    repetitions = defaultdict(set)
    for identifier, state, repetition in keys:
        repetitions[identifier, state].add(repetition)
    if any(len(values) < 3 for values in repetitions.values()):
        incomplete.append("insufficient_repetitions")
    if before_header["evidence_kind"] != "microphone":
        incomplete.append("not_microphone_acceptance")
    return {"schema_version": 1, "baseline": before_header, "candidate": after_header,
            "split": split, "purpose": purpose, "paired_results": len(keys), "quality": quality,
            "raw_cer_delta_95_percent_interval": interval, "measurements": measurements,
            "regressions": sorted(set(regressions)), "incomplete": sorted(set(incomplete)),
            "decision": "reject" if regressions else "incomplete" if incomplete else "eligible"}


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".asr-report-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--split", choices=("development", "validation"), default="validation")
    parser.add_argument("--purpose", choices=("quality", "performance"), default="quality")
    parser.add_argument("--target", choices=[m for m in METRICS if m != "peak_memory_bytes"], default="release_to_final_ms")
    args = parser.parse_args()
    cases = read_corpus(args.corpus)
    report = compare(cases, read_run(args.baseline, cases), read_run(args.candidate, cases), args.target, args.split, args.purpose)
    report["corpus_sha256"] = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
    write_private(args.output, report)
    print(f"ASR comparison: {report['decision']} ({report['paired_results']} paired results)")
    return 0 if report["decision"] == "eligible" else 2


if __name__ == "__main__":
    raise SystemExit(main())
