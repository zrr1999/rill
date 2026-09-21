#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Content identity and failure/ownership behavior of the shared worker cache."""

from __future__ import annotations
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_driver as build
import worker_artifact_cache as worker


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
                    "name": worker.WORKER,
                    "targets": [worker.WORKER],
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
                    "name": worker.WORKER,
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
        self.cache = worker.WorkerCache(self.root / "cache")
        self.output = self.root / "output"
        self.output.mkdir()
        executable = self.output / worker.WORKER
        executable.write_text("worker bytes")
        executable.chmod(0o755)
        for name in ("external_Crypto.bundle", "Sample_RillApp.bundle"):
            directory = self.output / name
            directory.mkdir()
            (directory / "data").write_text(name)

    def identity(self):
        return worker.input_identity(self.source, self.graph, self.environment)

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

    def test_identity_is_independent_of_checkout_path(self):
        import shutil

        other = self.root / "other-branch"
        shutil.copytree(self.source, other)
        self.assertEqual(
            self.identity(), worker.input_identity(other, self.graph, self.environment)
        )

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
        with self.assertRaises(worker.Uncacheable):
            self.identity()
        self.graph["targets"][0].pop("pluginUsages")
        (self.source / "Sources/Core/link.swift").symlink_to("Source.swift")
        with self.assertRaises(worker.Uncacheable):
            self.identity()

    def test_payload_includes_dependencies_and_excludes_app_resources(self):
        key = self.publish()
        payload = self.cache.read(key)
        self.assertTrue((payload / worker.WORKER).exists())
        self.assertTrue((payload / "external_Crypto.bundle/data").exists())
        self.assertFalse((payload / "Sample_RillApp.bundle").exists())

    def test_corrupt_incomplete_and_wrong_manifest_are_misses(self):
        key = self.publish()
        payload = self.cache.read(key)
        (payload / worker.WORKER).write_text("corrupt")
        self.assertIsNone(self.cache.read(key))
        key = self.publish()
        manifest = self.cache.entries / key / "manifest.json"
        manifest.write_text("[]")
        self.assertIsNone(self.cache.read(key))
        key = self.publish()
        manifest.unlink()
        self.assertIsNone(self.cache.read(key))
        self.assertEqual(self.cache.prune(0)["removed"], 1)

    def test_cleanup_includes_corrupt_entries_without_metadata(self):
        key = self.publish()
        (self.cache.entries / key / "used").unlink()
        (self.cache.entries / key / "manifest.json").unlink()
        self.assertEqual(self.cache.prune(0)["removed"], 1)
        (self.cache.entries / key).write_text("broken entry")
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

    def test_cleanup_removes_abandoned_pending_entries(self):
        key = build.digest(self.identity())
        pending = self.cache.entries / (".pending-" + key + "-interrupted")
        pending.mkdir()
        (pending / "partial").write_text("incomplete")
        with self.cache.lock(key):
            self.cache.prune(0)
            self.assertTrue(pending.exists())
        self.cache.prune(0)
        self.assertFalse(pending.exists())
        self.assertIsNone(self.cache.read(key))

    def test_manifest_key_cannot_redirect_cleanup(self):
        key = self.publish()
        manifest = self.cache.entries / key / "manifest.json"
        document = json.loads(manifest.read_text())
        document["key"] = "../output"
        manifest.write_text(json.dumps(document))
        self.assertIsNone(self.cache.read(key))
        self.cache.prune(0)
        self.assertTrue(self.output.exists())

    def test_new_runtime_products_remain_in_build_plan(self):
        self.graph["products"].append(
            {"name": "RillInputMethod", "type": {"executable": None}}
        )
        self.assertIn("RillInputMethod", worker.runtime_products(self.graph))


class ReleaseCacheIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = WorkerCacheTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.calls = []
        self.environment_patch = patch.dict(
            os.environ,
            {
                "RILL_BUILD_CACHE_DIR": str(self.fixture.cache.root),
                "CI": "false",
            },
        )
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)

    def run_release(self, *, mode="auto", source=None):
        fixture = self.fixture
        root = source or fixture.source
        result = fixture.root / ("receipt-" + root.name + ".json")

        def compile_product(context, subcommand, arguments, environment):
            self.calls.append(list(arguments))
            if "--product" in arguments:
                products = [arguments[arguments.index("--product") + 1]]
            else:
                products = worker.runtime_products(fixture.graph)
            for product in products:
                output = fixture.output / product
                output.write_text(product + " compiled")
                output.chmod(0o755)
            app_bundle = fixture.output / "Sample_RillApp.bundle" / "data"
            app_bundle.write_text((root / "Sources/RillApp/Source.swift").read_text())

        with (
            patch.object(build, "PROJECT", root),
            patch.object(build.BuildContext, "swift", return_value=str(fixture.output)),
            patch.object(
                build.BuildContext, "environment", return_value=fixture.environment
            ),
            patch.object(
                build.BuildContext, "build", autospec=True, side_effect=compile_product
            ),
            patch.object(build, "source_inputs", return_value={"source": "stable"}),
            patch.object(worker, "package_graph", return_value=fixture.graph),
            patch.object(worker, "verify_checkouts"),
            patch.object(build.subprocess, "run"),
        ):
            build.release(["--worker-cache", mode, "--result-file", str(result)])
        return json.loads(result.read_text())

    def test_cross_checkout_hit_builds_current_app_and_future_input_method(self):
        import shutil

        self.fixture.graph["products"].append(
            {"name": "RillInputMethod", "type": {"executable": None}}
        )
        first = self.run_release()
        self.assertEqual(first["workerCache"]["status"], "miss")
        other = self.fixture.root / "other"
        shutil.copytree(self.fixture.source, other)
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
            (directory / worker.WORKER).read_text(), "RillSpeechWorker compiled"
        )

    def test_clean_mode_never_uses_existing_worker_cache(self):
        self.run_release()
        self.calls.clear()
        result = self.run_release(mode="off")
        self.assertEqual(result["workerCache"]["status"], "off")
        self.assertEqual(
            self.calls,
            [
                [
                    "--build-system",
                    "swiftbuild",
                    "--manifest-cache",
                    "none",
                    "--configuration",
                    "release",
                    "--arch",
                    "arm64",
                ]
            ],
        )

    def test_source_drift_rejects_cache_publication(self):
        fixture = self.fixture
        with (
            patch.object(build, "PROJECT", fixture.source),
            patch.object(build.BuildContext, "swift", return_value=str(fixture.output)),
            patch.object(
                build.BuildContext, "environment", return_value=fixture.environment
            ),
            patch.object(build.BuildContext, "build"),
            patch.object(worker, "package_graph", return_value=fixture.graph),
            patch.object(
                build, "source_inputs", side_effect=[{"one": "a"}, {"one": "b"}]
            ),
        ):
            with self.assertRaisesRegex(build.BuildError, "Source changed"):
                build.release([])
        self.assertEqual(fixture.cache.status(), [])

    def test_resource_conflict_is_rejected(self):
        key = self.fixture.publish()
        payload = self.fixture.cache.read(key)
        (self.fixture.output / "external_Crypto.bundle/data").write_text(
            "conflicting output"
        )
        context = build.BuildContext(
            self.fixture.source, "release", build.RELEASE_ARGUMENTS
        )
        with self.assertRaisesRegex(build.BuildError, "Conflicting resource"):
            build.make_receipt(
                context,
                self.fixture.output,
                self.fixture.root / "bad.json",
                {},
                worker_products=payload,
            )


if __name__ == "__main__":
    unittest.main()
