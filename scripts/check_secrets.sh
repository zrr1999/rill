#!/usr/bin/env bash
# Scan committed history and the current tracked/untracked source snapshot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GITLEAKS_REQUIRED_VERSION="8.30.1"
GITLEAKS_CONFIG="$PROJECT_DIR/.gitleaks.toml"

error() {
  echo "✗ $*" >&2
  return 1
}

resolve_gitleaks_binary() {
  local candidate=""
  candidate="$(command -v gitleaks 2>/dev/null || true)"
  if [[ -z "$candidate" ]]; then
    error "Gitleaks $GITLEAKS_REQUIRED_VERSION is required. Install it with: scripts/preflight.sh install-gitleaks --destination DIR"
    return
  fi
  printf '%s\n' "$candidate"
}

verify_gitleaks_binary() {
  local binary="$1"
  local output=""
  local version=""

  if ! output="$("$binary" version 2>&1)"; then
    error "Cannot execute Gitleaks: $binary"
    return
  fi
  version="$(printf '%s\n' "$output" | tail -n 1 | awk '{print $NF}' | sed 's/^v//')"
  if [[ "$version" != "$GITLEAKS_REQUIRED_VERSION" ]]; then
    error "Gitleaks $GITLEAKS_REQUIRED_VERSION is required (found ${version:-unknown} at $binary). Install it with: scripts/preflight.sh install-gitleaks --destination DIR"
    return
  fi
}

copy_current_source_snapshot() {
  local project_dir="$1"
  local snapshot_dir="$2"
  local requested_file_list="${3-}"
  local relative_file=""
  local source_file=""
  local destination_file=""
  local file_list="${requested_file_list:-$snapshot_dir/.rill-source-files.zlist}"
  local copy_status=0

  if ! git -C "$project_dir" ls-files -z --cached --others --exclude-standard >"$file_list"; then
    rm -f "$file_list"
    error "Cannot enumerate the current tracked and untracked source snapshot"
    return
  fi
  while IFS= read -r -d '' relative_file; do
    source_file="$project_dir/$relative_file"
    # A tracked deletion is part of the current snapshot and must stay absent.
    if [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
      continue
    fi
    if [[ -L "$source_file" || ! -f "$source_file" ]]; then
      copy_status=1
      break
    fi
    destination_file="$snapshot_dir/$relative_file"
    mkdir -p "$(dirname "$destination_file")" || {
      copy_status=$?
      break
    }
    cp -p "$source_file" "$destination_file" || {
      copy_status=$?
      break
    }
    if [[ -L "$destination_file" || ! -f "$destination_file" ]]; then
      copy_status=1
      break
    fi
  done <"$file_list"
  if [[ -z "$requested_file_list" ]]; then
    rm -f "$file_list"
  fi
  if [[ "$copy_status" -ne 0 ]]; then
    error "Cannot copy the current source snapshot"
    return
  fi
}

verify_current_source_snapshot() {
  local project_dir="$1"
  local snapshot_dir="$2"
  local original_file_list="$3"
  local current_file_list=""
  local relative_file=""
  local source_file=""
  local snapshot_file=""

  [[ -f "$original_file_list" && ! -L "$original_file_list" ]] || {
    error "Cannot verify the current source snapshot manifest"
    return
  }
  current_file_list="$(mktemp "${TMPDIR:-/tmp}/rill-source-files.XXXXXX")"
  if ! git -C "$project_dir" ls-files -z --cached --others --exclude-standard \
    >"$current_file_list"; then
    rm -f "$current_file_list"
    error "Cannot re-enumerate the current source snapshot"
    return
  fi
  if ! cmp -s "$original_file_list" "$current_file_list"; then
    rm -f "$current_file_list"
    error "Current source file set changed during secret scanning; retry the scan"
    return
  fi
  rm -f "$current_file_list"

  while IFS= read -r -d '' relative_file; do
    source_file="$project_dir/$relative_file"
    snapshot_file="$snapshot_dir/$relative_file"
    if [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
      if [[ -e "$snapshot_file" || -L "$snapshot_file" ]]; then
        error "Current source deletion changed during secret scanning; retry the scan"
        return
      fi
      continue
    fi
    if [[ -L "$source_file" || ! -f "$source_file" \
      || -L "$snapshot_file" || ! -f "$snapshot_file" ]]; then
      error "Current source content changed during secret scanning; retry the scan"
      return
    fi
    if ! cmp -s "$source_file" "$snapshot_file"; then
      error "Current source content changed during secret scanning; retry the scan"
      return
    fi
  done <"$original_file_list"
}

run_secret_scan() {
  local project_dir="$1"
  local config_path="$2"
  local binary="$3"
  local snapshot_root=""
  local snapshot_manifest=""
  local history_status=0
  local snapshot_status=0

  if [[ ! -f "$config_path" ]]; then
    error "Gitleaks policy is missing: $config_path"
    return
  fi
  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null; then
    error "Secret scanning requires a Git worktree: $project_dir"
    return
  fi
  if [[ "$(git -C "$project_dir" rev-parse --is-shallow-repository)" != "false" ]]; then
    error "Secret scanning requires complete Git history. Fetch the full history before retrying."
    return
  fi

  "$binary" git \
    --config "$config_path" \
    --redact \
    --no-banner \
    --no-color \
    --timeout 120 \
    "$project_dir" || history_status=$?
  [[ "$history_status" -eq 0 ]] || return "$history_status"

  snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/rill-secret-scan.XXXXXX")"
  (
    trap 'rm -rf "$snapshot_root"' EXIT INT TERM
    snapshot_dir="$snapshot_root/source"
    snapshot_manifest="$snapshot_root/source-files.zlist"
    mkdir -p "$snapshot_dir" || exit $?
    copy_current_source_snapshot \
      "$project_dir" \
      "$snapshot_dir" \
      "$snapshot_manifest" || exit $?
    "$binary" dir \
      --config "$config_path" \
      --redact \
      --no-banner \
      --no-color \
      --timeout 120 \
      "$snapshot_dir" || exit $?
    verify_current_source_snapshot \
      "$project_dir" \
      "$snapshot_dir" \
      "$snapshot_manifest"
  ) || snapshot_status=$?
  return "$snapshot_status"
}

main() {
  local binary=""
  binary="$(resolve_gitleaks_binary)" || return $?
  verify_gitleaks_binary "$binary" || return $?
  run_secret_scan "$PROJECT_DIR" "$GITLEAKS_CONFIG" "$binary" || return $?
  echo "Secret scan passed with Gitleaks $GITLEAKS_REQUIRED_VERSION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
