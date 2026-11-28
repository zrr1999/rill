#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Assemble and sign the standalone InputMethodKit frontend and its pinned Rime runtime."""

import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
RIME_MANIFEST = json.loads((ROOT / "scripts/rime_runtime_manifest.json").read_text())
DATA_MANIFEST_PATH = ROOT / "scripts/input_method_data_manifest.json"
DATA_MANIFEST = json.loads(DATA_MANIFEST_PATH.read_text())
DATA_CACHE = ROOT / ".artifacts/input-method/default-assets"
DEFAULT_PROFILE = ROOT / "Resources/InputMethodDefaultProfile"
CODESIGN = "/usr/bin/codesign"


def checksum(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_runtime(directory: Path) -> bool:
    return all(
        (directory / name).is_file()
        and not (directory / name).is_symlink()
        and checksum(directory / name) == digest
        for entry in RIME_MANIFEST["files"]
        for name, digest in [(entry["path"], entry["sha256"])]
    )


def prepare_runtime() -> Path:
    version = RIME_MANIFEST["version"]
    digest = RIME_MANIFEST["archive_sha256"]
    destination = ROOT / ".artifacts" / "rime" / version
    receipt = destination / "archive.sha256"
    if receipt.is_file() and receipt.read_text().strip() == digest and verify_runtime(destination):
        return destination
    archive_cache = destination.parent / f"rime-{version}.tar.bz2"
    if archive_cache.is_file():
        archive = archive_cache.read_bytes()
    else:
        with urllib.request.urlopen(RIME_MANIFEST["archive_url"], timeout=60) as response:
            archive = response.read()
    if hashlib.sha256(archive).hexdigest() != digest:
        raise ValueError("Rime archive checksum mismatch")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:bz2") as bundle:
            bundle.extractall(staging, filter="data")
        if not verify_runtime(staging / "dist"):
            raise ValueError("Rime runtime file checksum mismatch")
        (staging / "dist" / "archive.sha256").write_text(digest + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(staging / "dist"), destination)
    return destination


def asset(name: str) -> Path:
    entry = DATA_MANIFEST[name]
    DATA_CACHE.mkdir(parents=True, exist_ok=True)
    target = DATA_CACHE / entry["filename"]
    if not target.exists():
        with tempfile.TemporaryDirectory(dir=DATA_CACHE) as temporary:
            download = Path(temporary) / "download"
            with urllib.request.urlopen(entry["url"], timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
            if checksum(download) != entry["sha256"]:
                raise ValueError(f"{name} download checksum mismatch")
            download.replace(target)
    if target.is_symlink() or checksum(target) != entry["sha256"]:
        raise ValueError(f"{name} cached asset checksum mismatch")
    return target


def prepare_data(resources: Path) -> None:
    profile = resources / "DefaultProfile"
    shared = resources / "SharedData/opencc"
    for directory in (profile, shared.parent):
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True)
    shutil.copytree(DEFAULT_PROFILE, profile, dirs_exist_ok=True)
    shutil.copy2(asset("pinyin"), profile / DATA_MANIFEST["pinyin"]["filename"])
    # Only architecture-independent dictionaries/configs, never the wheel's Python or native code.
    prefix = "opencc/clib/share/opencc/"
    with ZipFile(asset("opencc")) as archive:
        for name in archive.namelist():
            if name.startswith(prefix) and name.endswith((".json", ".ocd2")):
                relative = PurePosixPath(name.removeprefix(prefix))
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Unsafe input method data path")
                if stat.S_ISLNK(archive.getinfo(name).external_attr >> 16):
                    raise ValueError("Input method data must not contain symbolic links")
                target = shared.joinpath(*relative.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
    for required in (profile / "rill_pinyin.schema.yaml", profile / "default.yaml", shared / "s2t.json"):
        if not required.is_file():
            raise ValueError(f"Missing bundled input method data: {required.name}")
    shutil.copy2(DATA_MANIFEST_PATH, resources / "InputMethodDataManifest.json")


def assemble(executable: Path, output: Path) -> None:
    executable = executable.resolve(strict=True)
    output = output.resolve()
    runtime = prepare_runtime()
    contents = output / "Contents"
    for name in ("MacOS", "Frameworks", "Helpers", "Resources"):
        (contents / name).mkdir(parents=True, exist_ok=True)
    prepare_data(contents / "Resources")
    icon = ROOT / "Resources/AppIcon/RillInputMethodTemplate.tiff"
    icon_name = f"RillInputMethod-{hashlib.sha256(icon.read_bytes()).hexdigest()[:16]}Template.tiff"
    shutil.copy2(icon, contents / "Resources" / icon_name)
    shutil.copy2(executable, contents / "MacOS/RillInputMethod")
    subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks",
                    str(contents / "MacOS/RillInputMethod")], check=True)
    shutil.copy2(runtime / "lib" / f"librime.{RIME_MANIFEST['version']}.dylib", contents / "Frameworks/librime.1.dylib")
    shutil.copytree(runtime / "lib/rime-plugins", contents / "Frameworks/rime-plugins", dirs_exist_ok=True)
    for name in ("rime_deployer", "rime_dict_manager"):
        target = contents / "Helpers" / name
        shutil.copy2(runtime / "bin" / name, target)
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path/../Frameworks", str(target)], check=True)
    identifier = "dev.zrr.inputmethod.Rill"
    input_source_id = identifier + ".Hans"
    info = {
        "CFBundleIdentifier": identifier, "CFBundleName": "Rill", "CFBundleDisplayName": "Rill",
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "RillInputMethod", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "3", "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "26.0",
        "CFBundleIconFile": icon_name,
        "LSUIElement": True, "NSPrincipalClass": "NSApplication",
        "InputMethodConnectionName": "RillInputMethodConnection",
        "InputMethodServerControllerClass": "RillInputController",
        "TISInputSourceID": identifier,
        "TISIconIsTemplate": True, "tsInputMethodIconFileKey": icon_name,
        "ComponentInputModeDict": {
            "tsInputModeListKey": {input_source_id: {
                "TISInputSourceID": input_source_id, "TISIntendedLanguage": "zh-Hans",
                "tsInputModeMenuIconFileKey": icon_name,
                "tsInputModeAlternateMenuIconFileKey": icon_name,
                "tsInputModePaletteIconFileKey": icon_name,
                "tsInputModeCharacterRepertoireKey": ["Hans", "Hant", "Latn"],
                "tsInputModeDefaultStateKey": True, "tsInputModeIsVisibleKey": True,
                "tsInputModePrimaryInScriptKey": True, "tsInputModeScriptKey": "smUnicodeScript",
            }}, "tsVisibleInputModeOrderedArrayKey": [input_source_id],
        },
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    for language in ("en", "zh-Hans", "zh-Hant"):
        localized = contents / "Resources" / f"{language}.lproj"
        localized.mkdir(parents=True, exist_ok=True)
        (localized / "InfoPlist.strings").write_bytes(plistlib.dumps({
            "CFBundleName": "Rill", "CFBundleDisplayName": "Rill",
            identifier: "Rill", input_source_id: "Rill",
        }))
    notices = ROOT / "docs/input-method-dependencies.md"
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
