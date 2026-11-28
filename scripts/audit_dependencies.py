#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Adapt Swift commit pins for OSV-Scanner and reject incomplete scan reports."""

import json
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

from file_input import read_regular_file

ROOT = Path(__file__).resolve().parent.parent


def read(path):
    return read_regular_file(path, max_bytes=32 * 1024 * 1024, follow_symlinks=False)


def unique_keys(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON object keys")
    return result


def scan(report):
    swift = ROOT / "Package.resolved"
    resolved = json.loads(read(swift), object_pairs_hook=unique_keys)
    pins = resolved["pins"]
    if not pins or not isinstance(pins, list):
        raise ValueError("empty or invalid Swift lockfile")
    versions, commits = set(), {}
    for pin in pins:
        name, url, state = pin["identity"], pin["location"], pin["state"]
        sha, version = state["revision"], state.get("version")
        if version is None:
            # SwiftPM records explicit release-tag overrides in the branch field.
            tag = re.fullmatch(r"refs/tags/([0-9]+\.[0-9]+\.[0-9]+)", state.get("branch", ""))
            if not tag:
                raise ValueError(f"Swift pin has no release version: {name!r}")
            version = state["version"] = tag[1]
        if (
            pin["kind"] != "remoteSourceControl"
            or not name
            or name in commits
            or not url.startswith("https://")
            or not isinstance(version, str)
            or not version
            or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", sha)
        ):
            raise ValueError(f"unsupported or duplicate Swift pin: {name!r}")
        commits[name] = sha
        versions.add(
            ("SwiftURL", url.removeprefix("https://").removesuffix(".git"), version)
        )

    tracked = subprocess.check_output(
        ["git", "ls-files", "-z", ":(glob)**/uv.lock", ":(glob)**/*.py.lock"], cwd=ROOT
    )
    locks = sorted(
        {
            ROOT / "tools/uv.lock",
            *(ROOT / p.decode() for p in tracked.split(b"\0") if p),
        }
    )
    expected = {}
    for lock in locks:
        packages = tomllib.loads(read(lock).decode())["package"]
        expected[lock] = {("PyPI", pin["name"], pin["version"]) for pin in packages}
        if not expected[lock]:
            raise ValueError(f"empty Python lockfile: {lock}")

    with tempfile.TemporaryDirectory(prefix="rill-osv-") as tmp:
        if any("branch" in pin["state"] for pin in pins):
            # OSV's Swift extractor reads state.version. Keep the Git SHA scan as well.
            swift = Path(tmp) / "Package.resolved"
            swift.write_text(json.dumps(resolved))
        expected[swift] = versions
        inventory = Path(tmp) / "swift-commits.json"
        # The native Swift extractor supplies URL/version but omits state.revision.
        packages = [
            {"package": {"name": name, "commit": sha}} for name, sha in commits.items()
        ]
        inventory.write_text(json.dumps({"results": [{"packages": packages}]}))
        expected[inventory] = {("GIT", name, sha) for name, sha in commits.items()}
        # Never auto-discover rules that could suppress an advisory in this audit.
        config = inventory.with_name("osv-scanner.toml")
        config.touch()
        subprocess.run(
            [
                "osv-scanner",
                "scan",
                "source",
                "--config",
                str(config),
                "-L",
                f"osv-scanner:{inventory}",
                "-L",
                str(swift),
                *[arg for lock in locks for arg in ("-L", f"uv.lock:{lock}")],
                "--all-packages",
                "--format=json",
                "--output-file",
                str(report),
            ],
            cwd=ROOT,
            check=True,
        )
        observed = {}
        for source in json.loads(read(report), object_pairs_hook=unique_keys)[
            "results"
        ]:
            seen = observed.setdefault(Path(source["source"]["path"]), set())
            for item in source["packages"]:
                package = item["package"]
                ecosystem = package["ecosystem"]
                value = package["commit" if ecosystem == "GIT" else "version"]
                seen.add((ecosystem, package["name"], value))
        for source, packages in expected.items():
            if missing := packages - observed.get(source, set()):
                raise ValueError(
                    f"incomplete OSV inventory for {source}: {sorted(missing)}"
                )


def main():
    report = ROOT / ".artifacts/quality/dependency-osv.json"
    try:
        report.parent.mkdir(parents=True, exist_ok=True)
        report.unlink(missing_ok=True)
        scan(report)
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        AttributeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"OSV-Scanner audit failed: {error}; report: {report}", file=sys.stderr)
        return 1
    print(f"OSV-Scanner dependency audit passed; report: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
