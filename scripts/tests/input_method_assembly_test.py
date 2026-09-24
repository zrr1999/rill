#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check the signing boundary for a locally assembled input method bundle."""

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from assemble_input_method import sign_bundle


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
