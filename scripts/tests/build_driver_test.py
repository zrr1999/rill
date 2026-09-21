#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Behavioral checks for build ownership, invalidation and immutable receipts."""

from __future__ import annotations

import multiprocessing
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_driver as build


def try_lock(path, connection):
    with build.file_lock(Path(path), blocking=False) as acquired:
        connection.send(acquired)
    connection.close()


class BuildDriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        (self.root / "Package.swift").write_text("manifest")
        (self.root / ".gitignore").write_text(".build/\n.artifacts/\n")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.context = build.BuildContext(self.root, "release", build.RELEASE_ARGUMENTS)

    def test_clean_is_scoped_and_keeps_lock_outside_arena(self):
        debug = build.BuildContext(self.root, "debug", [])
        debug.scratch.mkdir()
        self.assertEqual(self.context.scratch, self.root / ".artifacts/build/release")
        self.context.scratch.mkdir(parents=True)
        sentinel = self.context.scratch / "worker"
        sentinel.write_text("release")
        with patch.object(build.subprocess, "run") as run:
            debug.clean()
        self.assertEqual(
            run.call_args.args[0],
            ["swift", "package", "--scratch-path", str(debug.scratch), "clean"],
        )
        self.assertEqual(sentinel.read_text(), "release")
        self.assertFalse(debug.lock_path.is_relative_to(debug.scratch))
        self.assertFalse(self.context.lock_path.is_relative_to(self.context.scratch))

    def test_unchanged_environment_does_not_clean(self):
        environment = {"toolchain": "one", "sourceRoot": str(self.root)}
        with (
            patch.object(self.context, "swift"),
            patch.object(self.context, "clean") as clean,
        ):
            self.context.build("build", [], environment)
            self.context.build("build", [], environment)
            clean.assert_not_called()
            self.context.build("build", [], {"toolchain": "two"})
            clean.assert_called_once()

    def test_product_and_filter_do_not_invalidate_environment(self):
        self.assertEqual(
            build.build_settings(["--product", "RillApp", "--filter", "OneTest"]), []
        )
        self.assertNotEqual(build.build_settings(["-Xswiftc", "-O"]), [])

    def test_swiftpm_metadata_after_clean_does_not_trigger_another_clean(self):
        self.context.scratch.mkdir(parents=True)
        for name in ("CACHEDIR.TAG", ".lock", ".buildSystem_debug"):
            (self.context.scratch / name).write_text("metadata")
        (self.context.scratch / "prebuilts").mkdir()
        with patch.object(self.context, "clean") as clean:
            self.context.prepare({})
            clean.assert_not_called()
            (self.context.scratch / "out").mkdir()
            self.context.prepare({})
            clean.assert_called_once()

    def test_stale_cache_retries_once_but_compile_error_does_not(self):
        with (
            patch.object(self.context, "prepare"),
            patch.object(self.context, "clean") as clean,
        ):
            with patch.object(
                self.context,
                "swift",
                side_effect=[
                    build.BuildFailure(1, "clang dependency scanning failure"),
                    "",
                ],
            ) as swift:
                self.context.build("build", [], {})
                self.assertEqual(swift.call_count, 2)
                clean.assert_called_once()
            clean.reset_mock()
            with patch.object(
                self.context, "swift", side_effect=build.BuildFailure(1, "type error")
            ):
                with self.assertRaises(build.BuildFailure):
                    self.context.build("build", [], {})
                clean.assert_not_called()

    def test_build_and_test_retain_locked_dependency_policy(self):
        with patch.object(build, "capture", return_value="") as capture:
            self.context.swift("test", ["--filter", "SomeTest"], quiet=True)
        command = capture.call_args.args[0]
        self.assertEqual(
            command[:5],
            [
                "swift",
                "test",
                "--force-resolved-versions",
                "-Xswiftc",
                "-warnings-as-errors",
            ],
        )
        self.assertIn("--scratch-path", command)

    def test_lock_blocks_second_process_and_release_recovers(self):
        receiver, sender = multiprocessing.Pipe(False)
        with self.context.lock():
            process = multiprocessing.Process(
                target=try_lock, args=(str(self.context.lock_path), sender)
            )
            process.start()
            self.assertTrue(receiver.poll(5))
            self.assertFalse(receiver.recv())
            process.join(5)
            self.assertEqual(process.exitcode, 0)
        with build.file_lock(self.context.lock_path, blocking=False) as acquired:
            self.assertTrue(acquired)

    def test_receipt_preserves_products_and_rejects_changed_inputs(self):
        output = self.context.scratch / "out/Products/Release"
        output.mkdir(parents=True)
        worker = output / "RillSpeechWorker"
        worker.write_text("original")
        worker.chmod(0o755)
        receipt_path = self.root / ".artifacts/receipt.json"
        build.make_receipt(
            self.context, output, receipt_path, build.source_inputs(self.root)
        )
        worker.write_text("concurrent rebuild")
        receipt = build.receipt_products(receipt_path, self.root)
        copied = Path(receipt["productsDirectory"]) / worker.name
        self.assertEqual(copied.read_text(), "original")
        copied.write_text("tampered")
        with self.assertRaisesRegex(build.BuildError, "products changed"):
            build.receipt_products(receipt_path, self.root)
        copied.write_text("original")
        (self.root / "new-source.swift").write_text("new code")
        with self.assertRaisesRegex(build.BuildError, "Source changed"):
            build.receipt_products(receipt_path, self.root)

    def test_source_inputs_cover_added_deleted_and_dirty_files(self):
        source = self.root / "code.swift"
        source.write_text("first")
        first = build.source_inputs(self.root)
        source.write_text("second")
        self.assertNotEqual(first, build.source_inputs(self.root))
        subprocess.run(["git", "-C", str(self.root), "add", "code.swift"], check=True)
        source.unlink()
        self.assertEqual(build.source_inputs(self.root)["code.swift"], "deleted")


if __name__ == "__main__":
    unittest.main()
