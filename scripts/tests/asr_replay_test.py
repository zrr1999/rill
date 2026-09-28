#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import asr_replay as replay


class ReplayTests(unittest.TestCase):
    def test_worker_protocol_roundtrip_rejects_wrong_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "worker"
            for wrong in (False, True):
                executable.write_text(f'''#!{sys.executable}
import json, sys
for line in sys.stdin:
 f=json.loads(line)
 f.update(kind="event", sequence=0, body={{"response":{{"_0":{{"modelPrepared":{{"_0":"model"}}}}}}}})
 if {wrong}: f["generation"]=2
 print(json.dumps(f), flush=True)
''')
                executable.chmod(0o700)
                worker = replay.Worker(executable, 2)
                try:
                    if wrong:
                        with self.assertRaises(replay.WorkerError):
                            worker.request("prepareModel", {})
                    else:
                        value, elapsed = worker.request("prepareModel", {})
                        self.assertEqual(value, "model")
                        self.assertGreater(elapsed, 0)
                finally:
                    worker.close()
                self.assertIsNotNone(worker.process.returncode)

    def test_preview_preserves_partial_tail_and_rejects_early_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tail.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 1601)
            executable = Path(directory) / "worker"
            executable.write_text(f'''#!{sys.executable}
import json, sys, base64
sequence = total = 0
for line in sys.stdin:
 f=json.loads(line); c=f["body"]["command"]["_0"]
 event=None
 if "start" in c: event={{"started":{{"modelID":"model"}}}}
 elif "appendAudio" in c:
  total+=len(base64.b64decode(c["appendAudio"]["_0"]["pcmFloat32LittleEndian"]))//4
 elif "finish" in c:
  event={{"completed":{{"previewText":""}}}} if total==1601 else {{"failure":{{"_0":"invalidAudio"}}}}
 if event is not None:
  f.update(kind="event", sequence=sequence, body={{"event":{{"_0":event}}}})
  sequence+=1; print(json.dumps(f), flush=True)
''')
            executable.chmod(0o700)
            worker = replay.Worker(executable, 2)
            try:
                metrics = worker.preview(path, "model", None, "realtime")
                self.assertIn("preview_retire_ms", metrics)
                self.assertNotIn("worker_first_hypothesis_ms", metrics)
            finally:
                worker.close()
            executable.write_text(executable.read_text().replace('event={"started":{"modelID":"model"}}', 'event={"completed":{"previewText":""}}'))
            worker = replay.Worker(executable, 2)
            try:
                with self.assertRaisesRegex(replay.WorkerError, "before_all_samples"):
                    worker.preview(path, "model", None, "realtime")
            finally:
                worker.close()

    def test_authorization_audio_identity_and_failure_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 160)
            case = {"audio_path": path.name, "audio_sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            with self.assertRaises(ValueError):
                replay.audio_fixture(case, path.parent)
            case["consent"] = "authorized"
            validated, duration = replay.audio_fixture(case, path.parent)
            self.assertEqual(duration, .01)
            class Failure:
                def request(self, operation, payload):
                    self.path = Path(payload["audioFilePath"])
                    self.was_private = self.path.stat().st_mode & 0o777 == 0o600
                    raise replay.WorkerError("timeout")
            worker = Failure()
            with self.assertRaises(replay.WorkerError):
                replay.replay_case(worker, case, validated, duration, "model", "revision", [], None)
            self.assertTrue(worker.was_private)
            self.assertFalse(worker.path.exists())
            path.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                replay.audio_fixture(case, path.parent)


if __name__ == "__main__":
    unittest.main()
