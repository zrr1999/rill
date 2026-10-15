#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check resources and the signing boundary of the standalone input method bundle."""

import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from assemble_input_method import assemble, sign_bundle


class InputMethodAssemblyTests(unittest.TestCase):
    def test_input_source_icons_resolve_to_bundled_brand_artwork(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime = root / "runtime"
            (runtime / "lib/rime-plugins").mkdir(parents=True)
            (runtime / "lib/librime.1.16.0.dylib").write_bytes(b"library")
            (runtime / "bin").mkdir()
            for name in ("rime_deployer", "rime_dict_manager"):
                (runtime / "bin" / name).write_bytes(b"helper")
            executable = root / "RillInputMethod"
            executable.write_bytes(b"executable")
            bundle = root / "RillInputMethod.app"
            with patch("assemble_input_method.prepare", return_value=runtime), \
                    patch("assemble_input_method.prepare_data"), \
                    patch("assemble_input_method.subprocess.run"):
                assemble(executable, bundle)

            contents = bundle / "Contents"
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertIs(info["TISIconIsTemplate"], True)
            icons = [info["tsInputMethodIconFileKey"]]
            modes = info["ComponentInputModeDict"]["tsInputModeListKey"].values()
            for mode in modes:
                icons.extend(mode[key] for key in (
                    "tsInputModeMenuIconFileKey", "tsInputModeAlternateMenuIconFileKey",
                    "tsInputModePaletteIconFileKey",
                ))
            brand = Path(__file__).resolve().parents[2] / "Sources/RillApp/Resources/RillMenuBarTemplate.pdf"
            for icon in icons:
                with self.subTest(icon=icon):
                    self.assertEqual((contents / "Resources" / icon).read_bytes(), brand.read_bytes())


class InputMethodSigningTests(unittest.TestCase):
    def make_bundle(self, root: Path) -> Path:
        bundle = root / "-option.app"
        (bundle / "Contents/Frameworks").mkdir(parents=True)
        (bundle / "Contents/Helpers").mkdir()
        (bundle / "Contents/Helpers/rime_deployer").write_bytes(b"helper")
        return bundle

    def test_relative_option_like_path_stays_a_single_file_argument(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.make_bundle(root)
            previous = Path.cwd()
            try:
                os.chdir(root)
                with patch("assemble_input_method.subprocess.run") as run:
                    sign_bundle(Path(bundle.name), "-")
            finally:
                os.chdir(previous)
            self.assertEqual(run.call_count, 3)
            for call in run.call_args_list:
                command = call.args[0]
                self.assertEqual(command[0], "/usr/bin/codesign")
                self.assertEqual(command[-2], "--")
                self.assertTrue(Path(command[-1]).is_absolute())

    def test_untrusted_identity_and_external_symlink_are_rejected_before_signing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = self.make_bundle(root)
            with patch("assemble_input_method.subprocess.run") as run:
                with self.assertRaises(ValueError):
                    sign_bundle(bundle, "--timestamp")
                run.assert_not_called()
                outside = root / "outside.dylib"
                outside.write_bytes(b"outside")
                (bundle / "Contents/Frameworks/escape.dylib").symlink_to(outside)
                with self.assertRaises(ValueError):
                    sign_bundle(bundle, "-")
                run.assert_not_called()

    def test_release_identity_is_a_certificate_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.make_bundle(Path(temporary))
            with patch("assemble_input_method.subprocess.run") as run:
                sign_bundle(bundle, "A" * 40)
            self.assertIn("--timestamp", run.call_args_list[0].args[0])


if __name__ == "__main__":
    unittest.main()
