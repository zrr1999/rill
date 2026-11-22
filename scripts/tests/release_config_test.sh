#!/usr/bin/env bash
# Assignments and command stubs are consumed by the sourced release script.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

set -euo pipefail

# These tests must not inherit release CI signing configuration.
unset NOTARY_KEYCHAIN

# Git exports repository-local variables to hooks. This suite creates and
# executes independent fixture repositories, so inherited paths such as
# GIT_INDEX_FILE must not redirect fixture operations into the caller's index.
unset \
  GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_CONFIG \
  GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT \
  GIT_OBJECT_DIRECTORY \
  GIT_DIR \
  GIT_WORK_TREE \
  GIT_IMPLICIT_WORK_TREE \
  GIT_GRAFT_FILE \
  GIT_INDEX_FILE \
  GIT_NO_REPLACE_OBJECTS \
  GIT_REPLACE_REF_BASE \
  GIT_PREFIX \
  GIT_SHALLOW_FILE \
  GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-release-config-tests.XXXXXX")"
PASSED=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

use_recorded_swap() {
  ditto() { cp -R "$1" "$2"; }
  fake_atomic_swap() {
    local left="$1"
    local right="$2"
    local temporary="$applications_dir/.test-swap.$$"

    printf '%s|%s\n' "$left" "$right" >>"$swap_log"
    mv "$left" "$temporary"
    mv "$right" "$left"
    mv "$temporary" "$right"
  }
  build_atomic_swap_helper() { ATOMIC_SWAP_HELPER="fake_atomic_swap"; }
}

run_install_quit_policy_case() {
  local fixture="$TEST_ROOT/install-quit-policy"
  local sleep_log="$fixture/sleep.log"
  local quit_log="$fixture/quit.log"
  local forced_termination_log="$fixture/forced-termination.log"
  local output=""
  local status=0
  local waited_seconds=""

  mkdir -p "$fixture"
  : >"$sleep_log"
  : >"$quit_log"
  : >"$forced_termination_log"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    refresh_running_rill_pids() {
      RUNNING_RILL_PIDS=(4242)
    }
    sleep() {
      printf '%s\n' "$1" >>"$sleep_log"
    }
    osascript() {
      printf '%s\n' "$*" >>"$quit_log"
    }
    kill() {
      printf 'kill %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    pkill() {
      printf 'pkill %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    killall() {
      printf 'killall %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    quit_running_rill_if_needed
  )"
  status=$?
  set -e

  waited_seconds="$(awk '{ total += $1 } END { printf "%.2f", total }' "$sleep_log")"
  if [[ "$status" -eq 0 ||
    "$output" != *"未强制终止进程"* ||
    "$(wc -l <"$quit_log" | xargs)" -ne 1 ||
    -s "$forced_termination_log" ]] \
    || ! awk -v waited="$waited_seconds" 'BEGIN { exit !(waited >= 20) }'; then
    echo "FAIL: installation requests a graceful quit and waits at least 20 seconds" >&2
    printf 'status=%s waited=%s\n%s\n' "$status" "$waited_seconds" "$output" >&2
    [[ ! -s "$forced_termination_log" ]] || cat "$forced_termination_log" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: installation requests a graceful quit, waits ${waited_seconds}s, and never force-kills"
}

run_orphaned_speech_worker_install_policy_case() {
  local fixture="$TEST_ROOT/orphaned-speech-worker-install-policy"
  local quit_log="$fixture/quit.log"
  local forced_termination_log="$fixture/forced-termination.log"
  local install_log="$fixture/install.log"
  local output=""
  local status=0

  mkdir -p "$fixture"
  : >"$quit_log"
  : >"$forced_termination_log"
  : >"$install_log"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    refresh_running_rill_pids() {
      # Simulate the main app exiting while its supervised speech worker is
      # orphaned. Installation must continue treating the bundle as in use.
      RUNNING_RILL_PIDS=(4343)
    }
    sleep() { :; }
    osascript() {
      printf '%s\n' "$*" >>"$quit_log"
    }
    kill() {
      printf 'kill %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    pkill() {
      printf 'pkill %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    killall() {
      printf 'killall %s\n' "$*" >>"$forced_termination_log"
      return 1
    }
    install_verified_app() {
      printf '%s\n' "$*" >>"$install_log"
    }
    quit_running_rill_if_needed
    install_verified_app candidate.app target.app
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ||
    "$output" != *"未强制终止进程"* ||
    "$(wc -l <"$quit_log" | xargs)" -ne 1 ||
    -s "$forced_termination_log" ||
    -s "$install_log" ]]; then
    echo "FAIL: orphaned speech worker must block installation without force termination" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: orphaned speech worker blocks installation without force-kill or bundle replacement"
}

run_install_staging_verification_failure_case() {
  local fixture="$TEST_ROOT/install-staging-verification-failure"
  local applications_dir="$fixture/Applications"
  local source_app="$fixture/source/Rill.app"
  local target_app="$applications_dir/Rill.app"
  local swap_log="$fixture/swap.log"
  local output=""
  local status=0

  mkdir -p "$source_app" "$target_app"
  printf '%s\n' new >"$source_app/version"
  printf '%s\n' old >"$target_app/version"
  : >"$swap_log"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_TEMP_DIR=""
    ditto() {
      cp -R "$1" "$2"
    }
    verify_install_candidate() {
      return 1
    }
    build_atomic_swap_helper() {
      printf '%s\n' unexpected >>"$swap_log"
      return 1
    }
    trap cleanup_release_temporary_files EXIT
    install_verified_app "$source_app" "$target_app"
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ||
    "$output" != *"安装 staging 中的 App 验证失败；旧版保持不变"* ||
    "$(<"$target_app/version")" != "old" ||
    -s "$swap_log" ]] \
    || find "$applications_dir" -maxdepth 1 -type d \
      -name '.rill-install.*' -print -quit | grep -q .; then
    echo "FAIL: staging verification failure preserves the installed app" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: staging verification failure preserves the installed app"
}

run_install_post_swap_rollback_case() {
  local fixture="$TEST_ROOT/install-post-swap-rollback"
  local applications_dir="$fixture/Applications"
  local source_app="$fixture/source/Rill.app"
  local target_app="$applications_dir/Rill.app"
  local swap_log="$fixture/swap.log"
  local output=""
  local status=0

  mkdir -p "$source_app" "$target_app"
  printf '%s\n' new >"$source_app/version"
  printf '%s\n' old >"$target_app/version"
  : >"$swap_log"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_TEMP_DIR=""
    verify_install_candidate() {
      [[ "$1" != "$target_app" ]]
    }
    use_recorded_swap
    trap cleanup_release_temporary_files EXIT
    install_verified_app "$source_app" "$target_app"
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ||
    "$output" != *"安装后验证失败；已原子恢复旧版 App"* ||
    "$(<"$target_app/version")" != "old" ||
    "$(wc -l <"$swap_log" | xargs)" -ne 2 ]] \
    || [[ "$(sed -n '1p' "$swap_log")" != "$(sed -n '2p' "$swap_log")" ]] \
    || find "$applications_dir" -maxdepth 1 -type d \
      -name '.rill-install.*' -print -quit | grep -q .; then
    echo "FAIL: post-swap verification failure atomically restores the old app" >&2
    printf '%s\n' "$output" >&2
    cat "$swap_log" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: post-swap verification failure uses the same atomic swap to restore the old app"
}

run_install_success_case() {
  local fixture="$TEST_ROOT/install-success"
  local applications_dir="$fixture/Applications"
  local source_app="$fixture/source/Rill.app"
  local target_app="$applications_dir/Rill.app"
  local swap_log="$fixture/swap.log"

  mkdir -p "$source_app" "$target_app"
  printf '%s\n' new >"$source_app/version"
  printf '%s\n' old >"$target_app/version"
  : >"$swap_log"

  (
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_TEMP_DIR=""
    verify_install_candidate() {
      return 0
    }
    use_recorded_swap
    install_verified_app "$source_app" "$target_app"
    [[ -z "$INSTALL_STAGING_ROOT" ]]
  )

  if [[ "$(<"$target_app/version")" != "new" ||
  "$(wc -l <"$swap_log" | xargs)" -ne 1 ]] \
    || find "$applications_dir" -maxdepth 1 -type d \
      -name '.rill-install.*' -print -quit | grep -q .; then
    echo "FAIL: a verified app replaces the old app and removes staging" >&2
    cat "$swap_log" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: a verified app replaces the old app and removes staging"
}

run_install_interruption_recovery_case() {
  local signal=""

  for signal in TERM INT; do
    local fixture="$TEST_ROOT/install-interruption-$signal"
    local applications_dir="$fixture/Applications"
    local source_app="$fixture/source/Rill.app"
    local target_app="$applications_dir/Rill.app"
    local swap_log="$fixture/swap.log"
    local verification_count="$fixture/verification-count"
    local output=""
    local status=0
    local target_version=""
    local recovery_version=""

    mkdir -p "$source_app" "$target_app"
    printf '%s\n' new >"$source_app/version"
    printf '%s\n' old >"$target_app/version"
    : >"$swap_log"
    printf '%s\n' 0 >"$verification_count"

    set +e
    output="$(
      exec 2>&1
      set --
      # shellcheck source=/dev/null
      source "$RELEASE_SCRIPT"
      RELEASE_TEMP_DIR=""
      ditto() {
        cp -R "$1" "$2"
      }
      verify_install_candidate() {
        local count=""

        count="$(($(<"$verification_count") + 1))"
        printf '%s\n' "$count" >"$verification_count"
        if [[ "$count" -eq 2 ]]; then
          /bin/sh -c 'kill -s "$1" "$PPID"' rill-install-test "$signal"
        fi
        return 0
      }
      use_recorded_swap
      trap cleanup_release_temporary_files EXIT
      trap 'handle_release_interrupt INT' INT
      trap 'handle_release_interrupt TERM' TERM
      install_verified_app "$source_app" "$target_app"
    )"
    status=$?
    set -e

    if [[ -f "$target_app/version" ]]; then
      target_version="$(<"$target_app/version")"
    fi
    recovery_version="$(
      find "$applications_dir" -path \
        '*/.rill-install.*/Rill.app/version' -type f -exec cat {} \; \
        -quit
    )"
    if [[ "$status" -eq 0 ||
      "$(<"$verification_count")" -ne 2 ||
      "$(wc -l <"$swap_log" | xargs)" -lt 1 ]] \
      || [[ "$target_version" != "old" && "$recovery_version" != "old" ]]; then
      echo "FAIL: $signal after swap restores or preserves the old app" >&2
      printf 'status=%s target=%s recovery=%s\n%s\n' \
        "$status" "$target_version" "$recovery_version" "$output" >&2
      cat "$swap_log" >&2
      exit 1
    fi
  done

  PASSED=$((PASSED + 1))
  echo "PASS: TERM and INT after swap restore or preserve the old app for recovery"
}

run_process_enumeration_failure_case() {
  local fixture="$TEST_ROOT/process-enumeration-failure"
  local ps_log="$fixture/ps.log"
  local quit_log="$fixture/quit.log"
  local detected_pids=""
  local output=""
  local status=0

  mkdir -p "$fixture"
  : >"$ps_log"
  : >"$quit_log"

  detected_pids="$(
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    ps() {
      [[ "$*" == "axww -o pid= -o comm=" ]] || return 64
      cat <<'PROCESS_LISTING'
  313 /Applications/Voice Tools/Rill.app/Contents/MacOS/Rill Helper
  4242 /Applications/Voice Tools/Rill.app/Contents/MacOS/Rill
  4343 /Applications/Voice Tools/Rill.app/Contents/Helpers/RillSpeechWorker
  5151 /Applications/Voice Tools/Other.app/Contents/MacOS/Other
PROCESS_LISTING
    }
    running_rill_pids
  )"
  if [[ "$detected_pids" != $'4242\n4343' ]]; then
    echo "FAIL: process detection must include the app and nested speech worker while preserving spaces" >&2
    printf 'detected=%s\n' "$detected_pids" >&2
    exit 1
  fi

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    ps() {
      printf '%s\n' "$*" >>"$ps_log"
      return 42
    }
    osascript() {
      printf '%s\n' "$*" >>"$quit_log"
    }
    quit_running_rill_if_needed
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 || ! -s "$ps_log" || -s "$quit_log" ]]; then
    echo "FAIL: process enumeration failure must abort installation closed" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: process detection includes the nested speech worker, handles spaces, and fails closed"
}

run_first_install_concurrent_target_case() {
  local fixture="$TEST_ROOT/first-install-concurrent-target"
  local applications_dir="$fixture/Applications"
  local source_app="$fixture/source/Rill.app"
  local target_app="$applications_dir/Rill.app"
  local publish_log="$fixture/publish.log"
  local output=""
  local status=0

  mkdir -p "$source_app" "$applications_dir"
  printf '%s\n' new >"$source_app/version"
  : >"$publish_log"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_TEMP_DIR=""
    ditto() {
      cp -R "$1" "$2"
    }
    verify_install_candidate() {
      if [[ "$1" != "$target_app" && ! -e "$target_app" ]]; then
        mkdir -p "$target_app"
        printf '%s\n' concurrent >"$target_app/version"
      fi
      return 0
    }
    fake_atomic_publish() {
      local candidate="$1"
      local target="$2"

      printf '%s\n' "$*" >>"$publish_log"
      [[ "$target" == "$target_app" ]] || return 64
      [[ ! -e "$target" ]] || return 1
      mv "$candidate" "$target"
    }
    use_fake_atomic_publish_helper() {
      ATOMIC_SWAP_HELPER="fake_atomic_publish"
      ATOMIC_INSTALL_HELPER="fake_atomic_publish"
      ATOMIC_RENAME_HELPER="fake_atomic_publish"
    }
    build_atomic_swap_helper() {
      use_fake_atomic_publish_helper
    }
    build_atomic_install_helper() {
      use_fake_atomic_publish_helper
    }
    build_atomic_rename_helper() {
      use_fake_atomic_publish_helper
    }
    trap cleanup_release_temporary_files EXIT
    install_verified_app "$source_app" "$target_app"
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ||
    ! -s "$publish_log" ||
    ! -f "$target_app/version" ||
    "$(<"$target_app/version")" != "concurrent" ||
    -e "$target_app/Rill.app" ]]; then
    echo "FAIL: first install must preserve a concurrent target" >&2
    printf '%s\n' "$output" >&2
    cat "$publish_log" >&2
    find "$applications_dir" -maxdepth 3 -print >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: first install preserves a concurrent target without nesting or deletion"
}

run_existing_install_concurrent_identity_case() {
  local fixture="$TEST_ROOT/existing-install-concurrent-identity"
  local applications_dir="$fixture/Applications"
  local source_app="$fixture/source/Rill.app"
  local target_app="$applications_dir/Rill.app"
  local swap_log="$fixture/swap.log"
  local swap_count="$fixture/swap-count"
  local output=""
  local status=0

  mkdir -p "$source_app" "$target_app"
  printf '%s\n' new >"$source_app/version"
  printf '%s\n' old >"$target_app/version"
  : >"$swap_log"
  printf '%s\n' 0 >"$swap_count"

  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_TEMP_DIR=""
    ditto() {
      cp -R "$1" "$2"
    }
    verify_install_candidate() {
      return 0
    }
    fake_atomic_swap() {
      local left="$1"
      local right="$2"
      local temporary="$applications_dir/.test-swap.$$"
      local count=""

      count="$(($(<"$swap_count") + 1))"
      printf '%s\n' "$count" >"$swap_count"
      printf '%s|%s\n' "$left" "$right" >>"$swap_log"
      if [[ "$count" -eq 1 ]]; then
        rm -rf "$right"
        mkdir -p "$right"
        printf '%s\n' concurrent >"$right/version"
      fi
      mv "$left" "$temporary"
      mv "$right" "$left"
      mv "$temporary" "$right"
    }
    build_atomic_swap_helper() {
      ATOMIC_SWAP_HELPER="fake_atomic_swap"
    }
    trap cleanup_release_temporary_files EXIT
    install_verified_app "$source_app" "$target_app"
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 ||
    "$output" != *"安装目标在原子替换期间发生并发变化；已恢复原坐标"* ||
    "$(wc -l <"$swap_log" | xargs)" -ne 2 ||
    "$(sed -n '1p' "$swap_log")" != "$(sed -n '2p' "$swap_log")" ||
    ! -f "$target_app/version" ||
    "$(<"$target_app/version")" != "concurrent" ||
    -e "$target_app/Rill.app" ]] \
    || find "$applications_dir" -maxdepth 1 -type d \
      -name '.rill-install.*' -print -quit | grep -q . \
    || find "$applications_dir" -type f -name version \
      -exec grep -l '^new$' {} \; -quit | grep -q .; then
    echo "FAIL: an existing-target identity race restores the concurrent target" >&2
    printf '%s\n' "$output" >&2
    cat "$swap_log" >&2
    find "$applications_dir" -maxdepth 3 -print >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: an existing-target identity race restores the concurrent target and cleans our candidate"
}

create_release_source_fixture() {
  local repository="$1"

  mkdir -p "$repository/scripts"
  printf '%s\n' '{"schemaVersion":2,"packages":[]}' \
    >"$repository/scripts/third_party_notices_manifest.json"
  printf '%s\n' '.build/' >"$repository/.gitignore"
  cp "$RELEASE_SCRIPT" "$repository/scripts/release.sh"
  chmod +x "$repository/scripts/release.sh"
  cat >"$repository/scripts/preflight.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${SNAPSHOT_PROBE:?SNAPSHOT_PROBE is required}"
if [[ -n "${RILL_RELEASE_SOURCE_CAPABILITY-}" ]]; then
  echo "release source capability leaked into snapshot preflight" >&2
  exit 74
fi
snapshot_project="$(cd "$(dirname "$0")/.." && pwd -P)"
printf '%s\n%s\n' \
  "$snapshot_project" \
  "$(git -C "$snapshot_project" rev-parse HEAD)" >"$SNAPSHOT_PROBE"
exit 73
SH
  chmod +x "$repository/scripts/preflight.sh"
  git -C "$repository" init -q
  git -C "$repository" add \
    .gitignore \
    scripts/preflight.sh \
    scripts/release.sh \
    scripts/third_party_notices_manifest.json
  git -C "$repository" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgsign=false \
    -c user.name="Rill Test" \
    -c user.email="rill-test@example.invalid" \
    commit -q -m "release source fixture"
  git -C "$repository" tag v1.2.3
}

run_release_source_revalidation_case() {
  local repository="$TEST_ROOT/source-revalidation-repository"
  local output=""
  local status=0

  create_release_source_fixture "$repository"
  set +e
  output="$(
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    PROJECT_DIR="$repository"
    DO_NOTARIZE=true
    unset RILL_RELEASE_SOURCE_SNAPSHOT RILL_RELEASE_SOURCE_COMMIT
    validate_notarized_release_source
    printf '%s\n' '{"schemaVersion":2,"packages":[{"identity":"drift"}]}' \
      >"$repository/scripts/third_party_notices_manifest.json"
    revalidate_notarized_release_source "测试复核前"
  )"
  status=$?
  set -e

  if [[ "$status" -eq 0 || "$output" != *"公证发布要求干净的 Git 工作树"* ]]; then
    echo "FAIL: source revalidation rejects drift after initial validation" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: source revalidation rejects drift after initial validation"
}

run_install_quit_policy_case
run_orphaned_speech_worker_install_policy_case
run_install_staging_verification_failure_case
run_install_post_swap_rollback_case
run_install_success_case
run_install_interruption_recovery_case
run_process_enumeration_failure_case
run_first_install_concurrent_target_case
run_existing_install_concurrent_identity_case
run_release_source_revalidation_case

echo "All $PASSED release safety tests passed."
