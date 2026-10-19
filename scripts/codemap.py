#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build/check the source-backed map without installing packages or executing Swift."""
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/codemap'


def file(path):
    full = (ROOT / path).resolve()
    if not full.is_relative_to(ROOT) or not full.is_file():
        raise ValueError('Missing or escaping evidence: ' + path)
    return full


def digest(path):
    return hashlib.sha256(file(path).read_bytes()).hexdigest()


def source_snapshot(baseline):
    assert re.fullmatch(r'[0-9a-f]{40}', baseline), 'Use an immutable Git commit'
    kind = subprocess.check_output(['git', 'cat-file', '-t', baseline], cwd=ROOT, text=True).strip()
    assert kind == 'commit', 'Snapshot baseline must name a commit object'
    archive = subprocess.check_output(
        ['git', 'archive', '--format=tar', baseline, 'Sources', 'Tests', 'Package.swift', 'Package.resolved'],
        cwd=ROOT,
    )
    with tarfile.open(fileobj=io.BytesIO(archive)) as snapshot:
        entries = [entry for entry in snapshot if not entry.isdir()]
        assert all(entry.isfile() for entry in entries), 'Snapshot contains unsupported source file types'
        return {entry.name: snapshot.extractfile(entry).read() for entry in entries}


def load():
    data = json.loads((OUT / 'codemap.json').read_text())
    assert data['schemaVersion'] == 2
    source = source_snapshot(data['baseline'])
    ids = [n['id'] for n in data['nodes']]
    assert len(ids) == len(set(ids)) and 0 < len(ids) <= 20
    assert 3 <= len(data['flows']) <= 5
    refs = set()
    owned = set()
    test_files = set()
    for path, content in source.items():
        if not path.startswith('Tests/') or not path.endswith('.swift'):
            continue
        text = content.decode()
        if (re.search(r'\bimport\s+XCTest\b', text) and re.search(r'\bfunc\s+test\w*\s*\(', text)
                or re.search(r'\bimport\s+Testing\b', text) and re.search(r'@Test\b', text)):
            test_files.add(path)
    tests = []
    for selection in data.pop('tests'):
        text = source[selection['path']].decode()
        lines = text.splitlines()
        positions = [i + 1 for i, line in enumerate(lines)
                     if re.search(r'\bfunc\s+' + re.escape(selection['symbol']) + r'\s*\(', line)]
        assert len(positions) == 1, selection
        test = {**selection, 'line': positions[0]}
        if test['framework'] == 'XCTest':
            assert test['symbol'].startswith('test') and 'XCTest' in text, test
        else:
            assert test['framework'] == 'Swift Testing' and 'import Testing' in text, test
            assert '@Test' in '\n'.join(lines[max(0, test['line'] - 7):test['line']]), test
        imports = set(re.findall(r'^\s*(?:@testable\s+)?import\s+(\w+)', text, re.MULTILINE))
        assert imports.intersection(ids), 'Test has no mapped module: ' + test['path']
        tests.append((test, imports))
    assert len(tests) == len({test['path'] for test, _ in tests}), 'Duplicate test selection'
    assert test_files == {test['path'] for test, _ in tests}, 'Review the representative selection for each test file'
    test_note = data.pop('testNote')
    for node in data['nodes']:
        assert node['role'] and node['impact'] and node['evidence']
        refs.update(node['evidence'])
        if node['id'] != 'external':
            actual = {path for path in source if path.startswith('Sources/' + node['id'] + '/')}
            assert actual, 'Missing module: ' + node['id']
            node['files'] = sorted(actual)
            node['tests'] = [test for test, imports in tests if node['id'] in imports]
            node['testNote'] = test_note
            assert not owned.intersection(actual), 'File assigned to multiple modules'
            owned.update(actual)
        else:
            node['files'] = node['evidence']
            node['tests'] = []
    all_sources = {path for path in source if path.startswith('Sources/')}
    assert owned == all_sources, 'Unmapped source files'
    edge_ids = [edge['id'] for edge in data['edges']]
    assert len(edge_ids) == len(set(edge_ids))
    for edge in data['edges']:
        assert edge['source'] in ids and edge['target'] in ids and edge['evidence']
        assert edge['kind'] in ('dependency', 'dataflow')
        refs.update(edge['evidence'])
    for flow in data['flows']:
        assert flow['steps'] and flow['command']
        for step in flow['steps']:
            assert step['node'] in ids and step['description'] and step['evidence']
            refs.update(step['evidence'])
    assert refs <= source.keys(), 'Missing snapshot evidence: ' + str(sorted(refs - source.keys()))
    return data, source


def html(data):
    payload = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')
    return (OUT / 'template.html').read_text().replace('__MAP_DATA__', payload)


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ''
    if mode not in ('build', 'check'):
        raise SystemExit('Usage: python3 scripts/codemap.py build|check')
    data, source = load()
    artifacts = {'docs/codemap/codemap.json', 'docs/codemap/codemap.html',
                 'docs/codemap/template.html', 'scripts/codemap.py', 'zensical.toml',
                 'docs/architecture.md', 'docs/documentation.md', 'docs/codemap/index.md'}
    if mode == 'build':
        (OUT / 'codemap.html').write_text(html(data))
    expected = {'schemaVersion': 3, 'baseline': data['baseline'], 'algorithm': 'sha256',
                'scope': 'Git snapshot source/test evidence and current map artifacts; not runtime acceptance.',
                'sourceFiles': [{'path': p, 'sha256': hashlib.sha256(source[p]).hexdigest()}
                                for p in sorted(source)],
                'artifacts': [{'path': p, 'sha256': digest(p)} for p in sorted(artifacts)]}
    if mode == 'build':
        (OUT / 'codemap.lock').write_text(json.dumps(expected, indent=2) + '\n')
    lock = json.loads((OUT / 'codemap.lock').read_text())
    assert lock == expected, 'Snapshot or map artifact lock differs; review changes before rebuilding'
    assert (OUT / 'codemap.html').read_text() == html(data), 'HTML differs from data/template'
    print(f"Verified {len(data['nodes'])} nodes, {len(data['edges'])} edges, {len(data['flows'])} flows and {len(source)} snapshot files at {data['baseline']}; source inventory and test declarations resolve.")


if __name__ == '__main__':
    main()
