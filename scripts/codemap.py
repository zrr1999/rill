#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build/check the source-backed map without installing packages or executing Swift."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/codemap'


def file(path):
    full = (ROOT / path).resolve()
    if not full.is_relative_to(ROOT) or not full.is_file():
        raise ValueError('Missing or escaping evidence: ' + path)
    return full


def digest(path):
    return hashlib.sha256(file(path).read_bytes()).hexdigest()


def load():
    data = json.loads((OUT / 'codemap.json').read_text())
    ids = [n['id'] for n in data['nodes']]
    assert len(ids) == len(set(ids)) and 0 < len(ids) <= 20
    assert 3 <= len(data['flows']) <= 5
    refs = {'Package.swift', 'Package.resolved', 'zensical.toml', 'docs/architecture.md',
            'docs/documentation.md', 'docs/codemap/index.md'}
    owned = set()
    for node in data['nodes']:
        assert node['role'] and node['impact'] and node['evidence']
        refs.update(node['files'] + node['evidence'])
        if node['id'] != 'external':
            actual = {str(p.relative_to(ROOT)) for p in (ROOT / 'Sources' / node['id']).rglob('*') if p.is_file()}
            assert actual == set(node['files']), 'Stale module inventory: ' + node['id']
            assert not owned.intersection(actual), 'File assigned to multiple modules'
            owned.update(actual)
        for test in node['tests']:
            refs.add(test['path'])
            text = file(test['path']).read_text()
            lines = text.splitlines()
            assert 1 <= test['line'] <= len(lines)
            assert re.search(r'\bfunc\s+' + re.escape(test['symbol']) + r'\s*\(', lines[test['line'] - 1]), test
            if test['framework'] == 'XCTest':
                assert test['symbol'].startswith('test') and 'XCTest' in text, test
            else:
                assert test['framework'] == 'Swift Testing' and 'import Testing' in text, test
                assert '@Test' in '\n'.join(lines[max(0, test['line'] - 7):test['line']]), test
            assert re.search(r'\bimport\s+' + re.escape(node['id']) + r'\b', text), test
    all_sources = {str(p.relative_to(ROOT)) for p in (ROOT / 'Sources').rglob('*') if p.is_file()}
    assert owned == all_sources, 'Unmapped source files'
    refs.update(str(p.relative_to(ROOT)) for p in (ROOT / 'Tests').rglob('*') if p.is_file())
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
    for path in refs:
        file(path)
    subprocess.run(['git', 'cat-file', '-e', data['baseline'] + '^{commit}'], cwd=ROOT, check=True)
    return data, refs


def html(data):
    payload = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c')
    return (OUT / 'template.html').read_text().replace('__MAP_DATA__', payload)


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ''
    if mode not in ('build', 'check'):
        raise SystemExit('Usage: python3 scripts/codemap.py build|check')
    data, refs = load()
    required = refs | {'docs/codemap/codemap.json', 'docs/codemap/codemap.html',
                       'docs/codemap/template.html', 'scripts/codemap.py'}
    if mode == 'build':
        (OUT / 'codemap.html').write_text(html(data))
        lock = {'schemaVersion': 2, 'baseline': data['baseline'], 'algorithm': 'sha256',
                'scope': 'Exact source/test evidence, inventory and generated map; not runtime acceptance.',
                'files': [{'path': p, 'sha256': digest(p)} for p in sorted(required)]}
        (OUT / 'codemap.lock').write_text(json.dumps(lock, indent=2) + '\n')
    lock = json.loads((OUT / 'codemap.lock').read_text())
    assert lock['baseline'] == data['baseline']
    assert lock['schemaVersion'] == 2
    paths = [entry['path'] for entry in lock['files']]
    assert len(paths) == len(set(paths)) and required == set(paths), 'Evidence lock manifest differs'
    for entry in lock['files']:
        assert digest(entry['path']) == entry['sha256'], 'Stale evidence: ' + entry['path']
    assert (OUT / 'codemap.html').read_text() == html(data), 'HTML differs from data/template'
    print(f"Verified {len(data['nodes'])} nodes, {len(data['edges'])} edges, {len(data['flows'])} flows and {len(lock['files'])} SHA-256 files; complete Sources inventory and test declarations resolve.")


if __name__ == '__main__':
    main()
