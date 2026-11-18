#!/usr/bin/env bash
# Audit the project lock and every tracked PEP 723 script lock.
set -euo pipefail

mkdir -p .artifacts/quality
arguments=(--lockfile tools/uv.lock)
while IFS= read -r -d '' path; do
  arguments+=(--lockfile "uv.lock:$path")
done < <(git ls-files -z 'scripts/*.py.lock' 'scripts/**/*.py.lock')
osv-scanner scan source "${arguments[@]}" --format json --output-file .artifacts/quality/python-osv.json
