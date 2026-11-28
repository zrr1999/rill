#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check input method data and signing during packaging."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import assemble_input_method as assembly


class InputMethodSigningTests(unittest.TestCase):
    def test_failed_nested_signature_stops_before_signing_the_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "RillInputMethod.app"
            library = bundle / "Contents/Frameworks/librime.dylib"
            helper = bundle / "Contents/Helpers/rime_deployer"
            for path in (library, helper):
                path.parent.mkdir(parents=True)
                path.touch()

            def codesign(command, *, check):
                if command[-1] == str(helper.resolve()):
                    raise subprocess.CalledProcessError(1, command)

            with patch.object(assembly.subprocess, "run", side_effect=codesign) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    assembly.sign_bundle(bundle, "-")
            self.assertNotIn(str(bundle.resolve()), [call.args[0][-1] for call in run.call_args_list])


class InputMethodDataTests(unittest.TestCase):
    def test_modified_cache_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dictionary = root / "pinyin_simp.dict.yaml"
            dictionary.write_bytes(b"original")
            manifest = {"pinyin": {"filename": dictionary.name, "sha256": assembly.checksum(dictionary)}}
            dictionary.write_bytes(b"modified")
            with patch.object(assembly, "DATA_CACHE", root), patch.object(assembly, "DATA_MANIFEST", manifest):
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    assembly.prepare_data(root / "resources")


if __name__ == "__main__":
    unittest.main()
