#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Replay authorized PCM WAV fixtures through a verified Release speech worker."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import math
import subprocess
import tempfile
import time
import uuid
import wave

import asr_benchmark
import build_driver


class WorkerError(Exception):
    pass


class Worker:
    def __init__(self, executable, timeout):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.timeout = timeout
        self.pending = bytearray()
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)

    def close(self):
        self.selector.close()
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()

    def request(self, operation, payload):
        identifier = str(uuid.uuid4()).upper()
        frame = {"protocolVersion": 5, "requestID": identifier, "generation": 1,
                 "sessionID": identifier, "sequence": 0, "kind": "command",
                 "body": {"request": {"_0": {operation: {"_0": payload}}}}}
        encoded = json.dumps(frame, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > 65536:
            raise WorkerError("request_too_large")
        started = time.monotonic()
        self.process.stdin.write(encoded)
        self.process.stdin.flush()
        expected_sequence = 0
        while True:
            remaining = self.timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise WorkerError("timeout")
            if b"\n" not in self.pending:
                if not self.selector.select(remaining):
                    raise WorkerError("timeout")
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise WorkerError("worker_exited")
                self.pending.extend(chunk)
                if len(self.pending) > 1048576:
                    raise WorkerError("response_too_large")
                continue
            line, _, rest = self.pending.partition(b"\n")
            self.pending = bytearray(rest)
            response = json.loads(line)
            if (response.get("protocolVersion") != 5 or response.get("generation") != 1
                    or response.get("requestID") != identifier or response.get("sessionID") != identifier
                    or response.get("kind") != "event" or response.get("sequence") != expected_sequence):
                raise WorkerError("response_identity_mismatch")
            expected_sequence += 1
            body = response["body"]["response"]["_0"]
            if "progress" in body:
                continue
            if "failure" in body:
                raise WorkerError("recognition_failed")
            expected = {"prepareModel": "modelPrepared", "releaseModel": "modelReleased",
                        "recognizeOffline": "recognitionCompleted"}[operation]
            if set(body) != {expected}:
                raise WorkerError("unexpected_response")
            return body[expected]["_0"], (time.monotonic() - started) * 1000


def audio_fixture(case, corpus_directory):
    if case.get("consent") != "authorized":
        raise ValueError("Each replay fixture must have explicit authorized consent.")
    path = (corpus_directory / case["audio_path"]).resolve()
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != case["audio_sha256"]:
        raise ValueError("Fixture bytes do not match the corpus identity.")
    with wave.open(str(path), "rb") as audio:
        if audio.getsampwidth() != 2 or audio.getnchannels() != 1 or audio.getframerate() != 16000:
            raise ValueError("Replay fixtures must be 16 kHz mono PCM16 WAV.")
        duration = audio.getnframes() / 16000
    return path, duration


def replay_case(worker, case, path, duration, model, model_revision, keyterms, language):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != case["audio_sha256"]:
        raise ValueError("Fixture changed after validation.")
    descriptor, temporary = tempfile.mkstemp(prefix="rill-benchmark-", suffix=".wav")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        payload = {"runID": str(uuid.uuid4()), "modelID": model, "keyterms": keyterms,
                   "threadCount": 1, "audioFilePath": temporary, "audioDurationSeconds": duration,
                   "audioFormat": {"sampleRateHz": 16000, "channelCount": 1, "encoding": "pcm16"},
                   "downloadIfNeeded": False}
        if language is not None:
            payload["language"] = language
        result, elapsed = worker.request("recognizeOffline", payload)
        if (result.get("metadata", {}).get("provider.model") != model
                or result.get("metadata", {}).get("provider.model_revision") != model_revision):
            raise WorkerError("model_identity_mismatch")
        metrics = {"worker_request_ms": elapsed}
        if result.get("processingDurationMillis") is not None:
            metrics["worker_inference_ms"] = result["processingDurationMillis"]
        return {"status": "ok", "texts": {"raw": result["rawText"]}, "metrics": metrics}
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache-state", choices=("cold_process", "cold_model", "first_inference", "warm"), required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if args.repetitions < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("Repetitions and timeout must be positive.")
    root = Path(__file__).resolve().parents[1]
    receipt = build_driver.receipt_products(args.build_receipt, root)
    executable = Path(receipt["productsDirectory"]) / "RillSpeechWorker"
    cases = asr_benchmark.read_corpus(args.corpus)
    configuration_bytes = args.configuration.read_bytes()
    configuration = json.loads(configuration_bytes)
    model = configuration["model_id"]
    model_revision = configuration["model_revision"]
    if not isinstance(model_revision, str) or not model_revision:
        raise ValueError("The pinned model revision is required.")
    evidence = json.loads(args.corpus.read_text())["evidence_kind"]
    if evidence not in {"microphone", "synthetic", "public_fixture"}:
        raise ValueError("Unknown evidence kind.")
    # Validate the complete corpus before starting a model or creating a report.
    fixtures = {key: audio_fixture(case, args.corpus.resolve().parent) for key, case in cases.items()}
    terms = configuration.get("keyterms", [])
    if (len(terms) > 16 or any(not isinstance(t, str) or not t or len(t.encode()) > 48
                              or "," in t or any(ord(c) < 32 for c in t) for t in terms)):
        raise ValueError("Keyterms exceed the bounded worker protocol.")
    header = {"schema_version": 1, "run_id": str(uuid.uuid4()),
              "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "source_digest": receipt["sourceFingerprint"], "model_id": model, "model_revision": model_revision,
              "configuration_digest": hashlib.sha256(configuration_bytes).hexdigest(),
              "device": subprocess.check_output(["sysctl", "-n", "hw.model", "hw.memsize"], text=True).strip(),
              "os_version": platform.platform(), "evidence_kind": evidence,
              "worker_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "measurement_scope": "worker_offline_only"}
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    worker = None
    failures = 0
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(json.dumps(header) + "\n")
            output.flush()
            for repetition in range(1, args.repetitions + 1):
                for identifier, case in cases.items():
                    path, duration = fixtures[identifier]
                    row = {"case_id": identifier, "audio_sha256": case["audio_sha256"],
                           "cache_state": args.cache_state, "repetition": repetition}
                    try:
                        if worker is None:
                            worker = Worker(executable, args.timeout)
                        preparation = {"modelID": model, "downloadIfNeeded": False}
                        if args.cache_state in {"cold_model", "first_inference"}:
                            worker.request("releaseModel", preparation)
                        if args.cache_state in {"first_inference", "warm"}:
                            worker.request("prepareModel", preparation)
                        if args.cache_state == "warm":
                            # A declared, unscored inference precedes each measured warm request.
                            replay_case(worker, case, path, duration, model, model_revision, terms, configuration.get("language"))
                        row.update(replay_case(worker, case, path, duration, model, model_revision, terms, configuration.get("language")))
                    except (WorkerError, OSError, ValueError, KeyError):
                        failures += 1
                        row.update(status="failed", metrics={})
                        if worker is not None:
                            worker.close()
                            worker = None
                    output.write(json.dumps(row, ensure_ascii=False) + "\n")
                    output.flush()
                    if args.cache_state == "cold_process" and worker is not None:
                        worker.close()
                        worker = None
    finally:
        if worker is not None:
            worker.close()
    print("Replay finished. Private raw-ASR results written; product latency and quality acceptance remain separate.")
    return 2 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
