#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import export_diagnostics as exporter
import analyze_diagnostics as analyzer


class DiagnosticExportTests(unittest.TestCase):
    def test_export_respects_clear_generation_and_does_not_export_message(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'Diagnostics'
            database = Path(directory) / 'rill.sqlite'
            with sqlite3.connect(database) as connection:
                connection.executescript('''
                    CREATE TABLE run_history_generation (id INTEGER, current_generation INTEGER);
                    INSERT INTO run_history_generation VALUES (1, 2);
                    CREATE TABLE diagnostic_events (id INTEGER, timestamp REAL, run_id TEXT,
                        subsystem TEXT, level TEXT, event TEXT, metadata_json TEXT,
                        message TEXT, write_generation INTEGER);
                ''')
                for index, generation in [(1, 1), (2, 2)]:
                    connection.execute('INSERT INTO diagnostic_events VALUES (?,?,?,?,?,?,?,?,?)',
                        (index, time.time(), 'run', 'session', 'debug', 'session.stage',
                         '{"stage":"completed"}', 'private message', generation))
            before = database.read_bytes()
            with patch.object(exporter, 'ROOT', root), patch.object(exporter, 'DATABASE', database), contextlib.redirect_stdout(io.StringIO()):
                exporter.main()
            output = (root / 'diagnostics.jsonl').read_text()
            header, event = [json.loads(line) for line in output.splitlines()]
            self.assertEqual(header['event_count'], 1)
            self.assertEqual(event['id'], 2)
            self.assertNotIn('private message', output)
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual((root / 'diagnostics.jsonl').stat().st_mode & 0o777, 0o600)

    def test_missing_database_fails_without_creating_source_or_replacing_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / 'missing.sqlite'
            output = root / 'diagnostics.jsonl'
            output.write_text('previous snapshot')
            with patch.object(exporter, 'ROOT', root), patch.object(exporter, 'DATABASE', database):
                with self.assertRaises(sqlite3.OperationalError):
                    exporter.main()
            self.assertFalse(database.exists())
            self.assertEqual(output.read_text(), 'previous snapshot')

    def test_missing_or_duplicate_endpoints_are_not_zero_latency(self):
        def event(index, code, metadata):
            return {'id': index, 'timestamp': 100 + index, 'time_utc': f't{index}',
                    'event': code, 'run_id': 'r', 'metadata': metadata}
        events = [event(1, 'recording.hotkey.released', {}),
                  event(2, 'provider.openai.rewrite.completed', {'durationMillis': '123'}),
                  event(3, 'session.stage', {'stage': 'completed'}),
                  event(4, 'clipboard.inject.paste.posted', {'pasteDispatchMillis': '12'})]
        header = {'exported_at_utc': '2026-09-23T00:00:00+00:00', 'invalid_event_count': 0}
        report = analyzer.scan(header, events)
        self.assertEqual(report['runs'][0]['metrics_ms']['api_completed'], 123)
        self.assertEqual(report['runs'][0]['metrics_ms']['pasteDispatchMillis'], 12)
        self.assertNotIn('recognition_measured', report['runs'][0]['metrics_ms'])
        report = analyzer.scan(header, events + [events[1]])
        self.assertNotIn('api_completed', report['runs'][0]['metrics_ms'])


if __name__ == '__main__':
    unittest.main()
