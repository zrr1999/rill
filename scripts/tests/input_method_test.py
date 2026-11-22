#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Reject invalid cached input method data before packaging."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import assemble_input_method as assembly


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
