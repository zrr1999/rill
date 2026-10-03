#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Private corpus/run I/O and pairing shared by ASR replay and analysis."""

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import tempfile

METRICS = ("first_preview_ms", "stable_preview_ms", "release_to_final_ms",
           "release_to_saved_ms", "release_to_paste_posted_ms", "worker_request_ms",
           "worker_inference_ms", "peak_memory_bytes", "model_prepare_ms",
           "stream_prepare_ms", "preview_retire_ms", "worker_first_hypothesis_ms",
           "worker_first_confirmed_ms", "host_replay_to_final_ms",
           "host_replay_to_saved_ms", "host_replay_to_isolated_dispatch_ms")
CACHE_STATES = {"cold_process", "cold_model", "first_inference", "warm", "idle_recovery"}


def percentiles(values):
    values = sorted(values)
    return {"n": len(values),
            "p50": statistics.median(values) if values else None,
            "p95": values[math.ceil(.95 * len(values)) - 1] if values else None}

def read_corpus(path, *, require_references=False):
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

def write_private(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".asr-report-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def paired_keys(cases, baseline, candidate, split, *, performance=False):
    before_header, before = baseline
    after_header, after = candidate
    if set(before) != set(after):
        raise ValueError("Paired runs must contain the same cases, cache states and repetitions.")
    fields = ("device", "os_version", "evidence_kind", "measurement_scope")
    if performance:
        fields += ("memory_scope", "preview_time_origin")
    for field in fields:
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
    return keys


def comparison_report(kind, cases, baseline, candidate, split, keys):
    expected = {identifier for identifier, case in cases.items() if case["split"] == split}
    repetitions = defaultdict(set)
    for identifier, state, repetition in keys:
        repetitions[identifier, state].add(repetition)
    states = sorted({key[1] for key in keys})
    complete = all({key[0] for key in keys if key[1] == state} == expected for state in states)
    return {
        "schema_version": 2, "kind": kind, "suite": "asr",
        "baseline": baseline[0], "candidate": candidate[0], "split": split,
        "corpus_sha256": fingerprint(cases),
        "baseline_run_sha256": fingerprint([baseline[0], [baseline[1][key] for key in sorted(baseline[1])]]),
        "candidate_run_sha256": fingerprint([candidate[0], [candidate[1][key] for key in sorted(candidate[1])]]),
        "paired_results": len(keys),
        "coverage": {"corpus_cases": len(cases), "split_cases": len(expected),
                     "complete": complete, "minimum_repetitions": min(map(len, repetitions.values())),
                     "results_by_cache_state": {state: sum(key[1] == state for key in keys) for state in states}},
    }


def decide(report, regressions, incomplete):
    return dict(report, regressions=sorted(set(regressions)), incomplete=sorted(set(incomplete)),
                decision="fail" if regressions else "incomplete" if incomplete else "pass")


def comparison_parser(description):
    parser = argparse.ArgumentParser(description=description)
    for name in ("corpus", "baseline", "candidate", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--split", choices=("development", "validation"), default="validation")
    return parser


def save_comparison(args, compare, *, quality=False, **options):
    cases = read_corpus(args.corpus, require_references=quality)
    report = compare(cases, read_run(args.baseline, cases), read_run(args.candidate, cases),
                     split=args.split, **options)
    write_private(args.output, report)
    print(f"ASR {report['kind']}: {report['decision']} ({report['paired_results']} paired results)")
    return 0 if report["decision"] == "pass" else 2
