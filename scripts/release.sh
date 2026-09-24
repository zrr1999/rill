#!/usr/bin/env bash
#
# Rill Release Script
# 构建、签名、公证并打包 Rill.app 为 DMG
#
# 用法:
#   ./scripts/release.sh                  # 构建 + 签名 + DMG
#   ./scripts/release.sh --notarize       # 构建 + 签名 + 公证 + DMG
#   ./scripts/release.sh --install        # 增量构建 + 安装到 /Applications
#   ./scripts/release.sh --preflight      # 完整预检后构建 + 签名 + DMG
#   ./scripts/release.sh --validate-config # 仅验证发布签名配置
#   RELEASE_OUTPUT_DIR=/tmp/rill-release ./scripts/release.sh # 输出到仓库外目录
#
set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────────────
APP_NAME="Rill"
BUNDLE_ID="dev.zrr.Rill"
SPEECH_WORKER_NAME="RillSpeechWorker"
SPEECH_WORKER_IDENTIFIER="dev.zrr.Rill.SpeechWorker"
MLX_RESOURCE_BUNDLE_NAME="mlx-swift_Cmlx.bundle"

# 签名身份（Developer ID Application 用于分发，Apple Development 用于本地）
SIGN_IDENTITY_WAS_SET=false
if [[ "${SIGN_IDENTITY+x}" == "x" ]]; then
  SIGN_IDENTITY_WAS_SET=true
else
  SIGN_IDENTITY="Developer ID Application"
fi
# notarytool keychain profile 名称
NOTARY_PROFILE="${NOTARY_PROFILE-Rill}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN-}"

# 路径（统一使用 physical path，避免 Swift/Clang module cache 因符号链接路径漂移失效）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR-$PROJECT_DIR/.artifacts/release}"
APP_BUNDLE=""
DMG_PATH=""
DMG_SHA256_PATH=""
FINAL_APP_BUNDLE=""
FINAL_DMG_PATH=""
FINAL_DMG_SHA256_PATH=""
RELEASE_TEMP_DIR=""
INSTALL_STAGING_ROOT=""
ATOMIC_SWAP_HELPER=""
ATOMIC_INSTALL_HELPER=""
INSTALL_TRANSACTION_STATE="idle"
INSTALL_TRANSACTION_CANDIDATE=""
INSTALL_TRANSACTION_TARGET=""
INSTALL_TRANSACTION_OLD_IDENTITY=""
INSTALL_TRANSACTION_NEW_IDENTITY=""

# ─── 参数解析 ────────────────────────────────────────────────────
DO_NOTARIZE=false
DO_INSTALL=false
DO_VALIDATE_CONFIG=false
DO_PREFLIGHT=false
VALIDATED_RELEASE_TAG=""
VALIDATED_RELEASE_COMMIT=""
VALIDATED_RELEASE_TREE=""
VALIDATED_RELEASE_DEPENDENCY_BLOB=""
VALIDATED_RELEASE_BUILD_NUMBER=""
RESOLVED_APP_VERSION=""
RESOLVED_BUILD_KIND=""
RESOLVED_SOURCE_DIRTY="false"
RESOLVED_SOURCE_REVISION=""
RESOLVED_VERSION_LABEL=""
NOTARIZED_SNAPSHOT_ROOT=""
NOTARIZED_SNAPSHOT_DIR=""
NOTARIZED_SNAPSHOT_CAPABILITY=""
SOURCE_SNAPSHOT_CAPABILITY="${RILL_RELEASE_SOURCE_CAPABILITY-}"
unset RILL_RELEASE_SOURCE_CAPABILITY

for arg in "$@"; do
  case "$arg" in
  --notarize) DO_NOTARIZE=true ;;
  --install) DO_INSTALL=true ;;
  --preflight) DO_PREFLIGHT=true ;;
  --validate-config) DO_VALIDATE_CONFIG=true ;;
  --help | -h)
    echo "用法: $0 [--notarize] [--install] [--preflight] [--validate-config]"
    echo "  --notarize   签名后提交 Apple 公证（需要 Developer ID Application 证书）"
    echo "  --install    构建后安装到 /Applications"
    echo "  --preflight  构建前运行完整仓库检查和全量测试"
    echo "  --validate-config  仅验证签名身份和公证参数，不构建、不签名"
    echo "  RELEASE_OUTPUT_DIR  可选输出目录；默认 .artifacts/release"
    exit 0
    ;;
  *)
    echo "未知参数: $arg"
    exit 1
    ;;
  esac
done

# A notarized distribution candidate must retain the complete release gate.
# Local build/install stays incremental unless the caller opts into it.
if $DO_NOTARIZE; then
  DO_PREFLIGHT=true
fi

# ─── 辅助函数 ────────────────────────────────────────────────────
info() { echo "▸ $*"; }
error() {
  echo "✗ $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || error "未找到发布所需命令: $1"
}

validate_project_worktree_alignment() {
  local repository_root=""

  repository_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || error "无法解析发布源码目录对应的 Git 工作树"
  repository_root="$(cd "$repository_root" && pwd -P)"
  if [[ "$repository_root" != "$PROJECT_DIR" ]]; then
    error \
      "发布脚本目录与 Git 工作树不一致：脚本=${PROJECT_DIR}，工作树=${repository_root}。" \
      "请从工作树目录运行 ./scripts/release.sh，避免旧源码覆盖已安装应用"
  fi
}

validate_release_output_location() {
  local candidate="$1"

  if [[ "$candidate" != /* ]]; then
    candidate="$PROJECT_DIR/$candidate"
  fi

  case "/$candidate/" in
  */../* | */./*)
    error "RELEASE_OUTPUT_DIR 不能包含 . 或 .. 路径段"
    ;;
  esac

  case "$candidate" in
  "$PROJECT_DIR" | "$PROJECT_DIR/")
    error "发布输出拒绝仓库根目录；请使用默认 .artifacts/release 或仓库外目录"
    ;;
  "$PROJECT_DIR/"*)
    case "$candidate" in
    "$PROJECT_DIR/.artifacts" | "$PROJECT_DIR/.artifacts/"*) ;;
    *)
      error "仓库内发布输出必须位于 .artifacts/ 下；也可使用仓库外目录"
      ;;
    esac
    ;;
  esac
}

resolve_release_output_location() {
  local candidate="$1"
  local component=""
  local existing_ancestor=""
  local physical_ancestor=""
  local suffix=""

  if [[ "$candidate" != /* ]]; then
    candidate="$PROJECT_DIR/$candidate"
  fi
  while [[ "$candidate" != "/" && "$candidate" == */ ]]; do
    candidate="${candidate%/}"
  done
  validate_release_output_location "$candidate"

  existing_ancestor="$candidate"
  while [[ ! -e "$existing_ancestor" && ! -L "$existing_ancestor" ]]; do
    component="${existing_ancestor##*/}"
    [[ -n "$component" ]] || error "无法解析 RELEASE_OUTPUT_DIR 的现有父目录"
    suffix="/$component$suffix"
    existing_ancestor="${existing_ancestor%/*}"
    [[ -n "$existing_ancestor" ]] || existing_ancestor="/"
  done
  [[ -d "$existing_ancestor" ]] \
    || error "RELEASE_OUTPUT_DIR 的现有父路径不是目录或链接无效"
  physical_ancestor="$(cd "$existing_ancestor" && pwd -P)"
  candidate="$physical_ancestor$suffix"
  validate_release_output_location "$candidate"
  printf '%s\n' "$candidate"
}

RUNNING_RILL_PIDS=()

running_rill_pids() {
  local process_listing=""

  process_listing="$(ps axww -o pid= -o comm=)" || return $?
  awk \
    -v app_suffix="/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
    -v worker_suffix="/$APP_NAME.app/Contents/Helpers/$SPEECH_WORKER_NAME" \
    '{
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ((length($0) >= length(app_suffix) \
          && substr($0, length($0) - length(app_suffix) + 1) == app_suffix) \
        || (length($0) >= length(worker_suffix) \
          && substr($0, length($0) - length(worker_suffix) + 1) == worker_suffix)) {
        print pid
      }
    }' \
    <<<"$process_listing"
}

refresh_running_rill_pids() {
  local pid
  local pid_listing=""

  RUNNING_RILL_PIDS=()
  pid_listing="$(running_rill_pids)" || return $?
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    RUNNING_RILL_PIDS+=("$pid")
  done <<<"$pid_listing"
}

wait_for_rill_exit() {
  # ApplicationTerminationCoordinator reports a slow-shutdown state after 15
  # seconds but continues draining durable state. The installer has its own
  # bounded wait and fails closed if either the app or supervised worker remains.
  local attempts="${1:-80}"
  local delay="${2:-0.25}"

  for ((i = 0; i < attempts; i++)); do
    refresh_running_rill_pids || return 2
    if [[ "${#RUNNING_RILL_PIDS[@]}" -eq 0 ]]; then
      return 0
    fi
    sleep "$delay"
  done

  refresh_running_rill_pids || return 2
  [[ "${#RUNNING_RILL_PIDS[@]}" -eq 0 ]]
}

quit_running_rill_if_needed() {
  local wait_status=0

  if ! refresh_running_rill_pids; then
    error "无法可靠枚举正在运行的 Rill 进程；已取消安装"
  fi
  if [[ "${#RUNNING_RILL_PIDS[@]}" -eq 0 ]]; then
    return 0
  fi

  info "检测到正在运行的 Rill，正在请求退出..."
  osascript -e 'tell application id "dev.zrr.Rill" to quit' >/dev/null 2>&1 || true

  if wait_for_rill_exit; then
    info "已退出旧版 Rill 进程"
    return 0
  else
    wait_status=$?
  fi
  if [[ "$wait_status" -eq 2 ]]; then
    error "等待 Rill 安全退出时无法可靠枚举进程；已取消安装"
  fi

  error "Rill 未能在安全退出期限内完成数据落盘；已取消安装，且未强制终止进程。请等待或手动退出后重试"
}

build_atomic_swap_helper() {
  local source="$RELEASE_TEMP_DIR/rill-atomic-swap.c"
  local install_source="$RELEASE_TEMP_DIR/rill-atomic-install.c"

  ATOMIC_SWAP_HELPER="$RELEASE_TEMP_DIR/rill-atomic-swap"
  ATOMIC_INSTALL_HELPER="$RELEASE_TEMP_DIR/rill-atomic-install"
  cat >"$source" <<'C_SOURCE'
#include <stdio.h>
#include <sys/stdio.h>

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fputs("usage: rill-atomic-swap LEFT RIGHT\n", stderr);
    return 64;
  }
  if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
    perror("renamex_np(RENAME_SWAP)");
    return 1;
  }
  return 0;
}
C_SOURCE
  cat >"$install_source" <<'C_SOURCE'
#include <stdio.h>
#include <sys/stdio.h>

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fputs("usage: rill-atomic-install SOURCE TARGET\n", stderr);
    return 64;
  }
  if (renamex_np(argv[1], argv[2], RENAME_EXCL) != 0) {
    perror("renamex_np(RENAME_EXCL)");
    return 1;
  }
  return 0;
}
C_SOURCE

  if ! xcrun --sdk macosx clang \
    -std=c11 -Wall -Wextra -Werror -O2 \
    "$source" -o "$ATOMIC_SWAP_HELPER"; then
    error "无法构建安装所需的原子替换辅助程序"
  fi
  if ! xcrun --sdk macosx clang \
    -std=c11 -Wall -Wextra -Werror -O2 \
    "$install_source" -o "$ATOMIC_INSTALL_HELPER"; then
    error "无法构建首次安装所需的原子发布辅助程序"
  fi
}

install_path_identity() {
  local path="$1"

  [[ -e "$path" && ! -L "$path" ]] || return 1
  stat -f '%d:%i' "$path"
}

reset_install_transaction() {
  INSTALL_TRANSACTION_STATE="idle"
  INSTALL_TRANSACTION_CANDIDATE=""
  INSTALL_TRANSACTION_TARGET=""
  INSTALL_TRANSACTION_OLD_IDENTITY=""
  INSTALL_TRANSACTION_NEW_IDENTITY=""
}

preserve_install_recovery_staging() {
  INSTALL_TRANSACTION_STATE="recovery-required"
  echo \
    "✗ 无法证明安装事务已安全回滚；保留 recovery staging: $INSTALL_STAGING_ROOT" \
    >&2
}

install_existing_coordinates_are_original() {
  local candidate_identity=""
  local target_identity=""

  candidate_identity="$(install_path_identity "$INSTALL_TRANSACTION_CANDIDATE")" \
    || return 1
  target_identity="$(install_path_identity "$INSTALL_TRANSACTION_TARGET")" \
    || return 1
  [[ "$candidate_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" \
    && "$target_identity" == "$INSTALL_TRANSACTION_OLD_IDENTITY" ]]
}

install_existing_coordinates_are_swapped() {
  local candidate_identity=""
  local target_identity=""

  candidate_identity="$(install_path_identity "$INSTALL_TRANSACTION_CANDIDATE")" \
    || return 1
  target_identity="$(install_path_identity "$INSTALL_TRANSACTION_TARGET")" \
    || return 1
  [[ "$candidate_identity" == "$INSTALL_TRANSACTION_OLD_IDENTITY" \
    && "$target_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]
}

rollback_install_transaction_if_needed() {
  local candidate_identity=""
  local target_identity=""

  case "$INSTALL_TRANSACTION_STATE" in
  idle | committed | rolled-back)
    return 0
    ;;
  recovery-required)
    return 1
    ;;
  prepared-existing)
    candidate_identity="$(
      install_path_identity "$INSTALL_TRANSACTION_CANDIDATE" 2>/dev/null || true
    )"
    target_identity="$(
      install_path_identity "$INSTALL_TRANSACTION_TARGET" 2>/dev/null || true
    )"
    if [[ "$candidate_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" \
      && "$target_identity" == "$INSTALL_TRANSACTION_OLD_IDENTITY" ]]; then
      INSTALL_TRANSACTION_STATE="rolled-back"
      return 0
    fi
    # If another installer replaced the old target between our identity read
    # and the atomic swap, candidate_identity is that concurrent target rather
    # than INSTALL_TRANSACTION_OLD_IDENTITY. As long as target still has our
    # exact candidate identity, swapping the pair back restores the true
    # pre-swap coordinates without guessing which installer owned them.
    if [[ -n "$candidate_identity" \
      && "$candidate_identity" != "$INSTALL_TRANSACTION_NEW_IDENTITY" \
      && "$target_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
      if "$ATOMIC_SWAP_HELPER" \
        "$INSTALL_TRANSACTION_CANDIDATE" \
        "$INSTALL_TRANSACTION_TARGET" \
        && [[ "$(
          install_path_identity "$INSTALL_TRANSACTION_CANDIDATE" 2>/dev/null || true
        )" == "$INSTALL_TRANSACTION_NEW_IDENTITY" ]] \
        && [[ "$(
          install_path_identity "$INSTALL_TRANSACTION_TARGET" 2>/dev/null || true
        )" == "$candidate_identity" ]]; then
        INSTALL_TRANSACTION_STATE="rolled-back"
        return 0
      fi
    fi
    preserve_install_recovery_staging
    return 1
    ;;
  prepared-first)
    candidate_identity="$(
      install_path_identity "$INSTALL_TRANSACTION_CANDIDATE" 2>/dev/null || true
    )"
    target_identity="$(
      install_path_identity "$INSTALL_TRANSACTION_TARGET" 2>/dev/null || true
    )"
    if [[ "$candidate_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" \
      && "$target_identity" != "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
      INSTALL_TRANSACTION_STATE="rolled-back"
      return 0
    fi
    if [[ -z "$candidate_identity" \
      && "$target_identity" == "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
      if "$ATOMIC_INSTALL_HELPER" \
        "$INSTALL_TRANSACTION_TARGET" \
        "$INSTALL_TRANSACTION_CANDIDATE" \
        && [[ ! -e "$INSTALL_TRANSACTION_TARGET" ]] \
        && [[ "$(
          install_path_identity "$INSTALL_TRANSACTION_CANDIDATE" 2>/dev/null || true
        )" == "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
        INSTALL_TRANSACTION_STATE="rolled-back"
        return 0
      fi
    fi
    preserve_install_recovery_staging
    return 1
    ;;
  *)
    preserve_install_recovery_staging
    return 1
    ;;
  esac
}

verify_install_candidate() {
  local candidate="$1"

  codesign --verify --deep --strict --verbose=2 "$candidate" || return 1
  if $DO_NOTARIZE; then
    xcrun stapler validate "$candidate" || return 1
    spctl --assess --type execute --verbose=4 "$candidate" || return 1
  fi
}

install_verified_app() {
  local source_app="$1"
  local target_app="$2"
  local applications_dir="${target_app%/*}"
  local candidate_app=""
  local target_identity=""
  local had_existing_app=false

  [[ "$target_app" == /* && "$applications_dir" != "$target_app" ]] \
    || error "安装目标必须是绝对 App 路径"
  [[ -d "$source_app" && ! -L "$source_app" ]] \
    || error "已验证 App 安装源无效"
  [[ -d "$applications_dir" && ! -L "$applications_dir" ]] \
    || error "安装目标目录无效或为符号链接: $applications_dir"
  [[ ! -L "$target_app" ]] \
    || error "拒绝替换符号链接安装目标: $target_app"
  if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" ]] || error "安装目标存在但不是 App 目录: $target_app"
    had_existing_app=true
  fi

  INSTALL_STAGING_ROOT="$(mktemp -d "$applications_dir/.rill-install.XXXXXX")" \
    || error "无法在安装目标卷创建私有 staging 目录"
  candidate_app="$INSTALL_STAGING_ROOT/$APP_NAME.app"

  if ! ditto "$source_app" "$candidate_app"; then
    error "无法将已验证 App 复制到安装 staging"
  fi
  if ! verify_install_candidate "$candidate_app"; then
    error "安装 staging 中的 App 验证失败；旧版保持不变"
  fi

  build_atomic_swap_helper
  INSTALL_TRANSACTION_CANDIDATE="$candidate_app"
  INSTALL_TRANSACTION_TARGET="$target_app"
  INSTALL_TRANSACTION_NEW_IDENTITY="$(install_path_identity "$candidate_app")" \
    || error "无法记录安装候选 App 的文件身份"

  if $had_existing_app; then
    INSTALL_TRANSACTION_OLD_IDENTITY="$(install_path_identity "$target_app")" \
      || error "无法记录旧版 App 的文件身份"
    INSTALL_TRANSACTION_STATE="prepared-existing"
    if ! "$ATOMIC_SWAP_HELPER" "$candidate_app" "$target_app"; then
      error "无法原子替换已安装 App；旧版保持不变"
    fi
    if ! install_existing_coordinates_are_swapped; then
      if rollback_install_transaction_if_needed; then
        error "安装目标在原子替换期间发生并发变化；已恢复原坐标"
      fi
      error "安装目标在原子替换期间发生并发变化；已保留 recovery staging"
    fi
  else
    INSTALL_TRANSACTION_STATE="prepared-first"
    if ! "$ATOMIC_INSTALL_HELPER" "$candidate_app" "$target_app"; then
      error "无法以排他原子操作发布首次安装的 App；目标可能已由其他安装创建"
    fi
    target_identity="$(install_path_identity "$target_app" 2>/dev/null || true)"
    if [[ -e "$candidate_app" \
      || "$target_identity" != "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
      if rollback_install_transaction_if_needed; then
        error "首次安装发布后的文件身份不一致；已撤销本次安装"
      fi
      error "首次安装发布后的文件身份不一致；已保留 recovery staging"
    fi
  fi

  if ! verify_install_candidate "$target_app"; then
    if rollback_install_transaction_if_needed; then
      if $had_existing_app; then
        error "安装后验证失败；已原子恢复旧版 App"
      fi
      error "首次安装验证失败；已撤销本次安装"
    fi
    error "安装后验证失败且无法证明安全回滚；已保留 recovery staging"
  fi

  if $had_existing_app; then
    if ! install_existing_coordinates_are_swapped; then
      if rollback_install_transaction_if_needed; then
        error "安装后文件身份发生并发变化；已原子恢复旧版 App"
      fi
      error "安装后文件身份发生并发变化；已保留 recovery staging"
    fi
  else
    target_identity="$(install_path_identity "$target_app" 2>/dev/null || true)"
    if [[ -e "$candidate_app" \
      || "$target_identity" != "$INSTALL_TRANSACTION_NEW_IDENTITY" ]]; then
      if rollback_install_transaction_if_needed; then
        error "首次安装验证后文件身份发生并发变化；已撤销本次安装"
      fi
      error "首次安装验证后文件身份发生并发变化；已保留 recovery staging"
    fi
  fi

  INSTALL_TRANSACTION_STATE="committed"
  rm -rf "$INSTALL_STAGING_ROOT"
  INSTALL_STAGING_ROOT=""
  reset_install_transaction
}

is_release_version_tag() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

require_clean_release_index() {
  local listing=""
  local line=""
  local tag=""

  if ! listing="$(git -C "$PROJECT_DIR" ls-files -v)"; then
    error "无法检查公证发布的 Git index flags"
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    tag="${line:0:1}"
    case "$tag" in
    [[:lower:]] | S)
      error "公证发布拒绝 assume-unchanged、skip-worktree 或 sparse checkout 条目"
      ;;
    esac
  done <<<"$listing"
}

read_release_source_coordinate() {
  local revision="$1"
  local label="$2"
  local value=""

  if ! value="$(git -C "$PROJECT_DIR" rev-parse "$revision")"; then
    error "无法读取公证发布的 $label"
  fi
  [[ "$value" =~ ^[[:xdigit:]]{40,64}$ ]] || error "公证发布的 $label 无效"
  printf '%s\n' "$value"
}

require_clean_release_worktree() {
  local status_output=""

  if ! status_output="$(
    git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=normal
  )"; then
    error "无法验证公证发布的 Git 工作树状态"
  fi
  [[ -z "$status_output" ]] \
    || error "公证发布要求干净的 Git 工作树（包括未跟踪文件）"
  require_clean_release_index
}

validate_notarized_release_source() {
  local pointed_tags=""
  local tag=""
  local dependency_manifest="scripts/third_party_notices_manifest.json"
  local worktree_dependency_blob=""
  local release_tags=()

  require_command git
  git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || error "公证发布必须从有效的 Git 工作树执行"
  [[ -f "$PROJECT_DIR/$dependency_manifest" ]] \
    || error "公证发布缺少第三方依赖清单"
  git -C "$PROJECT_DIR" ls-files --error-unmatch "$dependency_manifest" >/dev/null 2>&1 \
    || error "公证发布要求第三方依赖清单已纳入版本控制"
  require_clean_release_worktree

  VALIDATED_RELEASE_COMMIT="$(read_release_source_coordinate 'HEAD^{commit}' 'Git commit')"
  VALIDATED_RELEASE_TREE="$(read_release_source_coordinate 'HEAD^{tree}' 'Git tree')"
  VALIDATED_RELEASE_DEPENDENCY_BLOB="$(
    read_release_source_coordinate \
      "HEAD:$dependency_manifest" \
      'third-party dependency manifest blob'
  )"
  if ! worktree_dependency_blob="$(
    git -C "$PROJECT_DIR" hash-object "$dependency_manifest"
  )"; then
    error "无法验证工作树中的第三方依赖清单"
  fi
  [[ "$worktree_dependency_blob" == "$VALIDATED_RELEASE_DEPENDENCY_BLOB" ]] \
    || error "工作树中的第三方依赖清单与已验证 commit 不一致"

  if ! pointed_tags="$(git -C "$PROJECT_DIR" tag --points-at HEAD)"; then
    error "无法读取公证发布的 HEAD 标签"
  fi
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    if is_release_version_tag "$tag"; then
      release_tags+=("$tag")
    fi
  done <<<"$pointed_tags"

  if [[ "${#release_tags[@]}" -eq 0 ]]; then
    error "公证发布要求 HEAD 精确标记一个 vMAJOR.MINOR.PATCH 标签"
  fi
  if [[ "${#release_tags[@]}" -gt 1 ]]; then
    error "公证发布的 HEAD 存在多个版本标签，无法确定唯一版本"
  fi

  VALIDATED_RELEASE_TAG="${release_tags[0]}"
  if ! VALIDATED_RELEASE_BUILD_NUMBER="$(
    git -C "$PROJECT_DIR" rev-list --count "$VALIDATED_RELEASE_COMMIT"
  )"; then
    error "无法从 Git 历史生成公证发布构建号"
  fi
  [[ "$VALIDATED_RELEASE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || error "无法从 Git 历史生成有效的公证发布构建号"

  if [[ -n "$SOURCE_SNAPSHOT_CAPABILITY" ]]; then
    validate_and_consume_snapshot_capability "$SOURCE_SNAPSHOT_CAPABILITY"
  fi

  info "发布来源: $VALIDATED_RELEASE_TAG @ ${VALIDATED_RELEASE_COMMIT:0:12}"
}

validate_and_consume_snapshot_capability() {
  local capability="$1"
  local capability_parent=""
  local mode=""
  local content=""
  local expected=""

  [[ "$capability" == /* && -f "$capability" && ! -L "$capability" ]] \
    || error "公证发布快照 capability 缺失或不安全"
  capability_parent="$(cd "$(dirname "$capability")" && pwd -P)"
  [[ "$PROJECT_DIR" == "$capability_parent/source" && -f "$PROJECT_DIR/.git" ]] \
    || error "公证发布 capability 与 detached linked worktree 不匹配"
  if ! mode="$(stat -f '%Lp' "$capability")"; then
    error "无法读取公证发布快照 capability 权限"
  fi
  [[ "$mode" == "600" ]] || error "公证发布快照 capability 权限必须为 600"
  if ! content="$(<"$capability")"; then
    error "无法读取公证发布快照 capability"
  fi
  expected="$(printf '%s\n%s\n%s\n%s\n%s' \
    "$PROJECT_DIR" \
    "$VALIDATED_RELEASE_COMMIT" \
    "$VALIDATED_RELEASE_TREE" \
    "$VALIDATED_RELEASE_DEPENDENCY_BLOB" \
    "$RELEASE_OUTPUT_DIR")"
  [[ "$content" == "$expected" ]] \
    || error "公证发布快照 capability 与已验证来源不一致"
  rm -f "$capability"
  [[ ! -e "$capability" ]] || error "无法消费公证发布快照 capability"
}

revalidate_notarized_release_source() {
  local phase="$1"
  local commit=""
  local dependency_manifest="scripts/third_party_notices_manifest.json"
  local dependency_blob=""
  local tree=""
  local worktree_dependency_blob=""

  $DO_NOTARIZE || return 0
  require_clean_release_worktree
  commit="$(read_release_source_coordinate 'HEAD^{commit}' 'Git commit')"
  tree="$(read_release_source_coordinate 'HEAD^{tree}' 'Git tree')"
  dependency_blob="$(
    read_release_source_coordinate \
      "HEAD:$dependency_manifest" \
      'third-party dependency manifest blob'
  )"
  if ! worktree_dependency_blob="$(
    git -C "$PROJECT_DIR" hash-object "$dependency_manifest"
  )"; then
    error "无法重新验证工作树中的第三方依赖清单"
  fi
  [[ "$commit" == "$VALIDATED_RELEASE_COMMIT" ]] \
    || error "公证发布来源在${phase}发生 commit 漂移"
  [[ "$tree" == "$VALIDATED_RELEASE_TREE" ]] \
    || error "公证发布来源在${phase}发生 tree 漂移"
  [[ "$dependency_blob" == "$VALIDATED_RELEASE_DEPENDENCY_BLOB" \
    && "$worktree_dependency_blob" == "$VALIDATED_RELEASE_DEPENDENCY_BLOB" ]] \
    || error "公证发布来源在${phase}发生第三方依赖清单漂移"
  info "发布来源复核通过（${phase}）"
}

cleanup_notarized_snapshot() {
  if [[ -n "$NOTARIZED_SNAPSHOT_DIR" ]]; then
    git -C "$PROJECT_DIR" worktree remove --force "$NOTARIZED_SNAPSHOT_DIR" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$NOTARIZED_SNAPSHOT_ROOT" ]]; then
    rm -rf "$NOTARIZED_SNAPSHOT_ROOT"
  fi
  NOTARIZED_SNAPSHOT_DIR=""
  NOTARIZED_SNAPSHOT_ROOT=""
  NOTARIZED_SNAPSHOT_CAPABILITY=""
}

run_notarized_release_from_snapshot() {
  local output_dir="$RELEASE_OUTPUT_DIR"
  local exit_code=0

  case "$output_dir" in
  /*) ;;
  *) output_dir="$PROJECT_DIR/$output_dir" ;;
  esac

  NOTARIZED_SNAPSHOT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rill-source-snapshot.XXXXXX")"
  NOTARIZED_SNAPSHOT_ROOT="$(cd "$NOTARIZED_SNAPSHOT_ROOT" && pwd -P)"
  NOTARIZED_SNAPSHOT_DIR="$NOTARIZED_SNAPSHOT_ROOT/source"
  trap cleanup_notarized_snapshot EXIT
  trap 'exit 130' INT TERM

  info "创建隔离的公证发布源码快照..."
  git -c core.hooksPath=/dev/null -C "$PROJECT_DIR" worktree add \
    --detach "$NOTARIZED_SNAPSHOT_DIR" "$VALIDATED_RELEASE_COMMIT" >/dev/null 2>&1
  [[ -x "$NOTARIZED_SNAPSHOT_DIR/scripts/release.sh" ]] \
    || error "公证发布快照缺少可执行 release.sh"
  NOTARIZED_SNAPSHOT_CAPABILITY="$(
    mktemp "$NOTARIZED_SNAPSHOT_ROOT/capability.XXXXXX"
  )"
  chmod 600 "$NOTARIZED_SNAPSHOT_CAPABILITY"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$NOTARIZED_SNAPSHOT_DIR" \
    "$VALIDATED_RELEASE_COMMIT" \
    "$VALIDATED_RELEASE_TREE" \
    "$VALIDATED_RELEASE_DEPENDENCY_BLOB" \
    "$output_dir" >"$NOTARIZED_SNAPSHOT_CAPABILITY"

  set +e
  env \
    RILL_RELEASE_SOURCE_CAPABILITY="$NOTARIZED_SNAPSHOT_CAPABILITY" \
    RELEASE_OUTPUT_DIR="$output_dir" \
    SIGN_IDENTITY="$SIGN_IDENTITY" \
    NOTARY_PROFILE="$NOTARY_PROFILE" \
    NOTARY_KEYCHAIN="$NOTARY_KEYCHAIN" \
    bash "$NOTARIZED_SNAPSHOT_DIR/scripts/release.sh" "$@"
  exit_code=$?
  set -e

  cleanup_notarized_snapshot
  trap - EXIT INT TERM
  exit "$exit_code"
}

resolve_build_identity() {
  local pointed_tags=""
  local short_revision=""
  local status_output=""
  local tag=""
  local release_tags=()

  RESOLVED_SOURCE_DIRTY="false"
  if $DO_NOTARIZE; then
    [[ -n "$VALIDATED_RELEASE_TAG" ]] || error "公证发布版本尚未通过来源验证"
    [[ -n "$VALIDATED_RELEASE_COMMIT" ]] || error "公证发布 commit 尚未通过来源验证"
    RESOLVED_APP_VERSION="${VALIDATED_RELEASE_TAG#v}"
    RESOLVED_BUILD_KIND="notarized"
    RESOLVED_SOURCE_REVISION="$VALIDATED_RELEASE_COMMIT"
    RESOLVED_VERSION_LABEL="$RESOLVED_APP_VERSION"
    return 0
  fi

  if ! RESOLVED_SOURCE_REVISION="$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{commit}')"; then
    error "无法读取本地构建的 Git commit"
  fi
  [[ "$RESOLVED_SOURCE_REVISION" =~ ^[[:xdigit:]]{40,64}$ ]] \
    || error "本地构建的 Git commit 无效"
  if ! status_output="$(
    git -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=normal
  )"; then
    error "无法读取本地构建的 Git 工作树状态"
  fi
  if [[ -n "$status_output" ]]; then
    RESOLVED_SOURCE_DIRTY="true"
  fi
  if ! pointed_tags="$(git -C "$PROJECT_DIR" tag --points-at HEAD)"; then
    error "无法读取本地构建的 HEAD 标签"
  fi
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    if is_release_version_tag "$tag"; then
      release_tags+=("$tag")
    fi
  done <<<"$pointed_tags"

  if [[ "${#release_tags[@]}" -eq 1 && "$RESOLVED_SOURCE_DIRTY" == "false" ]]; then
    RESOLVED_APP_VERSION="${release_tags[0]#v}"
    RESOLVED_BUILD_KIND="tagged"
    RESOLVED_VERSION_LABEL="$RESOLVED_APP_VERSION"
    return 0
  fi

  short_revision="${RESOLVED_SOURCE_REVISION:0:12}"
  RESOLVED_APP_VERSION="0.0.0"
  RESOLVED_BUILD_KIND="development"
  RESOLVED_VERSION_LABEL="0.0.0-dev+$short_revision"
  if [[ "$RESOLVED_SOURCE_DIRTY" == "true" ]]; then
    RESOLVED_VERSION_LABEL+=".dirty"
  fi
}

get_build_number() {
  local build_number=""

  if $DO_NOTARIZE; then
    [[ "$VALIDATED_RELEASE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
      || error "公证发布构建号尚未通过来源验证"
    echo "$VALIDATED_RELEASE_BUILD_NUMBER"
    return 0
  fi

  build_number="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || true)"
  if [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "$build_number"
    return 0
  fi
  echo "1"
}

AVAILABLE_IDENTITY_HASHES=()
AVAILABLE_IDENTITY_NAMES=()
MATCHING_IDENTITY_INDEXES=()
RESOLVED_SIGN_IDENTITY=""
RESOLVED_SIGN_IDENTITY_HASH=""
RESOLVED_SIGN_IDENTITY_NAME=""

load_code_signing_identities() {
  local identity_output=""
  local line=""

  command -v security >/dev/null 2>&1 || error "未找到 security，无法检查代码签名身份"
  if ! identity_output="$(security find-identity -v -p codesigning 2>&1)"; then
    error "无法读取代码签名身份，请检查 Keychain 访问权限"
  fi

  AVAILABLE_IDENTITY_HASHES=()
  AVAILABLE_IDENTITY_NAMES=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+\"([^\"]+)\" ]]; then
      AVAILABLE_IDENTITY_HASHES+=("${BASH_REMATCH[1]}")
      AVAILABLE_IDENTITY_NAMES+=("${BASH_REMATCH[2]}")
    fi
  done <<<"$identity_output"
}

identity_matches_request() {
  local identity_hash="$1"
  local identity_name="$2"
  local requested="$3"
  local normalized_hash=""
  local normalized_requested=""

  normalized_hash="$(printf '%s' "$identity_hash" | tr '[:lower:]' '[:upper:]')"
  normalized_requested="$(printf '%s' "$requested" | tr '[:lower:]' '[:upper:]')"
  if [[ "$normalized_hash" == "$normalized_requested" || "$identity_name" == "$requested" ]]; then
    return 0
  fi

  case "$requested" in
  "Developer ID Application") [[ "$identity_name" == "Developer ID Application: "* ]] ;;
  "Apple Development") [[ "$identity_name" == "Apple Development: "* ]] ;;
  *) return 1 ;;
  esac
}

find_matching_identity_indexes() {
  local requested="$1"
  local index=0

  MATCHING_IDENTITY_INDEXES=()
  for ((index = 0; index < ${#AVAILABLE_IDENTITY_HASHES[@]}; index++)); do
    if identity_matches_request \
      "${AVAILABLE_IDENTITY_HASHES[$index]}" \
      "${AVAILABLE_IDENTITY_NAMES[$index]}" \
      "$requested"; then
      MATCHING_IDENTITY_INDEXES+=("$index")
    fi
  done
}

select_unique_signing_identity() {
  local requested="$1"
  local index=0

  find_matching_identity_indexes "$requested"
  if [[ "${#MATCHING_IDENTITY_INDEXES[@]}" -eq 0 ]]; then
    return 1
  fi
  if [[ "${#MATCHING_IDENTITY_INDEXES[@]}" -gt 1 ]]; then
    error "签名身份 '$requested' 匹配到多个证书；请将 SIGN_IDENTITY 设置为完整证书名称或 SHA-1 哈希"
  fi

  index="${MATCHING_IDENTITY_INDEXES[0]}"
  RESOLVED_SIGN_IDENTITY_HASH="${AVAILABLE_IDENTITY_HASHES[$index]}"
  RESOLVED_SIGN_IDENTITY_NAME="${AVAILABLE_IDENTITY_NAMES[$index]}"
  RESOLVED_SIGN_IDENTITY="$RESOLVED_SIGN_IDENTITY_HASH"
}

is_developer_id_application_identity() {
  [[ "$1" == "Developer ID Application: "* ]]
}

validate_release_configuration() {
  local requested_identity="$SIGN_IDENTITY"

  if [[ -n "${RILL_RELEASE_SOURCE_SNAPSHOT-}" \
    || -n "${RILL_RELEASE_SOURCE_COMMIT-}" ]]; then
    error "RILL_RELEASE_SOURCE_SNAPSHOT/COMMIT 是保留的内部变量，不能由调用方设置"
  fi
  if ! $DO_NOTARIZE && [[ -n "$SOURCE_SNAPSHOT_CAPABILITY" ]]; then
    error "公证发布快照 capability 只能用于 --notarize"
  fi
  [[ -n "${RELEASE_OUTPUT_DIR:-}" ]] || error "RELEASE_OUTPUT_DIR 不能为空"
  if [[ "$RELEASE_OUTPUT_DIR" == *$'\n'* || "$RELEASE_OUTPUT_DIR" == *$'\r'* ]]; then
    error "RELEASE_OUTPUT_DIR 不能包含换行符"
  fi
  RELEASE_OUTPUT_DIR="$(resolve_release_output_location "$RELEASE_OUTPUT_DIR")"
  case "$RELEASE_OUTPUT_DIR" in
  "/Applications" | "/Applications/$APP_NAME.app" | "/Applications/$APP_NAME.app/"*)
    error "RELEASE_OUTPUT_DIR 不能与安装目标 /Applications/$APP_NAME.app 重合"
    ;;
  esac
  if $SIGN_IDENTITY_WAS_SET && [[ -z "${SIGN_IDENTITY:-}" ]]; then
    error "SIGN_IDENTITY 不能为空"
  fi
  if [[ "$requested_identity" == *$'\n'* || "$requested_identity" == *$'\r'* ]]; then
    error "SIGN_IDENTITY 不能包含换行符"
  fi
  if $DO_NOTARIZE; then
    [[ -n "${NOTARY_PROFILE:-}" ]] || error "--notarize 需要非空的 NOTARY_PROFILE"
    if [[ "$NOTARY_PROFILE" == *$'\n'* || "$NOTARY_PROFILE" == *$'\r'* ]]; then
      error "NOTARY_PROFILE 不能包含换行符"
    fi
    if [[ -n "$NOTARY_KEYCHAIN" ]]; then
      [[ "$NOTARY_KEYCHAIN" == /* && -f "$NOTARY_KEYCHAIN" ]] || \
        error "NOTARY_KEYCHAIN 必须指向现有的绝对 Keychain 文件路径"
    fi
    validate_notarized_release_source
  fi

  load_code_signing_identities
  if ! select_unique_signing_identity "$requested_identity"; then
    if $DO_NOTARIZE; then
      error "公证发布需要可用的 Developer ID Application 身份；未找到 '$requested_identity'"
    fi
    if $SIGN_IDENTITY_WAS_SET; then
      error "未找到指定的签名身份 '$requested_identity'"
    fi

    info "未找到默认 Developer ID Application 身份，尝试本地 Apple Development 身份..."
    if ! select_unique_signing_identity "Apple Development"; then
      error "未找到可用的 Developer ID Application 或 Apple Development 签名身份"
    fi
    info "⚠ 使用 $RESOLVED_SIGN_IDENTITY_NAME 签名（仅适用于本地构建，不支持公证）"
  fi

  if $DO_NOTARIZE && ! is_developer_id_application_identity "$RESOLVED_SIGN_IDENTITY_NAME"; then
    error "公证发布只能使用 Developer ID Application；当前身份为 '$RESOLVED_SIGN_IDENTITY_NAME'"
  fi

  require_command codesign
  require_command ditto
  require_command plutil
  require_command shasum
  if $DO_INSTALL; then
    require_command open
    require_command osascript
    require_command stat
    require_command xcrun
    xcrun --find clang >/dev/null 2>&1 || error "当前 Xcode toolchain 不包含 clang"
  else
    require_command hdiutil
  fi
  if $DO_NOTARIZE; then
    require_command spctl
    require_command xcrun
    xcrun --find notarytool >/dev/null 2>&1 || error "当前 Xcode toolchain 不包含 notarytool"
    xcrun --find stapler >/dev/null 2>&1 || error "当前 Xcode toolchain 不包含 stapler"
  fi

  info "签名身份: $RESOLVED_SIGN_IDENTITY_NAME"
  info "证书 SHA-1: $RESOLVED_SIGN_IDENTITY_HASH"
  if $DO_NOTARIZE; then
    info "公证配置: Developer ID Application + Keychain profile '$NOTARY_PROFILE'"
  else
    info "发布模式: 本地签名（未请求公证）"
  fi
}

signature_detail_value() {
  local details="$1"
  local key="$2"
  printf '%s\n' "$details" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

plist_literal_keypath() {
  local key="$1"

  # plutil interprets periods as key-path separators. Entitlement names use
  # periods as literal characters, so each one must be escaped before lookup.
  printf '%s\n' "${key//./\\.}"
}

plist_extract_literal_raw() {
  local key="$1"
  local plist="$2"

  plutil -extract "$(plist_literal_keypath "$key")" raw -o - "$plist"
}

verify_signed_speech_worker() {
  local speech_worker="$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_NAME"
  local signature_details=""
  local signed_identifier=""
  local signed_authority=""
  local team_identifier=""
  local timestamp=""
  local signed_entitlements="$RELEASE_TEMP_DIR/speech-worker-entitlements.plist"
  local forbidden_entitlement=""
  local forbidden_entitlement_value=""

  [[ -x "$speech_worker" ]] || error "语音识别辅助进程不存在或不可执行"
  codesign --verify --strict --verbose=2 "$speech_worker"
  if ! signature_details="$(codesign -d --verbose=4 "$speech_worker" 2>&1)"; then
    error "无法读取语音识别辅助进程的签名详情"
  fi

  signed_identifier="$(signature_detail_value "$signature_details" "Identifier")"
  signed_authority="$(signature_detail_value "$signature_details" "Authority")"
  team_identifier="$(signature_detail_value "$signature_details" "TeamIdentifier")"
  timestamp="$(signature_detail_value "$signature_details" "Timestamp")"

  [[ "$signed_identifier" == "$SPEECH_WORKER_IDENTIFIER" ]] \
    || error "语音识别辅助进程签名标识不匹配：期望 '$SPEECH_WORKER_IDENTIFIER'，实际 '$signed_identifier'"
  [[ "$signed_authority" == "$RESOLVED_SIGN_IDENTITY_NAME" ]] \
    || error "语音识别辅助进程签名证书不匹配：期望 '$RESOLVED_SIGN_IDENTITY_NAME'，实际 '$signed_authority'"
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] \
    || error "语音识别辅助进程签名缺少有效 TeamIdentifier"
  [[ -n "$timestamp" ]] || error "语音识别辅助进程签名缺少可信时间戳"
  if ! printf '%s\n' "$signature_details" \
    | grep -Eq '^CodeDirectory .*flags=.*\([^)]*runtime[^)]*\)'; then
    error "语音识别辅助进程签名未启用 hardened runtime"
  fi
  if $DO_NOTARIZE; then
    printf '%s\n' "$signature_details" \
      | grep -Fxq 'Authority=Developer ID Certification Authority' \
      || error "语音识别辅助进程 Developer ID 签名链不完整"
    printf '%s\n' "$signature_details" | grep -Fxq 'Authority=Apple Root CA' \
      || error "语音识别辅助进程签名链缺少 Apple Root CA"
  fi

  : >"$signed_entitlements"
  if ! codesign -d --entitlements :- "$speech_worker" \
    >"$signed_entitlements" 2>/dev/null; then
    error "无法读取语音识别辅助进程的 entitlements"
  fi
  for forbidden_entitlement in \
    com.apple.security.device.audio-input \
    com.apple.security.get-task-allow \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.automation.apple-events \
    com.apple.security.personal-information.addressbook \
    com.apple.security.personal-information.calendars \
    com.apple.security.personal-information.location \
    com.apple.security.personal-information.photos-library; do
    forbidden_entitlement_value="$(
      plist_extract_literal_raw \
        "$forbidden_entitlement" \
        "$signed_entitlements" 2>/dev/null || true
    )"
    [[ "$forbidden_entitlement_value" != "true" ]] \
      || error "语音识别辅助进程包含不允许的 entitlement: $forbidden_entitlement"
  done

  info "语音识别辅助进程签名验证通过：hardened runtime、独立标识且无麦克风或敏感 entitlement"
}

verify_signed_app() {
  local signature_details=""
  local signed_identifier=""
  local signed_authority=""
  local team_identifier=""
  local timestamp=""
  local signed_entitlements="$RELEASE_TEMP_DIR/signed-entitlements.plist"
  local microphone_entitlement=""
  local application_identifier=""
  local app_sandbox_entitlement=""
  local unsafe_entitlement=""
  local unsafe_entitlement_value=""

  verify_signed_speech_worker
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  if ! signature_details="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"; then
    error "无法读取签名详情"
  fi

  signed_identifier="$(signature_detail_value "$signature_details" "Identifier")"
  signed_authority="$(signature_detail_value "$signature_details" "Authority")"
  team_identifier="$(signature_detail_value "$signature_details" "TeamIdentifier")"
  timestamp="$(signature_detail_value "$signature_details" "Timestamp")"

  [[ "$signed_identifier" == "$BUNDLE_ID" ]] || \
    error "签名标识不匹配：期望 '$BUNDLE_ID'，实际 '$signed_identifier'"
  [[ "$signed_authority" == "$RESOLVED_SIGN_IDENTITY_NAME" ]] || \
    error "签名证书不匹配：期望 '$RESOLVED_SIGN_IDENTITY_NAME'，实际 '$signed_authority'"
  [[ -n "$team_identifier" && "$team_identifier" != "not set" ]] || \
    error "签名缺少有效 TeamIdentifier"
  [[ -n "$timestamp" ]] || error "签名缺少可信时间戳"
  if ! printf '%s\n' "$signature_details" | grep -Eq '^CodeDirectory .*flags=.*\([^)]*runtime[^)]*\)'; then
    error "签名未启用 hardened runtime"
  fi
  if $DO_NOTARIZE; then
    printf '%s\n' "$signature_details" | grep -Fxq 'Authority=Developer ID Certification Authority' || \
      error "Developer ID 签名链缺少 Developer ID Certification Authority"
    printf '%s\n' "$signature_details" | grep -Fxq 'Authority=Apple Root CA' || \
      error "Developer ID 签名链缺少 Apple Root CA"
  fi

  if ! codesign -d --entitlements :- "$APP_BUNDLE" >"$signed_entitlements" 2>/dev/null; then
    error "无法读取已签名应用的 entitlements"
  fi
  microphone_entitlement="$(plist_extract_literal_raw com.apple.security.device.audio-input "$signed_entitlements" 2>/dev/null || true)"
  [[ "$microphone_entitlement" == "true" ]] || error "签名缺少麦克风输入 entitlement"
  app_sandbox_entitlement="$(plist_extract_literal_raw com.apple.security.app-sandbox "$signed_entitlements" 2>/dev/null || true)"
  [[ "$app_sandbox_entitlement" == "false" ]] || error "签名的 App Sandbox 状态与发布配置不一致"

  for unsafe_entitlement in \
    com.apple.security.get-task-allow \
    com.apple.security.cs.allow-jit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation; do
    unsafe_entitlement_value="$(plist_extract_literal_raw "$unsafe_entitlement" "$signed_entitlements" 2>/dev/null || true)"
    [[ "$unsafe_entitlement_value" != "true" ]] || \
      error "发布签名包含不安全的 entitlement: $unsafe_entitlement"
  done

  application_identifier="$(plist_extract_literal_raw com.apple.application-identifier "$signed_entitlements" 2>/dev/null || true)"
  if [[ -n "$application_identifier" ]]; then
    info "签名 application-identifier: $application_identifier"
  else
    info "签名未包含 application-identifier（脚本不会伪造受限 entitlement）"
  fi

  info "签名验证通过：hardened runtime、标识、证书、TeamIdentifier、时间戳和安全 entitlement 均有效"
}

artifact_sha256() {
  local artifact="$1"
  local checksum=""

  command -v shasum >/dev/null 2>&1 || error "未找到 shasum，无法生成 SHA-256"
  [[ -f "$artifact" ]] || error "无法为不存在的产物生成 SHA-256: $artifact"
  checksum="$(shasum -a 256 "$artifact" | awk '{ print tolower($1) }')"
  [[ "$checksum" =~ ^[[:xdigit:]]{64}$ ]] || error "无法生成有效的 SHA-256"
  printf '%s\n' "$checksum"
}

print_sha256() {
  local artifact="$1"
  local checksum=""

  checksum="$(artifact_sha256 "$artifact")"
  info "SHA-256: $checksum  $artifact"
}

write_sha256_sidecar() {
  local artifact="$1"
  local sidecar="${artifact}.sha256"
  local artifact_name=""
  local artifact_directory=""
  local checksum=""
  local expected_content=""
  local sidecar_name=""
  local temporary_sidecar=""

  artifact_name="$(basename "$artifact")"
  artifact_directory="$(dirname "$artifact")"
  sidecar_name="$(basename "$sidecar")"
  checksum="$(artifact_sha256 "$artifact")"
  expected_content="$checksum  $artifact_name"
  if ! temporary_sidecar="$(mktemp "${sidecar}.tmp.XXXXXX")"; then
    error "无法在最终 DMG 旁创建临时 SHA-256 文件"
  fi
  if ! printf '%s\n' "$expected_content" >"$temporary_sidecar"; then
    rm -f "$temporary_sidecar"
    error "无法写入最终 DMG 的 SHA-256 文件"
  fi
  if ! chmod 0644 "$temporary_sidecar"; then
    rm -f "$temporary_sidecar"
    error "无法设置最终 DMG 的 SHA-256 文件权限"
  fi
  if ! mv -f "$temporary_sidecar" "$sidecar"; then
    rm -f "$temporary_sidecar"
    error "无法原子发布最终 DMG 的 SHA-256 文件"
  fi
  if [[ "$(<"$sidecar")" != "$expected_content" ]]; then
    rm -f "$sidecar"
    error "最终 DMG 的 SHA-256 文件校验失败"
  fi
  if ! (cd "$artifact_directory" && shasum -a 256 -c "$sidecar_name" >/dev/null); then
    rm -f "$sidecar"
    error "最终 DMG 与 SHA-256 文件不匹配"
  fi
  info "SHA-256 sidecar: $sidecar"
}

publish_distribution_dmg_sidecar() {
  if ! $DO_NOTARIZE; then
    info "未请求公证；本地签名 DMG 不生成正式发布 SHA-256 sidecar"
    return 0
  fi
  write_sha256_sidecar "$DMG_PATH"
}

notarize_artifact() {
  local artifact="$1"
  local notary_result="$RELEASE_TEMP_DIR/notary-result.json"
  local notary_status=""
  local notary_id=""
  local arguments=(--keychain-profile "$NOTARY_PROFILE")

  if [[ -n "$NOTARY_KEYCHAIN" ]]; then
    arguments+=(--keychain "$NOTARY_KEYCHAIN")
  fi
  arguments+=(--wait --output-format json)
  if ! xcrun notarytool submit "$artifact" "${arguments[@]}" >"$notary_result"; then
    error "公证提交失败；请使用 notarytool log 检查对应请求"
  fi
  notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
  notary_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
  [[ "$notary_status" == "Accepted" ]] || \
    error "公证未获接受（状态: ${notary_status:-unknown}，请求: ${notary_id:-unknown}）"
  info "公证已接受（请求: ${notary_id}）"
}

finalize_distribution_dmg() {
  info "签名最终 DMG ($RESOLVED_SIGN_IDENTITY_NAME)..."
  codesign --force --timestamp \
    --sign "$RESOLVED_SIGN_IDENTITY" \
    "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  hdiutil verify "$DMG_PATH" >/dev/null

  if ! $DO_NOTARIZE; then
    info "最终 DMG 签名验证通过"
    return 0
  fi

  info "提交最终 DMG 公证..."
  revalidate_notarized_release_source "最终 DMG 公证提交前"
  notarize_artifact "$DMG_PATH"

  info "装订最终 DMG 公证票据..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  codesign --verify --strict --verbose=2 "$DMG_PATH"
  hdiutil verify "$DMG_PATH" >/dev/null
  spctl --assess --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$DMG_PATH"
  info "最终 DMG 的签名、公证票据和 Gatekeeper 验证均通过"
}

prepare_release_output_staging() {
  FINAL_APP_BUNDLE="$RELEASE_OUTPUT_DIR/$APP_NAME.app"
  FINAL_DMG_PATH="$RELEASE_OUTPUT_DIR/$APP_NAME.dmg"
  FINAL_DMG_SHA256_PATH="${FINAL_DMG_PATH}.sha256"

  # A new invocation invalidates every prior release-looking result before
  # any expensive or fallible work. Replacements stay on the same filesystem
  # so publication can use atomic rename after complete verification.
  rm -rf "$FINAL_APP_BUNDLE"
  rm -f "$FINAL_DMG_PATH" "$FINAL_DMG_SHA256_PATH"
  RELEASE_TEMP_DIR="$(mktemp -d "$RELEASE_OUTPUT_DIR/.rill-release.XXXXXX")"
  APP_BUNDLE="$RELEASE_TEMP_DIR/$APP_NAME.app"
  DMG_PATH="$RELEASE_TEMP_DIR/$APP_NAME.dmg"
  DMG_SHA256_PATH="${DMG_PATH}.sha256"
}

publish_staged_app() {
  [[ -d "$APP_BUNDLE" && ! -e "$FINAL_APP_BUNDLE" ]] \
    || error "已验证 App 的发布前置条件不满足"
  mv "$APP_BUNDLE" "$FINAL_APP_BUNDLE" \
    || error "无法原子发布已验证 App"
  APP_BUNDLE="$FINAL_APP_BUNDLE"
}

publish_staged_dmg() {
  [[ -f "$DMG_PATH" && ! -e "$FINAL_DMG_PATH" ]] \
    || error "已验证 DMG 的发布前置条件不满足"
  mv "$DMG_PATH" "$FINAL_DMG_PATH" \
    || error "无法原子发布已验证 DMG"
  DMG_PATH="$FINAL_DMG_PATH"

  if [[ -f "$DMG_SHA256_PATH" ]]; then
    [[ ! -e "$FINAL_DMG_SHA256_PATH" ]] \
      || error "最终 DMG SHA-256 sidecar 已存在"
    mv "$DMG_SHA256_PATH" "$FINAL_DMG_SHA256_PATH" \
      || error "无法原子发布最终 DMG SHA-256 sidecar"
    DMG_SHA256_PATH="$FINAL_DMG_SHA256_PATH"
  fi
}

cleanup_release_temporary_files() {
  local install_cleanup_is_safe=true

  # EXIT cleanup is the last recovery owner. Prevent a second signal from
  # interrupting an in-flight atomic rollback.
  trap '' INT TERM
  if ! rollback_install_transaction_if_needed; then
    install_cleanup_is_safe=false
  fi
  if [[ -n "$INSTALL_STAGING_ROOT" ]] && $install_cleanup_is_safe; then
    rm -rf "$INSTALL_STAGING_ROOT"
  fi
  if [[ -n "$RELEASE_TEMP_DIR" ]]; then
    rm -rf "$RELEASE_TEMP_DIR"
  fi
}

handle_release_interrupt() {
  local signal="$1"
  local exit_code=1

  trap '' INT TERM
  case "$signal" in
  INT) exit_code=130 ;;
  TERM) exit_code=143 ;;
  esac
  echo "✗ 发布流程收到 ${signal}；正在安全回滚未提交的安装事务" >&2
  exit "$exit_code"
}

# Keep pure release helpers sourceable so policy tests can exercise the same
# plist parsing code that validates a signed application.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# 身份配置必须在预检和构建前失败，避免用错误证书完成昂贵构建后才发现问题。
validate_release_configuration
if $DO_VALIDATE_CONFIG; then
  info "发布配置验证通过（未执行构建、签名或公证）"
  exit 0
fi
validate_project_worktree_alignment
if $DO_NOTARIZE && [[ -z "$SOURCE_SNAPSHOT_CAPABILITY" ]]; then
  run_notarized_release_from_snapshot "$@"
fi

# 相对输出路径以仓库根目录为基准。仓库内输出只能落在专用且忽略的
# .artifacts 目录；仓库根目录和其他源码目录都不是发布目标。
if [[ "$RELEASE_OUTPUT_DIR" != /* ]]; then
  RELEASE_OUTPUT_DIR="$PROJECT_DIR/$RELEASE_OUTPUT_DIR"
fi
mkdir -p "$RELEASE_OUTPUT_DIR"
RELEASE_OUTPUT_DIR="$(cd "$RELEASE_OUTPUT_DIR" && pwd -P)"
validate_release_output_location "$RELEASE_OUTPUT_DIR"
prepare_release_output_staging
trap cleanup_release_temporary_files EXIT
trap 'handle_release_interrupt INT' INT
trap 'handle_release_interrupt TERM' TERM
info "发布输出目录: $RELEASE_OUTPUT_DIR"

# ─── 步骤 1: 构建 ────────────────────────────────────────────────
cd "$PROJECT_DIR"
if $DO_PREFLIGHT; then
  info "运行完整发布预检和全量测试..."
  if $DO_NOTARIZE; then
    "$SCRIPT_DIR/preflight.sh" --clean
  else
    "$SCRIPT_DIR/preflight.sh"
  fi
  info "完整发布预检通过"
else
  info "跳过完整预检；如需全量测试请运行 scripts/preflight.sh 或传入 --preflight"
  info "增量构建 Release..."
fi
WORKER_CACHE="auto"
$DO_NOTARIZE && WORKER_CACHE="off"
BUILD_RESULT="$RELEASE_TEMP_DIR/build-result.json"
"$SCRIPT_DIR/swift_locked.sh" release --worker-cache "$WORKER_CACHE" --result-file "$BUILD_RESULT"
revalidate_notarized_release_source "构建后"

resolve_build_identity
VERSION="$RESOLVED_APP_VERSION"
BUILD_NUMBER=$(get_build_number)
info "版本: $RESOLVED_VERSION_LABEL ($BUILD_NUMBER)"
info "构建来源: $RESOLVED_BUILD_KIND @ ${RESOLVED_SOURCE_REVISION:0:12}, dirty=$RESOLVED_SOURCE_DIRTY"

# ─── 步骤 2: 创建 .app 包 ────────────────────────────────────────
info "创建 $APP_NAME.app..."
"$SCRIPT_DIR/assemble_app_bundle.sh" \
  --build-result "$BUILD_RESULT" \
  --app-bundle "$APP_BUNDLE" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER" \
  --build-kind "$RESOLVED_BUILD_KIND" \
  --source-revision "$RESOLVED_SOURCE_REVISION" \
  --source-dirty "$RESOLVED_SOURCE_DIRTY" \
  --version-label "$RESOLVED_VERSION_LABEL"

# 生成 entitlements；所有临时发布文件在退出时统一清理。
ENTITLEMENTS="$RELEASE_TEMP_DIR/Rill.entitlements"
cat >"$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

# ─── 步骤 3: 签名 ────────────────────────────────────────────────
info "签名 ($RESOLVED_SIGN_IDENTITY_NAME)..."
revalidate_notarized_release_source "签名前"

MLX_RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Helpers/$MLX_RESOURCE_BUNDLE_NAME"
info "先签名 MLX Metal 资源包..."
codesign --force --timestamp \
  --sign "$RESOLVED_SIGN_IDENTITY" \
  "$MLX_RESOURCE_BUNDLE"

SPEECH_WORKER_EXECUTABLE="$APP_BUNDLE/Contents/Helpers/$SPEECH_WORKER_NAME"
info "签名语音识别辅助进程..."
codesign --force --options runtime --timestamp \
  --identifier "$SPEECH_WORKER_IDENTIFIER" \
  --sign "$RESOLVED_SIGN_IDENTITY" \
  "$SPEECH_WORKER_EXECUTABLE"

info "签名外层应用..."
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$RESOLVED_SIGN_IDENTITY" \
  "$APP_BUNDLE"

verify_signed_app

# 公证后直接安装是一个非分发路径：notarytool 仍需要支持的上传容器，
# 因此只在 --install 与 --notarize 组合时保留临时 ZIP。标准分发路径会在
# 创建并签名最终 DMG 后，直接提交该外层容器。
if $DO_NOTARIZE && $DO_INSTALL; then
  info "提交直接安装构建公证..."
  revalidate_notarized_release_source "公证提交前"

  NOTARIZE_ZIP="$RELEASE_TEMP_DIR/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"
  notarize_artifact "$NOTARIZE_ZIP"

  info "装订公证票据..."
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

  info "公证票据与 Gatekeeper 验证通过"
fi

# ─── 步骤 4: 安装 或打包最终 DMG ─────────────────────────────────
if $DO_INSTALL; then
  publish_staged_app
  quit_running_rill_if_needed
  info "安装到 /Applications..."
  install_verified_app "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  info "✓ 已安装到 /Applications/$APP_NAME.app"
  print_sha256 "/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
  info "启动最新安装版本..."
  open "/Applications/$APP_NAME.app"
else
  info "创建 DMG..."
  DMG_STAGING="$RELEASE_TEMP_DIR/dmg-staging"
  mkdir -p "$DMG_STAGING"
  ditto "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$DMG_STAGING/$APP_NAME.app"
  ln -s /Applications "$DMG_STAGING/Applications"

  # Remove both members before creating a new release pair. A failed create,
  # signature, notarization, or staple step must never leave an old checksum
  # next to a new or incomplete DMG.
  rm -f "$DMG_PATH" "$DMG_SHA256_PATH"
  hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
  finalize_distribution_dmg
  publish_distribution_dmg_sidecar
  publish_staged_app
  publish_staged_dmg

  DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)
  info "✓ $DMG_PATH ($DMG_SIZE)"
  print_sha256 "$DMG_PATH"
fi

echo ""
echo "═══════════════════════════════════════"
echo "  $APP_NAME $RESOLVED_VERSION_LABEL 发布完成!"
echo "═══════════════════════════════════════"
