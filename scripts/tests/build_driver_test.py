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

    def test_metal_remount_reuses_outputs_but_compiler_changes_invalidate_them(self):
        first_mount = self.root / "mount-one/metal"
        second_mount = self.root / "mount-two/metal"
        for compiler in (first_mount, second_mount):
            compiler.parent.mkdir()
            compiler.write_bytes(b"same metal compiler")

        def environment(compiler, version="Metal version one"):
            def capture(command, root):
                if command == ["xcrun", "-f", "metal"]:
                    return str(compiler)
                return "stable toolchain"

            result = subprocess.CompletedProcess(
                args=["xcrun", "metal", "-v"],
                returncode=0,
                stdout="",
                stderr=f"{version}\nInstalledDir: {compiler.parent}\n",
            )
            with (
                patch.object(build, "capture", side_effect=capture),
                patch.object(build.subprocess, "run", return_value=result),
            ):
                return self.context.environment()

        with (
            patch.object(self.context, "swift"),
            patch.object(self.context, "clean") as clean,
        ):
            self.context.build("build", [], environment(first_mount))
            product = self.context.scratch / "built-product"
            product.write_bytes(b"compiled output")
            self.context.build("build", [], environment(second_mount))
            clean.assert_not_called()
            self.assertEqual(product.read_bytes(), b"compiled output")

            second_mount.write_bytes(b"changed metal compiler")
            self.context.build("build", [], environment(second_mount))
            self.assertEqual(clean.call_count, 1)
            self.context.build(
                "build", [], environment(second_mount, "Metal version two")
            )
            self.assertEqual(clean.call_count, 2)

    def test_stale_cache_retries_once_but_compile_error_does_not(self):
        with (
            patch.object(self.context, "prepare"),
            patch.object(self.context, "clean") as clean,
        ):
            with patch.object(
                self.context,
                "swift",
                side_effect=[
                    build.BuildFailure("build", 1, "clang dependency scanning failure"),
                    "",
                ],
            ) as swift:
                self.context.build("build", [], {})
                self.assertEqual(swift.call_count, 2)
                clean.assert_called_once()
            clean.reset_mock()
            with patch.object(
                self.context, "swift", side_effect=build.BuildFailure("build", 1, "type error")
            ):
                with self.assertRaises(build.BuildFailure):
                    self.context.build("build", [], {})
                clean.assert_not_called()

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
        app = output / "RillApp"
        app.write_text("app")
        app.chmod(0o755)
        receipt_path = self.root / ".artifacts/receipt.json"
        with self.assertRaisesRegex(build.BuildError, "App Intents compiler metadata"):
            build.make_receipt(
                self.context, output, receipt_path, build.source_inputs(self.root)
            )
        metadata_root = self.context.scratch / "out/Intermediates.noindex/RillMacOS.build"
        metadata_relative = Path("RillApp-product.build/Objects-normal/arm64/RillApp-primary.swiftconstvalues")
        metadata = metadata_root / "Release" / metadata_relative
        debug_metadata = metadata_root / "Debug" / metadata_relative
        test_metadata = metadata_root / "Release/RillApp-testable-t.build/Objects-normal/arm64" / metadata.name
        legacy_test_metadata = metadata_root / "Release/RillApp-1234-testable.build/Objects-normal/arm64" / metadata.name
        for path, content in (
            (metadata, "release"), (debug_metadata, "debug"),
            (test_metadata, "test"), (legacy_test_metadata, "legacy test"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        extra_metadata = metadata.with_name("Other.swiftconstvalues")
        extra_metadata.write_text("other release values")
        build.make_receipt(
            self.context, output, receipt_path, build.source_inputs(self.root)
        )
        worker.write_text("concurrent rebuild")
        metadata.write_text("concurrent metadata")
        receipt = build.receipt_products(receipt_path, self.root)
        receipt_link = receipt_path.with_name("receipt-link.json")
        receipt_link.symlink_to(receipt_path)
        self.assertEqual(build.receipt_products(receipt_link, self.root), receipt)
        copied_metadata = Path(receipt["productsDirectory"]) / metadata.name
        self.assertEqual(copied_metadata.read_text(), "release")
        self.assertEqual(
            (Path(receipt["productsDirectory"]) / extra_metadata.name).read_text(),
            "other release values",
        )
        copied = Path(receipt["productsDirectory"]) / worker.name
        self.assertEqual(copied.read_text(), "original")
        copied.write_text("tampered")
        with self.assertRaisesRegex(build.BuildError, "products changed"):
            build.receipt_products(receipt_path, self.root)
        copied.write_text("original")
        copied_metadata.write_text("tampered")
        with self.assertRaisesRegex(build.BuildError, "products changed"):
            build.receipt_products(receipt_path, self.root)
        copied_metadata.write_text("release")
        (self.root / "new-source.swift").write_text("new code")
        with self.assertRaisesRegex(build.BuildError, "Source changed"):
            build.receipt_products(receipt_path, self.root)

if __name__ == "__main__":
    unittest.main()
