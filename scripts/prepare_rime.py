#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fetch the reviewed Rime runtime into the ignored artifact cache."""

import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "scripts/rime_runtime_manifest.json").read_text())
VERSION = MANIFEST["version"]
SHA256 = MANIFEST["archive_sha256"]
URL = MANIFEST["archive_url"]


def verify(directory: Path) -> bool:
    return all(
        (directory / name).is_file()
        and not (directory / name).is_symlink()
        and hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest
        for entry in MANIFEST["files"]
        for name, digest in [(entry["path"], entry["sha256"])]
    )


def prepare() -> Path:
    destination = ROOT / ".artifacts" / "rime" / VERSION
    receipt = destination / "archive.sha256"
    if receipt.is_file() and receipt.read_text().strip() == SHA256 and verify(destination):
        return destination
    archive_cache = destination.parent / f"rime-{VERSION}.tar.bz2"
    if archive_cache.is_file():
        archive = archive_cache.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=60) as response:
            archive = response.read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise ValueError("Rime archive checksum mismatch")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:bz2") as bundle:
            bundle.extractall(staging, filter="data")
        if not verify(staging / "dist"):
            raise ValueError("Rime runtime file checksum mismatch")
        (staging / "dist" / "archive.sha256").write_text(SHA256 + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(staging / "dist"), destination)
    return destination


if __name__ == "__main__":
    print(prepare())
