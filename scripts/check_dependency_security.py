#!/usr/bin/env python3
"""Fail-closed security checks for locked SwiftPM dependencies.

The default offline check applies the reviewed Swift advisory baseline and
enforces its review window. ``--live-osv`` additionally submits every locked
Git commit to OSV's official batch API and fails when any advisory is returned.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11 or newer is required")


PROJECT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_LOCKFILE = PROJECT_DIR / "Package.resolved"
DEFAULT_BASELINE = Path(__file__).resolve().parent / "dependency_security_baseline.json"
OSV_QUERY_BATCH_URL = "https://api.osv.dev/v1/querybatch"
OSV_TIMEOUT_SECONDS = 30.0
MAX_JSON_BYTES = 32 * 1024 * 1024
MAX_PAGES_PER_QUERY = 100
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
    """A malformed policy, lockfile, network exchange, or OSV response."""


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
        return cls(*(int(component) for component in match.groups()))

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
    source: str
    advisory_id: str
    pin: LockedPin
    modified: str | None = None
    introduced: SemanticVersion | None = None
    fixed: SemanticVersion | None = None


@dataclass(frozen=True)
class _LiveAdvisory:
    advisory_id: str
    modified: str


@dataclass(frozen=True)
class _LivePage:
    advisories: tuple[_LiveAdvisory, ...]
    next_page_token: str | None


BatchTransport = Callable[[dict[str, object]], object]


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
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise DependencySecurityError(f"cannot read {label}: {path}") from error
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise DependencySecurityError(
                    f"{label} must be a regular non-symlink file: {path}"
                )
            if before.st_size > MAX_JSON_BYTES:
                raise DependencySecurityError(
                    f"{label} exceeds the {MAX_JSON_BYTES}-byte limit"
                )
            data = source.read(MAX_JSON_BYTES + 1)
            after = os.fstat(source.fileno())
    except DependencySecurityError:
        raise
    except OSError as error:
        raise DependencySecurityError(f"cannot read {label}: {path}") from error
    if len(data) > MAX_JSON_BYTES:
        raise DependencySecurityError(
            f"{label} exceeds the {MAX_JSON_BYTES}-byte limit"
        )
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    if len(data) != before.st_size or before_identity != after_identity:
        raise DependencySecurityError(f"{label} changed while it was being read")
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
    if not isinstance(raw_pins, list):
        raise DependencySecurityError("Package.resolved pins must be an array")

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
        raise DependencySecurityError("dependency security baseline schemaVersion must be 2")
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
    if not os.path.lexists(path):
        return ()
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
        raise DependencySecurityError(
            "dependency security baseline review has expired"
        )


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
                    source="reviewed-baseline",
                    advisory_id=advisory.advisory_id,
                    pin=pin,
                    introduced=advisory.introduced,
                    fixed=advisory.fixed,
                )
            )
    return tuple(
        sorted(findings, key=lambda item: (item.pin.identity, item.advisory_id))
    )


def _parse_modified(value: object, *, field: str) -> str:
    modified = _require_nonempty_string(value, field=field, maximum_length=128)
    if RFC3339_UTC_PATTERN.fullmatch(modified) is None:
        raise DependencySecurityError(f"{field} must be an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(modified[:-1] + "+00:00")
    except ValueError as error:
        raise DependencySecurityError(f"{field} is not a valid timestamp") from error
    if parsed.utcoffset() is None:
        raise DependencySecurityError(f"{field} must include a timezone")
    return modified


def parse_osv_batch_response(
    payload: object, *, expected_results: int
) -> tuple[_LivePage, ...]:
    root = _require_object(payload, field="OSV querybatch response")
    _require_exact_keys(root, {"results"}, field="OSV querybatch response")
    raw_results = root["results"]
    if not isinstance(raw_results, list) or len(raw_results) != expected_results:
        raise DependencySecurityError(
            "OSV querybatch response result count does not match the request"
        )

    pages: list[_LivePage] = []
    page_tokens: set[str] = set()
    for result_index, raw_result in enumerate(raw_results):
        field = f"OSV querybatch results[{result_index}]"
        result = _require_object(raw_result, field=field)
        unknown_keys = set(result) - {"vulns", "next_page_token"}
        if unknown_keys:
            raise DependencySecurityError(
                f"{field} has unexpected keys: {', '.join(sorted(unknown_keys))}"
            )
        raw_vulnerabilities = result.get("vulns", [])
        if not isinstance(raw_vulnerabilities, list):
            raise DependencySecurityError(f"{field}.vulns must be an array")
        advisories: list[_LiveAdvisory] = []
        page_ids: set[str] = set()
        for advisory_index, raw_vulnerability in enumerate(raw_vulnerabilities):
            advisory_field = f"{field}.vulns[{advisory_index}]"
            vulnerability = _require_object(raw_vulnerability, field=advisory_field)
            _require_exact_keys(vulnerability, {"id", "modified"}, field=advisory_field)
            advisory_id = _require_nonempty_string(
                vulnerability["id"], field=f"{advisory_field}.id", maximum_length=128
            )
            if ADVISORY_ID_PATTERN.fullmatch(advisory_id) is None:
                raise DependencySecurityError(f"{advisory_field}.id is invalid")
            if advisory_id in page_ids:
                raise DependencySecurityError(
                    f"OSV returned duplicate advisory {advisory_id} in one result"
                )
            page_ids.add(advisory_id)
            advisories.append(
                _LiveAdvisory(
                    advisory_id,
                    _parse_modified(
                        vulnerability["modified"], field=f"{advisory_field}.modified"
                    ),
                )
            )
        next_page_token: str | None = None
        if "next_page_token" in result:
            next_page_token = _require_nonempty_string(
                result["next_page_token"],
                field=f"{field}.next_page_token",
                maximum_length=8192,
            )
            if next_page_token in page_tokens:
                raise DependencySecurityError(
                    "OSV returned the same next_page_token for multiple results"
                )
            page_tokens.add(next_page_token)
        pages.append(_LivePage(tuple(advisories), next_page_token))
    return tuple(pages)


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(
        self,
        request: Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> Request | None:
        raise DependencySecurityError(
            f"OSV querybatch unexpectedly redirected with HTTP {code}"
        )


def post_osv_querybatch(payload: dict[str, object]) -> object:
    try:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode(
            "utf-8"
        )
    except (TypeError, ValueError) as error:
        raise DependencySecurityError(
            "cannot serialize the OSV querybatch request"
        ) from error
    request = Request(
        OSV_QUERY_BATCH_URL,
        data=body,
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Rill-dependency-security/1",
        },
        method="POST",
    )
    opener = build_opener(_RejectRedirects())
    try:
        with opener.open(request, timeout=OSV_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise DependencySecurityError(
                    f"OSV querybatch returned HTTP {response.status}"
                )
            if response.geturl() != OSV_QUERY_BATCH_URL:
                raise DependencySecurityError("OSV querybatch response URL changed")
            if response.headers.get_content_type() != "application/json":
                raise DependencySecurityError(
                    "OSV querybatch response Content-Type is not application/json"
                )
            content_length = response.headers.get("Content-Length")
            if content_length is not None:
                try:
                    declared_length = int(content_length)
                except ValueError as error:
                    raise DependencySecurityError(
                        "OSV querybatch returned an invalid Content-Length"
                    ) from error
                if declared_length < 0 or declared_length > MAX_JSON_BYTES:
                    raise DependencySecurityError(
                        "OSV querybatch response exceeds the size limit"
                    )
            response_body = response.read(MAX_JSON_BYTES + 1)
            if len(response_body) > MAX_JSON_BYTES:
                raise DependencySecurityError(
                    "OSV querybatch response exceeds the size limit"
                )
    except DependencySecurityError:
        raise
    except HTTPError as error:
        raise DependencySecurityError(
            f"OSV querybatch returned HTTP {error.code}"
        ) from error
    except (URLError, TimeoutError, OSError) as error:
        raise DependencySecurityError(
            "OSV querybatch network request failed"
        ) from error
    return decode_json(response_body, source="OSV querybatch response")


def scan_live_osv(
    pins: Sequence[LockedPin],
    *,
    transport: BatchTransport = post_osv_querybatch,
) -> tuple[SecurityFinding, ...]:
    pending: list[tuple[int, LockedPin, str | None]] = [
        (index, pin, None) for index, pin in enumerate(pins)
    ]
    seen_page_tokens = [set[str]() for _ in pins]
    seen_advisory_ids = [set[str]() for _ in pins]
    # The initial batch response is page one. Count every response so the
    # advertised cap cannot become one initial page plus MAX follow-ups.
    page_counts = [1 for _ in pins]
    findings: list[SecurityFinding] = []

    while pending:
        queries: list[dict[str, str]] = []
        for _, pin, page_token in pending:
            query = {"commit": pin.revision}
            if page_token is not None:
                query["page_token"] = page_token
            queries.append(query)
        try:
            raw_response = transport({"queries": queries})
        except DependencySecurityError:
            raise
        except (OSError, TimeoutError) as error:
            raise DependencySecurityError(
                "OSV querybatch network request failed"
            ) from error
        pages = parse_osv_batch_response(raw_response, expected_results=len(pending))

        next_pending: list[tuple[int, LockedPin, str | None]] = []
        for (original_index, pin, _), page in zip(pending, pages, strict=True):
            for advisory in page.advisories:
                if advisory.advisory_id in seen_advisory_ids[original_index]:
                    raise DependencySecurityError(
                        f"OSV returned duplicate advisory {advisory.advisory_id} "
                        f"across pages for {pin.identity}"
                    )
                seen_advisory_ids[original_index].add(advisory.advisory_id)
                findings.append(
                    SecurityFinding(
                        source="live-osv",
                        advisory_id=advisory.advisory_id,
                        pin=pin,
                        modified=advisory.modified,
                    )
                )
            if page.next_page_token is not None:
                if page.next_page_token in seen_page_tokens[original_index]:
                    raise DependencySecurityError(
                        f"OSV repeated a page token for {pin.identity}"
                    )
                seen_page_tokens[original_index].add(page.next_page_token)
                page_counts[original_index] += 1
                if page_counts[original_index] > MAX_PAGES_PER_QUERY:
                    raise DependencySecurityError(
                        f"OSV pagination exceeded {MAX_PAGES_PER_QUERY} pages for {pin.identity}"
                    )
                next_pending.append((original_index, pin, page.next_page_token))
        pending = next_pending

    return tuple(
        sorted(findings, key=lambda item: (item.pin.identity, item.advisory_id))
    )


def _print_findings(findings: Sequence[SecurityFinding]) -> None:
    print("Dependency security check failed:", file=sys.stderr)
    for finding in findings:
        if finding.source == "reviewed-baseline":
            print(
                f"- {finding.advisory_id}: {finding.pin.identity} {finding.pin.version} "
                f"is in the reviewed affected range >= {finding.introduced}, < {finding.fixed}",
                file=sys.stderr,
            )
        else:
            print(
                f"- {finding.advisory_id}: OSV reported {finding.pin.identity} "
                f"{finding.pin.version} at {finding.pin.revision} "
                f"(modified {finding.modified})",
                file=sys.stderr,
            )


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lockfile",
        type=Path,
        default=DEFAULT_LOCKFILE,
        help="SwiftPM Package.resolved file (default: repository root)",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=DEFAULT_BASELINE,
        help="Reviewed Swift dependency security baseline",
    )
    parser.add_argument(
        "--live-osv",
        action="store_true",
        help="Also query OSV for every locked SwiftPM commit",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        pins = load_lockfile(arguments.lockfile)
        policy = load_security_policy(arguments.baseline)
        validate_policy_freshness(policy)
        offline_findings = scan_offline_baseline(pins, policy.advisories)
        if offline_findings:
            _print_findings(offline_findings)
            return 1
        if arguments.live_osv:
            live_findings = scan_live_osv(pins)
            if live_findings:
                _print_findings(live_findings)
                return 1
    except DependencySecurityError as error:
        print(f"Dependency security check failed: {error}", file=sys.stderr)
        return 1

    mode = "reviewed baseline + live OSV" if arguments.live_osv else "reviewed baseline"
    audited_commits = len(pins)
    commit_label = "commit" if audited_commits == 1 else "commits"
    advisory_label = "advisory" if len(policy.advisories) == 1 else "advisories"
    print(
        f"Dependency security check passed ({mode}; {audited_commits} auditable "
        f"{commit_label}; {len(policy.advisories)} reviewed Swift {advisory_label}; "
        f"review valid until {policy.expires_at.isoformat()})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
