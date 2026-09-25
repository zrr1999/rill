#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
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
VALIDATE_MANIFEST = PROJECT_DIR / "scripts" / "validate_builtin_workflow_manifest.py"
WRITE_INFO_PLIST = PROJECT_DIR / "scripts" / "write_info_plist.py"
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
MLX_RESOURCE_BUNDLE_NAME = "mlx-swift_Cmlx.bundle"
DEPENDENCY_MANIFEST = PROJECT_DIR / "scripts" / "third_party_notices_manifest.json"
PACKAGE_MANIFEST = PROJECT_DIR / "Package.swift"
MLX_SILERO_RUNTIME = (
    PROJECT_DIR / "Sources" / "RillMLXRuntime" / "MLXSileroVADRuntime.swift"
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
            "uv",
            "run",
            "--script",
            str(GENERATOR),
            "--resolved",
            str(self.resolved),
            "--manifest",
            str(self.manifest),
            "--checkouts-dir",
            str(self.checkouts),
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
        input_method = build_dir / "RillInputMethod"
        input_method.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        input_method.chmod(0o755)

        own_bundle = build_dir / "RillMacOS_RillApp.bundle"
        create_bundle(own_bundle, "dev.zrr.Rill.resources")
        workflow_manifest = (
            own_bundle / "Contents" / "Resources" / "BuiltinWorkflowManifest.json"
        )
        write_json(workflow_manifest, {"workflows": []})

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

    def test_generator_rejects_vendored_manifest_entries(self) -> None:
        manifest = json.loads(self.fixture.manifest.read_text(encoding="utf-8"))
        manifest["packages"][0]["kind"] = "vendored"
        write_json(self.fixture.manifest, manifest)

        result = run(self.fixture.generator_command())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid kind: 'vendored'", result.stderr)

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
        copied_manifest_validator = (
            self.fixture.root / "scripts" / VALIDATE_MANIFEST.name
        )
        copied_info_plist_writer = self.fixture.root / "scripts" / WRITE_INFO_PLIST.name
        copied_icon_generator = self.fixture.root / "scripts" / APP_ICON_GENERATOR.name
        copied_icon_renderer = (
            self.fixture.root / "scripts" / APP_ICON_RENDITION_RENDERER.name
        )
        shutil.copy2(GENERATOR, copied_generator)
        shutil.copy2(ASSEMBLER, copied_assembler)
        shutil.copy2(EXECUTABLE_VERIFIER, copied_verifier)
        shutil.copy2(VALIDATE_MANIFEST, copied_manifest_validator)
        shutil.copy2(WRITE_INFO_PLIST, copied_info_plist_writer)
        shutil.copy2(APP_ICON_GENERATOR, copied_icon_generator)
        shutil.copy2(APP_ICON_RENDITION_RENDERER, copied_icon_renderer)
        # This suite isolates outer bundle resource provenance. The packaged Rime
        # runtime is exercised separately against real binaries in preflight.
        (self.fixture.root / "scripts/assemble_input_method.py").write_text(
            "import pathlib, sys\n"
            "pathlib.Path(sys.argv[sys.argv.index('--output') + 1]).mkdir(parents=True)\n",
            encoding="utf-8",
        )
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
        project_documents = ("LICENSE", "README.md")
        for document in project_documents:
            shutil.copy2(PROJECT_DIR / document, self.fixture.root / document)
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
            (app_bundle / "Contents" / "Resources" / MLX_RESOURCE_BUNDLE_NAME).exists()
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
        for document in project_documents:
            self.assertEqual(
                (app_bundle / "Contents" / "Resources" / document).read_bytes(),
                (PROJECT_DIR / document).read_bytes(),
            )
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
        self.assertFalse(
            (
                app_bundle
                / "Contents"
                / "Resources"
                / "RillMacOS_RillSherpaRuntime.bundle"
            ).exists()
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

        for document in project_documents:
            source = self.fixture.root / document
            for state in ("missing", "empty"):
                with self.subTest(document=document, state=state):
                    if state == "missing":
                        source.unlink()
                    else:
                        source.write_bytes(b"")
                    rejected = run(command, env=assembler_env)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertIn(
                        f"Project document not found or empty: {document}",
                        rejected.stderr,
                    )
                    self.assertEqual(
                        (app_bundle / "Contents" / "Resources" / document).read_bytes(),
                        (PROJECT_DIR / document).read_bytes(),
                    )
                    shutil.copy2(PROJECT_DIR / document, source)

        fake_ditto = fake_bin / "ditto"
        fake_ditto.write_text(
            """#!/bin/sh
/usr/bin/ditto "$@" || exit $?
if [ "${2##*/}" = "$RILL_TEST_CHANGED_DOCUMENT" ]; then
    printf '\\nchanged after copying\\n' >> "$2"
fi
""",
            encoding="utf-8",
        )
        fake_ditto.chmod(0o755)
        for document in project_documents:
            with self.subTest(document=document, state="changed after copying"):
                rejected = run(
                    command,
                    env={**assembler_env, "RILL_TEST_CHANGED_DOCUMENT": document},
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    f"Packaged project document differs from the repository source: {document}",
                    rejected.stderr,
                )
        fake_ditto.unlink()
        assembled = run(command, env=assembler_env)
        self.assertEqual(assembled.returncode, 0, assembled.stderr)

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
        checkouts = os.environ.get(
            "RILL_TEST_CHECKOUTS_DIR", str(PROJECT_DIR / ".build/checkouts")
        )
        result = run(
            [
                "uv",
                "run",
                "--script",
                str(GENERATOR),
                "--check",
                "--checkouts-dir",
                checkouts,
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_repository_has_no_retired_native_speech_inventory(self) -> None:
        manifest = json.loads(DEPENDENCY_MANIFEST.read_text(encoding="utf-8"))
        self.assertFalse(
            [
                package
                for package in manifest["packages"]
                if package["kind"] == "vendored"
            ]
        )
        package_manifest = PACKAGE_MANIFEST.read_text(encoding="utf-8").casefold()
        for retired_value in (
            "sherpaonnxnative",
            "onnxruntimenative",
            "rillsherparuntime",
            "csherpaonnx",
        ):
            self.assertNotIn(retired_value, package_manifest)

    def test_repository_pins_mlx_silero_v6_without_packaged_onnx(self) -> None:
        runtime = MLX_SILERO_RUNTIME.read_text(encoding="utf-8")
        local_notices = LOCAL_MODEL_NOTICES.read_text(encoding="utf-8")
        for pinned_value in (
            "mlx-community/silero-vad-v6",
            "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06",
            "9fe1befb9692a0d4135adadc33f8075ef6d350bd2391b88d750f2c233f97fa0b",
            "65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff",
        ):
            self.assertIn(pinned_value, runtime)
        self.assertIn("mlx-community/silero-vad-v6", local_notices)
        self.assertIn("no ONNX VAD is packaged", local_notices)
        self.assertNotIn(
            "RillSherpaRuntime", PACKAGE_MANIFEST.read_text(encoding="utf-8")
        )


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
