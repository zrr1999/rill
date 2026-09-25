#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Replay authorized PCM WAV fixtures through a verified Release speech worker."""

import argparse
import base64
import struct
import hashlib
import json
import os
from pathlib import Path
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

    def send(self, identifier, sequence, body):
        frame = {"protocolVersion": 5, "requestID": identifier, "generation": 1,
                 "sessionID": identifier, "sequence": sequence, "kind": "command", "body": body}
        encoded = json.dumps(frame, separators=(",", ":")).encode() + b"\n"
        if len(encoded) > 65536:
            raise WorkerError("request_too_large")
        self.process.stdin.write(encoded)
        self.process.stdin.flush()

    def read_frame(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                return None
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise WorkerError("worker_exited")
            self.pending.extend(chunk)
            if len(self.pending) > 1048576:
                raise WorkerError("response_too_large")
        line, _, rest = self.pending.partition(b"\n")
        self.pending = bytearray(rest)
        return json.loads(line)

    @staticmethod
    def validate_frame(frame, identifier, sequence):
        if (frame.get("protocolVersion") != 5 or frame.get("generation") != 1
                or frame.get("requestID") != identifier or frame.get("sessionID") != identifier
                or frame.get("kind") != "event" or frame.get("sequence") != sequence):
            raise WorkerError("response_identity_mismatch")

    def request(self, operation, payload):
        identifier = str(uuid.uuid4()).upper()
        started = time.monotonic()
        self.send(identifier, 0, {"request": {"_0": {operation: {"_0": payload}}}})
        expected_sequence = 0
        while True:
            frame = self.read_frame(self.timeout - (time.monotonic() - started))
            if frame is None:
                raise WorkerError("timeout")
            self.validate_frame(frame, identifier, expected_sequence)
            expected_sequence += 1
            body = frame["body"]["response"]["_0"]
            if "progress" in body:
                continue
            if "failure" in body:
                raise WorkerError("recognition_failed")
            expected = {"prepareModel": "modelPrepared", "releaseModel": "modelReleased",
                        "recognizeOffline": "recognitionCompleted"}[operation]
            if set(body) != {expected}:
                raise WorkerError("unexpected_response")
            return body[expected]["_0"], (time.monotonic() - started) * 1000

    def preview(self, path, model, language, profile):
        with wave.open(str(path), "rb") as audio:
            pcm = audio.readframes(audio.getnframes())
        samples = [value[0] / 32768 for value in struct.iter_unpack("<h", pcm)]
        identifier = str(uuid.uuid4()).upper()
        payload = {"modelID": model, "keyterms": [], "mode": "vad-and-transcription",
                   "profile": profile, "priority": 30, "downloadIfNeeded": False,
                   "audioFormat": {"sampleRateHz": 16000, "channelCount": 1, "encoding": "float32"}}
        if language is not None:
            payload["language"] = language
        started = time.monotonic()
        self.send(identifier, 0, {"command": {"_0": {"start": {"_0": payload}}}})
        sequence, expected, offset = 1, 0, 0
        audio_started = finished = None
        metrics = {}
        while True:
            now = time.monotonic()
            if now - started > self.timeout + len(samples) / 16000:
                raise WorkerError("preview_timeout")
            if audio_started is not None and finished is None:
                if offset < len(samples) and now >= audio_started + offset / 16000:
                    chunk = samples[offset:offset + 1600]
                    data = struct.pack("<" + "f" * len(chunk), *chunk)
                    self.send(identifier, sequence, {"command": {"_0": {"appendAudio": {
                        "_0": {"pcmFloat32LittleEndian": base64.b64encode(data).decode()}}}}})
                    sequence += 1
                    offset += len(chunk)
                if offset == len(samples) and now >= audio_started + offset / 16000:
                    self.send(identifier, sequence, {"command": {"_0": {"finish": {}}}})
                    finished = time.monotonic()
            frame = self.read_frame(.01)
            if frame is None:
                continue
            self.validate_frame(frame, identifier, expected)
            expected += 1
            body = frame["body"]["event"]["_0"]
            observed = time.monotonic()
            if "failure" in body:
                raise WorkerError("preview_failed")
            if "started" in body:
                if audio_started is not None or body["started"]["modelID"] != model:
                    raise WorkerError("preview_model_mismatch")
                audio_started = observed
                metrics["stream_prepare_ms"] = (observed - started) * 1000
            if "transcriptUpdate" in body and audio_started is not None:
                update = body["transcriptUpdate"]["_0"]
                if (update["confirmed"] + update["provisional"]).strip():
                    metrics.setdefault("worker_first_hypothesis_ms", (observed - audio_started) * 1000)
                if update["confirmed"].strip():
                    metrics.setdefault("worker_first_confirmed_ms", (observed - audio_started) * 1000)
            if "completed" in body:
                if finished is None or offset != len(samples):
                    raise WorkerError("preview_ended_before_all_samples")
                metrics["preview_retire_ms"] = (observed - finished) * 1000
                return metrics


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
        peak = result.get("metadata", {}).get("provider.worker_peak_rss_bytes")
        if peak is not None and int(peak) > 0:
            metrics["peak_memory_bytes"] = int(peak)
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
    parser.add_argument("--cache-state", choices=("cold_process", "cold_model", "first_inference", "warm", "idle_recovery"), required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--idle-seconds", type=float, default=30)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    if args.repetitions < 1 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("Repetitions and timeout must be positive.")
    if not math.isfinite(args.idle_seconds) or args.idle_seconds < 0:
        parser.error("Idle duration must be finite and nonnegative.")
    root = Path(__file__).resolve().parents[1]
    receipt = build_driver.receipt_products(args.build_receipt, root)
    executable = Path(receipt["productsDirectory"]) / "RillSpeechWorker"
    cases = asr_benchmark.read_corpus(args.corpus, require_references=False)
    configuration_bytes = args.configuration.read_bytes()
    configuration = json.loads(configuration_bytes)
    model = configuration["model_id"]
    model_revision = configuration["model_revision"]
    if not isinstance(model_revision, str) or not model_revision:
        raise ValueError("The pinned model revision is required.")
    profile = configuration.get("preview_profile")
    if profile is not None and profile not in {"realtime", "agent", "subtitle"}:
        raise ValueError("Unknown preview profile.")
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
              "device": subprocess.check_output(["sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], text=True).strip(),
              "os_version": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip() + "/" + subprocess.check_output(["sw_vers", "-buildVersion"], text=True).strip(), "evidence_kind": evidence,
              "worker_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "measurement_scope": "worker_replay_only",
              "memory_scope": "worker_process_lifetime_peak_resident_bytes",
              "preview_time_origin": "first_replayed_pcm_after_stream_started",
              "idle_seconds": args.idle_seconds if args.cache_state == "idle_recovery" else None,
              "idle_release_model": configuration.get("idle_release_model", False),
              "preview_keyterms": "unsupported" if profile else "not_requested"}
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    worker = None
    warmed = False
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
                            warmed = False
                        preparation = {"modelID": model, "downloadIfNeeded": False}
                        measured = {}
                        if args.cache_state in {"cold_model", "first_inference"}:
                            worker.request("releaseModel", preparation)
                        if args.cache_state in {"first_inference", "warm", "idle_recovery"}:
                            _, measured["model_prepare_ms"] = worker.request("prepareModel", preparation)
                        if args.cache_state in {"warm", "idle_recovery"} and not warmed:
                            # One declared unscored inference per worker, on already authorized audio.
                            replay_case(worker, case, path, duration, model, model_revision, terms, configuration.get("language"))
                            warmed = True
                        if args.cache_state == "idle_recovery":
                            if configuration.get("idle_release_model", False):
                                worker.request("releaseModel", preparation)
                                warmed = False
                            time.sleep(args.idle_seconds)
                        if profile is not None:
                            measured.update(worker.preview(path, model, configuration.get("language"), profile))
                        row.update(replay_case(worker, case, path, duration, model, model_revision, terms, configuration.get("language")))
                        row["metrics"].update(measured)
                    except (WorkerError, OSError, ValueError, KeyError) as error:
                        failures += 1
                        row.update(status="failed", metrics={}, failure_code=str(error) if isinstance(error, WorkerError) else "invalid_result_or_io")
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
