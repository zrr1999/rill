#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

"""Exercise published map snapshots against a real temporary Git repository."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CodeMapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write('Sources/A/A.swift', 'public struct A {}\n')
        self.write('Sources/B/B.swift', 'public struct B {}\n')
        self.write('Tests/Example.swift', 'import XCTest\n@testable import A\nimport B\nfunc testExample() {}\n')
        for path in ('Package.swift', 'Package.resolved', 'zensical.toml', 'docs/architecture.md',
                     'docs/documentation.md', 'docs/codemap/index.md'):
            self.write(path, '')
        self.write('docs/codemap/template.html', '__MAP_DATA__')
        self.write('scripts/codemap.py', (ROOT / 'scripts/codemap.py').read_text())
        self.git('init', '--quiet')
        self.git('config', 'user.email', 'codemap@example.invalid')
        self.git('config', 'user.name', 'Code map test')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'source snapshot')
        evidence = ['Sources/A/A.swift']
        self.data = {
            'schemaVersion': 2, 'baseline': self.git('rev-parse', 'HEAD').strip(),
            'nodes': [{'id': name, 'role': 'role', 'impact': 'impact', 'evidence': evidence}
                      for name in ('A', 'B')],
            'edges': [],
            'flows': [{'command': 'example', 'steps': [
                {'node': 'A', 'description': 'example', 'evidence': evidence}]} for _ in range(3)],
            'tests': [{'path': 'Tests/Example.swift', 'symbol': 'testExample', 'framework': 'XCTest'}],
            'testNote': 'Declarations only.',
        }
        self.save_data()

    def write(self, path, text):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE)

    def save_data(self):
        self.write('docs/codemap/codemap.json', json.dumps(self.data))

    def run_map(self, mode, *, succeeds=True):
        result = subprocess.run([sys.executable, 'scripts/codemap.py', mode], cwd=self.root,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_snapshot_is_stable_until_baseline_advances(self):
        self.run_map('build')
        original = json.loads((self.root / 'docs/codemap/codemap.html').read_text())
        self.assertEqual(original['nodes'][0]['files'], ['Sources/A/A.swift'])
        self.assertEqual([node['tests'][0]['line'] for node in original['nodes']], [4, 4])
        self.write('Sources/A/Added.swift', 'struct Added {}\n')
        self.write('Tests/Example.swift', '\nimport XCTest\n@testable import A\nimport B\nfunc testExample() {}\n')
        self.run_map('check')
        self.git('add', 'Sources', 'Tests')
        self.git('commit', '--quiet', '-m', 'new source snapshot')
        self.data['baseline'] = self.git('rev-parse', 'HEAD').strip()
        self.save_data()
        self.run_map('check', succeeds=False)
        self.run_map('build')
        updated = json.loads((self.root / 'docs/codemap/codemap.html').read_text())
        self.assertEqual(updated['nodes'][0]['files'], ['Sources/A/A.swift', 'Sources/A/Added.swift'])
        self.assertEqual([node['tests'][0]['line'] for node in updated['nodes']], [5, 5])

    def test_missing_snapshot_evidence_and_test_declarations_are_rejected(self):
        for change in ('evidence', 'test'):
            with self.subTest(change=change):
                if change == 'evidence':
                    self.data['nodes'][0]['evidence'] = ['Sources/A/Missing.swift']
                else:
                    self.data['nodes'][0]['evidence'] = ['Sources/A/A.swift']
                    self.data['tests'][0]['symbol'] = 'testMissing'
                self.save_data()
                self.run_map('build', succeeds=False)

    def test_changed_map_artifacts_and_snapshot_hashes_are_rejected(self):
        for path in ('docs/codemap/codemap.html', 'docs/codemap/template.html', 'docs/codemap/codemap.lock'):
            with self.subTest(path=path):
                self.run_map('build')
                original = (self.root / path).read_text()
                if path.endswith('.lock'):
                    lock = json.loads(original)
                    lock['sourceFiles'][0]['sha256'] = '0' * 64
                    self.write(path, json.dumps(lock))
                else:
                    self.write(path, original + 'changed')
                self.run_map('check', succeeds=False)
                self.write(path, original)

    def test_tree_object_cannot_be_used_as_a_commit_link(self):
        self.data['baseline'] = self.git('rev-parse', 'HEAD^{tree}').strip()
        self.save_data()
        self.run_map('build', succeeds=False)

    def test_new_test_file_requires_a_representative_when_advancing_snapshot(self):
        self.write('Tests/Added.swift', 'import Testing\nimport A\n@Test func added() {}\n')
        self.git('add', 'Tests')
        self.git('commit', '--quiet', '-m', 'add a test file')
        self.data['baseline'] = self.git('rev-parse', 'HEAD').strip()
        self.save_data()
        self.run_map('build', succeeds=False)
        self.data['tests'].append({'path': 'Tests/Added.swift', 'symbol': 'added', 'framework': 'Swift Testing'})
        self.save_data()
        self.run_map('build')
        generated = json.loads((self.root / 'docs/codemap/codemap.html').read_text())
        self.assertEqual([test['symbol'] for test in generated['nodes'][0]['tests']], ['testExample', 'added'])


if __name__ == '__main__':
    unittest.main()
