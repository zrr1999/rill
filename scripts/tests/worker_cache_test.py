#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Content identity and failure/ownership behavior of the shared worker cache."""

from __future__ import annotations
import json
import os
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_driver as build


class WorkerCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "Package.swift").write_text("manifest")
        (self.source / "Package.resolved").write_text("locked")
        self.graph = {
            "name": "Sample",
            "dependencies": [],
            "products": [
                {
                    "name": build.WORKER,
                    "targets": [build.WORKER],
                    "type": {"executable": None},
                },
                {
                    "name": "RillApp",
                    "targets": ["RillApp"],
                    "type": {"executable": None},
                },
            ],
            "targets": [
                {
                    "name": build.WORKER,
                    "type": "executable",
                    "dependencies": [{"byName": ["Core", None]}],
                },
                {"name": "Core", "type": "regular", "dependencies": []},
                {"name": "RillApp", "type": "executable", "dependencies": []},
            ],
        }
        for target in self.graph["targets"]:
            directory = self.source / "Sources" / target["name"]
            directory.mkdir(parents=True)
            (directory / "Source.swift").write_text(target["name"])
        self.environment = {
            "toolchain": {"swift": "6.4", "metal": "one"},
            "configuration": "release",
            "settings": ["--arch", "arm64"],
        }
        self.cache = build.WorkerCache(self.root / "cache")
        self.output = self.root / "out/Products/Release"
        self.output.mkdir(parents=True)
        self.calls = []
        self.enterContext(patch.dict(os.environ, {
            "RILL_BUILD_CACHE_DIR": str(self.cache.root),
            "CI": "false",
        }))
        executable = self.output / build.WORKER
        executable.write_text("worker bytes")
        executable.chmod(0o755)
        for name in ("external_Crypto.bundle", "Sample_RillApp.bundle"):
            directory = self.output / name
            directory.mkdir()
            (directory / "data").write_text(name)

    def identity(self):
        return build.input_identity(self.source, self.graph, self.environment)

    def publish(self):
        identity = self.identity()
        key = build.digest(identity)
        with self.cache.lock(key):
            self.cache.publish(key, self.output, identity, self.graph)
        return key

    def test_app_changes_do_not_invalidate_worker(self):
        before = self.identity()
        (self.source / "Sources/RillApp/Source.swift").write_text("new UI")
        self.assertEqual(before, self.identity())
        (self.source / "Sources/Core/New.swift").write_text("new core")
        self.assertNotEqual(before, self.identity())
        (self.source / "Sources/Core/New.swift").unlink()
        self.assertEqual(before, self.identity())
        (self.source / "Sources/Core/Source.swift").unlink()
        self.assertNotEqual(before, self.identity())

    def test_toolchain_lock_and_flags_invalidate(self):
        before = self.identity()
        self.environment["toolchain"]["metal"] = "two"
        self.assertNotEqual(before, self.identity())
        self.environment["toolchain"]["metal"] = "one"
        self.environment["settings"] += ["-Xswiftc", "-Osize"]
        self.assertNotEqual(before, self.identity())
        self.environment["settings"] = ["--arch", "arm64"]
        (self.source / "Package.resolved").write_text("new lock")
        self.assertNotEqual(before, self.identity())

    def test_unknown_inputs_bypass_cache(self):
        self.graph["targets"][0]["pluginUsages"] = ["generator"]
        with self.assertRaises(build.Uncacheable):
            self.identity()
        self.graph["targets"][0].pop("pluginUsages")
        (self.source / "Sources/Core/link.swift").symlink_to("Source.swift")
        with self.assertRaises(build.Uncacheable):
            self.identity()

    def test_untracked_compiler_inputs_bypass_cache(self):
        self.environment["toolchain"]["untrackedCompilerInputs"] = "true"
        with self.assertRaises(build.Uncacheable):
            self.identity()
        self.environment["toolchain"].pop("untrackedCompilerInputs")
        self.graph["targets"][0]["settings"] = [
            {"data": {"name": "unsafeFlags", "value": ["-include", "/tmp/header.h"]}}
        ]
        with self.assertRaises(build.Uncacheable):
            self.identity()

    def test_corrupt_incomplete_and_wrong_manifest_are_misses(self):
        key = self.publish()
        payload = self.cache.read(key)
        (payload / build.WORKER).write_text("corrupt")
        self.assertIsNone(self.cache.read(key))
        key = self.publish()
        manifest = self.cache.entries / key / "manifest.json"
        manifest.write_text("[]")
        self.assertIsNone(self.cache.read(key))
        key = self.publish()
        manifest.unlink()
        self.assertIsNone(self.cache.read(key))
        self.assertEqual(self.cache.prune(0)["removed"], 1)

    def test_cleanup_skips_active_entry(self):
        key = self.publish()
        with self.cache.lock(key):
            result = self.cache.prune(0)
            self.assertEqual(result["busy"], 1)
            self.assertIsNotNone(self.cache.read(key))
        self.assertEqual(self.cache.prune(0)["removed"], 1)
        self.assertIsNone(self.cache.read(key))

    def test_failed_publish_never_replaces_good_entry(self):
        key = self.publish()
        (self.output / "external_Crypto.bundle/bad").symlink_to("/does-not-exist")
        with self.assertRaises(build.BuildError):
            self.cache.publish(key, self.output, self.identity(), self.graph)
        self.assertIsNotNone(self.cache.read(key))
        self.assertFalse(list(self.cache.entries.glob(".pending-*")))

    def run_release(self, *, source=None):
        root = source or self.source
        result = self.root / ("receipt-" + root.name + ".json")

        def compile_product(context, subcommand, arguments, environment):
            self.calls.append(list(arguments))
            if "--product" in arguments:
                products = [arguments[arguments.index("--product") + 1]]
            else:
                products = build.runtime_products(self.graph)
            for product in products:
                output = self.output / product
                output.write_text(product + " compiled")
                output.chmod(0o755)
            app_bundle = self.output / "Sample_RillApp.bundle" / "data"
            app_bundle.write_text((root / "Sources/RillApp/Source.swift").read_text())
            if "RillApp" in products:
                metadata = self.output.parents[1] / "Intermediates.noindex/Sample.build/Release/RillApp-p.build/Objects-normal/arm64/RillApp-primary.swiftconstvalues"
                metadata.parent.mkdir(parents=True, exist_ok=True)
                metadata.write_text(app_bundle.read_text())

        with (
            patch.object(build, "PROJECT", root),
            patch.object(build.BuildContext, "swift", return_value=str(self.output)),
            patch.object(
                build.BuildContext, "environment", return_value=self.environment
            ),
            patch.object(
                build.BuildContext, "build", autospec=True, side_effect=compile_product
            ),
            patch.object(build, "source_inputs", return_value={"source": "stable"}),
            patch.object(build, "package_graph", return_value=self.graph),
            patch.object(build, "verify_checkouts"),
            patch.object(build.subprocess, "run"),
        ):
            build.release(["--worker-cache", "auto", "--result-file", str(result)])
        return json.loads(result.read_text())

    def test_cross_checkout_hit_builds_current_app_and_future_input_method(self):
        self.graph["products"].append(
            {"name": "RillInputMethod", "type": {"executable": None}}
        )
        first = self.run_release()
        self.assertEqual(first["workerCache"]["status"], "miss")
        other = self.root / "other"
        shutil.copytree(self.source, other)
        (other / "Sources/RillApp/Source.swift").write_text("new branch UI")
        self.calls.clear()
        second = self.run_release(source=other)
        self.assertEqual(second["workerCache"]["status"], "hit")
        products = [args[args.index("--product") + 1] for args in self.calls]
        self.assertEqual(products, ["RillApp", "RillInputMethod"])
        directory = Path(second["productsDirectory"])
        self.assertEqual(
            (directory / "Sample_RillApp.bundle/data").read_text(), "new branch UI"
        )
        self.assertEqual(
            (directory / "RillApp-primary.swiftconstvalues").read_text(), "new branch UI"
        )
        self.assertEqual(
            (directory / build.WORKER).read_text(), "RillSpeechWorker compiled"
        )

    def test_source_drift_rejects_cache_publication(self):
        with (
            patch.object(build, "PROJECT", self.source),
            patch.object(build.BuildContext, "swift", return_value=str(self.output)),
            patch.object(
                build.BuildContext, "environment", return_value=self.environment
            ),
            patch.object(build.BuildContext, "build"),
            patch.object(build, "package_graph", return_value=self.graph),
            patch.object(
                build, "source_inputs", side_effect=[{"one": "a"}, {"one": "b"}]
            ),
        ):
            with self.assertRaisesRegex(build.BuildError, "Source changed"):
                build.release([])
        self.assertEqual(self.cache.status(), [])


if __name__ == "__main__":
    unittest.main()
