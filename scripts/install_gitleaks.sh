#!/usr/bin/env bash
# Install the repository-pinned Gitleaks binary after verifying its release hash.
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
RELEASE_BASE_URL="https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION"
DESTINATION=""

error() {
  echo "✗ $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 --destination DIR

Downloads and verifies Gitleaks $GITLEAKS_VERSION for macOS or Linux x64.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --destination)
    [[ "$#" -ge 2 ]] || error "Missing value for --destination"
    DESTINATION="$2"
    shift 2
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    error "Unknown argument: $1"
    ;;
  esac
done

[[ -n "$DESTINATION" ]] || error "--destination is required"
ASSET_NAME=""
EXPECTED_SHA256=""
case "$(uname -s)/$(uname -m)" in
Darwin/arm64)
  ASSET_NAME="gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz"
  EXPECTED_SHA256="b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"
  ;;
Darwin/x86_64)
  ASSET_NAME="gitleaks_${GITLEAKS_VERSION}_darwin_x64.tar.gz"
  EXPECTED_SHA256="dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"
  ;;
Linux/x86_64)
  ASSET_NAME="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  EXPECTED_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
  ;;
*)
  error "Unsupported platform: $(uname -s)/$(uname -m)"
  ;;
esac

for command_name in curl install mktemp shasum tar; do
  command -v "$command_name" >/dev/null 2>&1 \
    || error "Required command not found: $command_name"
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-gitleaks-install.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

ARCHIVE_PATH="$TEMP_ROOT/$ASSET_NAME"
EXTRACT_DIR="$TEMP_ROOT/extracted"
mkdir -p "$EXTRACT_DIR" "$DESTINATION"

curl \
  --fail \
  --location \
  --proto '=https' \
  --retry 3 \
  --show-error \
  --silent \
  --tlsv1.2 \
  --output "$ARCHIVE_PATH" \
  "$RELEASE_BASE_URL/$ASSET_NAME"

printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE_PATH" | shasum -a 256 -c -
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
[[ -f "$EXTRACT_DIR/gitleaks" ]] || error "Verified archive does not contain gitleaks"
install -m 0755 "$EXTRACT_DIR/gitleaks" "$DESTINATION/gitleaks"

INSTALLED_VERSION="$("$DESTINATION/gitleaks" version | tail -n 1 | awk '{print $NF}' | sed 's/^v//')"
[[ "$INSTALLED_VERSION" == "$GITLEAKS_VERSION" ]] \
  || error "Installed Gitleaks version mismatch: ${INSTALLED_VERSION:-unknown}"

echo "Installed Gitleaks $GITLEAKS_VERSION at $DESTINATION/gitleaks"
