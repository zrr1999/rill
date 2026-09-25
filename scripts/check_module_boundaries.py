#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check architectural dependencies using SwiftPM and the Swift parser."""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = {
    "RillCore": set(),
    "RillSpeechContracts": {"RillCore"},
    "RillRecords": {"RillCore"},
    "RillKnowledge": {"RillCore"},
    "RillSpeech": {"RillCore", "RillPlatform", "RillSpeechContracts"},
    "RillClipboard": {"RillCore", "RillPlatform", "RillRecords"},
    "RillWorkflows": {"RillCore", "RillSpeechContracts", "RillSpeech", "RillRecords", "RillKnowledge"},
    "RillPersistence": {"RillCore"},
    "RillUI": {"RillCore", "RillWorkflows", "RillRecords", "RillKnowledge", "RillSpeech"},
    "RillPlatform": {"RillCore", "TOML"},
    "RillProviders": {"RillCore", "RillSpeechContracts", "RillSpeech", "OpenAI"},
    "RillSpeechWorker": {"RillCore", "RillSpeechContracts", "RillMLXRuntime"},
}
DOMAIN_IMPORTS = {"Foundation", "CryptoKit", "Dispatch", "Darwin", "RillCore"}


def output(*command: str) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True)


def main() -> None:
    package = json.loads(output("swift", "package", "dump-package"))
    targets = {target["name"]: target for target in package["targets"]}
    for name, expected in DEPENDENCIES.items():
        dependencies = targets[name]["dependencies"]
        actual = {next(iter(dependency.values()))[0] for dependency in dependencies}
        if actual != expected:
            raise SystemExit(f"{name}: expected dependencies {sorted(expected)}, found {sorted(actual)}")
    mlx_dependencies = {next(iter(dependency.values()))[0] for dependency in targets["RillMLXRuntime"]["dependencies"]}
    if mlx_dependencies & {"RillSpeech", "RillProviders", "RillPlatform", "RillApp", "OpenAI", "TOML"}:
        raise SystemExit("MLX runtime must depend on shared speech contracts without host providers")
    for name in ("RillCore", "RillRecords", "RillKnowledge", "RillWorkflows", "RillSpeechContracts"):
        sources = sorted(str(path) for path in (ROOT / "Sources" / name).rglob("*.swift"))
        imports = set(output("swiftc", "-frontend", "-emit-imported-modules", *sources).splitlines())
        allowed = DOMAIN_IMPORTS | DEPENDENCIES[name]
        if name == "RillKnowledge":
            allowed |= {"NaturalLanguage"}
        if unexpected := imports - allowed:
            raise SystemExit(f"{name}: platform or SDK imports escaped their adapters: {sorted(unexpected)}")
    print("Module boundaries passed (SwiftPM graph and parsed imports)")


if __name__ == "__main__":
    main()
