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
    "CRime": set(),
    "RillInputMethodContracts": set(),
    "RillInputMethodIPC": {"RillInputMethodContracts"},
    "RillInputMethodKit": {"CRime", "RillInputMethodContracts", "RillInputMethodIPC"},
    "RillInputMethod": {"RillInputMethodContracts", "RillInputMethodKit"},
    "RillSpeechContracts": {"RillCore"},
    "RillRecords": {"RillCore"},
    "RillKnowledge": {"RillCore"},
    "RillSpeech": {"RillCore", "RillSpeechContracts"},
    "RillClipboard": {"RillCore", "RillPlatform", "RillRecords"},
    "RillWorkflows": {"RillCore", "RillKnowledge", "RillRecords"},
    "RillPersistence": {"GRDB", "RillCore"},
    "RillPlatform": {"RillCore", "RillInputMethodContracts", "TOML"},
    "RillProviders": {"OpenAI", "RillCore", "RillSpeech", "RillSpeechContracts"},
    "RillUI": {"RillCore", "RillInputMethodContracts", "RillInputMethodIPC", "RillKnowledge", "RillRecords", "RillWorkflows"},
    "RillApp": {"RillClipboard", "RillCore", "RillKnowledge", "RillPersistence", "RillPlatform", "RillProviders", "RillRecords", "RillSpeech", "RillSpeechContracts", "RillUI", "RillWorkflows"},
    "RillMLXRuntime": {"HuggingFace", "MLX", "MLXAudioCore", "MLXAudioSTT", "MLXAudioTTS", "MLXAudioVAD", "MLXEmbedders", "MLXHuggingFace", "MLXLMCommon", "MLXNN", "RillCore", "RillSpeechContracts", "Tokenizers"},
    "RillSpeechWorker": {"RillMLXRuntime", "RillSpeechContracts"},
    "RillTestSupport": {"RillCore", "RillKnowledge", "RillRecords", "RillSpeech", "RillUI", "RillWorkflows"},
    "RillDomainTestSupport": {"RillCore", "RillKnowledge", "RillPlatform", "RillRecords", "RillSpeech", "RillWorkflows"},
}

FOUNDATION_IMPORTS = {"Foundation", "CryptoKit", "Dispatch", "Darwin"}
SYSTEM_IMPORTS = {
    "RillCore": FOUNDATION_IMPORTS | {"Synchronization"},
    "RillTestSupport": FOUNDATION_IMPORTS | {"AppKit", "XCTest"},
    "RillDomainTestSupport": FOUNDATION_IMPORTS,
    "RillSpeechContracts": FOUNDATION_IMPORTS,
    "RillRecords": FOUNDATION_IMPORTS,
    "RillKnowledge": FOUNDATION_IMPORTS | {"NaturalLanguage"},
    "RillSpeech": FOUNDATION_IMPORTS | {"OSLog"},
    "RillWorkflows": FOUNDATION_IMPORTS,
    "RillClipboard": FOUNDATION_IMPORTS | {"AppKit", "ApplicationServices"},
    "CRime": set(),
    "RillInputMethodContracts": FOUNDATION_IMPORTS,
    "RillInputMethodIPC": FOUNDATION_IMPORTS | {"Security"},
    "RillInputMethodKit": FOUNDATION_IMPORTS | {"AppKit", "InputMethodKit", "Carbon", "Combine", "SwiftUI"},
    "RillInputMethod": FOUNDATION_IMPORTS | {"AppKit", "InputMethodKit"},
    "RillMLXRuntime": FOUNDATION_IMPORTS,
    "RillSpeechWorker": FOUNDATION_IMPORTS,
    "RillPersistence": FOUNDATION_IMPORTS | {"OSLog", "SQLite3"},
    "RillProviders": FOUNDATION_IMPORTS | {"OSLog"},
    "RillPlatform": FOUNDATION_IMPORTS | {"AVFoundation", "AudioToolbox", "OSLog", "AppKit", "ApplicationServices",
        "Carbon", "CoreGraphics", "ImageIO", "Observation", "ScreenCaptureKit", "Security",
        "UniformTypeIdentifiers"},
    "RillUI": FOUNDATION_IMPORTS | {"AppKit", "Carbon", "ImageIO", "Observation", "Quartz",
        "QuartzCore", "QuickLookThumbnailing", "SwiftUI", "UniformTypeIdentifiers"},
    "RillApp": FOUNDATION_IMPORTS | {"AppIntents", "AppKit", "ApplicationServices", "Combine", "Observation", "QuartzCore", "SwiftUI"},
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
    failures: list[str] = []
    for name, target in targets.items():
        is_test = target["type"] == "test"
        source_root = ROOT / target.get("path", str(Path("Tests" if is_test else "Sources") / name))
        sources = sorted(str(path) for path in source_root.rglob("*.swift"))
        if name == "CRime" and list(source_root.rglob("*.c")):
            continue
        if not sources:
            raise SystemExit(f"{name}: no source files checked")
        imports = {module.split(".")[0] for module in output(
            "swiftc", "-frontend", "-swift-version", "6", "-module-name", name, "-emit-imported-modules", *sources).splitlines()}
        declared = {next(iter(dependency.values()))[0] for dependency in target["dependencies"]}
        permitted = declared | (TEST_IMPORTS if is_test else SYSTEM_IMPORTS[name])
        if unexpected := imports - permitted:
            failures.append(f"{name}: undeclared or forbidden imports: {sorted(unexpected)}")
        internal = set(DEPENDENCIES)
        if unused := (declared & internal) - imports:
            failures.append(f"{name}: declared internal dependencies are not imported: {sorted(unused)}")
    if failures:
        raise SystemExit("\n".join(failures))
    print("Module boundaries passed (SwiftPM graph and parsed imports)")


if __name__ == "__main__":
    main()
