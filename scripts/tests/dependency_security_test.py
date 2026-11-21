#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from __future__ import annotations

import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SCRIPTS_DIR.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPTS_DIR))

import check_dependency_security as security  # noqa: E402


REVISION_A = "a" * 40
REVISION_B = "b" * 40


def lock_payload(*pins: tuple[str, str, str]) -> dict[str, object]:
    return {
        "originHash": "c" * 64,
        "pins": [
            {
                "identity": identity,
                "kind": "remoteSourceControl",
                "location": f"https://github.com/example/{identity}.git",
                "state": {"revision": revision, "version": version},
            }
            for identity, version, revision in pins
        ],
        "version": 3,
    }


def baseline_payload() -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "reviewedAt": "2026-07-01T00:00:00Z",
        "expiresAt": "2026-09-29T00:00:00Z",
        "reviewedAdvisories": [
            {
                "id": "CVE-2026-28815",
                "packageIdentity": "swift-crypto",
                "introduced": "4.0.0",
                "fixed": "4.3.1",
                "source": (
                    "https://github.com/apple/swift-crypto/security/advisories/"
                    "GHSA-9m44-rr2w-ppp7"
                ),
            }
        ],
    }


def empty_policy_payload() -> dict[str, Any]:
    payload = baseline_payload()
    payload["reviewedAdvisories"] = []
    return payload


class DependencySecurityTests(unittest.TestCase):
    def parse_pins(self, *pins: tuple[str, str, str]) -> tuple[security.LockedPin, ...]:
        return security.parse_lockfile(lock_payload(*pins))

    def test_current_repository_passes_reviewed_baseline(self) -> None:
        pins = security.load_lockfile(PROJECT_DIR / "Package.resolved")
        policy = security.load_security_policy(
            SCRIPTS_DIR / "dependency_security_baseline.json"
        )
        security.validate_policy_freshness(policy)
        self.assertEqual(security.scan_offline_baseline(pins, policy.advisories), ())
        self.assertTrue(pins)

    def test_absent_lockfile_and_empty_inventories_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "Package.resolved"
            with self.assertRaisesRegex(security.DependencySecurityError, "cannot read"):
                security.load_lockfile(missing)
        with self.assertRaisesRegex(security.DependencySecurityError, "non-empty"):
            security.parse_lockfile(lock_payload())
        self.assertEqual(security.parse_baseline(empty_policy_payload()), ())

    def test_reviewed_advisory_affected_and_fixed_boundaries(self) -> None:
        advisories = security.parse_baseline(baseline_payload())
        cases = {
            "3.9.9": False,
            "4.0.0": True,
            "4.3.0": True,
            "4.3.1": False,
            "5.0.0": False,
        }
        for version, expected_affected in cases.items():
            with self.subTest(version=version):
                pins = self.parse_pins(("swift-crypto", version, REVISION_A))
                findings = security.scan_offline_baseline(pins, advisories)
                self.assertEqual(bool(findings), expected_affected)

    def test_offline_scan_rejects_advisory_for_unknown_package_identity(self) -> None:
        baseline = baseline_payload()
        baseline["reviewedAdvisories"].append(
            {
                "id": "CVE-2026-99999",
                "packageIdentity": "swift-crpyto",
                "introduced": "1.0.0",
                "fixed": "1.0.1",
                "source": "https://example.invalid/advisory",
            }
        )
        pins = self.parse_pins(("swift-crypto", "4.3.1", REVISION_A))
        advisories = security.parse_baseline(baseline)

        with self.assertRaisesRegex(
            security.DependencySecurityError,
            "not present in Package.resolved: swift-crpyto",
        ):
            security.scan_offline_baseline(pins, advisories)

    def test_semantic_version_rejects_non_stable_or_noncanonical_values(self) -> None:
        for value in ("4.3", "4.3.1-beta.1", "04.3.1", "4.03.1", 431):
            with self.subTest(value=value):
                with self.assertRaises(security.DependencySecurityError):
                    security.SemanticVersion.parse(value, field="test.version")

    def test_json_and_lockfile_reject_malformed_or_duplicate_input(self) -> None:
        with self.assertRaisesRegex(security.DependencySecurityError, "duplicate key"):
            security.decode_json('{"pins": [], "pins": []}', source="fixture")

        duplicate_identity = lock_payload(
            ("swift-crypto", "4.3.1", REVISION_A),
            ("swift-crypto", "4.3.1", REVISION_B),
        )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "duplicate identity"
        ):
            security.parse_lockfile(duplicate_identity)

        malformed_revision = lock_payload(("swift-crypto", "4.3.1", "not-a-revision"))
        with self.assertRaisesRegex(security.DependencySecurityError, "Git hash"):
            security.parse_lockfile(malformed_revision)

    def test_baseline_rejects_duplicate_or_malformed_policy(self) -> None:
        duplicate = baseline_payload()
        duplicate["reviewedAdvisories"].append(
            copy.deepcopy(duplicate["reviewedAdvisories"][0])
        )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "duplicates CVE-2026-28815"
        ):
            security.parse_baseline(duplicate)

        wrong_type = baseline_payload()
        wrong_type["schemaVersion"] = True
        with self.assertRaisesRegex(
            security.DependencySecurityError, "must be an integer"
        ):
            security.parse_baseline(wrong_type)

    def test_review_freshness_rejects_future_expired_and_overlong_windows(self) -> None:
        policy = security.parse_security_policy(empty_policy_payload())
        with self.assertRaisesRegex(
            security.DependencySecurityError, "reviewedAt is in the future"
        ):
            security.validate_policy_freshness(
                policy, now=datetime(2026, 6, 30, tzinfo=timezone.utc)
            )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "review has expired"
        ):
            security.validate_policy_freshness(
                policy, now=datetime(2026, 9, 29, tzinfo=timezone.utc)
            )

        overlong = empty_policy_payload()
        overlong["expiresAt"] = "2026-09-30T00:00:01Z"
        with self.assertRaisesRegex(
            security.DependencySecurityError, "review window exceeds 90 days"
        ):
            security.parse_security_policy(overlong)

    def test_legacy_schema_is_rejected(self) -> None:
        legacy = {"schemaVersion": 1, "reviewedAdvisories": []}
        with self.assertRaisesRegex(
            security.DependencySecurityError, "schemaVersion must be 2"
        ):
            security.parse_security_policy(legacy)

    def test_json_file_loader_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            target = root / "target.json"
            target.write_text("{}", encoding="utf-8")
            link = root / "link.json"
            link.symlink_to(target)

            with self.assertRaises(security.DependencySecurityError):
                security.load_json_file(link, label="fixture")

    def test_json_file_loader_rejects_oversized_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.json"
            path.write_text('{"value": "too long"}')
            with mock.patch.object(security, "MAX_JSON_BYTES", 8):
                with self.assertRaisesRegex(security.DependencySecurityError, "byte limit"):
                    security.load_json_file(path, label="fixture")

    def test_command_rejects_a_fifo_without_waiting_for_a_writer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("check_dependency_security.py", "file_input.py"):
                shutil.copy2(SCRIPTS_DIR / name, scripts / name)
            path = root / "Package.resolved"
            os.mkfifo(path)
            result = subprocess.run(
                [sys.executable, str(scripts / "check_dependency_security.py")],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("regular file", result.stderr)

    def test_commit_inventory_preserves_exact_revisions(self) -> None:
        pins = self.parse_pins(
            ("first-package", "1.0.0", REVISION_A),
            ("second-package", "2.0.0", REVISION_B),
        )
        self.assertEqual(
            security.commit_inventory(pins),
            {
                "results": [
                    {
                        "packages": [
                            {"package": {"name": "first-package", "commit": REVISION_A}},
                            {"package": {"name": "second-package", "commit": REVISION_B}},
                        ]
                    }
                ]
            },
        )

    def test_scanner_report_must_cover_each_source_and_coordinate(self) -> None:
        expected = {
            Path("/scan/swift-commits.json"): {("GIT", "first-package", REVISION_A)},
            Path("/scan/Package.resolved"): {("SwiftURL", "github.com/a/b", "1.0.0")},
            Path("/scan/uv.lock"): {("PyPI", "click", "8.0.0")},
        }
        complete = {
            "results": [
                {
                    "source": {"path": str(path)},
                    "packages": [
                        {"package": {
                            "ecosystem": ecosystem,
                            "name": name,
                            ("commit" if ecosystem == "GIT" else "version"): value,
                        }}
                        for ecosystem, name, value in coordinates
                    ],
                }
                for path, coordinates in expected.items()
            ]
        }
        security.verify_scanner_inventory(complete, expected)
        for i in range(len(complete["results"])):
            with self.subTest(source=i):
                partial = copy.deepcopy(complete)
                del partial["results"][i]
                with self.assertRaisesRegex(security.DependencySecurityError, "incomplete"):
                    security.verify_scanner_inventory(partial, expected)
        incomplete = copy.deepcopy(complete)
        incomplete["results"][0]["packages"][0]["package"]["commit"] = REVISION_B
        with self.assertRaisesRegex(security.DependencySecurityError, "incomplete"):
            security.verify_scanner_inventory(incomplete, expected)
        del incomplete["results"][0]["packages"][0]["package"]["commit"]
        with self.assertRaisesRegex(security.DependencySecurityError, "malformed"):
            security.verify_scanner_inventory(incomplete, expected)

    def test_offline_command_never_invokes_live_transport(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            lock = root / "Package.resolved"
            lock.write_text(json.dumps(lock_payload(("demo", "1.0.0", REVISION_A))))
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps(empty_policy_payload()), encoding="utf-8")
            with (
                mock.patch.object(security, "DEFAULT_LOCKFILE", lock),
                mock.patch.object(security, "DEFAULT_BASELINE", baseline),
                mock.patch.object(security, "scan_live_osv") as live_scan,
                mock.patch.object(
                    security, "validate_policy_freshness"
                ) as freshness_check,
                redirect_stdout(io.StringIO()),
            ):
                result = security.main([])

        self.assertEqual(result, 0)
        freshness_check.assert_called_once()
        live_scan.assert_not_called()

    def test_command_rejects_repository_input_overrides(self) -> None:
        for option in ("--lockfile", "--baseline"):
            with self.subTest(option=option), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    security.main([option, "/another-checkout/input.json"])
                self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
