#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Run authorized audio through Release ASR, workflow processing, encrypted Record commit and an isolated output sink."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

import asr_benchmark
import asr_replay
import build_driver


def create_report(path, header):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(json.dumps(header) + "\n")


def validate_report_identity(path, state):
    lines = path.read_text().splitlines(keepends=True)
    header = json.loads(lines[0])
    header["evidence_validation"] = state
    descriptor, temporary = tempfile.mkstemp(prefix=".rill-evidence-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(json.dumps(header) + "\n")
            output.writelines(lines[1:])
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def finish_reports(reports, cases, cache_state, repetitions):
    try:
        for report in reports:
            validate_report_identity(report, "passed")
        _, rows = asr_benchmark.read_run(reports[0], cases)
        expected = {(identifier, cache_state, repetition)
                    for identifier in cases for repetition in range(1, repetitions + 1)}
        if set(rows) != expected:
            raise ValueError("Incomplete host replay; keep the report as failed evidence.")
    except BaseException:
        for report in reports:
            validate_report_identity(report, "invalid")
        raise
    return 2 if any(row["status"] != "ok" for row in rows.values()) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache-state", choices=("first_inference", "warm"), required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("Repetitions must be positive.")
    root = Path(__file__).resolve().parents[1]
    receipt = build_driver.receipt_products(args.build_receipt, root)
    worker = Path(receipt["productsDirectory"]) / "RillSpeechWorker"
    cases = asr_benchmark.read_corpus(args.corpus, require_references=False)
    if not cases:
        parser.error("The corpus is empty.")
    configuration_bytes = args.configuration.read_bytes()
    config = json.loads(configuration_bytes)
    if not isinstance(config.get("model_revision"), str) or not config["model_revision"]:
        parser.error("The pinned model revision is required.")
    evidence = json.loads(args.corpus.read_text())["evidence_kind"]
    if evidence not in {"microphone", "synthetic", "public_fixture"}:
        parser.error("Unknown audio evidence kind.")
    fixtures = []
    for identifier, case in cases.items():
        path, duration = asr_replay.audio_fixture(case, args.corpus.resolve().parent)
        fixtures.append({"id": identifier, "audioPath": str(path), "audioSHA256": case["audio_sha256"],
                         "durationSeconds": duration, "consent": "authorized"})
    header = {"schema_version": 1, "run_id": str(uuid.uuid4()), "evidence_validation": "pending",
              "source_revision": build_driver.capture(["git", "rev-parse", "HEAD"], root).strip(),
              "source_digest": receipt["sourceFingerprint"],
              "model_id": config["model_id"], "model_revision": config["model_revision"],
              "configuration_digest": hashlib.sha256(configuration_bytes).hexdigest(),
              "device": subprocess.check_output(["sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], text=True).strip(),
              "os_version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
              "evidence_kind": evidence, "measurement_scope": "host_replay_isolated_output",
              "memory_scope": "not_measured", "preview_time_origin": "not_measured",
              "worker_sha256": hashlib.sha256(worker.read_bytes()).hexdigest(),
              "output_scope": "in_memory_sink_after_real_encrypted_record_commit",
              "text_pipeline": "configured_vocabulary_then_whitespace_normalization_no_llm"}
    create_report(args.output, header)
    reports = [args.output]
    try:
        warmup = args.output.with_suffix(args.output.suffix + ".warmup.jsonl") if args.cache_state == "warm" else None
        if warmup is not None:
            create_report(warmup, dict(header, analysis_role="warmup"))
            reports.append(warmup)
        request = {"worker": str(worker), "output": str(args.output.resolve()), "modelID": config["model_id"],
                   "modelRevision": config["model_revision"], "cacheState": args.cache_state,
                   "warmupOutput": str(warmup.resolve()) if warmup else None,
                   "language": config.get("language"), "keyterms": config.get("keyterms", []),
                   "replacements": config.get("replacements", []), "repetitions": args.repetitions, "cases": fixtures}
        with tempfile.TemporaryDirectory(prefix="rill-host-benchmark-") as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps(request))
            path.chmod(0o600)
            environment = dict(os.environ, RILL_PRODUCT_BENCHMARK_REQUEST=str(path))
            subprocess.run([str(root / "scripts/swift_locked.sh"), "test-domain", "-c", "release", "--filter",
                            "ProductPathBenchmarkTests/authorizedReleaseCorpusThroughProductionHostPipeline"],
                           cwd=root, env=environment, check=True)
        build_driver.receipt_products(args.build_receipt, root)
    except BaseException:
        for report in reports:
            validate_report_identity(report, "invalid")
        raise
    return finish_reports(reports, cases, args.cache_state, args.repetitions)


if __name__ == "__main__":
    raise SystemExit(main())
