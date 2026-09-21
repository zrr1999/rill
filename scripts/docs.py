#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["zensical==0.0.63"]
# ///
"""Stage the maintained Markdown sources, then run the pinned Zensical CLI."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import time
import tomllib


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".artifacts/docs/source"


def navigation_paths(value):
    if isinstance(value, str):
        if "://" not in value:
            yield value
    elif isinstance(value, list):
        for child in value:
            yield from navigation_paths(child)
    elif isinstance(value, dict):
        for child in value.values():
            yield from navigation_paths(child)


def stage():
    config = tomllib.loads((ROOT / "zensical.toml").read_text())["project"]
    paths = set(navigation_paths(config["nav"]))
    paths.update(config["extra"]["docs_assets"])
    targets = set()
    for name in sorted(paths):
        source = ROOT / name
        content = source.read_bytes()
        # The preview server treats extensionless URLs as directories.
        if source.suffix == ".md":
            content = re.sub(rb"(\]\((?:\.\./)*)LICENSE(?=[)#])", rb"\1LICENSE.txt", content)
        target = SOURCE / ("LICENSE.txt" if name == "LICENSE" else name)
        targets.add(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != content:
            target.write_bytes(content)
    for target in SOURCE.rglob("*"):
        if target.is_file() and target not in targets:
            target.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "serve"])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    stage()
    if args.command == "build":
        return subprocess.call(
            [sys.executable, "-m", "zensical", "build", "--clean", "--strict"], cwd=ROOT
        )

    # Zensical watches staged inputs; synchronize original Markdown while serving.
    process = subprocess.Popen(
        [sys.executable, "-m", "zensical", "serve", "--dev-addr", f"127.0.0.1:{args.port}"],
        cwd=ROOT,
    )
    try:
        while process.poll() is None:
            time.sleep(0.5)
            stage()
        return process.returncode
    except KeyboardInterrupt:
        return 0
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
