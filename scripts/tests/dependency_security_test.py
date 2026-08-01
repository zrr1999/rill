#!/usr/bin/env python3

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
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parent.parent
PROJECT_DIR = SCRIPTS_DIR.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(SCRIPTS_DIR))

import check_dependency_security as security  # noqa: E402


REVISION_A = "a" * 40
REVISION_B = "b" * 40
FIXED_KISSFFT_REVISION = security.REQUIRED_KISSFFT_REVISION


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


def baseline_payload() -> dict[str, object]:
    return {
        "schemaVersion": 1,
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


def vendored_manifest_payload() -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "packages": [
            {
                "kind": "vendored",
                "identity": "kissfft",
                "version": FIXED_KISSFFT_REVISION,
                "source": (
                    "https://github.com/mborgerding/kissfft/archive/"
                    f"{FIXED_KISSFFT_REVISION}.zip"
                ),
                "sourceSHA256": "d" * 64,
            },
            {
                "kind": "vendored",
                "identity": "onnxruntime",
                "version": "1.27.0",
                "source": (
                    "https://github.com/example/onnxruntime-libs/releases/download/"
                    "v1.27.0/runtime.zip"
                ),
                "sourceSHA256": "e" * 64,
            },
        ],
    }


def security_policy_payload() -> dict[str, object]:
    manifest = vendored_manifest_payload()
    kissfft, onnxruntime = manifest["packages"]
    return {
        "schemaVersion": 2,
        "reviewedAt": "2026-07-01T00:00:00Z",
        "expiresAt": "2026-09-29T00:00:00Z",
        "reviewedAdvisories": [],
        "vendoredDependencies": [
            {
                "identity": kissfft["identity"],
                "source": kissfft["source"],
                "sourceSHA256": kissfft["sourceSHA256"],
                "osv": {
                    "mode": "commit",
                    "repository": "https://github.com/mborgerding/kissfft",
                    "revision": FIXED_KISSFFT_REVISION,
                },
            },
            {
                "identity": onnxruntime["identity"],
                "source": onnxruntime["source"],
                "sourceSHA256": onnxruntime["sourceSHA256"],
                "osv": {
                    "mode": "unsupported",
                    "reason": "No verifiable source commit mapping for this binary.",
                },
            },
        ],
    }


class DependencySecurityTests(unittest.TestCase):
    def parse_pins(self, *pins: tuple[str, str, str]) -> tuple[security.LockedPin, ...]:
        return security.parse_lockfile(lock_payload(*pins))

    def test_current_repository_passes_reviewed_baseline(self) -> None:
        pins = security.load_lockfile(PROJECT_DIR / "Package.resolved")
        policy = security.load_security_policy(
            SCRIPTS_DIR / "dependency_security_baseline.json"
        )
        manifest = security.load_vendored_manifest(
            SCRIPTS_DIR / "third_party_notices_manifest.json"
        )

        security.validate_policy_freshness(policy)
        commits, unsupported = security.validate_vendored_inventory(
            manifest, policy.vendored_reviews
        )
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
        self.assertEqual(len(commits), 9)
        self.assertEqual(
            [review.identity for review in unsupported],
            ["onnxruntime", "silero-vad"],
        )
        silero = next(
            review for review in unsupported if review.identity == "silero-vad"
        )
        self.assertIn("standalone model release asset", silero.unsupported_reason)
        kissfft = next(pin for pin in commits if pin.identity == "kissfft")
        self.assertEqual(kissfft.revision, FIXED_KISSFFT_REVISION)

    def test_absent_lockfile_and_empty_inventories_are_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            missing = Path(temporary_directory) / "Package.resolved"
            self.assertEqual(security.load_lockfile(missing), ())
        self.assertEqual(security.parse_lockfile(lock_payload()), ())
        empty_baseline = {"schemaVersion": 1, "reviewedAdvisories": []}
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

    def test_vendored_policy_is_exact_and_exposes_only_reviewed_commits(self) -> None:
        manifest = security.parse_vendored_manifest(vendored_manifest_payload())
        policy = security.parse_security_policy(security_policy_payload())

        security.validate_policy_freshness(
            policy, now=datetime(2026, 7, 18, tzinfo=timezone.utc)
        )
        commits, unsupported = security.validate_vendored_inventory(
            manifest, policy.vendored_reviews
        )

        self.assertEqual(
            commits,
            (
                security.VendoredCommitPin(
                    "kissfft",
                    "https://github.com/mborgerding/kissfft",
                    FIXED_KISSFFT_REVISION,
                    FIXED_KISSFFT_REVISION,
                ),
            ),
        )
        self.assertEqual([review.identity for review in unsupported], ["onnxruntime"])
        self.assertIn("No verifiable source commit", unsupported[0].unsupported_reason)

    def test_vendored_inventory_rejects_drift_missing_and_extra_reviews(self) -> None:
        manifest_payload = vendored_manifest_payload()
        manifest = security.parse_vendored_manifest(manifest_payload)

        drifted = security_policy_payload()
        drifted["vendoredDependencies"][0]["sourceSHA256"] = "f" * 64
        drifted_policy = security.parse_security_policy(drifted)
        with self.assertRaisesRegex(
            security.DependencySecurityError, "source SHA-256 mismatch for kissfft"
        ):
            security.validate_vendored_inventory(
                manifest, drifted_policy.vendored_reviews
            )

        missing = security_policy_payload()
        missing["vendoredDependencies"].pop()
        missing_policy = security.parse_security_policy(missing)
        with self.assertRaisesRegex(
            security.DependencySecurityError, "missing reviews for onnxruntime"
        ):
            security.validate_vendored_inventory(
                manifest, missing_policy.vendored_reviews
            )

        extra = security_policy_payload()
        extra_review = copy.deepcopy(extra["vendoredDependencies"][1])
        extra_review["identity"] = "unshipped-library"
        extra["vendoredDependencies"].append(extra_review)
        extra_policy = security.parse_security_policy(extra)
        with self.assertRaisesRegex(
            security.DependencySecurityError, "reviews absent from manifest"
        ):
            security.validate_vendored_inventory(manifest, extra_policy.vendored_reviews)

    def test_git_archives_cannot_be_declared_osv_unsupported(self) -> None:
        policy_payload = security_policy_payload()
        policy_payload["vendoredDependencies"][0]["osv"] = {
            "mode": "unsupported",
            "reason": "Would hide a source commit.",
        }
        policy = security.parse_security_policy(policy_payload)
        manifest = security.parse_vendored_manifest(vendored_manifest_payload())

        with self.assertRaisesRegex(
            security.DependencySecurityError,
            "Git archive must have an OSV commit review: kissfft",
        ):
            security.validate_vendored_inventory(manifest, policy.vendored_reviews)

    def test_kissfft_old_revision_is_rejected_even_when_other_coordinates_match(
        self,
    ) -> None:
        policy_payload = security_policy_payload()
        policy_payload["vendoredDependencies"][0]["osv"]["revision"] = (
            "febd4caeed32e33ad8b2e0bb5ea77542c40f18ec"
        )
        policy = security.parse_security_policy(policy_payload)
        manifest = security.parse_vendored_manifest(vendored_manifest_payload())

        with self.assertRaisesRegex(
            security.DependencySecurityError,
            "does not match source archive for kissfft",
        ):
            security.validate_vendored_inventory(manifest, policy.vendored_reviews)

        old_revision = "febd4caeed32e33ad8b2e0bb5ea77542c40f18ec"
        old_source = (
            "https://github.com/mborgerding/kissfft/archive/"
            f"{old_revision}.zip"
        )
        old_manifest_payload = vendored_manifest_payload()
        old_manifest_payload["packages"][0]["version"] = old_revision
        old_manifest_payload["packages"][0]["source"] = old_source
        old_policy_payload = security_policy_payload()
        old_policy_payload["vendoredDependencies"][0]["source"] = old_source
        old_policy_payload["vendoredDependencies"][0]["osv"]["revision"] = old_revision
        old_manifest = security.parse_vendored_manifest(old_manifest_payload)
        old_policy = security.parse_security_policy(old_policy_payload)
        with self.assertRaisesRegex(
            security.DependencySecurityError,
            f"kissfft must use reviewed fixed commit {FIXED_KISSFFT_REVISION}",
        ):
            security.validate_vendored_inventory(
                old_manifest, old_policy.vendored_reviews
            )

    def test_review_freshness_rejects_future_expired_and_overlong_windows(self) -> None:
        policy = security.parse_security_policy(security_policy_payload())
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

        overlong = security_policy_payload()
        overlong["expiresAt"] = "2026-09-30T00:00:01Z"
        with self.assertRaisesRegex(
            security.DependencySecurityError, "review window exceeds 90 days"
        ):
            security.parse_security_policy(overlong)

    def test_schema_one_remains_parse_compatible_but_cannot_skip_freshness(self) -> None:
        legacy = security.parse_security_policy(baseline_payload())
        self.assertEqual(len(legacy.advisories), 1)
        with self.assertRaisesRegex(
            security.DependencySecurityError, "schemaVersion 2 is required"
        ):
            security.validate_policy_freshness(legacy)

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

    def test_live_osv_queries_vendored_commits_and_not_reviewed_unsupported_items(
        self,
    ) -> None:
        policy = security.parse_security_policy(security_policy_payload())
        manifest = security.parse_vendored_manifest(vendored_manifest_payload())
        commits, unsupported = security.validate_vendored_inventory(
            manifest, policy.vendored_reviews
        )
        requests: list[dict[str, object]] = []

        def transport(payload: dict[str, object]) -> object:
            requests.append(payload)
            return {"results": [{}]}

        self.assertEqual(security.scan_live_osv(commits, transport=transport), ())
        self.assertEqual(
            requests,
            [{"queries": [{"commit": FIXED_KISSFFT_REVISION}]}],
        )
        self.assertEqual([review.identity for review in unsupported], ["onnxruntime"])

    def test_offline_command_never_invokes_live_transport(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = root / "baseline.json"
            manifest = root / "manifest.json"
            baseline.write_text(
                json.dumps(security_policy_payload()), encoding="utf-8"
            )
            manifest.write_text(
                json.dumps(vendored_manifest_payload()), encoding="utf-8"
            )
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
                        "--third-party-manifest",
                        str(manifest),
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

    def test_repository_wires_offline_policy_and_live_ci_as_separate_gates(
        self,
    ) -> None:
        preflight = (SCRIPTS_DIR / "preflight.sh").read_text(encoding="utf-8")
        prek = (PROJECT_DIR / "prek.toml").read_text(encoding="utf-8")
        ci = (PROJECT_DIR / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertIn(
            'python3 "$SCRIPT_DIR/tests/dependency_security_test.py"', preflight
        )
        self.assertIn('python3 "$SCRIPT_DIR/check_dependency_security.py"', preflight)
        self.assertNotIn("--live-osv", preflight)
        self.assertIn('id = "dependency-security-policy"', prek)
        self.assertIn('id = "dependency-security-baseline"', prek)
        self.assertNotIn("--live-osv", prek)
        self.assertIn(
            "python3 scripts/check_dependency_security.py --live-osv",
            ci,
        )


if __name__ == "__main__":
    unittest.main()
