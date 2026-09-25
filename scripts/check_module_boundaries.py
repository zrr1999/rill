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
    "RillTestSupport": {"RillCore", "RillRuntime", "RillUI"},
    "RillSpeechContracts": {"RillCore"},
    "RillRuntime": {"RillCore"},
    "RillPersistence": {"RillCore"},
    "RillUI": {"RillCore", "RillRuntime"},
    "RillPlatform": {"RillCore", "TOML"},
    "RillProviders": {"RillCore", "RillSpeechContracts", "OpenAI"},
    "RillApp": {"RillCore", "RillSpeechContracts", "RillRuntime", "RillPlatform",
                "RillProviders", "RillPersistence", "RillUI"},
    "RillMLXRuntime": {"RillCore", "RillSpeechContracts", "MLXAudioCore", "MLXAudioSTT",
                       "MLXAudioTTS", "MLXAudioVAD", "MLX", "MLXNN", "MLXEmbedders",
                       "MLXHuggingFace", "MLXLMCommon", "Tokenizers", "HuggingFace"},
    "RillSpeechWorker": {"RillCore", "RillSpeechContracts", "RillMLXRuntime"},
}
FOUNDATION_IMPORTS = {"Foundation", "CryptoKit", "Dispatch", "Darwin"}
SYSTEM_IMPORTS = {
    "RillCore": FOUNDATION_IMPORTS,
    "RillTestSupport": FOUNDATION_IMPORTS,
    "RillSpeechContracts": FOUNDATION_IMPORTS,
    "RillRuntime": FOUNDATION_IMPORTS,
    "RillMLXRuntime": FOUNDATION_IMPORTS,
    "RillSpeechWorker": FOUNDATION_IMPORTS,
    "RillPersistence": FOUNDATION_IMPORTS | {"OSLog", "SQLite3"},
    "RillProviders": FOUNDATION_IMPORTS | {"AVFoundation", "AudioToolbox", "OSLog"},
    "RillPlatform": FOUNDATION_IMPORTS | {"AVFoundation", "AppKit", "ApplicationServices",
        "Carbon", "CoreGraphics", "ImageIO", "Observation", "ScreenCaptureKit", "Security",
        "UniformTypeIdentifiers"},
    "RillUI": FOUNDATION_IMPORTS | {"AppKit", "Carbon", "ImageIO", "Observation", "Quartz",
        "QuartzCore", "QuickLookThumbnailing", "SwiftUI", "UniformTypeIdentifiers"},
    "RillApp": FOUNDATION_IMPORTS | {"AppKit", "ApplicationServices", "Combine", "QuartzCore", "SwiftUI"},
}
TEST_IMPORTS = set().union(*SYSTEM_IMPORTS.values()) | {"Testing", "XCTest", "os"}


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
    production = {name for name, target in targets.items() if target["type"] != "test"}
    if production != DEPENDENCIES.keys():
        raise SystemExit(f"Every production target needs an explicit policy: {sorted(production ^ DEPENDENCIES.keys())}")
    for name, target in targets.items():
        is_test = target["type"] == "test"
        source_root = ROOT / target.get("path", str(Path("Tests" if is_test else "Sources") / name))
        sources = sorted(str(path) for path in source_root.rglob("*.swift"))
        if not sources:
            raise SystemExit(f"{name}: no source files checked")
        imports = {module.split(".")[0] for module in output(
            "swiftc", "-frontend", "-swift-version", "6", "-module-name", name, "-emit-imported-modules", *sources).splitlines()}
        declared = {next(iter(dependency.values()))[0] for dependency in target["dependencies"]}
        permitted = declared | (TEST_IMPORTS if is_test else SYSTEM_IMPORTS[name])
        if unexpected := imports - permitted:
            raise SystemExit(f"{name}: undeclared or forbidden imports: {sorted(unexpected)}")
    print("Module boundaries passed (SwiftPM graph and parsed imports)")


if __name__ == "__main__":
    main()
