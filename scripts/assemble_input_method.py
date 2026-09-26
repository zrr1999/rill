#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Assemble and sign the standalone InputMethodKit frontend and its pinned Rime runtime."""

import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from prepare_rime import prepare
from prepare_input_method_data import prepare as prepare_data

CODESIGN = "/usr/bin/codesign"


def assemble(executable: Path, output: Path) -> None:
    executable = executable.resolve(strict=True)
    output = output.resolve()
    runtime = prepare()
    contents = output / "Contents"
    for name in ("MacOS", "Frameworks", "Helpers", "Resources"):
        (contents / name).mkdir(parents=True, exist_ok=True)
    prepare_data(contents / "Resources")
    shutil.copy2(executable, contents / "MacOS/RillInputMethod")
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks",
                    str(contents / "MacOS/RillInputMethod")], check=True)
    shutil.copy2(runtime / "lib/librime.1.16.0.dylib", contents / "Frameworks/librime.1.dylib")
    shutil.copytree(runtime / "lib/rime-plugins", contents / "Frameworks/rime-plugins", dirs_exist_ok=True)
    for name in ("rime_deployer", "rime_dict_manager"):
        target = contents / "Helpers" / name
        shutil.copy2(runtime / "bin" / name, target)
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path/../Frameworks", str(target)], check=True)
    identifier = "dev.zrr.inputmethod.Rill"
    input_source_id = identifier + ".Hans"
    info = {
        "CFBundleIdentifier": identifier, "CFBundleName": "Rill", "CFBundleDisplayName": "Rill",
        "CFBundleExecutable": "RillInputMethod", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        "InputMethodConnectionName": "RillInputMethodConnection",
        "InputMethodServerControllerClass": "RillInputController",
        "TISInputSourceID": identifier,
        "ComponentInputModeDict": {
            "tsInputModeListKey": {input_source_id: {
                "TISInputSourceID": input_source_id, "TISIntendedLanguage": "zh-Hans",
                "tsInputModeCharacterRepertoireKey": ["Hans", "Hant", "Latn"],
                "tsInputModeDefaultStateKey": True, "tsInputModeIsVisibleKey": True,
                "tsInputModePrimaryInScriptKey": True, "tsInputModeScriptKey": "smUnicodeScript",
            }}, "tsVisibleInputModeOrderedArrayKey": [input_source_id],
        },
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    notices = Path(__file__).resolve().parent.parent / "docs/input-method-dependencies.md"
    shutil.copy2(notices, contents / "Resources/THIRD_PARTY_NOTICES.md")
    shutil.copytree(notices.parent.parent / "Resources/InputMethodLicenses",
                    contents / "Resources/Licenses", dirs_exist_ok=True)


def sign_bundle(output: Path, identity: str) -> None:
    if identity != "-" and re.fullmatch(r"[0-9A-Fa-f]{40}", identity) is None:
        raise ValueError("Signing identity must be '-' or a SHA-1 certificate hash")
    output = output.resolve(strict=True)
    if output.suffix != ".app" or not output.is_dir():
        raise ValueError("Signing target must be an existing app bundle")
    contents = output / "Contents"
    timestamp = ["--timestamp"] if identity != "-" else []
    # Ad-hoc signatures have no team identity for hardened library validation.
    options = "runtime" if identity != "-" else "0"
    binaries = [*sorted((contents / "Frameworks").rglob("*.dylib")),
                *sorted((contents / "Helpers").iterdir())]
    for binary in binaries:
        target = binary.resolve(strict=True)
        if not target.is_file() or not target.is_relative_to(output):
            raise ValueError(f"Signing target escapes the app bundle: {binary}")
    for binary in binaries:
        subprocess.run([CODESIGN, "--force", "--options", options,
                        *timestamp, "--sign", identity, "--", str(binary)], check=True)
    subprocess.run([CODESIGN, "--force", "--options", options,
                    *timestamp, "--sign", identity, "--", str(output)], check=True)
    subprocess.run([CODESIGN, "--verify", "--deep", "--strict", "--", str(output)], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sign-existing", type=Path)
    parser.add_argument("--unsigned", action="store_true")
    parser.add_argument("--signing-identity", default="-")
    args = parser.parse_args()
    if args.sign_existing:
        sign_bundle(args.sign_existing, args.signing_identity)
    elif args.executable is not None and args.output is not None:
        assemble(args.executable, args.output)
        if not args.unsigned:
            sign_bundle(args.output, args.signing_identity)
    else:
        parser.error("--executable and --output are required when assembling")
