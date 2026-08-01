#!/usr/bin/env python3

from __future__ import annotations

import argparse
import difflib
import json
import sys
import tomllib
import uuid
from collections.abc import Mapping
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources" / "RillApp" / "Resources" / "BuiltinWorkflows.toml"
JSON_OUTPUT = (
    ROOT / "Sources" / "RillApp" / "Resources" / "BuiltinWorkflowManifest.json"
)
SWIFT_OUTPUT = ROOT / "Sources" / "RillProviders" / "BuiltinWorkflowCatalog.swift"

VOICE_GROUP_ID = "4C5A3D00-90E6-4BA0-95D7-17E8B6DA0002"
PERSONAL_VOCABULARY_ID = "E79EF7C7-8867-5D6C-8E88-1119C62B9702"
DOCUMENT_KEYS = {"schema_version", "metadata", "workflows"}
POST_PROCESS_KEYS = {"id", "kind", "prompt"}
SUPPORTED_DELIVERY_STRATEGIES = {"immediate", "stackFirst", "clipboardOnly"}
SUPPORTED_POST_PROCESS_KINDS = {"llmRewrite", "normalizeWhitespace"}
SUPPORTED_AVAILABILITY = {"active", "planned"}
SUPPORTED_SPEECH_MODES = {
    "streaming-direct",
    "dedicated-transcription",
    "transcription-with-rewrite",
    "voice-assistant",
}
SUPPORTED_SETTINGS = {"output_mode"}
SUPPORTED_SPEECH_OUTPUT_CONFIGURATION = {
    "speech.language",
    "speech.provider",
    "speech.voice",
}
SUPPORTED_TITLE_KEYS = {
    "ambiguousDemoStack",
    "cleanInput",
    "cloudDictation",
    "commandMode",
    "directDemoClipboard",
    "formalWriting",
    "localDictation",
    "pushToTalkCapture",
    "pushToTalkPolish",
    "rawInput",
    "rewriteDemoStack",
    "speechRecognition",
    "stackDelivery",
    "translateInput",
    "streamingInput",
    "voiceAssistant",
}
SUPPORTED_TRIGGERS = {"manual", "hotkey", "menuBar", "wakeWord"}
WORKFLOW_KEYS = {
    "accent_color",
    "availability",
    "builtin_kind",
    "delivery",
    "default_enabled",
    "exclusive_group",
    "gesture",
    "id",
    "interaction_mode",
    "mode",
    "name",
    "output",
    "output_configuration",
    "post_process",
    "recognizer",
    "settings_expose",
    "symbol",
    "target_group",
    "text_style",
    "title_key",
    "trigger",
    "wake_phrases",
}


class SourceError(ValueError):
    """Raised when the declarative workflow source is invalid."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate built-in workflow artifacts from BuiltinWorkflows.toml."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify generated artifacts without writing any files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = load_manifest()
        outputs = {
            JSON_OUTPUT: json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
            SWIFT_OUTPUT: render_swift_catalog(manifest),
        }
        if args.check:
            return check_outputs(outputs)

        for path, content in outputs.items():
            if read_existing(path) != content:
                path.write_text(content, encoding="utf-8")
    except (OSError, SourceError, UnicodeError, tomllib.TOMLDecodeError) as error:
        print(f"builtin workflow generation failed: {error}", file=sys.stderr)
        return 2
    return 0


def load_manifest() -> dict[str, Any]:
    with SOURCE.open("rb") as handle:
        document = tomllib.load(handle)

    if not isinstance(document, dict):
        raise SourceError("the TOML root must be a table")
    reject_unknown_keys(document, DOCUMENT_KEYS, "document")

    schema_version = document.get("schema_version")
    if type(schema_version) is not int or schema_version < 1:
        raise SourceError("schema_version must be a positive integer")

    metadata = string_mapping(document.get("metadata", {}), "metadata")
    catalog = metadata.get("source")
    if not catalog:
        raise SourceError("metadata.source must be a non-empty string")

    raw_workflows = document.get("workflows")
    if not isinstance(raw_workflows, list) or not raw_workflows:
        raise SourceError("workflows must be a non-empty array of tables")

    workflows: list[dict[str, Any]] = []
    workflow_ids: set[uuid.UUID] = set()
    for index, raw_workflow in enumerate(raw_workflows, start=1):
        location = f"workflows[{index}]"
        entry = table(raw_workflow, location)
        workflow_id = parse_uuid(
            required_string(entry, "id", location), f"{location}.id"
        )
        if workflow_id in workflow_ids:
            raise SourceError(
                f"{location}.id duplicates another workflow ID: {workflow_id}"
            )
        workflow_ids.add(workflow_id)
        workflows.append(build_workflow(entry, location, workflow_id, catalog))

    return {
        "schemaVersion": schema_version,
        "voiceProfiles": [],
        "workflows": workflows,
        "metadata": metadata,
    }


def build_workflow(
    entry: Mapping[str, Any],
    location: str,
    workflow_id: uuid.UUID,
    catalog: str,
) -> dict[str, Any]:
    reject_unknown_keys(entry, WORKFLOW_KEYS, location)
    title_key = optional_string(entry, "title_key", location)
    if title_key is not None:
        validate_member(title_key, SUPPORTED_TITLE_KEYS, f"{location}.title_key")

    trigger = required_string(entry, "trigger", location)
    validate_member(trigger, SUPPORTED_TRIGGERS, f"{location}.trigger")

    delivery = required_string(entry, "delivery", location)
    validate_member(delivery, SUPPORTED_DELIVERY_STRATEGIES, f"{location}.delivery")

    recognizer = required_string(entry, "recognizer", location)
    metadata: dict[str, str] = {"catalog": catalog}
    default_enabled = optional_bool(entry, "default_enabled", location)
    if default_enabled is not None:
        metadata["workflow.default-enabled"] = (
            "true" if default_enabled else "false"
        )
    availability = optional_string(entry, "availability", location) or "active"
    validate_member(availability, SUPPORTED_AVAILABILITY, f"{location}.availability")
    if availability != "active":
        metadata["workflow.availability"] = availability
    speech_mode = optional_string(entry, "mode", location)
    if speech_mode is not None:
        validate_member(speech_mode, SUPPORTED_SPEECH_MODES, f"{location}.mode")
        metadata["workflow.speech-mode"] = speech_mode
    copy_optional_metadata(entry, "gesture", metadata, "trigger.gesture", location)
    copy_optional_metadata(
        entry, "interaction_mode", metadata, "interaction.mode", location
    )
    metadata["workflow.builtin-kind"] = required_string(entry, "builtin_kind", location)
    copy_optional_metadata(
        entry,
        "exclusive_group",
        metadata,
        "workflow.exclusive-group",
        location,
    )

    if recognizer == "auto":
        recognizer_id = "sherpa-onnx.local"
        metadata["recognizer.selection"] = "auto"
    else:
        recognizer_id = recognizer

    settings = string_list(
        entry.get("settings_expose", []), f"{location}.settings_expose"
    )
    unsupported_settings = set(settings) - SUPPORTED_SETTINGS
    if unsupported_settings:
        values = ", ".join(sorted(unsupported_settings))
        raise SourceError(
            f"{location}.settings_expose contains unsupported values: {values}"
        )
    if "output_mode" in settings:
        metadata["settings.expose.output-mode"] = "true"

    target_group = optional_string(entry, "target_group", location)
    if target_group is not None:
        metadata["clipboard.target-group-id"] = resolve_target_group(
            target_group, location
        )

    copy_optional_metadata(
        entry, "text_style", metadata, "workflow.text-style", location
    )

    wake_phrases = string_list(
        entry.get("wake_phrases", []), f"{location}.wake_phrases"
    )
    if trigger == "wakeWord":
        validate_wake_phrases(wake_phrases, f"{location}.wake_phrases")
    elif "wake_phrases" in entry:
        raise SourceError(
            f"{location}.wake_phrases is supported only for wakeWord workflows"
        )

    output_id = required_string(entry, "output", location)
    output_configuration = string_mapping(
        entry.get("output_configuration", {}),
        f"{location}.output_configuration",
    )
    if output_configuration:
        if output_id != "speech.speak":
            raise SourceError(
                f"{location}.output_configuration is supported only for speech.speak"
            )
        unsupported_output_configuration = (
            set(output_configuration) - SUPPORTED_SPEECH_OUTPUT_CONFIGURATION
        )
        if unsupported_output_configuration:
            values = ", ".join(sorted(unsupported_output_configuration))
            raise SourceError(
                f"{location}.output_configuration contains unsupported values: {values}"
            )
        provider = output_configuration.get("speech.provider")
        if provider is not None:
            validate_member(
                provider,
                {"automatic", "qwen3", "system"},
                f"{location}.output_configuration.speech.provider",
            )

    raw_steps = entry.get("post_process", [])
    if not isinstance(raw_steps, list):
        raise SourceError(f"{location}.post_process must be an array of tables")
    steps = [
        build_post_process(
            workflow_id,
            index,
            table(step, f"{location}.post_process[{index}]"),
            is_planned=availability == "planned",
        )
        for index, step in enumerate(raw_steps, start=1)
    ]
    step_ids = [step["id"] for step in steps]
    if len(step_ids) != len(set(step_ids)):
        raise SourceError(f"{location}.post_process must use unique step IDs")

    setup: dict[str, Any] = {
        "speechRoute": {
            "selection": "automatic" if recognizer == "auto" else "fixed",
            "recognizerID": recognizer_id,
        },
        "vocabularyBindings": [
            {
                "id": str(uuid.uuid5(workflow_id, "personal-vocabulary-binding")),
                "collectionID": PERSONAL_VOCABULARY_ID,
                "uses": ["recognitionHints", "textReplacement"],
                "condition": {},
            }
        ],
    }
    if trigger == "wakeWord":
        setup["wakeWord"] = {"phrases": wake_phrases}

    return {
        "id": str(workflow_id).upper(),
        "name": required_string(entry, "name", location),
        "titleKey": title_key,
        "trigger": trigger,
        "plan": {
            "setup": setup,
            "process": {
                "steps": [
                    {
                        "id": str(uuid.uuid5(workflow_id, "recognize-speech")),
                        "kind": "recognizeSpeech",
                    },
                    {
                        "id": str(uuid.uuid5(workflow_id, "apply-vocabulary")),
                        "kind": "applyVocabulary",
                    },
                    *steps,
                ]
            },
            "output": {
                "actions": [
                {
                    "id": output_id,
                    "configuration": output_configuration,
                }
                ],
                "deliveryPolicy": {"strategy": delivery},
            },
        },
        "ui": {
            "symbolName": required_string(entry, "symbol", location),
            "accentColorName": required_string(entry, "accent_color", location),
        },
        "metadata": metadata,
    }


def build_post_process(
    workflow_id: uuid.UUID,
    index: int,
    step: Mapping[str, Any],
    *,
    is_planned: bool,
) -> dict[str, Any]:
    location = f"workflow {str(workflow_id).upper()} post_process[{index}]"
    reject_unknown_keys(step, POST_PROCESS_KEYS, location)
    kind = required_string(step, "kind", location)
    validate_member(kind, SUPPORTED_POST_PROCESS_KINDS, f"{location}.kind")

    raw_id = optional_string(step, "id", location)
    step_id = (
        parse_uuid(raw_id, f"{location}.id")
        if raw_id is not None
        else uuid.uuid5(workflow_id, f"post-process-{index}")
    )
    prompt = optional_string(step, "prompt", location)
    if kind == "llmRewrite":
        if prompt is None:
            raise SourceError(f"{location}.prompt is required for llmRewrite")
    elif prompt is not None:
        raise SourceError(f"{location}.prompt is unsupported for built-in {kind} steps")
    return {
        "id": str(step_id),
        "kind": kind,
        "prompt": prompt,
    }


def render_swift_catalog(manifest: Mapping[str, Any]) -> str:
    workflows = manifest["workflows"]
    lines = [
        "// Generated by scripts/generate_builtin_workflows.py from",
        "// Sources/RillApp/Resources/BuiltinWorkflows.toml. Do not edit.",
        "",
        "import Foundation",
        "import RillCore",
        "",
        "private func staticUUID(_ string: String) -> UUID {",
        "    guard let uuid = UUID(uuidString: string) else {",
        '        preconditionFailure("Invalid UUID string: \\(string)")',
        "    }",
        "    return uuid",
        "}",
        "",
        "public struct BuiltinWorkflowCatalog: WorkflowCatalog {",
        "    public init() {}",
        "",
        "    public func manifest() -> WorkflowManifest {",
        "        WorkflowManifest(",
        f"            schemaVersion: {manifest['schemaVersion']},",
        "            workflows: [",
    ]

    for workflow in workflows:
        lines.extend(render_swift_workflow(workflow, indent=16))

    lines.extend(
        [
            "            ],",
            "            metadata: [",
        ]
    )
    lines.extend(render_swift_mapping(manifest["metadata"], indent=16))
    lines.extend(
        [
            "            ]",
            "        )",
            "    }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def render_swift_workflow(workflow: Mapping[str, Any], indent: int) -> list[str]:
    prefix = " " * indent
    plan = workflow["plan"]
    setup = plan["setup"]
    process = plan["process"]
    output = plan["output"]
    route = setup["speechRoute"]
    delivery = output["deliveryPolicy"]
    ui = workflow["ui"]
    title_key = workflow["titleKey"]

    lines = [
        f"{prefix}WorkflowDefinition(",
        f"{prefix}    id: staticUUID({swift_string(workflow['id'])}),",
        f"{prefix}    name: {swift_string(workflow['name'])},",
        f"{prefix}    titleKey: {'.' + title_key if title_key is not None else 'nil'},",
        f"{prefix}    trigger: .{workflow['trigger']},",
        f"{prefix}    plan: WorkflowPlan(",
        f"{prefix}        setup: WorkflowSetupPhase(",
        f"{prefix}            speechRoute: WorkflowSpeechRoute(",
        f"{prefix}                selection: .{route['selection']},",
        f"{prefix}                recognizerID: {swift_string(route['recognizerID'])}",
        f"{prefix}            ),",
        f"{prefix}            vocabularyBindings: [",
        f"{prefix}                VocabularyCollectionBinding(",
        f"{prefix}                    id: staticUUID({swift_string(setup['vocabularyBindings'][0]['id'])}),",
        f"{prefix}                    collectionID: VocabularyCollection.personalID",
        f"{prefix}                ),",
        f"{prefix}            ]{',' if 'wakeWord' in setup else ''}",
    ]
    if "wakeWord" in setup:
        phrases = ", ".join(
            swift_string(phrase) for phrase in setup["wakeWord"]["phrases"]
        )
        lines.extend(
            [
                f"{prefix}            wakeWord: WakeWordConfiguration(",
                f"{prefix}                phrases: [{phrases}]",
                f"{prefix}            )",
            ]
        )
    lines.extend(
        [
            f"{prefix}        ),",
            f"{prefix}        process: WorkflowProcessPhase(steps: [",
        ]
    )

    for step in process["steps"]:
        prompt = step.get("prompt")
        lines.extend(
            [
                f"{prefix}            WorkflowProcessStep(",
                f"{prefix}                id: staticUUID({swift_string(step['id'])}),",
                f"{prefix}                kind: .{step['kind']}{',' if prompt is not None else ''}",
            ]
        )
        if prompt is not None:
            lines.append(f"{prefix}                prompt: {swift_string(prompt)}")
        lines.append(f"{prefix}            ),")
    lines.extend(
        [
            f"{prefix}        ]),",
            f"{prefix}        output: WorkflowOutputPhase(",
            f"{prefix}            actions: [",
        ]
    )
    actions = output["actions"]
    for action in actions:
        configuration = action["configuration"]
        if configuration:
            lines.append(f"{prefix}                OutputActionReference(")
            lines.append(f"{prefix}                    id: {swift_string(action['id'])},")
            lines.append(f"{prefix}                    configuration: [")
            lines.extend(render_swift_mapping(configuration, indent=indent + 24))
            lines.append(f"{prefix}                    ]")
            lines.append(f"{prefix}                ),")
        else:
            lines.append(
                f"{prefix}                OutputActionReference(id: {swift_string(action['id'])}),"
            )
    lines.extend(
        [
            f"{prefix}            ],",
            f"{prefix}            deliveryPolicy: DeliveryPolicy(strategy: .{delivery['strategy']})",
            f"{prefix}        )",
            f"{prefix}    ),",
            f"{prefix}    ui: WorkflowUIConfig(",
            f"{prefix}        symbolName: {swift_string(ui['symbolName'])},",
            f"{prefix}        accentColorName: {swift_string(ui['accentColorName'])}",
            f"{prefix}    ),",
            f"{prefix}    metadata: [",
        ]
    )
    lines.extend(render_swift_mapping(workflow["metadata"], indent=indent + 8))
    lines.extend(
        [
            f"{prefix}    ]",
            f"{prefix}),",
        ]
    )
    return lines


def render_swift_mapping(values: Mapping[str, str], indent: int) -> list[str]:
    prefix = " " * indent
    return [
        f"{prefix}{swift_string(key)}: {swift_string(value)},"
        for key, value in values.items()
    ]


def swift_string(value: str) -> str:
    escaped: list[str] = []
    for character in value:
        if character == "\\":
            escaped.append("\\\\")
        elif character == '"':
            escaped.append('\\"')
        elif character == "\n":
            escaped.append("\\n")
        elif character == "\r":
            escaped.append("\\r")
        elif character == "\t":
            escaped.append("\\t")
        elif ord(character) < 0x20 or ord(character) == 0x7F:
            escaped.append(f"\\u{{{ord(character):X}}}")
        else:
            escaped.append(character)
    return f'"{"".join(escaped)}"'


def swift_number(value: int | float) -> str:
    if type(value) not in (int, float):
        raise SourceError(
            f"expected a number while rendering Swift, got {type(value).__name__}"
        )
    return str(value)


def check_outputs(outputs: Mapping[Path, str]) -> int:
    stale = False
    for path, expected in outputs.items():
        actual = read_existing(path)
        if actual == expected:
            continue
        stale = True
        relative_path = path.relative_to(ROOT)
        print(f"{relative_path} is out of date.", file=sys.stderr)
        if actual is not None:
            diff = difflib.unified_diff(
                actual.splitlines(keepends=True),
                expected.splitlines(keepends=True),
                fromfile=f"a/{relative_path}",
                tofile=f"b/{relative_path}",
            )
            sys.stderr.writelines(diff)

    if stale:
        print(
            "Run scripts/generate_builtin_workflows.py to refresh generated artifacts.",
            file=sys.stderr,
        )
        return 1
    return 0


def read_existing(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None


def required_string(entry: Mapping[str, Any], key: str, location: str) -> str:
    value = optional_string(entry, key, location)
    if value is None:
        raise SourceError(f"{location}.{key} is required")
    return value


def optional_string(entry: Mapping[str, Any], key: str, location: str) -> str | None:
    value = entry.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise SourceError(f"{location}.{key} must be a non-empty string")
    return value


def optional_bool(entry: Mapping[str, Any], key: str, location: str) -> bool | None:
    value = entry.get(key)
    if value is None:
        return None
    if type(value) is not bool:
        raise SourceError(f"{location}.{key} must be a boolean")
    return value


def copy_optional_metadata(
    entry: Mapping[str, Any],
    source_key: str,
    metadata: dict[str, str],
    destination_key: str,
    location: str,
) -> None:
    value = optional_string(entry, source_key, location)
    if value is not None:
        metadata[destination_key] = value


def string_mapping(value: Any, location: str) -> dict[str, str]:
    mapping = table(value, location)
    result: dict[str, str] = {}
    for key, item in mapping.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise SourceError(f"{location} must contain only string keys and values")
        result[key] = item
    return result


def string_list(value: Any, location: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise SourceError(f"{location} must be an array of strings")
    if len(value) != len(set(value)):
        raise SourceError(f"{location} must not contain duplicate values")
    return value


def validate_wake_phrases(value: list[str], location: str) -> None:
    if not 1 <= len(value) <= 4:
        raise SourceError(f"{location} must contain between one and four phrases")
    identities: set[str] = set()
    for phrase in value:
        normalized = " ".join(phrase.split())
        if len(normalized) < 2 or len(normalized) > 64:
            raise SourceError(f"{location} contains an invalid phrase")
        identity = normalized.casefold()
        if identity in identities:
            raise SourceError(f"{location} must not contain duplicate phrases")
        identities.add(identity)


def table(value: Any, location: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise SourceError(f"{location} must be a table")
    return value


def parse_uuid(value: str, location: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as error:
        raise SourceError(f"{location} must be a valid UUID: {value}") from error


def validate_member(value: str, supported: set[str], location: str) -> None:
    if value not in supported:
        choices = ", ".join(sorted(supported))
        raise SourceError(f"{location} must be one of: {choices}")


def reject_unknown_keys(
    values: Mapping[str, Any], supported: set[str], location: str
) -> None:
    unknown = set(values) - supported
    if unknown:
        keys = ", ".join(sorted(unknown))
        raise SourceError(f"{location} contains unsupported fields: {keys}")


def resolve_target_group(target_group: str, location: str) -> str:
    if target_group != "voice":
        raise SourceError(f"{location}.target_group is unsupported: {target_group}")
    return VOICE_GROUP_ID


if __name__ == "__main__":
    raise SystemExit(main())
