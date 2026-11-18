#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check input method packaging offline, or validate a bundle and frozen migration profiles."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import assemble_input_method as assembly


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
            with patch("assemble_input_method.prepare_runtime", return_value=runtime), \
                    patch("assemble_input_method.prepare_data"), \
                    patch("assemble_input_method.subprocess.run"):
                assembly.assemble(executable, bundle)

            contents = bundle / "Contents"
            info = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertIs(info["TISIconIsTemplate"], True)
            icons = [info["tsInputMethodIconFileKey"], info["CFBundleIconFile"]]
            modes = info["ComponentInputModeDict"]["tsInputModeListKey"].values()
            for mode in modes:
                icons.extend(mode[key] for key in (
                    "tsInputModeMenuIconFileKey", "tsInputModeAlternateMenuIconFileKey",
                    "tsInputModePaletteIconFileKey",
                ))
            brand = Path(__file__).resolve().parents[2] / "Resources/AppIcon/RillInputMethodTemplate.tiff"
            expected_name = f"RillInputMethod-{hashlib.sha256(brand.read_bytes()).hexdigest()[:16]}.tiff"
            for icon in icons:
                with self.subTest(icon=icon):
                    self.assertEqual(icon, expected_name)
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
                    assembly.sign_bundle(Path(bundle.name), "-")
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
                    assembly.sign_bundle(bundle, "--timestamp")
                run.assert_not_called()
                outside = root / "outside.dylib"
                outside.write_bytes(b"outside")
                (bundle / "Contents/Frameworks/escape.dylib").symlink_to(outside)
                with self.assertRaises(ValueError):
                    assembly.sign_bundle(bundle, "-")
                run.assert_not_called()

    def test_release_identity_is_a_certificate_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.make_bundle(Path(temporary))
            with patch("assemble_input_method.subprocess.run") as run:
                assembly.sign_bundle(bundle, "A" * 40)
            self.assertIn("--timestamp", run.call_args_list[0].args[0])


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
        self.manifest["pinyin"] = {"filename": dictionary.name, "sha256": assembly.checksum(dictionary)}
        archive = self.root / "opencc.zip"
        with ZipFile(archive, "w") as bundle:
            for path, contents in {
                "opencc/clib/share/opencc/s2t.json": "{}",
                "opencc/clib/share/opencc/STCharacters.ocd2": "dictionary",
                "opencc/clib/opencc.so": "Unwanted native code",
            }.items():
                bundle.writestr(path, contents)
        self.manifest["opencc"] = {"filename": archive.name, "sha256": assembly.checksum(archive)}
        manifest_path = self.root / "manifest.json"
        manifest_path.write_text(json.dumps(self.manifest))
        for name, value in (("DATA_CACHE", self.root), ("DATA_MANIFEST", self.manifest), ("DATA_MANIFEST_PATH", manifest_path),
                            ("DEFAULT_PROFILE", default)):
            patcher = patch.object(assembly, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_offline_bundle_replaces_old_models_with_lightweight_data(self):
        output = self.root / "resources"
        (output / "DefaultProfile").mkdir(parents=True)
        (output / "DefaultProfile/old.gram").write_bytes(b"obsolete language model")
        with patch.object(assembly.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network access")):
            assembly.prepare_data(output)
        self.assertTrue((output / "DefaultProfile/rill_pinyin.schema.yaml").is_file())
        self.assertEqual((output / "DefaultProfile/pinyin_simp.dict.yaml").read_text(), "dictionary fixture")
        self.assertFalse(list(output.rglob("*.gram")))
        self.assertTrue((output / "SharedData/opencc/STCharacters.ocd2").is_file())
        self.assertFalse(list(output.rglob("*.so")))

    def test_modified_cache_is_rejected(self):
        (self.root / "pinyin_simp.dict.yaml").write_bytes(b"modified")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            assembly.prepare_data(self.root / "resources")

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
                self.manifest["opencc"]["sha256"] = assembly.checksum(archive)
                message = "symbolic links" if symlink else "Unsafe input method data path"
                with self.assertRaisesRegex(ValueError, message):
                    assembly.prepare_data(self.root / "resources")
                self.assertFalse((self.root / "resources/outside.json").exists())


def check_bundle(bundle: Path) -> None:
    bundle = bundle.resolve()
    contents = bundle / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    assert identifier == "dev.zrr.inputmethod.Rill"
    assert ".inputmethod." in identifier
    mode = info["ComponentInputModeDict"]["tsInputModeListKey"][identifier + ".Hans"]
    assert mode["TISInputSourceID"] == identifier + ".Hans"
    assert mode["tsInputModeIsVisibleKey"] is True
    for language in ("en", "zh-Hans", "zh-Hant"):
        names = plistlib.loads((contents / "Resources" / f"{language}.lproj/InfoPlist.strings").read_bytes())
        assert names[identifier + ".Hans"] == "Rill"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    with tempfile.TemporaryDirectory(prefix="rill-ime-test-") as temporary:
        root = Path(temporary)
        profile = root / "profile"
        shutil.copytree(contents / "Resources/SharedData", profile)
        (profile / "default.yaml").write_text(
            "config_version: '1'\nschema_list:\n  - schema: wanxiang\nmenu:\n  page_size: 6\n"
        )
        (profile / "wanxiang.schema.yaml").write_text(
            """schema:
  schema_id: wanxiang
  name: Rill integration fixture
  version: '1'
engine:
  processors: [ascii_composer, speller, selector, navigator, express_editor]
  segmentors: [ascii_segmentor, abc_segmentor, fallback_segmentor]
  translators: [table_translator]
  filters: [simplifier]
switches:
  - {name: simplification, reset: 1}
simplifier:
  option_name: simplification
  opencc_config: s2t.json
speller:
  alphabet: abcdefghijklmnopqrstuvwxyz
translator:
  dictionary: wanxiang
  enable_sentence: false
  enable_user_dict: true
menu:
  page_size: 6
"""
        )
        (profile / "wanxiang.dict.yaml").write_text(
            "---\nname: wanxiang\nversion: '1'\nsort: by_weight\n"
            "use_preset_vocabulary: false\n...\n你好\tnihao\t100\n泥好\tnihao\t10\n"
            "世界\tshijie\t100\n汉字\thanzi\t100\n"
        )
        subprocess.run(
            [str(contents / "Helpers/rime_deployer"), "--build", str(profile), str(profile), str(profile / "build")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60,
        )
        inputs = root / "inputs.json"
        inputs.write_text(json.dumps(["nihao", "shijie", "hanzi"]))
        output = root / "output.json"
        executable = str(contents / "MacOS/RillInputMethod")
        subprocess.run([executable, "--probe-profile", str(profile), str(inputs), str(output)],
                       check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        first = json.loads(output.read_text())
        assert first[0]["candidates"][:2] == ["你好", "泥好"], first
        assert first[0]["committed"] == "你好"
        assert first[1]["committed"] == "世界"
        assert first[2]["committed"] == "漢字", "Bundled OpenCC conversion did not run"
        assert (profile / "wanxiang.userdb").is_dir()
        copied = root / "copied"
        shutil.copytree(profile, copied)
        subprocess.run([executable, "--probe-profile", str(copied), str(inputs), str(output)],
                       check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert json.loads(output.read_text()) == first
        # Fresh daily-use profile, entirely from the app; Squirrel and ~/Library/Rime are never read.
        default = root / "default"
        shutil.copytree(contents / "Resources/SharedData", default)
        shutil.copytree(contents / "Resources/DefaultProfile", default, dirs_exist_ok=True)
        assert not list(default.glob("*.userdb")), "Packaged default must not include personal databases"
        assert not list(default.rglob("*.gram")), "The lightweight default must not include a language model"
        subprocess.run(
            [str(contents / "Helpers/rime_deployer"), "--build", str(default), str(default), str(default / "build")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180,
        )
        inputs.write_text(json.dumps(["nihao", "shurufa", "zhongwen"]))
        subprocess.run([executable, "--probe-profile", str(default), str(inputs), str(output)],
                       check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        fresh = json.loads(output.read_text())
        assert [item["committed"] for item in fresh] == ["你好", "输入法", "中文"], fresh
        assert all(len(item["candidates"]) == 6 for item in fresh), fresh
    print("Packaged input method: lightweight pinyin default, Rime/plugins, candidates, commits and userdb passed.")


def database_hashes(profile: Path) -> dict[str, str]:
    return {str(path.relative_to(profile)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(profile.glob("*.userdb/*")) if path.is_file()}


def prepare_copy(source: Path, target: Path, shared: Path) -> None:
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("engine.lock", "sync"))
    for path in shared.rglob("*"):
        relative = path.relative_to(shared)
        destination = target / relative
        if path.is_file() and not destination.exists() and relative.parts[0] != "build":
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
    sync = str(target / "sync").replace("'", "''")
    (target / "installation.yaml").write_text(
        f"installation_id: 'rill-validation'\nsync_dir: '{sync}'\n"
    )


def backup(profile: Path, helper: Path) -> list[tuple[str, str, str]]:
    subprocess.run([str(helper), "-b", "wanxiang"], cwd=profile, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    text = (profile / "sync/rill-validation/wanxiang.userdb.txt").read_text()
    rows = [tuple(line.split("\t")) for line in text.splitlines() if line and not line.startswith("#")]
    assert rows and all(len(row) == 3 for row in rows), "Unexpected database backup format"
    assert all({v.split("=")[0] for v in row[2].split()} == {"c", "d", "t"} for row in rows)
    return rows


def check_migration(args: argparse.Namespace) -> None:
    original, migrated, bundle = args.original.resolve(), args.migrated.resolve(), args.bundle.resolve()
    before = database_hashes(original)
    assert before and before == database_hashes(migrated), "Complete database files differ"
    contents = bundle / "Contents"
    shared = args.shared or contents / "Resources/SharedData"
    inputs = ["nihao", "shurufa", "jianqieban", "yuyinshibie", "gongzuoliu", "zhongwen", "ceshi", "rill"]
    with tempfile.TemporaryDirectory(prefix="rill-migration-") as temporary:
        root = Path(temporary)
        copies = [root / "original", root / "migrated"]
        for source, target in zip((original, migrated), copies, strict=True):
            prepare_copy(source, target, shared)
        old_rows, new_rows = [backup(copy, contents / "Helpers/rime_dict_manager") for copy in copies]
        assert Counter(old_rows) == Counter(new_rows), "Reading, phrase, count or dynamic weight differs"
        input_file = root / "inputs.json"
        input_file.write_text(json.dumps(inputs))
        outputs = []
        for index, copy in enumerate(copies):
            output = root / f"output-{index}.json"
            subprocess.run([str(contents / "MacOS/RillInputMethod"), "--probe-profile", str(copy),
                            str(input_file), str(output)], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
            outputs.append(json.loads(output.read_text()))
        matches = sum(old == new for old, new in zip(*outputs, strict=True))
        assert matches == len(inputs), f"Candidate/commit replay matched only {matches}/{len(inputs)} inputs"
    assert database_hashes(original) == before == database_hashes(migrated), "Frozen snapshots changed"
    report = {
        "complete_database_files_identical": len(before),
        "reading_phrase_rows": len(old_rows),
        "unique_phrases": len({row[1] for row in old_rows}),
        "reading_phrase_count_weight_tick_equal": True,
        "fixed_inputs": inputs,
        "identical_candidate_and_commit_replays": matches,
        "engine": "packaged Rime 1.16.0 for both copies",
        "source_profiles_unchanged": True,
    }
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command")
    bundle = commands.add_parser("bundle", help="Validate a signed input method bundle")
    bundle.add_argument("bundle", type=Path)
    migration = commands.add_parser("migration", help="Compare frozen profiles on disposable copies")
    migration.add_argument("--original", type=Path, required=True, help="Already frozen Squirrel snapshot")
    migration.add_argument("--migrated", type=Path, required=True, help="Imported Rill snapshot")
    migration.add_argument("--bundle", type=Path, required=True)
    migration.add_argument("--shared", type=Path, help="Defaults to the packaged Rill SharedData")
    migration.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "bundle":
        check_bundle(args.bundle)
    elif args.command == "migration":
        check_migration(args)
    else:
        unittest.main(argv=[sys.argv[0]])
