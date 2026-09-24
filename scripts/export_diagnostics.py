#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Export the last seven days of Rill's already-sanitized diagnostic events.

Local monitoring utility: reads SQLite in read-only mode, never reads encrypted
receipts, transcripts, clipboard payloads, credentials, or audio. Replaces the
previous snapshot instead of accumulating a second permanent event history.
"""

import collections
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import time


ROOT = Path.home() / "Library/Application Support/Rill/Diagnostics"
DATABASE = ROOT.parent / "rill.sqlite"


def atomic_write(name, content):
    fd, temporary = tempfile.mkstemp(prefix=".export-", dir=ROOT)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, ROOT / name)
    finally:
        Path(temporary).unlink(missing_ok=True)


def utc(timestamp):
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat()


def main():
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(ROOT, 0o700)
    now = time.time()
    since = now - 7 * 86400
    connection = sqlite3.connect(DATABASE.as_uri() + "?mode=ro", uri=True, timeout=5)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only = ON")
        connection.execute("BEGIN")
        generation = connection.execute(
            "SELECT current_generation FROM run_history_generation WHERE id = 1"
        ).fetchone()[0]
        rows = connection.execute(
            "SELECT id, timestamp, run_id, subsystem, level, event, metadata_json "
            "FROM diagnostic_events WHERE timestamp >= ? AND timestamp <= ? "
            "AND write_generation = ? ORDER BY timestamp, id", (since, now, generation)
        ).fetchall()
    finally:
        connection.close()
    events = []
    for row in rows:
        event = dict(row)
        event["metadata"] = json.loads(event.pop("metadata_json"))
        event["time_utc"] = utc(event["timestamp"])
        events.append(event)
    counts = collections.Counter(e["level"] for e in events)
    warnings = collections.Counter(
        (e["level"], e["event"]) for e in events
        if e["level"] in ("warning", "error")
    )
    summary = {
        "schema_version": 2,
        "history_generation": generation,
        "exported_at_utc": utc(now),
        "window_start_utc": utc(since),
        "event_count": len(events),
        "latest_event_utc": events[-1]["time_utc"] if events else None,
        "max_event_id": max((e["id"] for e in events), default=None),
        "levels": dict(counts),
        "warnings_and_errors": [
            {"level": level, "event": event, "count": count}
            for (level, event), count in warnings.most_common()
        ],
        "invalid_event_count": sum(
            e["event"] == "diagnostic.event.invalid" for e in events
        ),
        "scope": "Stored sanitized diagnostic events only; no free-text messages or encrypted receipts.",
        "timing_note": "Group by run_id and event. session.stage completed durationMillis is measured from session.startedAt, not standalone STT or API latency. Missing timings are not zero.",
    }
    info_path = Path("/Applications/Rill.app/Contents/Info.plist")
    if info_path.is_file():
        with info_path.open("rb") as source:
            info = plistlib.load(source)
        summary["installed_app_at_export"] = {
            key: info.get(key) for key in (
                "CFBundleShortVersionString", "CFBundleVersion", "RillSourceRevision"
            )
        }
        summary["version_note"] = "Installed artifact at export time; historical events have no per-run build identity."
    header = {"type": "export", **summary}
    atomic_write("diagnostics.jsonl", "\n".join(
        json.dumps(value, ensure_ascii=False) for value in [header, *events]
    ) + "\n")
    atomic_write("summary.json", json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
