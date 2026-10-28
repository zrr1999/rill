#!/usr/bin/env bash
# Fail closed: only scope-selected skips are valid, and scope selection and tool tests must succeed.
set -euo pipefail

[[ "${SCOPE_RESULT:-}" == success ]] || {
  echo "Change scope selection must succeed (got ${SCOPE_RESULT:-missing})." >&2
  exit 1
}

[[ "${TOOLS_RESULT:-}" == success ]] || {
  echo "Development tool tests must succeed (got ${TOOLS_RESULT:-missing})." >&2
  exit 1
}

check_selected_job() {
  local name="$1" scope="$2" result="$3"
  case "$scope:$result" in
  true:success | false:skipped) return 0 ;;
  *)
    echo "$name has invalid scope/result: ${scope:-missing}/${result:-missing}." >&2
    return 1
    ;;
  esac
}

check_selected_job 'Both preflight lanes' "${APP_SCOPE:-}" "${PREFLIGHT_RESULT:-}"
check_selected_job 'Record workload validation' "${WORKLOAD_SCOPE:-}" "${WORKLOAD_RESULT:-}"
echo 'All selected verification jobs succeeded.'
