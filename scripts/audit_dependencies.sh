#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

uv run --no-build --locked --script scripts/check_dependency_security.py --live-osv

scanner="$RUNNER_TEMP/osv-scanner"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/google/osv-scanner/releases/download/v2.7.0/osv-scanner_linux_amd64 \
  --output "$scanner"
printf '%s  %s\n' '160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b' "$scanner" | sha256sum --check
chmod +x "$scanner"

arguments=(--lockfile tools/uv.lock)
while IFS= read -r -d '' path; do
  arguments+=(--lockfile "uv.lock:$path")
done < <(git ls-files -z 'scripts/*.py.lock' 'scripts/**/*.py.lock')
"$scanner" scan source "${arguments[@]}" --format json --output-file python-osv.json
