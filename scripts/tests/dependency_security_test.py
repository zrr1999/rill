#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from __future__ import annotations

import copy
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
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
        self.assertEqual(len(pins), 35)
        self.assertTrue(
            {
                "mlx-audio-swift",
                "mlx-swift",
                "openai",
                "swift-huggingface",
                "swift-openapi-runtime",
                "swift-toml",
                "swift-xet",
            }.issubset({pin.identity for pin in pins})
        )
        self.assertEqual(policy.advisories, ())

    def test_absent_lockfile_and_empty_inventories_are_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "Package.resolved"
            self.assertEqual(security.load_lockfile(missing), ())
        self.assertEqual(security.parse_lockfile(lock_payload()), ())
        empty_baseline = empty_policy_payload()
        self.assertEqual(security.parse_baseline(empty_baseline), ())
        self.assertEqual(security.scan_live_osv((), transport=lambda _: {}), ())

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

    def test_live_response_maps_to_lock_order_and_any_advisory_is_a_finding(
        self,
    ) -> None:
        pins = self.parse_pins(
            ("first-package", "1.0.0", REVISION_A),
            ("second-package", "2.0.0", REVISION_B),
        )
        requests: list[dict[str, object]] = []

        def transport(payload: dict[str, object]) -> object:
            requests.append(payload)
            return {
                "results": [
                    {},
                    {
                        "vulns": [
                            {
                                "id": "GHSA-abcd-1234-efgh",
                                "modified": "2026-07-13T00:00:00Z",
                            }
                        ]
                    },
                ]
            }

        findings = security.scan_live_osv(pins, transport=transport)

        self.assertEqual(
            requests,
            [{"queries": [{"commit": REVISION_A}, {"commit": REVISION_B}]}],
        )
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].pin.identity, "second-package")
        self.assertEqual(findings[0].advisory_id, "GHSA-abcd-1234-efgh")

    def test_offline_command_never_invokes_live_transport(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = root / "baseline.json"
            baseline.write_text(json.dumps(empty_policy_payload()), encoding="utf-8")
            with (
                mock.patch.object(security, "scan_live_osv") as live_scan,
                mock.patch.object(
                    security, "validate_policy_freshness"
                ) as freshness_check,
                redirect_stdout(io.StringIO()),
            ):
                result = security.main(
                    [
                        "--lockfile",
                        str(root / "missing-Package.resolved"),
                        "--baseline",
                        str(baseline),
                    ]
                )

        self.assertEqual(result, 0)
        freshness_check.assert_called_once()
        live_scan.assert_not_called()

    def test_live_pagination_only_requeries_results_with_tokens(self) -> None:
        pins = self.parse_pins(
            ("first-package", "1.0.0", REVISION_A),
            ("second-package", "2.0.0", REVISION_B),
        )
        requests: list[dict[str, object]] = []
        responses = iter(
            [
                {"results": [{"next_page_token": "page-two"}, {}]},
                {"results": [{}]},
            ]
        )

        def transport(payload: dict[str, object]) -> object:
            requests.append(payload)
            return next(responses)

        self.assertEqual(security.scan_live_osv(pins, transport=transport), ())
        self.assertEqual(
            requests,
            [
                {"queries": [{"commit": REVISION_A}, {"commit": REVISION_B}]},
                {"queries": [{"commit": REVISION_A, "page_token": "page-two"}]},
            ],
        )

    def test_live_rejects_repeated_tokens_and_duplicate_advisories_across_pages(
        self,
    ) -> None:
        pins = self.parse_pins(("first-package", "1.0.0", REVISION_A))

        repeated_token_responses = iter(
            [
                {"results": [{"next_page_token": "same"}]},
                {"results": [{"next_page_token": "same"}]},
            ]
        )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "repeated a page token"
        ):
            security.scan_live_osv(
                pins, transport=lambda _: next(repeated_token_responses)
            )

        advisory = {
            "id": "CVE-2026-00001",
            "modified": "2026-07-13T00:00:00.123456Z",
        }
        duplicate_advisory_responses = iter(
            [
                {"results": [{"vulns": [advisory], "next_page_token": "next"}]},
                {"results": [{"vulns": [advisory]}]},
            ]
        )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "duplicate advisory"
        ):
            security.scan_live_osv(
                pins, transport=lambda _: next(duplicate_advisory_responses)
            )

    def test_live_pagination_cap_includes_the_initial_response(self) -> None:
        pins = self.parse_pins(("first-package", "1.0.0", REVISION_A))
        call_count = 0

        def transport(_: dict[str, object]) -> object:
            nonlocal call_count
            call_count += 1
            return {"results": [{"next_page_token": f"page-{call_count + 1}"}]}

        with self.assertRaisesRegex(
            security.DependencySecurityError,
            f"pagination exceeded {security.MAX_PAGES_PER_QUERY} pages",
        ):
            security.scan_live_osv(pins, transport=transport)

        self.assertEqual(call_count, security.MAX_PAGES_PER_QUERY)

    def test_live_rejects_malformed_response_shapes(self) -> None:
        pins = self.parse_pins(("first-package", "1.0.0", REVISION_A))
        malformed_responses = [
            {},
            {"results": []},
            {"results": [{"unexpected": True}]},
            {"results": [{"vulns": "not-an-array"}]},
            {
                "results": [
                    {
                        "vulns": [
                            {
                                "id": "CVE-2026-00001",
                                "modified": "not-a-timestamp",
                            }
                        ]
                    }
                ]
            },
        ]
        for response in malformed_responses:
            with self.subTest(response=response):
                with self.assertRaises(security.DependencySecurityError):
                    security.scan_live_osv(pins, transport=lambda _: response)

        two_pins = self.parse_pins(
            ("first-package", "1.0.0", REVISION_A),
            ("second-package", "2.0.0", REVISION_B),
        )
        with self.assertRaisesRegex(
            security.DependencySecurityError, "same next_page_token"
        ):
            security.scan_live_osv(
                two_pins,
                transport=lambda _: {
                    "results": [
                        {"next_page_token": "duplicate"},
                        {"next_page_token": "duplicate"},
                    ]
                },
            )

    def test_live_network_failure_is_fail_closed(self) -> None:
        pins = self.parse_pins(("first-package", "1.0.0", REVISION_A))

        def failing_transport(_: dict[str, object]) -> object:
            raise OSError("network unavailable")

        with self.assertRaisesRegex(
            security.DependencySecurityError, "network request failed"
        ):
            security.scan_live_osv(pins, transport=failing_transport)

    def test_repository_python_scripts_use_uv_inline_metadata(self) -> None:
        expected_header = (
            "#!/usr/bin/env -S uv run --script\n"
            "# /// script\n"
            '# requires-python = ">=3.11"\n'
            "# dependencies = []\n"
            "# ///\n"
        )
        script_paths = sorted(SCRIPTS_DIR.glob("*.py")) + sorted(
            (SCRIPTS_DIR / "tests").glob("*.py")
        )
        self.assertTrue(script_paths)
        for script_path in script_paths:
            with self.subTest(script=script_path.relative_to(PROJECT_DIR)):
                self.assertTrue(
                    script_path.read_text(encoding="utf-8").startswith(expected_header)
                )

if __name__ == "__main__":
    unittest.main()
