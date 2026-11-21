#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Fail-closed security checks for locked SwiftPM dependencies.

The default offline check applies the reviewed Swift advisory baseline and
enforces its review window. ``--live-osv`` delegates advisory matching to
the pinned OSV-Scanner and verifies that every locked input was inventoried.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from file_input import read_regular_file


PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_LOCKFILE = PROJECT_DIR / "Package.resolved"
DEFAULT_BASELINE = Path(__file__).resolve().parent / "dependency_security_baseline.json"
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_REVIEW_WINDOW = timedelta(days=90)
IDENTITY_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
REVISION_PATTERN = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SEMVER_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
ADVISORY_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}$")
RFC3339_UTC_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,9})?Z$"
)


class DependencySecurityError(ValueError):
    """An invalid policy, lockfile, or scanner inventory."""


@dataclass(frozen=True, order=True)
class SemanticVersion:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, value: object, *, field: str) -> SemanticVersion:
        if not isinstance(value, str):
            raise DependencySecurityError(f"{field} must be a semantic-version string")
        match = SEMVER_PATTERN.fullmatch(value)
        if match is None:
            raise DependencySecurityError(
                f"{field} must use stable MAJOR.MINOR.PATCH syntax"
            )
        try:
            components = tuple(int(component) for component in match.groups())
        except ValueError as error:
            raise DependencySecurityError(
                f"{field} contains an invalid integer"
            ) from error
        return cls(*components)

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True)
class LockedPin:
    identity: str
    location: str
    version: SemanticVersion
    revision: str


@dataclass(frozen=True)
class SecurityPolicy:
    reviewed_at: datetime
    expires_at: datetime
    advisories: tuple[ReviewedAdvisory, ...]


@dataclass(frozen=True)
class ReviewedAdvisory:
    advisory_id: str
    package_identity: str
    introduced: SemanticVersion
    fixed: SemanticVersion
    source: str

    def affects(self, version: SemanticVersion) -> bool:
        return self.introduced <= version < self.fixed


@dataclass(frozen=True)
class SecurityFinding:
    advisory_id: str
    pin: LockedPin
    introduced: SemanticVersion
    fixed: SemanticVersion


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DependencySecurityError(f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def decode_json(data: bytes | str, *, source: str) -> object:
    try:
        text = data.decode("utf-8") if isinstance(data, bytes) else data
    except UnicodeDecodeError as error:
        raise DependencySecurityError(f"{source} is not valid UTF-8") from error
    if text.startswith("\ufeff"):
        raise DependencySecurityError(f"{source} must not contain a UTF-8 BOM")

    def reject_constant(value: str) -> Any:
        raise DependencySecurityError(f"{source} contains invalid JSON number: {value}")

    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except DependencySecurityError:
        raise
    except json.JSONDecodeError as error:
        raise DependencySecurityError(f"{source} is malformed JSON") from error


def load_json_file(path: Path, *, label: str) -> object:
    try:
        data = read_regular_file(
            path, max_bytes=MAX_JSON_BYTES, follow_symlinks=False
        )
    except (OSError, ValueError) as error:
        raise DependencySecurityError(f"cannot read {label}: {error}") from error
    return decode_json(data, source=label)


def _require_object(value: object, *, field: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise DependencySecurityError(f"{field} must be a JSON object")
    return value


def _require_exact_keys(
    value: dict[str, object], expected: set[str], *, field: str
) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        details: list[str] = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        raise DependencySecurityError(
            f"{field} has invalid keys ({'; '.join(details)})"
        )


def _require_integer(value: object, *, field: str) -> int:
    if type(value) is not int:
        raise DependencySecurityError(f"{field} must be an integer")
    return value


def _require_nonempty_string(
    value: object, *, field: str, maximum_length: int = 4096
) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum_length:
        raise DependencySecurityError(f"{field} must be a non-empty bounded string")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        raise DependencySecurityError(f"{field} must not contain control characters")
    return value


def _require_https_url(value: object, *, field: str) -> str:
    url = _require_nonempty_string(value, field=field)
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise DependencySecurityError(
            f"{field} must be an HTTPS URL without credentials, query, or fragment"
        )
    return url


def parse_lockfile(payload: object) -> tuple[LockedPin, ...]:
    root = _require_object(payload, field="Package.resolved")
    _require_exact_keys(
        root, {"originHash", "pins", "version"}, field="Package.resolved"
    )
    if _require_integer(root["version"], field="Package.resolved.version") != 3:
        raise DependencySecurityError("Package.resolved version must be 3")
    origin_hash = root["originHash"]
    if (
        not isinstance(origin_hash, str)
        or SHA256_PATTERN.fullmatch(origin_hash) is None
    ):
        raise DependencySecurityError(
            "Package.resolved originHash must be 64 lowercase hex"
        )
    raw_pins = root["pins"]
    if not isinstance(raw_pins, list) or not raw_pins:
        raise DependencySecurityError("Package.resolved pins must be a non-empty array")

    pins: list[LockedPin] = []
    seen_identities: set[str] = set()
    for index, raw_pin in enumerate(raw_pins):
        field = f"Package.resolved.pins[{index}]"
        pin = _require_object(raw_pin, field=field)
        _require_exact_keys(pin, {"identity", "kind", "location", "state"}, field=field)
        identity = _require_nonempty_string(pin["identity"], field=f"{field}.identity")
        if IDENTITY_PATTERN.fullmatch(identity) is None:
            raise DependencySecurityError(f"{field}.identity is invalid")
        if identity in seen_identities:
            raise DependencySecurityError(
                f"Package.resolved has duplicate identity: {identity}"
            )
        seen_identities.add(identity)
        if pin["kind"] != "remoteSourceControl":
            raise DependencySecurityError(f"{field}.kind must be remoteSourceControl")
        location = _require_https_url(pin["location"], field=f"{field}.location")
        state = _require_object(pin["state"], field=f"{field}.state")
        _require_exact_keys(state, {"revision", "version"}, field=f"{field}.state")
        revision = _require_nonempty_string(
            state["revision"], field=f"{field}.state.revision", maximum_length=64
        )
        if REVISION_PATTERN.fullmatch(revision) is None:
            raise DependencySecurityError(
                f"{field}.state.revision must be a 40- or 64-character lowercase Git hash"
            )
        version = SemanticVersion.parse(
            state["version"], field=f"{field}.state.version"
        )
        pins.append(LockedPin(identity, location, version, revision))
    return tuple(pins)


def _parse_reviewed_advisories(raw_advisories: object) -> tuple[ReviewedAdvisory, ...]:
    if not isinstance(raw_advisories, list):
        raise DependencySecurityError("reviewedAdvisories must be an array")

    advisories: list[ReviewedAdvisory] = []
    seen_coordinates: set[tuple[str, str]] = set()
    for index, raw_advisory in enumerate(raw_advisories):
        field = f"reviewedAdvisories[{index}]"
        advisory = _require_object(raw_advisory, field=field)
        _require_exact_keys(
            advisory,
            {"id", "packageIdentity", "introduced", "fixed", "source"},
            field=field,
        )
        advisory_id = _require_nonempty_string(advisory["id"], field=f"{field}.id")
        if ADVISORY_ID_PATTERN.fullmatch(advisory_id) is None:
            raise DependencySecurityError(f"{field}.id is invalid")
        package_identity = _require_nonempty_string(
            advisory["packageIdentity"], field=f"{field}.packageIdentity"
        )
        if IDENTITY_PATTERN.fullmatch(package_identity) is None:
            raise DependencySecurityError(f"{field}.packageIdentity is invalid")
        coordinate = (advisory_id, package_identity)
        if coordinate in seen_coordinates:
            raise DependencySecurityError(
                f"dependency security baseline duplicates {advisory_id} for {package_identity}"
            )
        seen_coordinates.add(coordinate)
        introduced = SemanticVersion.parse(
            advisory["introduced"], field=f"{field}.introduced"
        )
        fixed = SemanticVersion.parse(advisory["fixed"], field=f"{field}.fixed")
        if introduced >= fixed:
            raise DependencySecurityError(f"{field} must have introduced < fixed")
        source = _require_https_url(advisory["source"], field=f"{field}.source")
        advisories.append(
            ReviewedAdvisory(
                advisory_id,
                package_identity,
                introduced,
                fixed,
                source,
            )
        )

    return tuple(advisories)


def _parse_utc_datetime(value: object, *, field: str) -> datetime:
    timestamp = _require_nonempty_string(value, field=field, maximum_length=128)
    if RFC3339_UTC_PATTERN.fullmatch(timestamp) is None:
        raise DependencySecurityError(f"{field} must be an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as error:
        raise DependencySecurityError(f"{field} is not a valid timestamp") from error
    if parsed.utcoffset() != timedelta(0):
        raise DependencySecurityError(f"{field} must use UTC")
    return parsed


def parse_security_policy(payload: object) -> SecurityPolicy:
    root = _require_object(payload, field="dependency security baseline")
    schema_version = _require_integer(
        root.get("schemaVersion"), field="dependency security baseline.schemaVersion"
    )
    if schema_version != 2:
        raise DependencySecurityError(
            "dependency security baseline schemaVersion must be 2"
        )
    _require_exact_keys(
        root,
        {
            "schemaVersion",
            "reviewedAt",
            "expiresAt",
            "reviewedAdvisories",
        },
        field="dependency security baseline",
    )
    reviewed_at = _parse_utc_datetime(
        root["reviewedAt"], field="dependency security baseline.reviewedAt"
    )
    expires_at = _parse_utc_datetime(
        root["expiresAt"], field="dependency security baseline.expiresAt"
    )
    if expires_at <= reviewed_at:
        raise DependencySecurityError(
            "dependency security baseline expiresAt must be after reviewedAt"
        )
    if expires_at - reviewed_at > MAX_REVIEW_WINDOW:
        raise DependencySecurityError(
            "dependency security baseline review window exceeds 90 days"
        )
    return SecurityPolicy(
        reviewed_at,
        expires_at,
        _parse_reviewed_advisories(root["reviewedAdvisories"]),
    )


def parse_baseline(payload: object) -> tuple[ReviewedAdvisory, ...]:
    """Return reviewed Swift advisories for compatibility with existing callers."""

    return parse_security_policy(payload).advisories


def load_lockfile(path: Path = DEFAULT_LOCKFILE) -> tuple[LockedPin, ...]:
    return parse_lockfile(load_json_file(path, label="Package.resolved"))


def load_baseline(path: Path = DEFAULT_BASELINE) -> tuple[ReviewedAdvisory, ...]:
    return parse_baseline(load_json_file(path, label="dependency security baseline"))


def load_security_policy(path: Path = DEFAULT_BASELINE) -> SecurityPolicy:
    return parse_security_policy(
        load_json_file(path, label="dependency security baseline")
    )


def validate_policy_freshness(
    policy: SecurityPolicy, *, now: datetime | None = None
) -> None:
    current = datetime.now(timezone.utc) if now is None else now
    if current.tzinfo is None or current.utcoffset() is None:
        raise DependencySecurityError("security review clock must include a timezone")
    current = current.astimezone(timezone.utc)
    if policy.reviewed_at > current:
        raise DependencySecurityError(
            "dependency security baseline reviewedAt is in the future"
        )
    if current >= policy.expires_at:
        raise DependencySecurityError("dependency security baseline review has expired")


def scan_offline_baseline(
    pins: Sequence[LockedPin], advisories: Sequence[ReviewedAdvisory]
) -> tuple[SecurityFinding, ...]:
    pins_by_identity = {pin.identity: pin for pin in pins}
    unknown_identities = sorted(
        {
            advisory.package_identity
            for advisory in advisories
            if advisory.package_identity not in pins_by_identity
        }
    )
    if unknown_identities:
        raise DependencySecurityError(
            "reviewed advisory package identity is not present in Package.resolved: "
            + ", ".join(unknown_identities)
        )
    findings: list[SecurityFinding] = []
    for advisory in advisories:
        pin = pins_by_identity.get(advisory.package_identity)
        if pin is not None and advisory.affects(pin.version):
            findings.append(
                SecurityFinding(
                    advisory_id=advisory.advisory_id,
                    pin=pin,
                    introduced=advisory.introduced,
                    fixed=advisory.fixed,
                )
            )
    return tuple(
        sorted(findings, key=lambda item: (item.pin.identity, item.advisory_id))
    )


def commit_inventory(pins: Sequence[LockedPin]) -> dict[str, object]:
    # Official OSV-Scanner custom lockfile format. Keep commit and version inputs
    # separate: the native Swift extractor currently drops state.revision.
    return {
        "results": [
            {
                "packages": [
                    {"package": {"name": pin.identity, "commit": pin.revision}}
                    for pin in pins
                ]
            }
        ]
    }


def uv_inventory(path: Path) -> set[tuple[str, str]]:
    # This is only an inventory completeness check; OSV-Scanner extracts and matches
    # the actual lockfile.
    try:
        data = read_regular_file(path, max_bytes=MAX_JSON_BYTES, follow_symlinks=False)
        packages = tomllib.loads(data.decode("utf-8"))["package"]
        if not isinstance(packages, list) or not packages:
            raise ValueError("expected a non-empty package array")
        return {
            (
                _require_nonempty_string(package["name"], field="name"),
                _require_nonempty_string(package["version"], field="version"),
            )
            for package in packages
        }
    except (KeyError, TypeError, OSError, ValueError) as error:
        raise DependencySecurityError(f"invalid {path}: {error}") from error


def verify_scanner_inventory(
    report: object, expected: dict[Path, set[tuple[str, str, str]]]
) -> None:
    try:
        observed: dict[Path, set[tuple[str, str, str]]] = {}
        results = _require_object(report, field="OSV-Scanner report")["results"]
        if not isinstance(results, list):
            raise ValueError("expected a results array")
        for result in results:
            path = Path(result["source"]["path"])
            packages = observed.setdefault(path, set())
            for item in result["packages"]:
                coordinate = item["package"]
                ecosystem = coordinate["ecosystem"]
                value = coordinate["commit" if ecosystem == "GIT" else "version"]
                packages.add((ecosystem, coordinate["name"], value))
    except (KeyError, TypeError, ValueError) as error:
        raise DependencySecurityError("malformed OSV-Scanner inventory") from error

    for path, packages in expected.items():
        missing = packages - observed.get(path, set())
        if missing:
            raise DependencySecurityError(
                f"OSV-Scanner inventory incomplete for {path}: missing {sorted(missing)}"
            )


def scan_live_osv(pins: Sequence[LockedPin]) -> int:
    if not pins:
        raise DependencySecurityError("cannot audit an empty Swift lockfile")
    tracked = subprocess.run(
        ["git", "ls-files", "-z", "scripts/*.py.lock", "scripts/**/*.py.lock"],
        cwd=PROJECT_DIR,
        check=True,
        capture_output=True,
    ).stdout
    python_locks = [
        PROJECT_DIR / "tools/uv.lock",
        *(PROJECT_DIR / path.decode("utf-8") for path in tracked.split(b"\0") if path),
    ]
    expected = {
        path: {("PyPI", name, version) for name, version in uv_inventory(path)}
        for path in python_locks
    }
    expected[DEFAULT_LOCKFILE] = {
        (
            "SwiftURL",
            pin.location.removeprefix("https://").removesuffix(".git"),
            str(pin.version),
        )
        for pin in pins
    }
    report = PROJECT_DIR / ".artifacts/quality/dependency-osv.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="rill-osv-") as directory:
        inventory = Path(directory).resolve() / "swift-commits.json"
        inventory.write_text(json.dumps(commit_inventory(pins)), encoding="utf-8")
        expected[inventory] = {("GIT", pin.identity, pin.revision) for pin in pins}
        config = inventory.with_name("osv-scanner.toml")
        # Do not allow auto-discovered configuration to silently suppress an
        # advisory or exclude a package from this no-exceptions audit.
        config.write_text("", encoding="utf-8")
        result = subprocess.run(
            [
                "osv-scanner",
                "scan",
                "source",
                "--config",
                str(config),
                "-L",
                f"osv-scanner:{inventory}",
                "-L",
                str(DEFAULT_LOCKFILE),
                *[arg for path in python_locks for arg in ("-L", f"uv.lock:{path}")],
                "--all-packages",
                "--format=json",
                "--output-file",
                str(report),
            ],
            cwd=PROJECT_DIR,
            check=False,
        )
        if result.returncode:
            print(
                f"OSV-Scanner exited with status {result.returncode}; see {report}",
                file=sys.stderr,
            )
            return 1
        verify_scanner_inventory(
            load_json_file(report, label="OSV-Scanner report"), expected
        )
    print(f"OSV-Scanner dependency audit passed; see {report}.")
    return 0


def _print_findings(findings: Sequence[SecurityFinding]) -> None:
    print("Dependency security check failed:", file=sys.stderr)
    for finding in findings:
        print(
            f"- {finding.advisory_id}: {finding.pin.identity} {finding.pin.version} "
            f"is in the reviewed affected range >= {finding.introduced}, < {finding.fixed}",
            file=sys.stderr,
        )


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live-osv",
        action="store_true",
        help="Use OSV-Scanner to audit locked Swift revisions and versions and Python versions",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        pins = load_lockfile(DEFAULT_LOCKFILE)
        policy = load_security_policy(DEFAULT_BASELINE)
        validate_policy_freshness(policy)
        offline_findings = scan_offline_baseline(pins, policy.advisories)
        if offline_findings:
            _print_findings(offline_findings)
            return 1
        if arguments.live_osv:
            return scan_live_osv(pins)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Dependency security check failed: {error}", file=sys.stderr)
        return 1

    audited_commits = len(pins)
    commit_label = "commit" if audited_commits == 1 else "commits"
    advisory_label = "advisory" if len(policy.advisories) == 1 else "advisories"
    print(
        f"Dependency security check passed (reviewed baseline; {audited_commits} auditable "
        f"{commit_label}; {len(policy.advisories)} reviewed Swift {advisory_label}; "
        f"review valid until {policy.expires_at.isoformat()})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
