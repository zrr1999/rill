#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Bundle public, checksum-pinned Rime data without reading any installed input method."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import urllib.request
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "scripts/input_method_data_manifest.json"
MANIFEST = json.loads(MANIFEST_PATH.read_text())
CACHE = ROOT / ".artifacts/input-method/default-assets"
DEFAULT_PROFILE = ROOT / "Resources/InputMethodDefaultProfile"


def checksum(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def asset(name: str) -> Path:
    entry = MANIFEST[name]
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / entry["filename"]
    if not target.exists():
        with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
            download = Path(temporary) / "download"
            with urllib.request.urlopen(entry["url"], timeout=60) as response, download.open("wb") as output:
                shutil.copyfileobj(response, output)
            if checksum(download) != entry["sha256"]:
                raise ValueError(f"{name} download checksum mismatch")
            download.replace(target)
    if target.is_symlink() or checksum(target) != entry["sha256"]:
        raise ValueError(f"{name} cached asset checksum mismatch")
    return target


def copy_zip_entry(archive: ZipFile, name: str, destination: Path, relative: PurePosixPath) -> None:
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Unsafe input method data path")
    if stat.S_ISLNK(archive.getinfo(name).external_attr >> 16):
        raise ValueError("Input method data must not contain symbolic links")
    target = destination.joinpath(*relative.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(name) as source, target.open("wb") as output:
        shutil.copyfileobj(source, output)


def prepare(resources: Path) -> None:
    profile = resources / "DefaultProfile"
    shared = resources / "SharedData/opencc"
    for directory in (profile, shared.parent):
        if directory.exists():
            shutil.rmtree(directory)
        directory.mkdir(parents=True)
    shutil.copytree(DEFAULT_PROFILE, profile, dirs_exist_ok=True)
    shutil.copy2(asset("pinyin"), profile / MANIFEST["pinyin"]["filename"])
    # Only architecture-independent dictionaries/configs, never the wheel's Python or native code.
    prefix = "opencc/clib/share/opencc/"
    with ZipFile(asset("opencc")) as archive:
        for name in archive.namelist():
            if name.startswith(prefix) and name.endswith((".json", ".ocd2")):
                copy_zip_entry(archive, name, shared, PurePosixPath(name.removeprefix(prefix)))
    for required in (profile / "rill_pinyin.schema.yaml", profile / "default.yaml", shared / "s2t.json"):
        if not required.is_file():
            raise ValueError(f"Missing bundled input method data: {required.name}")
    shutil.copy2(MANIFEST_PATH, resources / "InputMethodDataManifest.json")
