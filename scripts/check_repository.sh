#!/usr/bin/env bash
# Validate Git-visible workflow files or scan the repository for secrets.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

error() {
  echo "✗ $*" >&2
  return 1
}

check_workflows() (
  cd "$PROJECT_DIR" || return
  local file_list path
  local -a files=()
  file_list="$(mktemp "${TMPDIR:-/tmp}/rill-workflows.XXXXXX")" || return
  trap 'rm -f -- "$file_list"' EXIT
  if ! git ls-files --cached --others --exclude-standard -z >"$file_list"; then
    error "Cannot enumerate Git-visible workflow files"
    return
  fi
  while IFS= read -r -d '' path; do
    case "$path" in
    .github/workflows/*.yml | .github/workflows/*.yaml | .github/workflows/actions.lock | .github/dependabot.yml | .github/dependabot.yaml | action.yml | action.yaml | */action.yml | */action.yaml)
      [[ -e "$path" || -L "$path" ]] && files+=("$path")
      ;;
    esac
  done <"$file_list"
  if [[ ${#files[@]} -eq 0 ]]; then
    error "No repository workflows or actions found"
    return
  fi
  jactionlint --shellcheck=shellcheck --ruff=ruff "$@" "${files[@]}"
)

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
    if [[ -L "$source_file" || ! -f "$source_file" ||
      -L "$snapshot_file" || ! -f "$snapshot_file" ]]; then
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
    --log-opts="--all HEAD" \
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

reject_record_matches() {
  local message="$1" status
  shift
  if git grep -n -E "$@"; then
    error "$message"
    return
  else
    status=$?
  fi
  if [[ "$status" -ne 1 ]]; then
    error "Unable to check the Record domain boundary with git grep"
  fi
}

check_record_domain_boundary() (
  cd "$PROJECT_DIR" || return
  local legacy_domain_pattern='(^|[^A-Za-z0-9_])(DeliveryStack|ClipboardHistoryItem|ClipboardGroup|ClipboardPasteMode|ClipboardItemDryRun)([^A-Za-z0-9_]|$)'
  local declaration_pattern='^[[:space:]]*(public |internal |private |fileprivate )?(final )?(struct|class|enum|protocol|actor|typealias) Clipboard[A-Z]'
  local resource_pattern='id[[:space:]]*=[[:space:]]*"(stack\.push|clipboard\.copy)"|strategy[[:space:]]*=[[:space:]]*"(stack-first|clipboard-only)"'
  local legacy_sources

  reject_record_matches "Legacy Stack/Clipboard domain types escaped LegacyClipboardMigration" \
    -e "$legacy_domain_pattern" -- Sources ':!**/LegacyClipboardMigration.swift' || return

  reject_record_matches "Clipboard-prefixed domain declarations must be SystemClipboard-prefixed or migration-only" \
    -e "$declaration_pattern" -- Sources ':!**/LegacyClipboardMigration.swift' || return

  legacy_sources="$(
    find Sources -type f \
      \( -name 'DeliveryStack*.swift' -o -name 'Clipboard*.swift' -o -name 'StackPasteController.swift' \) \
      ! -name 'LegacyClipboardMigration.swift' \
      -print
  )" || return
  if [[ -n "$legacy_sources" ]]; then
    printf '%s\n' "$legacy_sources" >&2
    error "Legacy Stack/Clipboard source files remain outside the migration boundary"
    return
  fi

  reject_record_matches "Built-in workflow resources must emit canonical Record action IDs and strategies" \
    -e "$resource_pattern" -- Sources/RillPlatform/Resources/BuiltinWorkflows || return
  echo "Record domain boundary check passed"
)

main() {
  case "${1:-}" in
  workflows)
    shift
    check_workflows "$@"
    ;;
  secrets | record-boundary)
    if [[ $# -ne 1 ]]; then
      error "The $1 check does not take additional arguments"
      return
    fi
    if [[ "$1" == secrets ]]; then
      run_secret_scan "$PROJECT_DIR" "$PROJECT_DIR/.gitleaks.toml" gitleaks
    else
      check_record_domain_boundary
    fi
    ;;
  *)
    echo "Usage: $0 {workflows [jactionlint arguments] | secrets | record-boundary}" >&2
    return 2
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
