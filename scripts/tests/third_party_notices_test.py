#!/usr/bin/env python3
"""Black-box tests for third-party notice provenance and app packaging."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


PROJECT_DIR = Path(__file__).resolve().parents[2]
GENERATOR = PROJECT_DIR / "scripts" / "generate_third_party_notices.py"
ASSEMBLER = PROJECT_DIR / "scripts" / "assemble_app_bundle.sh"
EXECUTABLE_VERIFIER = PROJECT_DIR / "scripts" / "verify_release_executable.sh"
APP_ICON_GENERATOR = PROJECT_DIR / "scripts" / "generate_app_icon.sh"
APP_ICON_RENDITION_RENDERER = (
    PROJECT_DIR / "scripts" / "render_app_icon_renditions.swift"
)
APP_BUNDLE_RESOURCES = PROJECT_DIR / "Resources" / "AppBundle"
APP_ICON_SOURCE = (
    PROJECT_DIR / "Resources" / "AppIcon" / "AppIcon-1024-routed-voice-cursor.png"
)
PRIVACY_NOTICE = PROJECT_DIR / "PRIVACY.md"
LOCAL_MODEL_NOTICES = PROJECT_DIR / "LOCAL_MODEL_NOTICES.md"
WAKE_WORD_MODEL_CATALOG = (
    PROJECT_DIR / "Sources" / "RillProviders" / "WakeWordModelCatalog.swift"
)
MLX_RESOURCE_BUNDLE_NAME = "mlx-swift_Cmlx.bundle"
DEPENDENCY_MANIFEST = PROJECT_DIR / "scripts" / "third_party_notices_manifest.json"
PACKAGE_MANIFEST = PROJECT_DIR / "Package.swift"
SHERPA_BUILD_SCRIPT = PROJECT_DIR / "scripts" / "build_sherpa_onnx_runtime.sh"
SHERPA_BUILD_PROVENANCE = (
    PROJECT_DIR / "vendor" / "sherpa-onnx-v1.13.4" / "BUILD_PROVENANCE.md"
)
SHERPA_VENDOR_ROOT = PROJECT_DIR / "vendor" / "sherpa-onnx-v1.13.4"
SHERPA_SOURCE_INPUTS = SHERPA_VENDOR_ROOT / "SOURCE_INPUTS.sha256"
SHERPA_ARTIFACT_SUMS = SHERPA_VENDOR_ROOT / "SHA256SUMS"
SHERPA_ARCHIVE = (
    SHERPA_VENDOR_ROOT
    / "sherpa-onnx.xcframework"
    / "macos-arm64_x86_64"
    / "libsherpa-onnx.a"
)
SILERO_VAD_SOURCE = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "asr-models/silero_vad.onnx"
)
SILERO_VAD_SHA256 = (
    "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
)
SILERO_VAD_SIZE = 643_854
SILERO_VAD_ROOT = PROJECT_DIR / "Sources" / "RillSherpaRuntime" / "Resources"
SILERO_VAD_RESOURCE = SILERO_VAD_ROOT / "silero_vad.onnx"
SILERO_VAD_LICENSE = SILERO_VAD_ROOT / "LICENSE.silero-vad"
SILERO_VAD_LICENSE_SHA256 = (
    "51c19c8be941a3fb00ccf58f0bf9053de9f7237a0b37327896eabad32dffe873"
)
SILERO_VAD_UPSTREAM_LICENSE_SHA256 = (
    "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b"
)
WAKE_WORD_ARCHIVE_SHA256 = (
    "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6"
)
WAKE_WORD_LICENSE_REVISION = "541d04e28be57efc6fdf46a341da09e043a37b52"
WAKE_WORD_LICENSE_SHA256 = (
    "34d92bb4dc9fb259efb67f329d2cd68f6e0a6226121a694a3b6b4c748378559c"
)


class Fixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.resolved = root / "Package.resolved"
        self.manifest = root / "scripts" / "third_party_notices_manifest.json"
        self.checkouts = root / ".build" / "checkouts"
        self.output = root / "THIRD_PARTY_NOTICES.md"
        self.checkout = self.checkouts / "sample"
        self.license_path = self.checkout / "LICENSE"
        self.source_path = self.checkout / "Source.swift"
        self.license_content = b"Sample dependency license\nCopyright Example\n"
        self.revision = ""

    def create(self) -> None:
        (self.root / "scripts").mkdir(parents=True)
        self.checkout.mkdir(parents=True)
        self.license_path.write_bytes(self.license_content)
        self.source_path.write_text("let sample = true\n", encoding="utf-8")
        run(["git", "init", "-q"], cwd=self.checkout, check=True)
        run(["git", "add", "LICENSE", "Source.swift"], cwd=self.checkout, check=True)
        run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Rill Test",
                "-c",
                "user.email=rill-test@example.invalid",
                "commit",
                "-q",
                "-m",
                "license evidence",
            ],
            cwd=self.checkout,
            check=True,
        )
        self.revision = run(
            ["git", "rev-parse", "HEAD"], cwd=self.checkout, check=True
        ).stdout.strip()
        self.write_resolved()
        self.write_manifest()

    def write_resolved(self, extra_pins: list[dict[str, object]] | None = None) -> None:
        pins: list[dict[str, object]] = [
            {
                "identity": "sample",
                "kind": "remoteSourceControl",
                "location": "https://example.invalid/sample.git",
                "state": {"revision": self.revision, "version": "1.2.3"},
            }
        ]
        pins.extend(extra_pins or [])
        write_json(
            self.resolved,
            {"originHash": "f" * 64, "pins": pins, "version": 3},
        )

    def write_manifest(self, digest: str | None = None) -> None:
        write_json(
            self.manifest,
            {
                "schemaVersion": 2,
                "packages": [
                    {
                        "kind": "sourceControl",
                        "identity": "sample",
                        "licenseExpression": "MIT",
                        "evidence": [
                            {
                                "kind": "license",
                                "path": "LICENSE",
                                "sha256": digest
                                or hashlib.sha256(self.license_content).hexdigest(),
                            }
                        ],
                    }
                ],
            },
        )

    def generator_command(self, check: bool = False) -> list[str]:
        command = [
            "python3",
            str(GENERATOR),
            "--resolved",
            str(self.resolved),
            "--manifest",
            str(self.manifest),
            "--checkouts-dir",
            str(self.checkouts),
            "--project-dir",
            str(self.root),
            "--output",
            str(self.output),
        ]
        if check:
            command.append("--check")
        return command

    def generate(self) -> subprocess.CompletedProcess[str]:
        return run(self.generator_command(), check=True)

    def create_build_products(self) -> Path:
        build_dir = self.root / "build"
        executable = build_dir / "RillApp"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        speech_worker = build_dir / "RillSpeechWorker"
        speech_worker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        speech_worker.chmod(0o755)

        own_bundle = build_dir / "RillMacOS_RillApp.bundle"
        create_bundle(own_bundle, "dev.zrr.Rill.resources")
        workflow_manifest = (
            own_bundle / "Contents" / "Resources" / "BuiltinWorkflowManifest.json"
        )
        write_json(workflow_manifest, {"workflows": []})

        sherpa_bundle = build_dir / "RillMacOS_RillSherpaRuntime.bundle"
        create_bundle(sherpa_bundle, "dev.zrr.Rill.sherpa-resources")
        sherpa_resources = sherpa_bundle / "Contents" / "Resources"
        shutil.copy2(SILERO_VAD_RESOURCE, sherpa_resources / SILERO_VAD_RESOURCE.name)
        shutil.copy2(SILERO_VAD_LICENSE, sherpa_resources / SILERO_VAD_LICENSE.name)

        mlx_bundle = build_dir / MLX_RESOURCE_BUNDLE_NAME
        create_bundle(mlx_bundle, "mlx-swift_Cmlx")
        (mlx_bundle / "Contents" / "Resources" / "default.metallib").write_bytes(
            b"fixture metal library"
        )
        return build_dir


class ThirdPartyNoticesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="rill-third-party-notices."
        )
        self.fixture = Fixture(Path(self.temporary_directory.name))
        self.fixture.create()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_generator_emits_locked_inventory_and_is_reproducible(self) -> None:
        self.fixture.generate()
        content = self.fixture.output.read_text(encoding="utf-8")
        self.assertIn("`sample` | source control | 1.2.3", content)
        self.assertIn(self.fixture.revision, content)
        self.assertIn("Sample dependency license", content)
        checked = run(self.fixture.generator_command(check=True))
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_generator_can_pin_a_license_excerpt_by_line_range(self) -> None:
        first_line = b"Sample dependency license\n"
        manifest = json.loads(self.fixture.manifest.read_text(encoding="utf-8"))
        evidence = manifest["packages"][0]["evidence"][0]
        evidence.update(
            {
                "sha256": hashlib.sha256(first_line).hexdigest(),
                "lineStart": 1,
                "lineEnd": 1,
            }
        )
        write_json(self.fixture.manifest, manifest)

        self.fixture.generate()
        content = self.fixture.output.read_text(encoding="utf-8")
        self.assertIn("`LICENSE#L1-L1`", content)
        self.assertIn("Sample dependency license", content)
        self.assertNotIn("Copyright Example", content)

    def test_check_rejects_missing_or_stale_generated_output(self) -> None:
        missing = run(self.fixture.generator_command(check=True))
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("missing or unreadable", missing.stderr)

        self.fixture.generate()
        with self.fixture.output.open("a", encoding="utf-8") as destination:
            destination.write("stale\n")
        stale = run(self.fixture.generator_command(check=True))
        self.assertNotEqual(stale.returncode, 0)
        self.assertIn("stale", stale.stderr)

    def test_generator_rejects_unreviewed_locked_package(self) -> None:
        self.fixture.write_resolved(
            [
                {
                    "identity": "unreviewed",
                    "kind": "remoteSourceControl",
                    "location": "https://example.invalid/unreviewed.git",
                    "state": {"revision": "a" * 40, "version": "9.9.9"},
                }
            ]
        )
        result = run(self.fixture.generator_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreviewed locked packages: unreviewed", result.stderr)

    def test_generator_accepts_license_added_on_a_descendant_evidence_revision(
        self,
    ) -> None:
        locked_revision = self.fixture.revision
        later_license = self.fixture.checkout / "LICENSE-LATER"
        later_content = b"License granted on a descendant revision\n"
        later_license.write_bytes(later_content)
        run(["git", "add", "LICENSE-LATER"], cwd=self.fixture.checkout, check=True)
        run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Rill Test",
                "-c",
                "user.email=rill-test@example.invalid",
                "commit",
                "-q",
                "-m",
                "add later license",
            ],
            cwd=self.fixture.checkout,
            check=True,
        )
        evidence_revision = run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.fixture.checkout,
            check=True,
        ).stdout.strip()
        run(
            ["git", "checkout", "--detach", "-q", locked_revision],
            cwd=self.fixture.checkout,
            check=True,
        )
        write_json(
            self.fixture.manifest,
            {
                "schemaVersion": 2,
                "packages": [
                    {
                        "kind": "sourceControl",
                        "identity": "sample",
                        "licenseExpression": "MIT",
                        "evidenceRevision": evidence_revision,
                        "evidence": [
                            {
                                "kind": "license",
                                "path": "LICENSE-LATER",
                                "sha256": hashlib.sha256(later_content).hexdigest(),
                            }
                        ],
                    }
                ],
            },
        )

        self.fixture.generate()
        content = self.fixture.output.read_text(encoding="utf-8")

        self.assertIn(f"`LICENSE-LATER@{evidence_revision}`", content)
        self.assertIn("License granted on a descendant revision", content)

    def test_generator_supports_vendored_only_without_lockfile_and_rejects_artifact_drift(
        self,
    ) -> None:
        self.fixture.resolved.unlink()
        vendor_root = self.fixture.root / "vendor" / "sample-runtime"
        vendor_root.mkdir(parents=True)
        artifact = vendor_root / "libsample.a"
        artifact.write_bytes(b"reviewed static archive\n")
        license_path = vendor_root / "LICENSE"
        license_path.write_bytes(self.fixture.license_content)
        write_json(
            self.fixture.manifest,
            {
                "schemaVersion": 2,
                "packages": [
                    {
                        "kind": "vendored",
                        "identity": "sample-runtime",
                        "version": "2.0.0",
                        "source": "https://example.invalid/sample-runtime/v2.0.0",
                        "sourceSHA256": "a" * 64,
                        "root": "vendor/sample-runtime",
                        "artifacts": [
                            {
                                "path": artifact.name,
                                "sha256": hashlib.sha256(
                                    artifact.read_bytes()
                                ).hexdigest(),
                            }
                        ],
                        "licenseExpression": "MIT",
                        "evidence": [
                            {
                                "kind": "license",
                                "path": license_path.name,
                                "sha256": hashlib.sha256(
                                    license_path.read_bytes()
                                ).hexdigest(),
                            }
                        ],
                    }
                ],
            },
        )

        self.fixture.generate()
        content = self.fixture.output.read_text(encoding="utf-8")
        self.assertIn("`sample-runtime` | vendored | 2.0.0", content)
        checked = run(self.fixture.generator_command(check=True))
        self.assertEqual(checked.returncode, 0, checked.stderr)

        artifact.write_bytes(b"tampered static archive\n")
        rejected = run(self.fixture.generator_command())
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Artifact SHA-256 mismatch", rejected.stderr)

    def test_generator_rejects_missing_or_changed_evidence(self) -> None:
        self.fixture.license_path.unlink()
        missing = run(self.fixture.generator_command())
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Missing or unsafe evidence", missing.stderr)

        self.fixture.license_path.write_bytes(b"changed license\n")
        changed = run(self.fixture.generator_command())
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("SHA-256 mismatch", changed.stderr)

    def test_generator_rejects_checkout_revision_drift(self) -> None:
        marker = self.fixture.checkout / "marker.txt"
        marker.write_text("new commit\n", encoding="utf-8")
        run(["git", "add", "marker.txt"], cwd=self.fixture.checkout, check=True)
        run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Rill Test",
                "-c",
                "user.email=rill-test@example.invalid",
                "commit",
                "-q",
                "-m",
                "revision drift",
            ],
            cwd=self.fixture.checkout,
            check=True,
        )
        result = run(self.fixture.generator_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checkout revision mismatch", result.stderr)

    def test_generator_rejects_dirty_checkout(self) -> None:
        self.fixture.source_path.write_text("let sample = false\n", encoding="utf-8")
        result = run(self.fixture.generator_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checkout worktree is dirty", result.stderr)

    def test_generator_rejects_hidden_checkout_index_flags(self) -> None:
        run(
            ["git", "update-index", "--assume-unchanged", "Source.swift"],
            cwd=self.fixture.checkout,
            check=True,
        )
        self.fixture.source_path.write_text("let sample = false\n", encoding="utf-8")
        result = run(self.fixture.generator_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checkout index flags are not allowed", result.stderr)

    def test_assembler_packages_reviewed_resources_and_rejects_drift(self) -> None:
        copied_generator = self.fixture.root / "scripts" / GENERATOR.name
        copied_assembler = self.fixture.root / "scripts" / ASSEMBLER.name
        copied_verifier = self.fixture.root / "scripts" / EXECUTABLE_VERIFIER.name
        copied_icon_generator = self.fixture.root / "scripts" / APP_ICON_GENERATOR.name
        copied_icon_renderer = (
            self.fixture.root / "scripts" / APP_ICON_RENDITION_RENDERER.name
        )
        shutil.copy2(GENERATOR, copied_generator)
        shutil.copy2(ASSEMBLER, copied_assembler)
        shutil.copy2(EXECUTABLE_VERIFIER, copied_verifier)
        shutil.copy2(APP_ICON_GENERATOR, copied_icon_generator)
        shutil.copy2(APP_ICON_RENDITION_RENDERER, copied_icon_renderer)
        copied_app_bundle_resources = self.fixture.root / "Resources" / "AppBundle"
        shutil.copytree(APP_BUNDLE_RESOURCES, copied_app_bundle_resources)
        copied_app_icon_source = (
            self.fixture.root / "Resources" / "AppIcon" / APP_ICON_SOURCE.name
        )
        copied_app_icon_source.parent.mkdir(parents=True)
        shutil.copy2(APP_ICON_SOURCE, copied_app_icon_source)
        copied_privacy_notice = self.fixture.root / PRIVACY_NOTICE.name
        shutil.copy2(PRIVACY_NOTICE, copied_privacy_notice)
        copied_local_model_notices = self.fixture.root / LOCAL_MODEL_NOTICES.name
        shutil.copy2(LOCAL_MODEL_NOTICES, copied_local_model_notices)
        fake_bin = self.fixture.root / "bin"
        fake_bin.mkdir()
        fake_lipo = fake_bin / "lipo"
        fake_lipo.write_text(
            """#!/bin/sh
if [ "$#" -ne 2 ] || [ "$2" != "-archs" ]; then
    exit 64
fi
printf '%s\\n' arm64
""",
            encoding="utf-8",
        )
        fake_lipo.chmod(0o755)
        fake_nm = fake_bin / "nm"
        fake_nm.write_text(
            """#!/bin/sh
cat <<'EOF'
00000001 (__TEXT,__text) external _SherpaOnnxCreateOfflineRecognizer
00000002 (__TEXT,__text) external _SherpaOnnxCreateVoiceActivityDetector
00000003 (__TEXT,__text) external _SherpaOnnxOfflineStreamSetOption
EOF
""",
            encoding="utf-8",
        )
        fake_nm.chmod(0o755)
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            """#!/bin/sh
if [ "$#" -ne 5 ] || [ "$1" != "vtool" ] || [ "$2" != "-arch" ] \\
    || [ "$4" != "-show-build" ]; then
    exit 64
fi
case "$3" in
    arm64) ;;
    *) exit 64 ;;
esac
cat <<'EOF'
Load command 9
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 14.0
      sdk 15.2
   ntools 1
     tool LD
  version 1115.7
EOF
""",
            encoding="utf-8",
        )
        fake_xcrun.chmod(0o755)
        assembler_env = {"PATH": f"{fake_bin}:{os.environ['PATH']}"}
        self.fixture.generate()
        build_dir = self.fixture.create_build_products()
        app_bundle = self.fixture.root / "output" / "Rill.app"
        command = [
            "bash",
            str(copied_assembler),
            "--build-dir",
            str(build_dir),
            "--app-bundle",
            str(app_bundle),
            "--version",
            "1.2.3",
            "--build-number",
            "42",
            "--build-kind",
            "test",
            "--source-revision",
            "a" * 40,
            "--source-dirty",
            "false",
            "--version-label",
            "1.2.3-test+fixture",
        ]
        assembled = run(command, env=assembler_env)
        self.assertEqual(assembled.returncode, 0, assembled.stderr)
        packaged_speech_worker = (
            app_bundle / "Contents" / "Helpers" / "RillSpeechWorker"
        )
        self.assertTrue(packaged_speech_worker.is_file())
        self.assertTrue(os.access(packaged_speech_worker, os.X_OK))
        self.assertEqual(
            packaged_speech_worker.read_bytes(),
            (build_dir / "RillSpeechWorker").read_bytes(),
        )
        packaged_mlx_bundle = (
            app_bundle / "Contents" / "Helpers" / MLX_RESOURCE_BUNDLE_NAME
        )
        self.assertTrue(packaged_mlx_bundle.is_dir())
        self.assertFalse(
            (
                app_bundle / "Contents" / "Resources" / MLX_RESOURCE_BUNDLE_NAME
            ).exists()
        )
        self.assertEqual(
            (
                packaged_mlx_bundle / "Contents" / "Resources" / "default.metallib"
            ).read_bytes(),
            (
                build_dir
                / MLX_RESOURCE_BUNDLE_NAME
                / "Contents"
                / "Resources"
                / "default.metallib"
            ).read_bytes(),
        )
        packaged = app_bundle / "Contents" / "Resources" / "THIRD_PARTY_NOTICES.md"
        self.assertEqual(packaged.read_bytes(), self.fixture.output.read_bytes())
        packaged_privacy_notice = (
            app_bundle / "Contents" / "Resources" / PRIVACY_NOTICE.name
        )
        self.assertEqual(
            packaged_privacy_notice.read_bytes(),
            copied_privacy_notice.read_bytes(),
        )
        packaged_local_model_notices = (
            app_bundle / "Contents" / "Resources" / LOCAL_MODEL_NOTICES.name
        )
        self.assertEqual(
            packaged_local_model_notices.read_bytes(),
            copied_local_model_notices.read_bytes(),
        )
        packaged_sherpa_resources = (
            app_bundle
            / "Contents"
            / "Resources"
            / "RillMacOS_RillSherpaRuntime.bundle"
            / "Contents"
            / "Resources"
        )
        self.assertEqual(
            (packaged_sherpa_resources / SILERO_VAD_RESOURCE.name).read_bytes(),
            SILERO_VAD_RESOURCE.read_bytes(),
        )
        self.assertEqual(
            (packaged_sherpa_resources / SILERO_VAD_LICENSE.name).read_bytes(),
            SILERO_VAD_LICENSE.read_bytes(),
        )

        with (app_bundle / "Contents" / "Info.plist").open("rb") as source:
            info_plist = plistlib.load(source)
        self.assertEqual(info_plist["CFBundleDevelopmentRegion"], "en")
        self.assertEqual(info_plist["CFBundleIconFile"], "Rill.icns")
        self.assertEqual(
            info_plist["NSMicrophoneUsageDescription"],
            "Rill needs microphone access to capture voice input for speech-to-text.",
        )

        expected_descriptions = {
            "en": (
                "Rill needs microphone access to capture voice input for "
                "speech-to-text."
            ),
            "zh-Hans": "Rill 需要使用麦克风来采集语音输入并转换为文字。",
        }
        for localization, expected_description in expected_descriptions.items():
            source = (
                copied_app_bundle_resources
                / f"{localization}.lproj"
                / "InfoPlist.strings"
            )
            localized = (
                app_bundle
                / "Contents"
                / "Resources"
                / f"{localization}.lproj"
                / "InfoPlist.strings"
            )
            self.assertEqual(localized.read_bytes(), source.read_bytes())
            extracted = run(
                [
                    "plutil",
                    "-extract",
                    "NSMicrophoneUsageDescription",
                    "raw",
                    "-o",
                    "-",
                    str(localized),
                ]
            )
            self.assertEqual(extracted.returncode, 0, extracted.stderr)
            self.assertEqual(extracted.stdout.strip(), expected_description)

        packaged_icon = app_bundle / "Contents" / "Resources" / "Rill.icns"
        self.assertGreater(packaged_icon.stat().st_size, 0)
        extracted_iconset = self.fixture.root / "packaged-icon.iconset"
        extracted = run(
            [
                "iconutil",
                "-c",
                "iconset",
                str(packaged_icon),
                "-o",
                str(extracted_iconset),
            ]
        )
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        self.assertTrue((extracted_iconset / "icon_512x512@2x.png").is_file())

        built_silero_model = (
            build_dir
            / "RillMacOS_RillSherpaRuntime.bundle"
            / "Contents"
            / "Resources"
            / SILERO_VAD_RESOURCE.name
        )
        built_silero_model.write_bytes(b"drifted-model")
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Built Silero VAD model SHA-256 mismatch", rejected.stderr)
        self.assertTrue(app_bundle.exists())
        shutil.copy2(SILERO_VAD_RESOURCE, built_silero_model)

        self.fixture.output.unlink()
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("missing or unreadable", rejected.stderr)
        self.assertTrue(app_bundle.exists())

        self.fixture.generate()
        copied_local_model_notices.unlink()
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Local model notices not found", rejected.stderr)
        self.assertTrue(app_bundle.exists())

        shutil.copy2(LOCAL_MODEL_NOTICES, copied_local_model_notices)
        simplified_chinese_source = (
            copied_app_bundle_resources / "zh-Hans.lproj" / "InfoPlist.strings"
        )
        simplified_chinese_source.unlink()
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "Localized Info.plist strings not found: zh-Hans", rejected.stderr
        )
        self.assertTrue(app_bundle.exists())

        shutil.copy2(
            APP_BUNDLE_RESOURCES / "zh-Hans.lproj" / "InfoPlist.strings",
            simplified_chinese_source,
        )
        simplified_chinese_source.write_text(
            '"CFBundleDisplayName" = "Rill";\n"CFBundleName" = "Rill";\n',
            encoding="utf-8",
        )
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "Missing NSMicrophoneUsageDescription in localized Info.plist strings: "
            "zh-Hans",
            rejected.stderr,
        )
        self.assertTrue(app_bundle.exists())

        shutil.copy2(
            APP_BUNDLE_RESOURCES / "zh-Hans.lproj" / "InfoPlist.strings",
            simplified_chinese_source,
        )
        copied_app_icon_source.unlink()
        rejected = run(command, env=assembler_env)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("App icon source not found", rejected.stderr)
        self.assertTrue(app_bundle.exists())

    def test_repository_notice_is_current(self) -> None:
        result = run(["python3", str(GENERATOR), "--check"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repository_silero_vad_resource_is_pinned_and_packaged(self) -> None:
        for resource in (SILERO_VAD_RESOURCE, SILERO_VAD_LICENSE):
            self.assertTrue(resource.exists(), f"missing reviewed resource: {resource}")
            self.assertFalse(resource.is_symlink(), f"resource is a symlink: {resource}")
            self.assertTrue(resource.is_file(), f"resource is not regular: {resource}")

        model_bytes = SILERO_VAD_RESOURCE.read_bytes()
        self.assertEqual(len(model_bytes), SILERO_VAD_SIZE)
        self.assertEqual(hashlib.sha256(model_bytes).hexdigest(), SILERO_VAD_SHA256)

        license_bytes = SILERO_VAD_LICENSE.read_bytes()
        self.assertEqual(
            hashlib.sha256(license_bytes).hexdigest(), SILERO_VAD_LICENSE_SHA256
        )
        self.assertTrue(license_bytes.endswith(b"\n"))
        self.assertEqual(
            hashlib.sha256(license_bytes[:-1]).hexdigest(),
            SILERO_VAD_UPSTREAM_LICENSE_SHA256,
        )

        manifest = json.loads(DEPENDENCY_MANIFEST.read_text(encoding="utf-8"))
        silero = next(
            package
            for package in manifest["packages"]
            if package["identity"] == "silero-vad"
        )
        self.assertEqual(silero["kind"], "vendored")
        self.assertEqual(silero["source"], SILERO_VAD_SOURCE)
        self.assertEqual(silero["sourceSHA256"], SILERO_VAD_SHA256)
        self.assertEqual(silero["root"], "Sources/RillSherpaRuntime/Resources")
        self.assertEqual(
            silero["artifacts"],
            [{"path": "silero_vad.onnx", "sha256": SILERO_VAD_SHA256}],
        )
        self.assertEqual(silero["licenseExpression"], "MIT")
        self.assertEqual(
            silero["evidence"],
            [
                {
                    "kind": "license",
                    "path": "LICENSE.silero-vad",
                    "sha256": SILERO_VAD_LICENSE_SHA256,
                }
            ],
        )

        package_manifest = PACKAGE_MANIFEST.read_text(encoding="utf-8")
        self.assertIn('.copy("Resources/silero_vad.onnx")', package_manifest)
        self.assertIn('.copy("Resources/LICENSE.silero-vad")', package_manifest)

        local_notices = LOCAL_MODEL_NOTICES.read_text(encoding="utf-8")
        for pinned_value in (
            SILERO_VAD_SOURCE,
            SILERO_VAD_SHA256,
            str(SILERO_VAD_SIZE),
        ):
            self.assertIn(pinned_value, local_notices)
        self.assertIn("does not suppress noise", local_notices)

    def test_repository_wake_word_license_evidence_is_pinned_and_packaged(
        self,
    ) -> None:
        catalog = WAKE_WORD_MODEL_CATALOG.read_text(encoding="utf-8")
        local_notices = LOCAL_MODEL_NOTICES.read_text(encoding="utf-8")
        third_party_notices = (PROJECT_DIR / "THIRD_PARTY_NOTICES.md").read_text(
            encoding="utf-8"
        )

        for pinned_value in (
            WAKE_WORD_ARCHIVE_SHA256,
            WAKE_WORD_LICENSE_REVISION,
            WAKE_WORD_LICENSE_SHA256,
            "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
            "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
            'licenseExpression: "Apache-2.0"',
            "upstreamNotice: .notProvidedByPublisher",
        ):
            self.assertIn(pinned_value, catalog)

        for pinned_value in (
            WAKE_WORD_ARCHIVE_SHA256,
            WAKE_WORD_LICENSE_REVISION,
            WAKE_WORD_LICENSE_SHA256,
            "Apache License 2.0",
            "no `NOTICE` file was provided",
            "`left-64`",
        ):
            self.assertIn(pinned_value, local_notices)
        self.assertIn("Apache License", third_party_notices)

    def test_repository_native_runtime_inventory_matches_reviewed_build(self) -> None:
        manifest = json.loads(DEPENDENCY_MANIFEST.read_text(encoding="utf-8"))
        packages = [
            package
            for package in manifest["packages"]
            if package["kind"] == "vendored"
        ]
        by_identity = {package["identity"]: package for package in packages}
        expected_identities = {
            "eigen",
            "kaldi-decoder",
            "kaldi-native-fbank",
            "kaldifst",
            "kissfft",
            "nlohmann-json",
            "onnxruntime",
            "openfst",
            "sherpa-onnx",
            "silero-vad",
            "simple-sentencepiece",
        }
        self.assertEqual(set(by_identity), expected_identities)
        self.assertEqual(len(packages), len(expected_identities))
        self.assertTrue(all(package["kind"] == "vendored" for package in packages))

        source_input_hashes = {
            line.split(maxsplit=1)[0]
            for line in SHERPA_SOURCE_INPUTS.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
        native_runtime_identities = expected_identities - {"silero-vad"}
        self.assertEqual(
            source_input_hashes,
            {
                by_identity[identity]["sourceSHA256"]
                for identity in native_runtime_identities
            },
        )

        sherpa = by_identity["sherpa-onnx"]
        self.assertEqual(
            sherpa["source"],
            "https://github.com/k2-fsa/sherpa-onnx/archive/"
            "142807252687d81b40d6315f23470a1512a00de3.tar.gz",
        )
        self.assertEqual(
            sherpa["sourceSHA256"],
            "f0dc7c9b41b8691313daee671e826eb23946fa1320559a8d37e84f8774af76b2",
        )
        expected_archive_sha256 = (
            "8950e345310f223d3be649c80de8059957a2a01f8553cca24c99071a6a292db6"
        )
        merged_artifact_path = (
            "sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a"
        )
        for identity in native_runtime_identities - {"onnxruntime"}:
            artifacts = {
                artifact["path"]: artifact["sha256"]
                for artifact in by_identity[identity]["artifacts"]
            }
            self.assertEqual(
                artifacts[merged_artifact_path], expected_archive_sha256
            )

        serialized_manifest = json.dumps(manifest, sort_keys=True).casefold()
        for forbidden_identity in ("espeak", "hclust", "piper"):
            self.assertNotIn(forbidden_identity, serialized_manifest)

        build_contract = (
            SHERPA_BUILD_SCRIPT.read_text(encoding="utf-8")
            + SHERPA_BUILD_PROVENANCE.read_text(encoding="utf-8")
        )
        for required_setting in (
            "CMAKE_CXX_FLAGS=-DEIGEN_MPL2_ONLY",
            "SHERPA_ONNX_ENABLE_TTS=OFF",
            "SHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF",
            "SHERPA_ONNX_ENABLE_PORTAUDIO=OFF",
        ):
            self.assertIn(required_setting, build_contract)

        build_script = SHERPA_BUILD_SCRIPT.read_text(encoding="utf-8")
        for reproducibility_gate in (
            "EXPECTED_SOURCE_ARCHIVE_SHA256=",
            "-ffile-prefix-map=$WORK_ROOT=$REPRODUCIBLE_BUILD_ROOT",
            "FETCHCONTENT_FULLY_DISCONNECTED=ON",
            "EXPECTED_PATCHED_KALDI_NATIVE_FBANK_CMAKE_SHA256=",
            'libtool -static -D -no_warning_for_no_symbols',
            "SherpaOnnxOfflineStreamSetOption",
        ):
            self.assertIn(reproducibility_gate, build_script)

        checked_artifacts = run(
            ["shasum", "-a", "256", "-c", str(SHERPA_ARTIFACT_SUMS)],
            cwd=SHERPA_VENDOR_ROOT,
        )
        self.assertEqual(
            checked_artifacts.returncode,
            0,
            checked_artifacts.stdout + checked_artifacts.stderr,
        )

        for architecture in ("arm64", "x86_64"):
            architecture_check = run(
                ["lipo", str(SHERPA_ARCHIVE), "-verify_arch", architecture]
            )
            self.assertEqual(
                architecture_check.returncode, 0, architecture_check.stderr
            )
            symbols = run(["nm", "-a", "-arch", architecture, str(SHERPA_ARCHIVE)])
            self.assertEqual(symbols.returncode, 0, symbols.stderr)
            self.assertIn("_SherpaOnnxCreateOfflineRecognizer", symbols.stdout)
            self.assertIn("_SherpaOnnxCreateVoiceActivityDetector", symbols.stdout)
            self.assertIn("_SherpaOnnxOfflineStreamSetOption", symbols.stdout)
            lowered_symbols = symbols.stdout.casefold()
            for forbidden_pattern in (
                "_espeak_",
                "piper",
                "phonemiz",
                "hclust",
                "fastcluster",
                "offline-tts-impl",
                "offline-speaker-diarization-impl",
            ):
                self.assertNotIn(forbidden_pattern, lowered_symbols)

        archive_strings = run(["strings", str(SHERPA_ARCHIVE)])
        self.assertEqual(archive_strings.returncode, 0, archive_strings.stderr)
        self.assertIn(
            "/usr/src/voxtype/sherpa-runtime/", archive_strings.stdout
        )
        for private_path in (
            "/Users/",
            "/private/var/folders/",
            "/var/folders/",
            "/private/tmp/voxtype-sherpa",
            "/tmp/voxtype-sherpa",
            "/private/tmp/rill-sherpa",
            "/tmp/rill-sherpa",
        ):
            self.assertNotIn(private_path, archive_strings.stdout)


def create_bundle(path: Path, identifier: str) -> None:
    resources = path / "Contents" / "Resources"
    resources.mkdir(parents=True)
    with (path / "Contents" / "Info.plist").open("wb") as destination:
        plistlib.dump(
            {
                "CFBundleIdentifier": identifier,
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": path.stem,
                "CFBundlePackageType": "BNDL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            },
            destination,
            fmt=plistlib.FMT_XML,
            sort_keys=True,
        )


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def run(
    command: list[str],
    *,
    cwd: Path | None = None,
    check: bool = False,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        capture_output=True,
        text=True,
        timeout=30,
        env={**os.environ, **(env or {}), "LC_ALL": "C"},
    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
