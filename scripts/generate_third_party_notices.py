#!/usr/bin/env python3
"""Generate distributable notices from locked and vendored dependencies.

The reviewed manifest records license evidence for every dependency. SwiftPM's
``Package.resolved`` supplies source-control pins when they exist; vendored
packages instead carry reviewed source, version, artifact, and evidence hashes
directly in the manifest. The generator fails closed when either inventory or
any reviewed byte changes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import urlparse


PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_RESOLVED = PROJECT_DIR / "Package.resolved"
DEFAULT_MANIFEST = PROJECT_DIR / "scripts" / "third_party_notices_manifest.json"
DEFAULT_CHECKOUTS = PROJECT_DIR / ".build" / "checkouts"
DEFAULT_OUTPUT = PROJECT_DIR / "THIRD_PARTY_NOTICES.md"
MAX_EVIDENCE_BYTES = 2 * 1024 * 1024
IDENTITY_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]*\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
REVISION_PATTERN = re.compile(r"[0-9a-f]{40,64}\Z")
VERSION_PATTERN = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+-]{0,127}\Z")


class NoticeError(Exception):
    """A content or provenance failure that must block notice generation."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolved", type=Path, default=DEFAULT_RESOLVED)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--checkouts-dir", type=Path, default=DEFAULT_CHECKOUTS)
    parser.add_argument("--project-dir", type=Path, default=PROJECT_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail unless the existing output exactly matches generated content.",
    )
    return parser.parse_args()


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise NoticeError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise NoticeError(f"Cannot read {label} at {path}: {error}") from error
    try:
        return json.loads(raw, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, NoticeError) as error:
        raise NoticeError(f"Invalid {label} at {path}: {error}") from error


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NoticeError(f"{label} must be a JSON object")
    return value


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = ", ".join(sorted(expected - actual)) or "none"
        extra = ", ".join(sorted(actual - expected)) or "none"
        raise NoticeError(f"{label} keys mismatch (missing: {missing}; extra: {extra})")


def load_resolved_pins(path: Path) -> dict[str, dict[str, str]]:
    if not os.path.lexists(path):
        return {}
    if path.is_symlink():
        raise NoticeError(f"Package.resolved must not be a symlink: {path}")
    root = require_object(load_json(path, "Package.resolved"), "Package.resolved")
    require_exact_keys(
        root,
        {"originHash", "pins", "version"},
        "Package.resolved",
    )
    if root["version"] != 3:
        raise NoticeError("Package.resolved version must be 3")
    origin_hash = root["originHash"]
    if not isinstance(origin_hash, str) or not SHA256_PATTERN.fullmatch(origin_hash):
        raise NoticeError("Package.resolved originHash must be 64 lowercase hex")
    pins = root.get("pins")
    if not isinstance(pins, list):
        raise NoticeError("Package.resolved pins must be an array")

    result: dict[str, dict[str, str]] = {}
    for index, raw_pin in enumerate(pins):
        pin = require_object(raw_pin, f"Package.resolved.pins[{index}]")
        identity = pin.get("identity")
        location = pin.get("location")
        kind = pin.get("kind")
        state = pin.get("state")
        if not isinstance(identity, str) or not IDENTITY_PATTERN.fullmatch(identity):
            raise NoticeError(f"Package.resolved.pins[{index}] has an invalid identity")
        if identity in result:
            raise NoticeError(
                f"Package.resolved contains duplicate identity: {identity}"
            )
        if kind != "remoteSourceControl":
            raise NoticeError(f"Unsupported dependency kind for {identity}: {kind!r}")
        if not isinstance(location, str) or not valid_https_source(location):
            raise NoticeError(f"Package {identity} must use an HTTPS source URL")
        state_object = require_object(state, f"Package.resolved state for {identity}")
        revision = state_object.get("revision")
        if not isinstance(revision, str) or not REVISION_PATTERN.fullmatch(revision):
            raise NoticeError(f"Package {identity} has an invalid locked revision")
        version_value = state_object.get("version")
        branch_value = state_object.get("branch")
        if isinstance(version_value, str) and version_value:
            version = version_value
        elif isinstance(branch_value, str) and branch_value:
            version = f"branch:{branch_value}"
        else:
            version = "revision-only"
        result[identity] = {
            "identity": identity,
            "location": location,
            "revision": revision,
            "version": version,
        }
    return result


def valid_https_source(value: str) -> bool:
    parsed = urlparse(value)
    return (
        parsed.scheme == "https"
        and bool(parsed.netloc)
        and not parsed.username
        and not parsed.password
        and not parsed.query
        and not parsed.fragment
    )


def load_manifest(path: Path) -> dict[str, dict[str, Any]]:
    if path.is_symlink():
        raise NoticeError(f"Notice manifest must not be a symlink: {path}")
    root = require_object(load_json(path, "notice manifest"), "notice manifest")
    require_exact_keys(root, {"schemaVersion", "packages"}, "notice manifest")
    if root["schemaVersion"] != 2:
        raise NoticeError(
            f"Unsupported notice manifest schema: {root['schemaVersion']!r}"
        )
    packages = root["packages"]
    if not isinstance(packages, list) or not packages:
        raise NoticeError("Notice manifest packages must be a non-empty array")

    result: dict[str, dict[str, Any]] = {}
    for index, raw_package in enumerate(packages):
        package = require_object(raw_package, f"notice manifest packages[{index}]")
        package_kind = package.get("kind")
        if package_kind == "sourceControl":
            expected_keys = {"kind", "identity", "licenseExpression", "evidence"}
            if "evidenceRevision" in package:
                expected_keys.add("evidenceRevision")
        elif package_kind == "vendored":
            expected_keys = {
                "kind",
                "identity",
                "version",
                "source",
                "sourceSHA256",
                "root",
                "artifacts",
                "licenseExpression",
                "evidence",
            }
        else:
            raise NoticeError(
                f"Notice manifest package {index} has an invalid kind: {package_kind!r}"
            )
        require_exact_keys(
            package,
            expected_keys,
            f"notice manifest packages[{index}]",
        )
        identity = package["identity"]
        expression = package["licenseExpression"]
        evidence = package["evidence"]
        if not isinstance(identity, str) or not IDENTITY_PATTERN.fullmatch(identity):
            raise NoticeError(
                f"Notice manifest package {index} has an invalid identity"
            )
        if identity in result:
            raise NoticeError(
                f"Notice manifest contains duplicate identity: {identity}"
            )
        if not isinstance(expression, str) or not expression or len(expression) > 128:
            raise NoticeError(
                f"Notice manifest package {identity} has an invalid license expression"
            )
        if not isinstance(evidence, list) or not evidence:
            raise NoticeError(f"Notice manifest package {identity} has no evidence")

        checked_evidence: list[dict[str, Any]] = []
        evidence_paths: set[str] = set()
        has_license = False
        for evidence_index, raw_evidence in enumerate(evidence):
            item = require_object(
                raw_evidence,
                f"notice manifest package {identity} evidence[{evidence_index}]",
            )
            evidence_keys = {"kind", "path", "sha256"}
            has_line_start = "lineStart" in item
            has_line_end = "lineEnd" in item
            if has_line_start or has_line_end:
                if not (has_line_start and has_line_end):
                    raise NoticeError(
                        f"Package {identity} evidence line range must include "
                        "lineStart and lineEnd"
                    )
                evidence_keys.update({"lineStart", "lineEnd"})
            require_exact_keys(
                item,
                evidence_keys,
                f"notice manifest package {identity} evidence[{evidence_index}]",
            )
            evidence_kind = item["kind"]
            relative_path = item["path"]
            digest = item["sha256"]
            if evidence_kind not in {"license", "notice"}:
                raise NoticeError(
                    f"Package {identity} has unsupported evidence kind: {evidence_kind!r}"
                )
            if not isinstance(relative_path, str) or not safe_relative_path(
                relative_path
            ):
                raise NoticeError(
                    f"Package {identity} has an unsafe evidence path: {relative_path!r}"
                )
            if relative_path in evidence_paths:
                raise NoticeError(
                    f"Package {identity} repeats evidence path: {relative_path}"
                )
            if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
                raise NoticeError(
                    f"Package {identity} has an invalid SHA-256 for {relative_path}"
                )
            evidence_paths.add(relative_path)
            has_license = has_license or evidence_kind == "license"
            checked_item: dict[str, Any] = {
                "kind": evidence_kind,
                "path": relative_path,
                "sha256": digest,
            }
            if has_line_start:
                line_start = item["lineStart"]
                line_end = item["lineEnd"]
                if (
                    not isinstance(line_start, int)
                    or isinstance(line_start, bool)
                    or not isinstance(line_end, int)
                    or isinstance(line_end, bool)
                    or line_start < 1
                    or line_end < line_start
                    or line_end - line_start >= 1_000
                ):
                    raise NoticeError(
                        f"Package {identity} has an invalid evidence line range"
                    )
                checked_item.update(
                    {"lineStart": line_start, "lineEnd": line_end}
                )
            checked_evidence.append(checked_item)
        if not has_license:
            raise NoticeError(f"Package {identity} must include license evidence")
        checked_package: dict[str, Any] = {
            "kind": package_kind,
            "identity": identity,
            "licenseExpression": expression,
            "evidence": checked_evidence,
        }
        if package_kind == "sourceControl" and "evidenceRevision" in package:
            evidence_revision = package["evidenceRevision"]
            if not isinstance(evidence_revision, str) or not REVISION_PATTERN.fullmatch(
                evidence_revision
            ):
                raise NoticeError(
                    f"Package {identity} has an invalid evidence revision"
                )
            checked_package["evidenceRevision"] = evidence_revision
        if package_kind == "vendored":
            version = package["version"]
            source = package["source"]
            source_digest = package["sourceSHA256"]
            root_path = package["root"]
            artifacts = package["artifacts"]
            if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
                raise NoticeError(f"Vendored package {identity} has an invalid version")
            if not isinstance(source, str) or not valid_https_source(source):
                raise NoticeError(
                    f"Vendored package {identity} must use an HTTPS source URL"
                )
            if not isinstance(source_digest, str) or not SHA256_PATTERN.fullmatch(
                source_digest
            ):
                raise NoticeError(
                    f"Vendored package {identity} has an invalid source SHA-256"
                )
            if not isinstance(root_path, str) or not safe_relative_path(root_path):
                raise NoticeError(
                    f"Vendored package {identity} has an unsafe root: {root_path!r}"
                )
            if not isinstance(artifacts, list) or not artifacts:
                raise NoticeError(f"Vendored package {identity} has no artifacts")
            checked_artifacts: list[dict[str, str]] = []
            artifact_paths: set[str] = set()
            for artifact_index, raw_artifact in enumerate(artifacts):
                artifact = require_object(
                    raw_artifact,
                    f"notice manifest package {identity} artifacts[{artifact_index}]",
                )
                require_exact_keys(
                    artifact,
                    {"path", "sha256"},
                    f"notice manifest package {identity} artifacts[{artifact_index}]",
                )
                artifact_path = artifact["path"]
                artifact_digest = artifact["sha256"]
                if not isinstance(artifact_path, str) or not safe_relative_path(
                    artifact_path
                ):
                    raise NoticeError(
                        f"Vendored package {identity} has an unsafe artifact path: "
                        f"{artifact_path!r}"
                    )
                if artifact_path in artifact_paths:
                    raise NoticeError(
                        f"Vendored package {identity} repeats artifact path: "
                        f"{artifact_path}"
                    )
                if not isinstance(artifact_digest, str) or not SHA256_PATTERN.fullmatch(
                    artifact_digest
                ):
                    raise NoticeError(
                        f"Vendored package {identity} has an invalid artifact SHA-256: "
                        f"{artifact_path}"
                    )
                artifact_paths.add(artifact_path)
                checked_artifacts.append(
                    {"path": artifact_path, "sha256": artifact_digest}
                )
            checked_package.update(
                {
                    "version": version,
                    "source": source,
                    "sourceSHA256": source_digest,
                    "root": root_path,
                    "artifacts": checked_artifacts,
                }
            )
        result[identity] = checked_package
    return result


def safe_relative_path(value: str) -> bool:
    path = PurePosixPath(value)
    return (
        value == path.as_posix()
        and not path.is_absolute()
        and len(path.parts) > 0
        and all(part not in {"", ".", ".."} for part in path.parts)
    )


def validate_inventory(
    pins: dict[str, dict[str, str]], manifest: dict[str, dict[str, Any]]
) -> None:
    source_control = {
        identity
        for identity, package in manifest.items()
        if package["kind"] == "sourceControl"
    }
    missing = sorted(set(pins) - source_control)
    stale = sorted(source_control - set(pins))
    if missing or stale:
        missing_text = ", ".join(missing) or "none"
        stale_text = ", ".join(stale) or "none"
        raise NoticeError(
            "Dependency notice inventory mismatch "
            f"(unreviewed locked packages: {missing_text}; stale manifest packages: {stale_text})"
        )


def repository_basename(location: str) -> str:
    name = PurePosixPath(urlparse(location).path).name
    return name[:-4] if name.lower().endswith(".git") else name


def find_checkout(checkouts_dir: Path, pin: dict[str, str]) -> Path:
    try:
        children = [child for child in checkouts_dir.iterdir() if child.is_dir()]
    except OSError as error:
        raise NoticeError(
            f"Cannot enumerate dependency checkouts at {checkouts_dir}: {error}"
        ) from error
    expected_names = {
        pin["identity"].casefold(),
        repository_basename(pin["location"]).casefold(),
    }
    matches = [child for child in children if child.name.casefold() in expected_names]
    if len(matches) != 1:
        rendered = ", ".join(str(match) for match in sorted(matches)) or "none"
        raise NoticeError(
            f"Expected exactly one checkout for {pin['identity']}; matches: {rendered}"
        )
    checkout = matches[0].resolve()
    verify_checkout_revision(checkout, pin)
    return checkout


def verify_checkout_revision(checkout: Path, pin: dict[str, str]) -> None:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise NoticeError(
            f"Cannot verify checkout revision for {pin['identity']}: {error}"
        ) from error
    actual = result.stdout.strip().lower()
    expected = pin["revision"].lower()
    if actual != expected:
        raise NoticeError(
            f"Checkout revision mismatch for {pin['identity']}: expected {expected}, found {actual}"
        )


def verify_checkout_worktree(checkout: Path, pin: dict[str, str]) -> None:
    try:
        index = subprocess.run(
            ["git", "-C", str(checkout), "ls-files", "-v"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
            env={**os.environ, "LC_ALL": "C"},
        )
        status = subprocess.run(
            [
                "git",
                "-C",
                str(checkout),
                "status",
                "--porcelain=v1",
                "--untracked-files=normal",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise NoticeError(
            f"Cannot verify checkout worktree for {pin['identity']}: {error}"
        ) from error
    if any(
        line[:1].islower() or line.startswith("S ")
        for line in index.stdout.splitlines()
    ):
        raise NoticeError(f"Checkout index flags are not allowed for {pin['identity']}")
    if status.stdout:
        raise NoticeError(f"Checkout worktree is dirty for {pin['identity']}")


def resolve_reviewed_file(
    root: Path,
    relative_path: str,
    *,
    identity: str,
    label: str,
) -> Path:
    candidate = root.joinpath(*PurePosixPath(relative_path).parts)
    cursor = root
    try:
        if cursor.is_symlink():
            raise NoticeError(f"{label} root must not be a symlink: {cursor}")
        for part in PurePosixPath(relative_path).parts:
            cursor /= part
            if cursor.is_symlink():
                raise NoticeError(f"{label} must not traverse a symlink: {cursor}")
        resolved_root = root.resolve(strict=True)
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except NoticeError:
        raise
    except (OSError, ValueError) as error:
        raise NoticeError(
            f"Missing or unsafe {label.lower()} for {identity}: {relative_path}"
        ) from error
    if not resolved.is_file():
        raise NoticeError(f"{label} is not a regular file: {resolved}")
    return resolved


def load_evidence(
    root: Path,
    package: dict[str, Any],
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for item in package["evidence"]:
        evidence_revision = package.get("evidenceRevision")
        if evidence_revision is None:
            resolved = resolve_reviewed_file(
                root,
                item["path"],
                identity=package["identity"],
                label="Evidence",
            )
            try:
                size = resolved.stat().st_size
                if size <= 0 or size > MAX_EVIDENCE_BYTES:
                    raise NoticeError(
                        f"Evidence size is invalid for {resolved}: {size} bytes"
                    )
                content = resolved.read_bytes()
            except OSError as error:
                raise NoticeError(f"Cannot read evidence at {resolved}: {error}") from error
            display_path = item["path"]
        else:
            try:
                ancestry = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(root),
                        "merge-base",
                        "--is-ancestor",
                        "HEAD",
                        evidence_revision,
                    ],
                    capture_output=True,
                    timeout=10,
                    env={**os.environ, "LC_ALL": "C"},
                )
                if ancestry.returncode != 0:
                    raise NoticeError(
                        f"Evidence revision is not a descendant of the locked "
                        f"{package['identity']} revision: {evidence_revision}"
                    )
                blob = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(root),
                        "show",
                        f"{evidence_revision}:{item['path']}",
                    ],
                    check=True,
                    capture_output=True,
                    timeout=10,
                    env={**os.environ, "LC_ALL": "C"},
                )
            except NoticeError:
                raise
            except (OSError, subprocess.SubprocessError) as error:
                raise NoticeError(
                    f"Cannot read evidence revision for {package['identity']}: "
                    f"{evidence_revision}/{item['path']}"
                ) from error
            content = blob.stdout
            if len(content) <= 0 or len(content) > MAX_EVIDENCE_BYTES:
                raise NoticeError(
                    f"Evidence size is invalid for "
                    f"{package['identity']}@{evidence_revision}/{item['path']}: "
                    f"{len(content)} bytes"
                )
            display_path = f"{item['path']}@{evidence_revision}"
        if "lineStart" in item:
            lines = content.splitlines(keepends=True)
            line_start = item["lineStart"]
            line_end = item["lineEnd"]
            if line_end > len(lines):
                raise NoticeError(
                    f"Evidence line range exceeds {package['identity']}/{item['path']}"
                )
            content = b"".join(lines[line_start - 1 : line_end])
            display_path += f"#L{line_start}-L{line_end}"
        digest = hashlib.sha256(content).hexdigest()
        if digest != item["sha256"]:
            raise NoticeError(
                f"Evidence SHA-256 mismatch for {package['identity']}/{item['path']}: "
                f"expected {item['sha256']}, found {digest}"
            )
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise NoticeError(f"Evidence is not UTF-8: {resolved}") from error
        result.append(
            {**item, "path": display_path, "content": content, "text": text}
        )
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise NoticeError(
            f"Cannot hash reviewed artifact at {path}: {error}"
        ) from error
    return digest.hexdigest()


def verify_vendored_artifacts(
    root: Path, package: dict[str, Any]
) -> list[dict[str, str]]:
    verified: list[dict[str, str]] = []
    for item in package["artifacts"]:
        resolved = resolve_reviewed_file(
            root,
            item["path"],
            identity=package["identity"],
            label="Artifact",
        )
        try:
            size = resolved.stat().st_size
        except OSError as error:
            raise NoticeError(
                f"Cannot inspect reviewed artifact at {resolved}: {error}"
            ) from error
        if size <= 0:
            raise NoticeError(f"Reviewed artifact is empty: {resolved}")
        digest = sha256_file(resolved)
        if digest != item["sha256"]:
            raise NoticeError(
                f"Artifact SHA-256 mismatch for {package['identity']}/{item['path']}: "
                f"expected {item['sha256']}, found {digest}"
            )
        verified.append(item)
    return verified


def markdown_cell(value: str) -> str:
    return value.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ")


def markdown_fence(text: str) -> str:
    longest = max(
        (len(match.group(0)) for match in re.finditer(r"`+", text)), default=0
    )
    return "`" * max(3, longest + 1)


def normalize_embedded_text(text: str) -> str:
    """Keep notice wording intact while avoiding generated whitespace failures."""
    return "\n".join(line.rstrip(" \t") for line in text.splitlines())


def render(
    pins: dict[str, dict[str, str]],
    manifest: dict[str, dict[str, Any]],
    checkouts_dir: Path,
    project_dir: Path,
) -> bytes:
    collected: dict[str, list[dict[str, Any]]] = {}
    verified_artifacts: dict[str, list[dict[str, str]]] = {}
    unique_texts: dict[str, dict[str, Any]] = {}
    for identity in sorted(manifest):
        package = manifest[identity]
        if package["kind"] == "sourceControl":
            checkout = find_checkout(checkouts_dir, pins[identity])
            evidence = load_evidence(checkout, package)
            verify_checkout_worktree(checkout, pins[identity])
            verified_artifacts[identity] = []
        else:
            vendor_root = project_dir.joinpath(*PurePosixPath(package["root"]).parts)
            try:
                resolved_project = project_dir.resolve(strict=True)
                resolved_vendor_root = vendor_root.resolve(strict=True)
                resolved_vendor_root.relative_to(resolved_project)
            except (OSError, ValueError) as error:
                raise NoticeError(
                    f"Missing or unsafe vendored root for {identity}: {package['root']}"
                ) from error
            if vendor_root.is_symlink():
                raise NoticeError(
                    f"Vendored root must not be a symlink for {identity}: {vendor_root}"
                )
            verified_artifacts[identity] = verify_vendored_artifacts(
                resolved_vendor_root, package
            )
            evidence = load_evidence(resolved_vendor_root, package)
        collected[identity] = evidence
        for item in evidence:
            entry = unique_texts.setdefault(
                item["sha256"],
                {"content": item["content"], "text": item["text"], "sources": []},
            )
            if entry["content"] != item["content"]:
                raise NoticeError(
                    f"SHA-256 collision while collecting {identity}/{item['path']}"
                )
            entry["sources"].append(
                {"identity": identity, "kind": item["kind"], "path": item["path"]}
            )

    lines = [
        "# Rill Third-Party Notices",
        "",
        "This file is generated from `Package.resolved` when present and the reviewed",
        "source, artifact, and license evidence in",
        "`scripts/third_party_notices_manifest.json`. Do not edit it manually.",
        "",
        "The notices below cover source-control dependencies locked for this build and",
        "native runtimes vendored into the source tree.",
        "They do not grant a license to Rill itself.",
        "SHA-256 values cover the reviewed artifacts and original evidence bytes;",
        "rendered text only normalizes line endings and trailing horizontal whitespace.",
        "",
        "## Dependency inventory",
        "",
        "| Package | Kind | Version | Source | License | Reviewed artifacts | Reviewed evidence |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for identity in sorted(manifest):
        package = manifest[identity]
        evidence_text = "<br>".join(
            f"`{item['path']}` ({item['kind']}, `{item['sha256']}`)"
            for item in collected[identity]
        )
        if package["kind"] == "sourceControl":
            pin = pins[identity]
            kind = "source control"
            version = pin["version"]
            source = pin["location"]
            artifact_text = f"Git revision `{pin['revision']}`"
        else:
            kind = "vendored"
            version = package["version"]
            source = package["source"]
            artifact_text = (
                f"source archive (`{package['sourceSHA256']}`)<br>"
                + "<br>".join(
                    f"`{item['path']}` (`{item['sha256']}`)"
                    for item in verified_artifacts[identity]
                )
            )
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{markdown_cell(identity)}`",
                    kind,
                    markdown_cell(version),
                    f"<{source}>",
                    f"`{markdown_cell(package['licenseExpression'])}`",
                    artifact_text,
                    evidence_text,
                ]
            )
            + " |"
        )

    lines.extend(["", "## License and notice texts", ""])
    for digest in sorted(unique_texts):
        item = unique_texts[digest]
        sources = sorted(
            f"`{source['identity']}/{source['path']}` ({source['kind']})"
            for source in item["sources"]
        )
        text = normalize_embedded_text(item["text"])
        fence = markdown_fence(text)
        lines.extend(
            [
                f"### Evidence `{digest}`",
                "",
                "Applies to: " + ", ".join(sources) + ".",
                "",
                fence + "text",
                text,
                fence,
                "",
            ]
        )
    return ("\n".join(lines).rstrip() + "\n").encode("utf-8")


def check_or_write(output: Path, content: bytes, check: bool) -> None:
    if check:
        try:
            existing = output.read_bytes()
        except OSError as error:
            raise NoticeError(
                f"Generated notice is missing or unreadable at {output}: {error}"
            ) from error
        if existing != content:
            raise NoticeError(
                f"Generated notice is stale: {output}; run scripts/generate_third_party_notices.py"
            )
        return

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, output)
    except OSError as error:
        if temporary_path is not None:
            try:
                temporary_path.unlink(missing_ok=True)
            except OSError:
                pass
        raise NoticeError(
            f"Cannot write generated notice at {output}: {error}"
        ) from error


def main() -> int:
    arguments = parse_args()
    try:
        pins = load_resolved_pins(arguments.resolved)
        manifest = load_manifest(arguments.manifest)
        validate_inventory(pins, manifest)
        content = render(
            pins,
            manifest,
            arguments.checkouts_dir,
            arguments.project_dir,
        )
        check_or_write(arguments.output, content, arguments.check)
    except NoticeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    action = "verified" if arguments.check else "generated"
    print(f"Third-party notices {action}: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
