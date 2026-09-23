#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"

echo 'Testing dependency security policy...'
uv run --script "$TEST_DIR/dependency_security_test.py"
echo 'Testing diagnostic export...'
uv run --script "$TEST_DIR/diagnostic_export_test.py"
echo 'Testing secret scanning...'
bash "$TEST_DIR/secret_scan_test.sh"
echo 'Testing build ownership and receipts...'
uv run --no-build --locked --script "$TEST_DIR/build_driver_test.py"
echo 'Testing worker artifact caching...'
uv run --no-build --locked --script "$TEST_DIR/worker_cache_test.py"
echo 'Testing release configuration...'
bash "$TEST_DIR/release_config_test.sh"
echo 'Testing app icon generation...'
bash "$TEST_DIR/app_icon_test.sh"
