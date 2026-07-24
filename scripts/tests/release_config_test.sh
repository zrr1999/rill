#!/usr/bin/env bash

set -euo pipefail

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
CI_WORKFLOW="$PROJECT_DIR/.github/workflows/ci.yml"
RELEASE_SCRIPT="$PROJECT_DIR/scripts/release.sh"
ASSEMBLER_SCRIPT="$PROJECT_DIR/scripts/assemble_app_bundle.sh"
PREFLIGHT_SCRIPT="$PROJECT_DIR/scripts/preflight.sh"
SHELL_SYNTAX_SCRIPT="$PROJECT_DIR/scripts/check_shell_syntax.sh"
RELEASE_ARTIFACT_HYGIENE_SCRIPT="$PROJECT_DIR/scripts/check_release_artifact_hygiene.sh"
EXECUTABLE_VERIFIER="$PROJECT_DIR/scripts/verify_release_executable.sh"
LOCKED_SWIFT_SCRIPT="$PROJECT_DIR/scripts/swift_locked.sh"
XCODE_RELEASE_BUILD_SCRIPT="$PROJECT_DIR/scripts/build_xcode_release.sh"
PACKAGE_MANIFEST="$PROJECT_DIR/Package.swift"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-release-config-tests.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
PASSED=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != "find-identity -v -p codesigning" ]]; then
  echo "unexpected security invocation: $*" >&2
  exit 64
fi
printf '%s\n' "${FAKE_IDENTITIES:-     0 valid identities found}"
SH
chmod +x "$FAKE_BIN/security"

cat >"$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
*"rev-parse --is-inside-work-tree")
  printf '%s\n' true
  ;;
*"rev-parse HEAD^{commit}")
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567
  ;;
*"rev-parse HEAD^{tree}")
  printf '%s\n' 123456789abcdef0123456789abcdef012345678
  ;;
*"rev-parse HEAD:scripts/third_party_notices_manifest.json")
  printf '%s\n' 23456789abcdef0123456789abcdef0123456789
  ;;
*"hash-object scripts/third_party_notices_manifest.json")
  printf '%s\n' 23456789abcdef0123456789abcdef0123456789
  ;;
*"rev-list --count "*)
  printf '%s\n' 42
  ;;
*"ls-files --error-unmatch scripts/third_party_notices_manifest.json")
  if [[ "${FAKE_DEPENDENCY_MANIFEST_TRACKED-true}" == "true" ]]; then
    printf '%s\n' scripts/third_party_notices_manifest.json
  else
    exit 1
  fi
  ;;
*"ls-files -v")
  printf '%s' "${FAKE_GIT_INDEX-H scripts/third_party_notices_manifest.json}"
  ;;
*"status --porcelain=v1 --untracked-files=normal")
  printf '%s' "${FAKE_GIT_STATUS-}"
  ;;
*"tag --points-at HEAD")
  printf '%s' "${FAKE_GIT_TAGS-v1.2.3}"
  ;;
*)
  echo "unexpected git invocation: $*" >&2
  exit 64
  ;;
esac
SH
chmod +x "$FAKE_BIN/git"

cat >"$FAKE_BIN/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_SWIFT_LOG:?FAKE_SWIFT_LOG is required}"
{
  printf '%s\n' CALL
  printf '%s\n' "$@"
} >>"$FAKE_SWIFT_LOG"
SH
chmod +x "$FAKE_BIN/swift"

APPLE_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example Developer (TEAMLOCAL1)"
     1 valid identities found'
DEVELOPER_ID_IDENTITIES='  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Company (TEAMDIST01)"
     1 valid identities found'
BOTH_IDENTITIES='  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example Developer (TEAMLOCAL1)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Company (TEAMDIST01)"
     2 valid identities found'
AMBIGUOUS_DEVELOPER_IDS='  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Example Company (TEAMDIST01)"
  2) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Other Company (TEAMDIST02)"
     2 valid identities found'

run_case() {
  local name="$1"
  local expected_status="$2"
  local expected_fragment="$3"
  local identities="$4"
  local requested_identity="$5"
  local requested_profile="$6"
  shift 6

  local output=""
  local status=0
  local command=(
    env -u SIGN_IDENTITY -u NOTARY_PROFILE -u RELEASE_OUTPUT_DIR
    "PATH=$FAKE_BIN:$PATH"
    "FAKE_IDENTITIES=$identities"
  )
  if [[ "$requested_identity" != "<unset>" ]]; then
    command+=("SIGN_IDENTITY=$requested_identity")
  fi
  if [[ "$requested_profile" != "<unset>" ]]; then
    command+=("NOTARY_PROFILE=$requested_profile")
  fi
  command+=(bash "$RELEASE_SCRIPT" "$@" --validate-config)

  set +e
  output="$("${command[@]}" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: $name (expected status $expected_status, got $status)" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_fragment"* ]]; then
    echo "FAIL: $name (missing: $expected_fragment)" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" == *"运行发布预检"* ]]; then
    echo "FAIL: $name (--validate-config unexpectedly started a build)" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: $name"
}

run_invalid_output_dir_case() {
  local name="$1"
  local output_dir="$2"
  local expected_fragment="$3"
  local output=""
  local status=0

  set +e
  output="$(env \
    -u SIGN_IDENTITY \
    -u NOTARY_PROFILE \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_IDENTITIES=$APPLE_IDENTITIES" \
    "RELEASE_OUTPUT_DIR=$output_dir" \
    bash "$RELEASE_SCRIPT" --validate-config 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 || "$output" != *"$expected_fragment"* ]]; then
    echo "FAIL: $name" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" == *"运行发布预检"* ]]; then
    echo "FAIL: $name (--validate-config unexpectedly started a build)" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: $name"
}

run_reserved_internal_environment_case() {
  local output=""
  local status=0

  set +e
  output="$(env \
    -u SIGN_IDENTITY \
    -u NOTARY_PROFILE \
    -u RELEASE_OUTPUT_DIR \
    -u RILL_RELEASE_SOURCE_CAPABILITY \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_IDENTITIES=$APPLE_IDENTITIES" \
    "RILL_RELEASE_SOURCE_SNAPSHOT=1" \
    "RILL_RELEASE_SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567" \
    bash "$RELEASE_SCRIPT" --validate-config 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 || "$output" != *"保留的内部变量"* ]]; then
    echo "FAIL: caller-provided legacy snapshot environment is rejected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: caller-provided legacy snapshot environment is rejected"
}

run_notarized_source_case() {
  local name="$1"
  local expected_fragment="$2"
  local git_status="$3"
  local git_tags="$4"
  local dependency_manifest_tracked="$5"
  local git_index="${6-H scripts/third_party_notices_manifest.json}"
  local output=""
  local status=0

  set +e
  output="$(env \
    -u SIGN_IDENTITY \
    -u NOTARY_PROFILE \
    -u RELEASE_OUTPUT_DIR \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_IDENTITIES=$DEVELOPER_ID_IDENTITIES" \
    "FAKE_GIT_STATUS=$git_status" \
    "FAKE_GIT_TAGS=$git_tags" \
    "FAKE_DEPENDENCY_MANIFEST_TRACKED=$dependency_manifest_tracked" \
    "FAKE_GIT_INDEX=$git_index" \
    bash "$RELEASE_SCRIPT" --notarize --validate-config 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 || "$output" != *"$expected_fragment"* ]]; then
    echo "FAIL: $name" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" == *"运行发布预检"* ]]; then
    echo "FAIL: $name (--validate-config unexpectedly started a build)" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: $name"
}

run_locked_dependency_policy_case() {
  local invocation_log="$TEST_ROOT/swift-invocations.log"
  local expected_log=""

  : >"$invocation_log"
  [[ -x "$LOCKED_SWIFT_SCRIPT" ]] || {
    echo "FAIL: locked SwiftPM wrapper is not executable" >&2
    exit 1
  }
  PATH="$FAKE_BIN:$PATH" FAKE_SWIFT_LOG="$invocation_log" \
    "$LOCKED_SWIFT_SCRIPT" build --show-bin-path
  PATH="$FAKE_BIN:$PATH" FAKE_SWIFT_LOG="$invocation_log" \
    "$LOCKED_SWIFT_SCRIPT" test --parallel
  expected_log=$'CALL\nbuild\n--force-resolved-versions\n-Xswiftc\n-warnings-as-errors\n--show-bin-path\nCALL\ntest\n--force-resolved-versions\n-Xswiftc\n-warnings-as-errors\n--parallel'
  if [[ "$(<"$invocation_log")" != "$expected_log" ]]; then
    echo "FAIL: locked SwiftPM wrapper injects dependency and warning policies" >&2
    cat "$invocation_log" >&2
    exit 1
  fi
  if grep -Eq '(^|[[:space:]])swift[[:space:]]+(build|test)([[:space:]]|$)' \
    "$PREFLIGHT_SCRIPT" "$RELEASE_SCRIPT"; then
    echo "FAIL: release scripts contain an unlocked SwiftPM build or test path" >&2
    exit 1
  fi
  if ! grep -Fq 'build_xcode_release.sh"' "$PREFLIGHT_SCRIPT" \
    || ! grep -Fq 'swift_locked.sh" test' "$PREFLIGHT_SCRIPT" \
    || ! grep -Fq 'build_xcode_release.sh" --show-bin-path' "$RELEASE_SCRIPT" \
    || ! grep -Fq 'exec "$SCRIPT_DIR/swift_locked.sh"' "$XCODE_RELEASE_BUILD_SCRIPT"; then
    echo "FAIL: release scripts do not route every build and test through the locked wrapper" >&2
    exit 1
  fi
  if grep -Fq 'Package.resolved is required' \
    "$PREFLIGHT_SCRIPT" "$XCODE_RELEASE_BUILD_SCRIPT"; then
    echo "FAIL: zero-remote-dependency build requires a synthetic lockfile" >&2
    exit 1
  fi
  if ! grep -Fq '"$THIRD_PARTY_NOTICES_GENERATOR" --check' \
    "$ASSEMBLER_SCRIPT"; then
    echo "FAIL: bundle assembly does not verify vendored dependency provenance" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: release build paths share dependency and warning policies and verify vendored provenance"
}

run_vendored_xcode_build_policy_case() {
  [[ -x "$XCODE_RELEASE_BUILD_SCRIPT" ]] || {
    echo "FAIL: Xcode release build wrapper is not executable" >&2
    exit 1
  }
  if ! grep -Fq -- '--manifest-cache none' "$XCODE_RELEASE_BUILD_SCRIPT" \
    || ! grep -Fq -- '--arch arm64' "$XCODE_RELEASE_BUILD_SCRIPT" \
    || ! grep -Fq 'exec "$SCRIPT_DIR/swift_locked.sh"' "$XCODE_RELEASE_BUILD_SCRIPT" \
    || ! grep -Fq 'xcrun metal -v' \
      "$XCODE_RELEASE_BUILD_SCRIPT" \
    || ! grep -Fq 'xcodebuild -downloadComponent MetalToolchain' \
      "$XCODE_RELEASE_BUILD_SCRIPT"; then
    echo "FAIL: Xcode release build does not use the reviewed locked wrapper" >&2
    exit 1
  fi
  if grep -Eqi \
    'argmax|whisper|apply --reverse|--build-system[[:space:]]+xcode|--arch[[:space:]]+x86_64' \
    "$XCODE_RELEASE_BUILD_SCRIPT"; then
    echo "FAIL: Xcode release build retains an obsolete dependency workaround" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: Xcode release build consumes vendored dependencies without checkout mutation"
}

run_executable_package_surface_policy_case() {
  local product_block=""
  local published_product_count=""
  local executable_product_count=""
  local library_product_count=""

  product_block="$(sed -n '/^[[:space:]]*products: \[/,/^[[:space:]]*\],/p' "$PACKAGE_MANIFEST")"
  published_product_count="$(grep -Ec '^[[:space:]]*\.[[:alnum:]_]+\(' <<<"$product_block" || true)"
  executable_product_count="$(grep -Ec '^[[:space:]]*\.executable\(' <<<"$product_block" || true)"
  library_product_count="$(grep -Ec '^[[:space:]]*\.library\(' <<<"$product_block" || true)"
  if [[ "$published_product_count" -ne 2 ]] \
    || [[ "$executable_product_count" -ne 2 ]] \
    || ! grep -Fq '.executable(name: "RillApp", targets: ["RillApp"])' "$PACKAGE_MANIFEST" \
    || ! grep -Fq '.executable(name: "RillSpeechWorker", targets: ["RillSpeechWorker"])' "$PACKAGE_MANIFEST"; then
    echo "FAIL: Package.swift must publish exactly the RillApp and RillSpeechWorker executable products" >&2
    exit 1
  fi
  if [[ "$library_product_count" -ne 0 ]]; then
    echo "FAIL: internal Rill modules must not become accidental public library products" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: SwiftPM publishes only the App and supervised speech worker executables"
}

run_vendored_sherpa_dependency_policy_case() {
  if ! grep -Fq 'name: "SherpaOnnxNative"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'path: "vendor/sherpa-onnx-v1.13.4/sherpa-onnx.xcframework"' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'name: "OnnxRuntimeNative"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'path: "vendor/sherpa-onnx-v1.13.4/onnxruntime.xcframework"' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq '"-Ivendor/sherpa-onnx-v1.13.4/sherpa-onnx.xcframework/macos-arm64_x86_64/Headers"' \
      "$PACKAGE_MANIFEST"; then
    echo "FAIL: sherpa-onnx native dependencies are not repository-vendored" >&2
    exit 1
  fi
  if ! grep -Fq 'url: "https://github.com/Blaizzy/mlx-audio-swift.git"' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'exact: "0.1.3"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'url: "https://github.com/huggingface/swift-huggingface.git"' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'exact: "0.8.1"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'url: "https://github.com/ml-explore/mlx-swift.git"' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'exact: "0.31.4"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq 'name: "RillMLXRuntime"' "$PACKAGE_MANIFEST" \
    || ! grep -Fq '.product(name: "MLXAudioSTT", package: "mlx-audio-swift")' \
      "$PACKAGE_MANIFEST" \
    || ! grep -Fq '.product(name: "MLX", package: "mlx-swift")' \
      "$PACKAGE_MANIFEST"; then
    echo "FAIL: native MLX Swift dependencies are not exactly constrained" >&2
    exit 1
  fi
  if grep -Eqi 'argmax|whisperkit' "$PACKAGE_MANIFEST"; then
    echo "FAIL: Package.swift retains an obsolete speech dependency" >&2
    exit 1
  fi
  if [[ ! -f "$PROJECT_DIR/Package.resolved" ]]; then
    echo "FAIL: remote SwiftPM graph must retain Package.resolved" >&2
    exit 1
  fi
  if ! grep -Fq \
    'verify_xcode_resource_accessor "RillMacOS_RillSherpaRuntime"' \
    "$PREFLIGHT_SCRIPT"; then
    echo "FAIL: preflight does not verify the relocatable Sherpa resource accessor" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  echo "PASS: sherpa remains vendored and the native MLX Swift graph is exactly locked"
}

run_shell_syntax_policy_case() {
  local fixture="$TEST_ROOT/shell-syntax-policy"
  local output=""
  local status=0

  mkdir -p "$fixture/scripts"
  cp "$SHELL_SYNTAX_SCRIPT" "$fixture/scripts/check_shell_syntax.sh"
  chmod +x "$fixture/scripts/check_shell_syntax.sh"
  cat >"$fixture/scripts/valid.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
  cat >"$fixture/scripts/invalid.sh" <<'SH'
#!/usr/bin/env bash
if then
SH

  set +e
  output="$(bash "$fixture/scripts/check_shell_syntax.sh" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"invalid.sh"* ]]; then
    echo "FAIL: shell syntax gate rejects an invalid release script" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  rm "$fixture/scripts/invalid.sh"
  bash "$fixture/scripts/check_shell_syntax.sh"
  if ! grep -Fq 'bash "$SCRIPT_DIR/check_shell_syntax.sh"' "$PREFLIGHT_SCRIPT"; then
    echo "FAIL: preflight does not invoke the fail-closed shell syntax gate" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: preflight invokes a shell syntax gate that rejects invalid scripts"
}

run_release_artifact_hygiene_policy_case() {
  local fixture="$TEST_ROOT/release-artifact-hygiene"
  local artifact=""
  local output=""
  local status=0

  mkdir -p "$fixture/.artifacts/release/Rill.app"
  touch "$fixture/.artifacts/release/Rill.dmg"
  bash "$RELEASE_ARTIFACT_HYGIENE_SCRIPT" "$fixture" >/dev/null

  rm -rf "$fixture/.artifacts"
  for artifact in Rill.app Rill.dmg Rill.dmg.sha256; do
    if [[ "$artifact" == *.app ]]; then
      mkdir -p "$fixture/$artifact"
    else
      touch "$fixture/$artifact"
    fi
    set +e
    output="$(bash "$RELEASE_ARTIFACT_HYGIENE_SCRIPT" "$fixture" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 \
      || "$output" != *"Repository-root release artifacts are forbidden"* \
      || "$output" != *"$artifact"* ]]; then
      echo "FAIL: repository-root $artifact is rejected" >&2
      printf '%s\n' "$output" >&2
      exit 1
    fi
    rm -rf "$fixture/$artifact"
  done

  if git -C "$PROJECT_DIR" check-ignore -q --no-index Rill.app \
    || git -C "$PROJECT_DIR" check-ignore -q --no-index Rill.dmg; then
    echo "FAIL: repository-root release-looking artifacts are hidden by .gitignore" >&2
    exit 1
  fi
  if ! git -C "$PROJECT_DIR" check-ignore -q --no-index \
    .artifacts/release/Rill.app; then
    echo "FAIL: the dedicated release artifact directory is not ignored" >&2
    exit 1
  fi

  if ! grep -Fq \
    'RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR-$PROJECT_DIR/.artifacts/release}"' \
    "$RELEASE_SCRIPT" \
    || ! grep -Fq 'validate_release_output_location "$RELEASE_OUTPUT_DIR"' \
      "$RELEASE_SCRIPT" \
    || ! grep -Fq 'bash "$SCRIPT_DIR/check_release_artifact_hygiene.sh"' \
      "$PREFLIGHT_SCRIPT"; then
    echo "FAIL: release output isolation is not enforced by release and preflight" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: release artifacts are isolated and repository-root lookalikes fail closed"
}

run_release_output_staging_policy_case() {
  local fixture="$TEST_ROOT/release-output-staging"
  local output_dir="$fixture/output"

  mkdir -p "$output_dir/Rill.app"
  printf '%s\n' stale >"$output_dir/Rill.dmg"
  printf '%s\n' stale >"$output_dir/Rill.dmg.sha256"

  (
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    RELEASE_OUTPUT_DIR="$output_dir"
    APP_NAME="Rill"
    prepare_release_output_staging

    if [[ -e "$FINAL_APP_BUNDLE" \
      || -e "$FINAL_DMG_PATH" \
      || -e "$FINAL_DMG_SHA256_PATH" ]]; then
      echo "FAIL: release start did not invalidate stale output artifacts" >&2
      exit 1
    fi
    case "$RELEASE_TEMP_DIR" in
    "$output_dir"/.rill-release.*) ;;
    *)
      echo "FAIL: release staging is not on the output filesystem" >&2
      exit 1
      ;;
    esac

    mkdir -p "$APP_BUNDLE"
    printf '%s\n' verified >"$APP_BUNDLE/marker"
    printf '%s\n' verified >"$DMG_PATH"
    printf '%s\n' verified >"$DMG_SHA256_PATH"
    publish_staged_app
    publish_staged_dmg

    [[ -f "$FINAL_APP_BUNDLE/marker" \
      && -f "$FINAL_DMG_PATH" \
      && -f "$FINAL_DMG_SHA256_PATH" \
      && ! -e "$RELEASE_TEMP_DIR/Rill.app" \
      && ! -e "$RELEASE_TEMP_DIR/Rill.dmg" ]] \
      || {
        echo "FAIL: verified release artifacts were not atomically published" >&2
        exit 1
      }
    rm -rf "$RELEASE_TEMP_DIR"
  )

  PASSED=$((PASSED + 1))
  echo "PASS: stale release output is invalidated and verified artifacts publish from staging"
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
  if [[ "$status" -eq 0 \
    || "$output" != *"未强制终止进程"* \
    || "$(wc -l <"$quit_log" | xargs)" -ne 1 \
    || -s "$forced_termination_log" ]] \
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

  if [[ "$status" -eq 0 \
    || "$output" != *"未强制终止进程"* \
    || "$(wc -l <"$quit_log" | xargs)" -ne 1 \
    || -s "$forced_termination_log" \
    || -s "$install_log" ]]; then
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

  if [[ "$status" -eq 0 \
    || "$output" != *"安装 staging 中的 App 验证失败；旧版保持不变"* \
    || "$(<"$target_app/version")" != "old" \
    || -s "$swap_log" ]] \
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
    ditto() {
      cp -R "$1" "$2"
    }
    verify_install_candidate() {
      [[ "$1" != "$target_app" ]]
    }
    fake_atomic_swap() {
      local left="$1"
      local right="$2"
      local temporary="$applications_dir/.test-swap.$$"

      printf '%s|%s\n' "$left" "$right" >>"$swap_log"
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

  if [[ "$status" -eq 0 \
    || "$output" != *"安装后验证失败；已原子恢复旧版 App"* \
    || "$(<"$target_app/version")" != "old" \
    || "$(wc -l <"$swap_log" | xargs)" -ne 2 ]] \
    || [[ "$(sed -n '1p' "$swap_log")" != "$(sed -n '2p' "$swap_log")" ]] \
    || find "$applications_dir" -maxdepth 1 -type d \
      -name '.rill-install.*' -print -quit | grep -q . \
    || ! grep -Fq 'renamex_np(argv[1], argv[2], RENAME_SWAP)' "$RELEASE_SCRIPT"; then
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

      printf '%s|%s\n' "$left" "$right" >>"$swap_log"
      mv "$left" "$temporary"
      mv "$right" "$left"
      mv "$temporary" "$right"
    }
    build_atomic_swap_helper() {
      ATOMIC_SWAP_HELPER="fake_atomic_swap"
    }
    install_verified_app "$source_app" "$target_app"
    [[ -z "$INSTALL_STAGING_ROOT" ]]
  )

  if [[ "$(<"$target_app/version")" != "new" \
    || "$(wc -l <"$swap_log" | xargs)" -ne 1 ]] \
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

        count="$(( $(<"$verification_count") + 1 ))"
        printf '%s\n' "$count" >"$verification_count"
        if [[ "$count" -eq 2 ]]; then
          /bin/sh -c 'kill -s "$1" "$PPID"' rill-install-test "$signal"
        fi
        return 0
      }
      fake_atomic_swap() {
        local left="$1"
        local right="$2"
        local temporary="$applications_dir/.test-swap.$$"

        printf '%s|%s\n' "$left" "$right" >>"$swap_log"
        mv "$left" "$temporary"
        mv "$right" "$left"
        mv "$temporary" "$right"
      }
      build_atomic_swap_helper() {
        ATOMIC_SWAP_HELPER="fake_atomic_swap"
      }
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
    if [[ "$status" -eq 0 \
      || "$(<"$verification_count")" -ne 2 \
      || "$(wc -l <"$swap_log" | xargs)" -lt 1 ]] \
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

  if [[ "$status" -eq 0 \
    || ! -s "$publish_log" \
    || ! -f "$target_app/version" \
    || "$(<"$target_app/version")" != "concurrent" \
    || -e "$target_app/Rill.app" ]] \
    || ! grep -Fq 'RENAME_EXCL' "$RELEASE_SCRIPT"; then
    echo "FAIL: first install must use RENAME_EXCL and preserve a concurrent target" >&2
    printf '%s\n' "$output" >&2
    cat "$publish_log" >&2
    find "$applications_dir" -maxdepth 3 -print >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: RENAME_EXCL rejects a concurrent first-install target without nesting or deletion"
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

      count="$(( $(<"$swap_count") + 1 ))"
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

  if [[ "$status" -eq 0 \
    || "$output" != *"安装目标在原子替换期间发生并发变化；已恢复原坐标"* \
    || "$(wc -l <"$swap_log" | xargs)" -ne 2 \
    || "$(sed -n '1p' "$swap_log")" != "$(sed -n '2p' "$swap_log")" \
    || ! -f "$target_app/version" \
    || "$(<"$target_app/version")" != "concurrent" \
    || -e "$target_app/Rill.app" ]] \
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

assert_preflight_toolchain_case() {
  local name="$1"
  local python_version="$2"
  local swift_version="$3"
  local expected_status="$4"
  local expected_fragment="$5"
  local output=""
  local status=0

  set +e
  output="$(
    (
      set --
      # shellcheck source=/dev/null
      source "$PREFLIGHT_SCRIPT"
      python3() {
        [[ "$*" == "--version" ]] || return 64
        printf 'Python %s\n' "$python_version"
      }
      swift() {
        [[ "$*" == "--version" ]] || return 64
        printf 'Apple Swift version %s (swiftlang-test)\n' "$swift_version"
      }
      verify_toolchain_versions
    ) 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -ne "$expected_status" || "$output" != *"$expected_fragment"* ]]; then
    echo "FAIL: $name" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

run_preflight_toolchain_policy_case() {
  local toolchain_check_line=""
  local project_work_line=""

  assert_preflight_toolchain_case \
    "preflight accepts its documented minimum toolchain" \
    "3.11.0" \
    "6.2.0" \
    0 \
    "Swift toolchain: 6.2.0"
  assert_preflight_toolchain_case \
    "preflight rejects Python below 3.11" \
    "3.10.13" \
    "6.2.0" \
    1 \
    "Python 3.11 or newer is required (found 3.10.13)"
  assert_preflight_toolchain_case \
    "preflight rejects Swift below 6.2" \
    "3.11.0" \
    "6.1.2" \
    1 \
    "Swift 6.2 or newer is required (found 6.1.2)"

  toolchain_check_line="$(grep -n -m1 '^verify_toolchain_versions$' "$PREFLIGHT_SCRIPT" | cut -d: -f1)"
  project_work_line="$(grep -n -m1 '^cd "$PROJECT_DIR"$' "$PREFLIGHT_SCRIPT" | cut -d: -f1)"
  if [[ -z "$toolchain_check_line" || -z "$project_work_line" \
    || "$toolchain_check_line" -ge "$project_work_line" ]]; then
    echo "FAIL: preflight must enforce toolchain minimums before repository work" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: preflight enforces Python 3.11+ and Swift 6.2+"
}

run_preflight_evidence_policy_case() {
  local output=""
  local report_line=""
  local success_line=""
  local revision="0123456789abcdef0123456789abcdef01234567"

  output="$(
    (
      set --
      # shellcheck source=/dev/null
      source "$PREFLIGHT_SCRIPT"
      SOURCE_REVISION="$revision"
      SOURCE_DIRTY="true"
      report_preflight_evidence
    )
  )"
  if [[ "$output" != *"class=working-source"* \
    || "$output" != *"source_revision=$revision"* \
    || "$output" != *"source_dirty=true"* ]]; then
    echo "FAIL: preflight evidence must identify working source revision and dirty state" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  report_line="$(grep -n -m1 '^report_preflight_evidence$' "$PREFLIGHT_SCRIPT" | cut -d: -f1)"
  success_line="$(grep -n -m1 '^info "Preflight passed"$' "$PREFLIGHT_SCRIPT" | cut -d: -f1)"
  if [[ -z "$report_line" || -z "$success_line" || "$report_line" -ge "$success_line" ]]; then
    echo "FAIL: preflight must report its evidence coordinate immediately before success" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: preflight reports a deterministic working-source evidence coordinate"
}

run_arm64_executable_policy_case() {
  local fixture="$TEST_ROOT/arm64-executable-policy"
  local fake_bin="$fixture/bin"
  local executable="$fixture/RillSpeechWorker"
  local lipo_invocation_log="$fixture/lipo-invocation.log"
  local vtool_invocation_log="$fixture/vtool-invocation.log"
  local expected_lipo_log=""
  local expected_vtool_log=""
  local output=""
  local status=0

  mkdir -p "$fake_bin"
  cat >"$fake_bin/lipo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_LIPO_LOG:?FAKE_LIPO_LOG is required}"
printf '%s\n' "$@" >>"$FAKE_LIPO_LOG"
[[ "$#" -eq 2 && "$2" == "-archs" ]] || {
  echo "unexpected lipo invocation: $*" >&2
  exit 64
}
printf '%s\n' "${FAKE_LIPO_ARCHS:-arm64}"
exit "${FAKE_LIPO_STATUS:-0}"
SH
  chmod +x "$fake_bin/lipo"
  cat >"$fake_bin/nm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 4 && "$1" == "-m" && "$2" == "-arch" && "$3" == "arm64" ]] || {
  echo "unexpected nm invocation: $*" >&2
  exit 64
}
if [[ -n "${FAKE_NM_LOG:-}" ]]; then
  printf '%s\n' "$3" >>"$FAKE_NM_LOG"
fi
if [[ "${FAKE_NM_MISSING_RECOGNIZER:-}" != "$3" ]]; then
  printf '%s\n' \
    '00000001 (__TEXT,__text) external _SherpaOnnxCreateOfflineRecognizer'
fi
if [[ "${FAKE_NM_MISSING_VAD:-}" != "$3" ]]; then
  printf '%s\n' \
    '00000002 (__TEXT,__text) external _SherpaOnnxCreateVoiceActivityDetector'
fi
if [[ "${FAKE_NM_MISSING_STREAM_OPTION:-}" != "$3" ]]; then
  printf '%s\n' \
    '00000003 (__TEXT,__text) external _SherpaOnnxOfflineStreamSetOption'
fi
if [[ "${FAKE_NM_FORBIDDEN:-}" == "$3" ]]; then
  printf '%s\n' \
    '00000004 (__TEXT,__text) external _espeak_Initialize'
fi
SH
  chmod +x "$fake_bin/nm"
  cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_VTOOL_LOG:?FAKE_VTOOL_LOG is required}"
[[ "$#" -eq 5 && "$1" == "vtool" && "$2" == "-arch" && "$4" == "-show-build" ]] || {
  echo "unexpected xcrun invocation: $*" >&2
  exit 64
}
architecture="$3"
printf '%s\n' "$*" >>"$FAKE_VTOOL_LOG"
case "$architecture" in
arm64)
  command_name="${FAKE_VTOOL_ARM64_COMMAND:-${FAKE_VTOOL_COMMAND:-LC_BUILD_VERSION}}"
  platform="${FAKE_VTOOL_ARM64_PLATFORM:-${FAKE_VTOOL_PLATFORM:-MACOS}}"
  minos="${FAKE_VTOOL_ARM64_MINOS:-${FAKE_VTOOL_MINOS:-14.0}}"
  ;;
*)
  echo "unexpected architecture: $architecture" >&2
  exit 64
  ;;
esac
cat <<EOF
$5 (architecture $architecture):
Load command 1
      cmd $command_name
  cmdsize 32
 platform $platform
    minos $minos
      sdk 15.2
   ntools 1
     tool LD
  version 1.0
EOF
SH
  chmod +x "$fake_bin/xcrun"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$executable"
  chmod +x "$executable"

  : >"$vtool_invocation_log"
  local nm_invocation_log="$fixture/nm-invocation.log"
  : >"$nm_invocation_log"
  PATH="$fake_bin:$PATH" \
    FAKE_LIPO_LOG="$lipo_invocation_log" \
    FAKE_NM_LOG="$nm_invocation_log" \
    FAKE_VTOOL_LOG="$vtool_invocation_log" \
    bash "$EXECUTABLE_VERIFIER" --require-sherpa "$executable"
  expected_lipo_log="$(printf '%s\n' "$executable" -archs)"
  if [[ "$(<"$lipo_invocation_log")" != "$expected_lipo_log" ]]; then
    echo "FAIL: arm64 executable verifier did not inspect the exact architecture set" >&2
    cat "$lipo_invocation_log" >&2
    exit 1
  fi
  expected_vtool_log="$(cat <<EOF
vtool -arch arm64 -show-build $executable
EOF
)"
  if [[ "$(<"$vtool_invocation_log")" != "$expected_vtool_log" ]]; then
    echo "FAIL: arm64 executable verifier did not inspect the build-version slice" >&2
    cat "$vtool_invocation_log" >&2
    exit 1
  fi
  if [[ "$(<"$nm_invocation_log")" != "arm64" ]]; then
    echo "FAIL: arm64 executable verifier did not inspect sherpa linkage" >&2
    cat "$nm_invocation_log" >&2
    exit 1
  fi

  : >"$nm_invocation_log"
  PATH="$fake_bin:$PATH" \
    FAKE_LIPO_LOG="$lipo_invocation_log" \
    FAKE_NM_LOG="$nm_invocation_log" \
    FAKE_VTOOL_LOG="$vtool_invocation_log" \
    bash "$EXECUTABLE_VERIFIER" "$executable"
  if [[ -s "$nm_invocation_log" ]]; then
    echo "FAIL: common app executable verification unexpectedly requires Sherpa linkage" >&2
    cat "$nm_invocation_log" >&2
    exit 1
  fi

  local executable_symlink="$fixture/RillSpeechWorker-link"
  ln -s "$executable" "$executable_symlink"
  set +e
  output="$(bash "$EXECUTABLE_VERIFIER" "$executable_symlink" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 \
    || "$output" != *"executable regular non-symlink file"* ]]; then
    echo "FAIL: executable verifier accepts a symlinked build product" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_LIPO_ARCHS="x86_64 arm64" \
      bash "$EXECUTABLE_VERIFIER" "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"must contain only arm64"* ]]; then
    echo "FAIL: arm64 executable verifier accepts a universal executable" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_VTOOL_ARM64_MINOS=14.1 \
      bash "$EXECUTABLE_VERIFIER" "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"arm64 slice must require macOS 14.0 exactly"* ]]; then
    echo "FAIL: executable verifier accepts a newer arm64 deployment target" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_VTOOL_ARM64_PLATFORM=IOS \
      bash "$EXECUTABLE_VERIFIER" "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"arm64 slice must target the macOS platform"* ]]; then
    echo "FAIL: executable verifier accepts a non-macOS platform" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_VTOOL_ARM64_COMMAND=LC_VERSION_MIN_MACOSX \
      bash "$EXECUTABLE_VERIFIER" "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"exactly one LC_BUILD_VERSION"* ]]; then
    echo "FAIL: executable verifier accepts a missing LC_BUILD_VERSION" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_NM_MISSING_RECOGNIZER=arm64 \
      bash "$EXECUTABLE_VERIFIER" --require-sherpa "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 \
    || "$output" != *"must statically define SherpaOnnxCreateOfflineRecognizer in the arm64 slice"* ]]; then
    echo "FAIL: executable verifier accepts missing sherpa-onnx static linkage" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_NM_MISSING_VAD=arm64 \
      bash "$EXECUTABLE_VERIFIER" --require-sherpa "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 \
    || "$output" != *"must statically define SherpaOnnxCreateVoiceActivityDetector in the arm64 slice"* ]]; then
    echo "FAIL: executable verifier accepts missing sherpa-onnx VAD static linkage" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_NM_MISSING_STREAM_OPTION=arm64 \
      bash "$EXECUTABLE_VERIFIER" --require-sherpa "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 \
    || "$output" != *"must statically define SherpaOnnxOfflineStreamSetOption in the arm64 slice"* ]]; then
    echo "FAIL: executable verifier accepts missing sherpa-onnx stream-option linkage" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  output="$(
    PATH="$fake_bin:$PATH" \
      FAKE_LIPO_LOG="$lipo_invocation_log" \
      FAKE_VTOOL_LOG="$vtool_invocation_log" \
      FAKE_NM_FORBIDDEN=arm64 \
      bash "$EXECUTABLE_VERIFIER" --require-sherpa "$executable" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 \
    || "$output" != *"must exclude Piper and eSpeak implementation code in the arm64 slice"* ]]; then
    echo "FAIL: executable verifier accepts Piper or eSpeak implementation code" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq 'verify_release_executable.sh" "$BUILD_DIR/RillApp"' "$PREFLIGHT_SCRIPT" \
    || ! grep -Fq '"$BUILD_DIR/RillSpeechWorker"' "$PREFLIGHT_SCRIPT" \
    || ! grep -Fq 'verify_release_executable.sh" "$EXECUTABLE_SOURCE"' "$ASSEMBLER_SCRIPT" \
    || ! grep -Fq '"$SPEECH_WORKER_SOURCE"' "$ASSEMBLER_SCRIPT" \
    || ! grep -Fq '"$APP_BUNDLE/Contents/MacOS/$APP_NAME"' "$ASSEMBLER_SCRIPT" \
    || ! grep -Fq '"$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_PRODUCT"' \
      "$ASSEMBLER_SCRIPT"; then
    echo "FAIL: preflight and app assembly do not verify both release executables" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: both executables require an arm64-only macOS 14 slice and the worker alone requires reviewed Sherpa linkage"
}

run_local_build_identity_case() {
  local repository="$TEST_ROOT/local-build-identity"
  local head_revision=""
  local resolved=""

  mkdir -p "$repository"
  git -C "$repository" init -q
  printf '%s\n' base >"$repository/source.txt"
  git -C "$repository" add source.txt
  git -C "$repository" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgsign=false \
    -c user.name="Rill Test" \
    -c user.email="rill-test@example.invalid" \
    commit -q -m "base"
  git -C "$repository" tag v1.2.3
  printf '%s\n' next >>"$repository/source.txt"
  git -C "$repository" add source.txt
  git -C "$repository" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgsign=false \
    -c user.name="Rill Test" \
    -c user.email="rill-test@example.invalid" \
    commit -q -m "after tag"
  head_revision="$(git -C "$repository" rev-parse HEAD)"

  resolved="$(
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    PROJECT_DIR="$repository"
    DO_NOTARIZE=false
    resolve_build_identity
    printf '%s|%s|%s|%s|%s' \
      "$RESOLVED_APP_VERSION" \
      "$RESOLVED_BUILD_KIND" \
      "$RESOLVED_VERSION_LABEL" \
      "$RESOLVED_SOURCE_REVISION" \
      "$RESOLVED_SOURCE_DIRTY"
  )"
  if [[ "$resolved" != "0.0.0|development|0.0.0-dev+${head_revision:0:12}|$head_revision|false" ]]; then
    echo "FAIL: a commit after a tag must not inherit the historical release version" >&2
    printf '%s\n' "$resolved" >&2
    exit 1
  fi

  git -C "$repository" tag v1.2.4
  resolved="$(
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    PROJECT_DIR="$repository"
    DO_NOTARIZE=false
    resolve_build_identity
    printf '%s|%s|%s|%s' \
      "$RESOLVED_APP_VERSION" \
      "$RESOLVED_BUILD_KIND" \
      "$RESOLVED_VERSION_LABEL" \
      "$RESOLVED_SOURCE_DIRTY"
  )"
  if [[ "$resolved" != "1.2.4|tagged|1.2.4|false" ]]; then
    echo "FAIL: a clean HEAD with one semantic tag should retain that version" >&2
    printf '%s\n' "$resolved" >&2
    exit 1
  fi

  printf '%s\n' dirty >>"$repository/source.txt"
  resolved="$(
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    PROJECT_DIR="$repository"
    DO_NOTARIZE=false
    resolve_build_identity
    printf '%s|%s|%s|%s' \
      "$RESOLVED_APP_VERSION" \
      "$RESOLVED_BUILD_KIND" \
      "$RESOLVED_VERSION_LABEL" \
      "$RESOLVED_SOURCE_DIRTY"
  )"
  if [[ "$resolved" != "0.0.0|development|0.0.0-dev+${head_revision:0:12}.dirty|true" ]]; then
    echo "FAIL: a dirty tagged source must be labeled as a development build" >&2
    printf '%s\n' "$resolved" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: local build versions distinguish exact tags, later commits, and dirty sources"
}

run_ci_prek_policy_case() {
  if ! grep -Fq 'uses: j178/prek-action@e98a699c41eb69ab013a45817a0406469a748f8d # v2.0.5' "$CI_WORKFLOW" \
    || ! grep -Fq 'prek-version: "0.3.10"' "$CI_WORKFLOW" \
    || ! grep -Fq 'prek validate-config prek.toml' "$CI_WORKFLOW" \
    || ! grep -Fq 'prek -c prek.toml run --all-files' "$CI_WORKFLOW"; then
    echo "FAIL: CI must install the reviewed prek action and version, then run the complete config" >&2
    exit 1
  fi
  if grep -Eq 'uses:[[:space:]]+j178/prek-action@(v|main|master)' "$CI_WORKFLOW"; then
    echo "FAIL: CI prek action must use an immutable commit" >&2
    exit 1
  fi
  if [[ "$(grep -Ec '^[[:space:]]+lfs: true$' "$CI_WORKFLOW")" -ne 2 ]]; then
    echo "FAIL: every CI checkout must materialize the vendored Git LFS runtime archives" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: CI pins reviewed prek code, fetches Git LFS runtimes, and executes the complete configuration"
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

run_notarized_output_symlink_policy_case() {
  local repository="$TEST_ROOT/source-output-symlink-repository"
  local snapshot_bin="$TEST_ROOT/source-output-symlink-bin"
  local probe="$TEST_ROOT/source-output-symlink-probe"
  local output=""
  local status=0

  create_release_source_fixture "$repository"
  ln -s . "$repository/.artifacts"
  mkdir -p "$snapshot_bin"
  cp "$FAKE_BIN/security" "$snapshot_bin/security"
  chmod +x "$snapshot_bin/security"

  set +e
  output="$(env \
    -u RILL_RELEASE_SOURCE_CAPABILITY \
    -u RILL_RELEASE_SOURCE_SNAPSHOT \
    -u RILL_RELEASE_SOURCE_COMMIT \
    "PATH=$snapshot_bin:$PATH" \
    "FAKE_IDENTITIES=$DEVELOPER_ID_IDENTITIES" \
    "SNAPSHOT_PROBE=$probe" \
    "RELEASE_OUTPUT_DIR=$repository/.artifacts/release" \
    "SIGN_IDENTITY=Developer ID Application" \
    "NOTARY_PROFILE=Rill-Test" \
    bash "$repository/scripts/release.sh" --notarize 2>&1)"
  status=$?
  set -e

  if [[ "$status" -eq 0 \
    || "$output" != *"仓库内发布输出必须位于 .artifacts/ 下"* \
    || -e "$repository/release" \
    || -e "$probe" ]]; then
    echo "FAIL: notarized release accepts output symlinked into its source tree" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: notarized release rejects physical output symlinks before snapshot dispatch"
}

run_release_snapshot_case() {
  local repository="$TEST_ROOT/source-snapshot-repository"
  local probe="$TEST_ROOT/source-snapshot-probe"
  local expected_commit=""
  local snapshot_project=""
  local snapshot_commit=""
  local snapshot_bin="$TEST_ROOT/source-snapshot-bin"
  local output=""
  local status=0

  create_release_source_fixture "$repository"
  expected_commit="$(git -C "$repository" rev-parse HEAD)"
  mkdir -p "$snapshot_bin"
  cp "$FAKE_BIN/security" "$snapshot_bin/security"
  chmod +x "$snapshot_bin/security"
  set +e
  output="$(env \
    -u RILL_RELEASE_SOURCE_CAPABILITY \
    -u RILL_RELEASE_SOURCE_SNAPSHOT \
    -u RILL_RELEASE_SOURCE_COMMIT \
    "PATH=$snapshot_bin:$PATH" \
    "FAKE_IDENTITIES=$DEVELOPER_ID_IDENTITIES" \
    "SNAPSHOT_PROBE=$probe" \
    "RELEASE_OUTPUT_DIR=$TEST_ROOT/release-output" \
    "SIGN_IDENTITY=Developer ID Application" \
    "NOTARY_PROFILE=Rill-Test" \
    bash "$repository/scripts/release.sh" --notarize 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 73 ]]; then
    echo "FAIL: notarized CLI did not enter its detached snapshot" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  snapshot_project="$(sed -n '1p' "$probe")"
  snapshot_commit="$(sed -n '2p' "$probe")"
  if [[ "$snapshot_project" == "$repository" \
    || -e "$snapshot_project" \
    || "$snapshot_commit" != "$expected_commit" ]]; then
    echo "FAIL: notarized release executes from a cleaned detached snapshot" >&2
    printf 'project=%s\ncommit=%s\n' "$snapshot_project" "$snapshot_commit" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: notarized release executes from a cleaned detached snapshot"
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

run_literal_plist_key_case() {
  local plist="$TEST_ROOT/signed-entitlements.plist"
  local values=""

  cat >"$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.app-sandbox</key>
  <false/>
  <key>com.apple.application-identifier</key>
  <string>TEAMID.dev.zrr.Rill</string>
</dict>
</plist>
PLIST

  values="$(
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    printf '%s|%s|%s' \
      "$(plist_extract_literal_raw com.apple.security.device.audio-input "$plist")" \
      "$(plist_extract_literal_raw com.apple.security.app-sandbox "$plist")" \
      "$(plist_extract_literal_raw com.apple.application-identifier "$plist")"
  )"

  if [[ "$values" != "true|false|TEAMID.dev.zrr.Rill" ]]; then
    echo "FAIL: dotted entitlement names are read as literal plist keys" >&2
    printf '%s\n' "$values" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: dotted entitlement names are read as literal plist keys"
}

run_speech_worker_bundle_signing_policy_case() {
  local fixture="$TEST_ROOT/speech-worker-bundle-signing"
  local app_bundle="$fixture/Rill.app"
  local speech_worker="$app_bundle/Contents/Helpers/RillSpeechWorker"
  local main_flow=""
  local helper_identifier_line=""
  local outer_entitlements_line=""
  local verification_line=""
  local output=""
  local status=0

  mkdir -p "$(dirname "$speech_worker")" "$fixture/temp"
  printf '%s\n' worker >"$speech_worker"
  chmod +x "$speech_worker"

  (
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    APP_BUNDLE="$app_bundle"
    RELEASE_TEMP_DIR="$fixture/temp"
    RESOLVED_SIGN_IDENTITY_NAME="Developer ID Application: Example Company (TEAMDIST01)"
    DO_NOTARIZE=false
    codesign() {
      case "$1 $2" in
      "--verify --strict") return 0 ;;
      "-d --verbose=4")
        cat <<'DETAILS'
Identifier=dev.zrr.Rill.SpeechWorker
Authority=Developer ID Application: Example Company (TEAMDIST01)
TeamIdentifier=TEAMDIST01
Timestamp=Jul 19, 2026 at 12:00:00
CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+2 location=embedded
DETAILS
        ;;
      "-d --entitlements") return 0 ;;
      *) return 64 ;;
      esac
    }
    info() { :; }
    verify_signed_speech_worker
  )

  set +e
  (
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    APP_BUNDLE="$app_bundle"
    RELEASE_TEMP_DIR="$fixture/temp"
    RESOLVED_SIGN_IDENTITY_NAME="Developer ID Application: Example Company (TEAMDIST01)"
    DO_NOTARIZE=false
    codesign() {
      case "$1 $2" in
      "--verify --strict") return 0 ;;
      "-d --verbose=4")
        cat <<'DETAILS'
Identifier=dev.zrr.Rill.SpeechWorker
Authority=Developer ID Application: Example Company (TEAMDIST01)
TeamIdentifier=TEAMDIST01
Timestamp=Jul 19, 2026 at 12:00:00
CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+2 location=embedded
DETAILS
        ;;
      "-d --entitlements")
        cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
        ;;
      *) return 64 ;;
      esac
    }
    info() { :; }
    verify_signed_speech_worker
  ) >"$fixture/microphone-entitlement.out" 2>&1
  status=$?
  set -e
  output="$(<"$fixture/microphone-entitlement.out")"
  if [[ "$status" -eq 0 \
    || "$output" != *"com.apple.security.device.audio-input"* ]]; then
    echo "FAIL: speech worker signature accepts the app's microphone entitlement" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  (
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    APP_BUNDLE="$app_bundle"
    RELEASE_TEMP_DIR="$fixture/temp"
    RESOLVED_SIGN_IDENTITY_NAME="Developer ID Application: Example Company (TEAMDIST01)"
    DO_NOTARIZE=false
    codesign() {
      case "$1 $2" in
      "--verify --strict") return 0 ;;
      "-d --verbose=4")
        cat <<'DETAILS'
Identifier=wrong.identifier
Authority=Developer ID Application: Example Company (TEAMDIST01)
TeamIdentifier=not set
Timestamp=Jul 19, 2026 at 12:00:00
CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+2 location=embedded
DETAILS
        ;;
      *) return 64 ;;
      esac
    }
    info() { :; }
    verify_signed_speech_worker
  ) >"$fixture/identity.out" 2>&1
  status=$?
  set -e
  output="$(<"$fixture/identity.out")"
  if [[ "$status" -eq 0 \
    || "$output" != *"签名标识不匹配"* ]]; then
    echo "FAIL: speech worker signature accepts a mismatched identifier or Team" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  set +e
  (
    exec 2>&1
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    APP_BUNDLE="$app_bundle"
    RELEASE_TEMP_DIR="$fixture/temp"
    RESOLVED_SIGN_IDENTITY_NAME="Developer ID Application: Example Company (TEAMDIST01)"
    DO_NOTARIZE=false
    codesign() {
      case "$1 $2" in
      "--verify --strict") return 0 ;;
      "-d --verbose=4")
        cat <<'DETAILS'
Identifier=dev.zrr.Rill.SpeechWorker
Authority=Developer ID Application: Example Company (TEAMDIST01)
TeamIdentifier=not set
Timestamp=Jul 19, 2026 at 12:00:00
CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+2 location=embedded
DETAILS
        ;;
      *) return 64 ;;
      esac
    }
    info() { :; }
    verify_signed_speech_worker
  ) >"$fixture/team.out" 2>&1
  status=$?
  set -e
  output="$(<"$fixture/team.out")"
  if [[ "$status" -eq 0 \
    || "$output" != *"TeamIdentifier"* ]]; then
    echo "FAIL: speech worker signature accepts a missing TeamIdentifier" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  if ! grep -Fq '"$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_PRODUCT"' \
    "$ASSEMBLER_SCRIPT" \
    || ! grep -Fq 'ditto \' "$ASSEMBLER_SCRIPT" \
    || ! grep -Fq 'codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"' \
      "$RELEASE_SCRIPT" \
    || ! grep -Fq 'codesign --verify --deep --strict --verbose=2 "$candidate"' \
      "$RELEASE_SCRIPT"; then
    echo "FAIL: bundle assembly or release verification omits the nested speech worker" >&2
    exit 1
  fi

  main_flow="$(sed -n '/^# ─── 步骤 3: 签名/,/^verify_signed_app$/p' "$RELEASE_SCRIPT")"
  helper_identifier_line="$(grep -n -m1 -- '--identifier "$SPEECH_WORKER_IDENTIFIER"' \
    <<<"$main_flow" | cut -d: -f1)"
  outer_entitlements_line="$(grep -n -m1 -- '--entitlements "$ENTITLEMENTS"' \
    <<<"$main_flow" | cut -d: -f1)"
  verification_line="$(grep -n -m1 '^verify_signed_app$' <<<"$main_flow" | cut -d: -f1)"
  if [[ -z "$helper_identifier_line" \
    || -z "$outer_entitlements_line" \
    || -z "$verification_line" \
    || "$helper_identifier_line" -ge "$outer_entitlements_line" \
    || "$outer_entitlements_line" -ge "$verification_line" ]]; then
    echo "FAIL: release must sign the helper before the outer app and then verify the nested graph" >&2
    exit 1
  fi
  if sed -n '1,/^info "签名外层应用/p' <<<"$main_flow" \
    | grep -Fq -- '--entitlements'; then
    echo "FAIL: speech worker signing inherits the main app entitlement file" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: speech worker is bundled, signed first with a stable Team/identifier and hardened runtime, and receives no microphone entitlement"
}

run_distribution_dmg_policy_case() {
  local fixture="$TEST_ROOT/distribution-dmg-policy"
  local invocation_log="$fixture/invocations.log"
  local expected_log=""
  local main_flow=""
  local create_line=""
  local finalize_line=""
  local sidecar_line=""
  local publish_app_line=""
  local publish_dmg_line=""
  local install_flow=""
  local local_dmg="$fixture/local/Rill.dmg"
  local expected_checksum=""
  local expected_sidecar_content=""

  mkdir -p "$fixture"
  : >"$invocation_log"
  printf '%s\n' 'final signed and stapled dmg bytes' >"$fixture/Rill.dmg"
  printf '%s\n' 'stale checksum' >"$fixture/Rill.dmg.sha256"

  (
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    DO_NOTARIZE=true
    RELEASE_TEMP_DIR="$fixture"
    DMG_PATH="$fixture/Rill.dmg"
    RESOLVED_SIGN_IDENTITY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    RESOLVED_SIGN_IDENTITY_NAME="Developer ID Application: Example Company (TEAMDIST01)"
    NOTARY_PROFILE="Rill-Test"

    info() { :; }
    error() {
      printf 'error %s\n' "$*" >>"$invocation_log"
      return 1
    }
    revalidate_notarized_release_source() {
      printf 'revalidate %s\n' "$*" >>"$invocation_log"
    }
    codesign() { printf 'codesign %s\n' "$*" >>"$invocation_log"; }
    hdiutil() { printf 'hdiutil %s\n' "$*" >>"$invocation_log"; }
    xcrun() {
      printf 'xcrun %s\n' "$*" >>"$invocation_log"
      if [[ "$1" == "notarytool" ]]; then
        printf '%s\n' '{"status":"Accepted","id":"test-request"}'
      fi
    }
    plutil() {
      printf 'plutil %s\n' "$*" >>"$invocation_log"
      case "$2" in
      status) printf '%s\n' Accepted ;;
      id) printf '%s\n' test-request ;;
      *) return 64 ;;
      esac
    }
    spctl() { printf 'spctl %s\n' "$*" >>"$invocation_log"; }

    finalize_distribution_dmg
    publish_distribution_dmg_sidecar
  )

  expected_log="$(cat <<EOF
codesign --force --timestamp --sign BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB $fixture/Rill.dmg
codesign --verify --strict --verbose=2 $fixture/Rill.dmg
hdiutil verify $fixture/Rill.dmg
revalidate 最终 DMG 公证提交前
xcrun notarytool submit $fixture/Rill.dmg --keychain-profile Rill-Test --wait --output-format json
plutil -extract status raw -o - $fixture/dmg-notary-result.json
plutil -extract id raw -o - $fixture/dmg-notary-result.json
xcrun stapler staple $fixture/Rill.dmg
xcrun stapler validate $fixture/Rill.dmg
codesign --verify --strict --verbose=2 $fixture/Rill.dmg
hdiutil verify $fixture/Rill.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 $fixture/Rill.dmg
EOF
)"
  if [[ "$(<"$invocation_log")" != "$expected_log" ]]; then
    echo "FAIL: final DMG is signed, submitted, stapled, and verified in order" >&2
    cat "$invocation_log" >&2
    exit 1
  fi

  expected_checksum="$(shasum -a 256 "$fixture/Rill.dmg" | awk '{ print tolower($1) }')"
  expected_sidecar_content="$expected_checksum  Rill.dmg"
  if [[ ! -f "$fixture/Rill.dmg.sha256" \
    || "$(<"$fixture/Rill.dmg.sha256")" != "$expected_sidecar_content" ]]; then
    echo "FAIL: final DMG sidecar does not use the standard stable SHA-256 format" >&2
    [[ -e "$fixture/Rill.dmg.sha256" ]] && cat "$fixture/Rill.dmg.sha256" >&2
    exit 1
  fi
  if ! (cd "$fixture" && shasum -a 256 -c Rill.dmg.sha256 >/dev/null); then
    echo "FAIL: standard SHA-256 tooling cannot verify the final DMG sidecar" >&2
    exit 1
  fi
  if find "$fixture" -maxdepth 1 -name 'Rill.dmg.sha256.tmp.*' -print -quit | grep -q .; then
    echo "FAIL: atomic DMG sidecar publication left a temporary file" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$local_dmg")"
  printf '%s\n' 'local unnotarized dmg bytes' >"$local_dmg"
  (
    set --
    # shellcheck source=/dev/null
    source "$RELEASE_SCRIPT"
    DO_NOTARIZE=false
    DMG_PATH="$local_dmg"
    info() { :; }
    publish_distribution_dmg_sidecar
  )
  if [[ -e "${local_dmg}.sha256" ]]; then
    echo "FAIL: a local unnotarized DMG published an official release sidecar" >&2
    exit 1
  fi

  main_flow="$(sed -n '/步骤 4: 安装 或打包最终 DMG/,/echo ""/p' "$RELEASE_SCRIPT")"
  create_line="$(grep -n -m1 'hdiutil create' <<<"$main_flow" | cut -d: -f1)"
  finalize_line="$(grep -n -m1 '^  finalize_distribution_dmg$' <<<"$main_flow" | cut -d: -f1)"
  sidecar_line="$(grep -n -m1 '^  publish_distribution_dmg_sidecar$' <<<"$main_flow" | cut -d: -f1)"
  publish_app_line="$(grep -n '^  publish_staged_app$' <<<"$main_flow" | tail -1 | cut -d: -f1)"
  publish_dmg_line="$(grep -n -m1 '^  publish_staged_dmg$' <<<"$main_flow" | cut -d: -f1)"
  if [[ -z "$create_line" || -z "$finalize_line" || -z "$sidecar_line" \
    || -z "$publish_app_line" || -z "$publish_dmg_line" \
    || "$create_line" -ge "$finalize_line" \
    || "$finalize_line" -ge "$sidecar_line" \
    || "$sidecar_line" -ge "$publish_app_line" \
    || "$publish_app_line" -ge "$publish_dmg_line" ]]; then
    echo "FAIL: the release flow must verify the DMG and sidecar before publishing staged artifacts" >&2
    exit 1
  fi
  if [[ "$(grep -Ec '^[[:space:]]+write_sha256_sidecar ' "$RELEASE_SCRIPT")" -ne 1 ]] \
    || ! grep -Fq 'prepare_release_output_staging' "$RELEASE_SCRIPT" \
    || ! grep -Fq 'rm -f "$FINAL_DMG_PATH" "$FINAL_DMG_SHA256_PATH"' "$RELEASE_SCRIPT"; then
    echo "FAIL: only the verified DMG may publish a sidecar, and stale release pairs must fail closed early" >&2
    exit 1
  fi
  install_flow="$(sed -n '/^if \$DO_INSTALL; then$/,/^else$/p' "$RELEASE_SCRIPT")"
  if ! grep -Fq 'publish_staged_app' <<<"$install_flow"; then
    echo "FAIL: --install must invalidate stale output and publish only the verified staged App" >&2
    exit 1
  fi
  if ! grep -Fq 'if $DO_NOTARIZE && $DO_INSTALL; then' "$RELEASE_SCRIPT"; then
    echo "FAIL: temporary ZIP notarization must be limited to direct installation" >&2
    exit 1
  fi
  if grep -Fq 'stapler validate "$DMG_STAGING/$APP_NAME.app"' "$RELEASE_SCRIPT"; then
    echo "FAIL: the DMG path must validate the outer ticket, not require an unstapled nested app" >&2
    exit 1
  fi

  PASSED=$((PASSED + 1))
  echo "PASS: final DMG is verified before its atomic portable SHA-256 sidecar is published"
}

run_case \
  "notarization never falls back to Apple Development" \
  1 \
  "公证发布需要可用的 Developer ID Application" \
  "$APPLE_IDENTITIES" \
  "<unset>" \
  "<unset>" \
  --notarize

run_case \
  "notarization rejects an explicitly selected development identity" \
  1 \
  "公证发布只能使用 Developer ID Application" \
  "$BOTH_IDENTITIES" \
  "Apple Development" \
  "<unset>" \
  --notarize

run_case \
  "notarization accepts one Developer ID Application identity" \
  0 \
  "发布配置验证通过（未执行构建、签名或公证）" \
  "$DEVELOPER_ID_IDENTITIES" \
  "<unset>" \
  "<unset>" \
  --notarize

run_notarized_source_case \
  "notarization rejects an untracked dependency manifest" \
  "第三方依赖清单已纳入版本控制" \
  "" \
  "v1.2.3" \
  "false"

run_notarized_source_case \
  "notarization rejects a dirty worktree" \
  "公证发布要求干净的 Git 工作树" \
  " M README.md" \
  "v1.2.3" \
  "true"

run_notarized_source_case \
  "notarization rejects hidden index flags" \
  "拒绝 assume-unchanged、skip-worktree 或 sparse checkout" \
  "" \
  "v1.2.3" \
  "true" \
  "h scripts/third_party_notices_manifest.json"

run_notarized_source_case \
  "notarization rejects an untagged HEAD" \
  "HEAD 精确标记一个 vMAJOR.MINOR.PATCH 标签" \
  "" \
  "" \
  "true"

run_notarized_source_case \
  "notarization rejects a non-semantic version tag" \
  "HEAD 精确标记一个 vMAJOR.MINOR.PATCH 标签" \
  "" \
  "v1.2" \
  "true"

run_notarized_source_case \
  "notarization rejects multiple semantic version tags" \
  "HEAD 存在多个版本标签" \
  "" \
  $'v1.2.3\nv1.2.4' \
  "true"

run_case \
  "a Developer ID Application SHA-1 resolves to its certificate type" \
  0 \
  "签名身份: Developer ID Application: Example Company" \
  "$BOTH_IDENTITIES" \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "<unset>" \
  --notarize

run_case \
  "local default may fall back to Apple Development" \
  0 \
  "仅适用于本地构建，不支持公证" \
  "$APPLE_IDENTITIES" \
  "<unset>" \
  "<unset>"

run_case \
  "an explicitly requested missing identity never falls back" \
  1 \
  "未找到指定的签名身份" \
  "$APPLE_IDENTITIES" \
  "Developer ID Application: Missing Company (MISSING001)" \
  "<unset>"

run_case \
  "a generic request must not choose between multiple distribution identities" \
  1 \
  "匹配到多个证书" \
  "$AMBIGUOUS_DEVELOPER_IDS" \
  "<unset>" \
  "<unset>" \
  --notarize

run_case \
  "an explicitly empty identity fails closed" \
  1 \
  "SIGN_IDENTITY 不能为空" \
  "$BOTH_IDENTITIES" \
  "" \
  "<unset>"

run_case \
  "notarization rejects an explicitly empty keychain profile" \
  1 \
  "--notarize 需要非空的 NOTARY_PROFILE" \
  "$DEVELOPER_ID_IDENTITIES" \
  "<unset>" \
  "" \
  --notarize

run_invalid_output_dir_case \
  "an explicitly empty release output directory fails closed" \
  "" \
  "RELEASE_OUTPUT_DIR 不能为空"

run_invalid_output_dir_case \
  "a release output directory cannot contain a newline" \
  $'invalid\npath' \
  "RELEASE_OUTPUT_DIR 不能包含换行符"

run_invalid_output_dir_case \
  "the repository root cannot be a release output directory" \
  "$PROJECT_DIR" \
  "发布输出拒绝仓库根目录"

run_invalid_output_dir_case \
  "a repository-local release output must stay under .artifacts" \
  "$PROJECT_DIR/release-output" \
  "仓库内发布输出必须位于 .artifacts/ 下"

run_invalid_output_dir_case \
  "release output traversal segments fail before directory creation" \
  "$PROJECT_DIR/.artifacts/../release-output" \
  "RELEASE_OUTPUT_DIR 不能包含 . 或 .. 路径段"

run_invalid_output_dir_case \
  "the release output cannot overlap the installed application" \
  "/Applications" \
  "RELEASE_OUTPUT_DIR 不能与安装目标 /Applications/Rill.app 重合"

run_invalid_output_dir_case \
  "the release output cannot be nested inside the installed application" \
  "/Applications/Rill.app/Contents/ReleaseOutput" \
  "RELEASE_OUTPUT_DIR 不能与安装目标 /Applications/Rill.app 重合"

run_reserved_internal_environment_case
run_literal_plist_key_case
run_speech_worker_bundle_signing_policy_case
run_distribution_dmg_policy_case
run_locked_dependency_policy_case
run_vendored_xcode_build_policy_case
run_executable_package_surface_policy_case
run_vendored_sherpa_dependency_policy_case
run_ci_prek_policy_case
run_shell_syntax_policy_case
run_release_artifact_hygiene_policy_case
run_release_output_staging_policy_case
run_install_quit_policy_case
run_orphaned_speech_worker_install_policy_case
run_install_staging_verification_failure_case
run_install_post_swap_rollback_case
run_install_success_case
run_install_interruption_recovery_case
run_process_enumeration_failure_case
run_first_install_concurrent_target_case
run_existing_install_concurrent_identity_case
run_preflight_toolchain_policy_case
run_preflight_evidence_policy_case
run_arm64_executable_policy_case
run_local_build_identity_case
run_notarized_output_symlink_policy_case
run_release_snapshot_case
run_release_source_revalidation_case

echo "All $PASSED release configuration tests passed."
