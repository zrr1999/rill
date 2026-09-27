#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Exercise the packaged Rime ABI, plugins, deployment, composition and userdb reopen."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(bundle: Path) -> None:
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    run(parser.parse_args().bundle)
