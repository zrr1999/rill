#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check the public data bundle without downloading or reading user profiles."""

import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import prepare_input_method_data as data  # noqa: E402


class InputMethodDataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = {}
        default = self.root / "default"
        default.mkdir()
        (default / "default.yaml").write_text("schema_list: [{schema: rill_pinyin}]")
        (default / "rill_pinyin.schema.yaml").write_text("schema: {schema_id: rill_pinyin}")
        dictionary = self.root / "pinyin_simp.dict.yaml"
        dictionary.write_text("dictionary fixture")
        self.manifest["pinyin"] = {"filename": dictionary.name, "sha256": data.checksum(dictionary)}
        for name, entries in {
            "opencc": {
                "opencc/clib/share/opencc/s2t.json": "{}",
                "opencc/clib/share/opencc/STCharacters.ocd2": "dictionary",
                "opencc/clib/opencc.so": "Unwanted native code",
            },
        }.items():
            archive = self.root / (name + ".zip")
            with ZipFile(archive, "w") as bundle:
                for path, contents in entries.items():
                    bundle.writestr(path, contents)
            self.manifest[name] = {"filename": archive.name, "sha256": data.checksum(archive)}
        manifest_path = self.root / "manifest.json"
        manifest_path.write_text(json.dumps(self.manifest))
        for name, value in (("CACHE", self.root), ("MANIFEST", self.manifest), ("MANIFEST_PATH", manifest_path),
                            ("DEFAULT_PROFILE", default)):
            patcher = patch.object(data, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_offline_bundle_replaces_old_models_with_lightweight_data(self):
        output = self.root / "resources"
        (output / "DefaultProfile").mkdir(parents=True)
        (output / "DefaultProfile/old.gram").write_bytes(b"obsolete language model")
        with patch.object(data.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")):
            data.prepare(output)
        self.assertTrue((output / "DefaultProfile/rill_pinyin.schema.yaml").is_file())
        self.assertEqual((output / "DefaultProfile/pinyin_simp.dict.yaml").read_text(), "dictionary fixture")
        self.assertFalse(list(output.rglob("*.gram")))
        self.assertTrue((output / "SharedData/opencc/STCharacters.ocd2").is_file())
        self.assertFalse(list(output.rglob("*.so")))

    def test_modified_cache_is_rejected(self):
        (self.root / "pinyin_simp.dict.yaml").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            data.prepare(self.root / "resources")

    def test_archive_path_escape_and_symbolic_links_are_rejected(self):
        prefix = "opencc/clib/share/opencc/"
        for path, symlink in ((prefix + "../../outside.json", False), (prefix + "linked.json", True)):
            with self.subTest(path=path):
                archive = self.root / "opencc.zip"
                with ZipFile(archive, "w") as bundle:
                    info = ZipInfo(path)
                    if symlink:
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    bundle.writestr(info, "../../outside")
                self.manifest["opencc"]["sha256"] = data.checksum(archive)
                message = "symbolic links" if symlink else "Unsafe input method data path"
                with self.assertRaisesRegex(ValueError, message):
                    data.prepare(self.root / "resources")
                self.assertFalse((self.root / "resources/outside.json").exists())


if __name__ == "__main__":
    unittest.main()
