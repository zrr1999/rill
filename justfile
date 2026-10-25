# List the available repository commands.
default:
    @just --list

# Install the pre-commit and commit-message hooks.
install:
    uvx prek install --prepare-hooks

# Run maintained formatting and configuration hooks.
check:
    uvx prek validate-config prek.toml
    uvx prek -c prek.toml run --all-files

# Build the documentation, or serve a local preview (`serve [PORT]`).
[positional-arguments]
docs *args:
    #!/usr/bin/env bash
    set -euo pipefail
    case "${1:-build}" in
      build)
        if [[ $# -gt 1 ]]; then
          echo "Usage: just docs [serve [PORT]]" >&2
          exit 2
        fi
        uv run --no-build --locked --script scripts/docs.py build
        ;;
      serve)
        if [[ $# -gt 2 ]]; then
          echo "Usage: just docs [serve [PORT]]" >&2
          exit 2
        fi
        uv run --no-build --locked --script scripts/docs.py serve --port "${2:-8000}"
        ;;
      *)
        echo "Usage: just docs [serve [PORT]]" >&2
        exit 2
        ;;
    esac

# Build one Debug product, or all arm64 Release products (`release [arguments...]`).
[positional-arguments]
build target="RillApp" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    target="$1"
    shift
    if [[ "$target" == release ]]; then
      scripts/preflight.sh swift release "$@"
    elif [[ $# -eq 0 ]]; then
      scripts/preflight.sh swift build --product "$target"
    else
      echo "Usage: just build [PRODUCT] | just build release [arguments...]" >&2
      exit 2
    fi

# Run domain and native tests, or one suite: desktop, scripts, tools, render, stress.
[positional-arguments]
test suite="default":
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1" in
      default) scripts/preflight.sh test ;;
      desktop) scripts/preflight.sh test-desktop ;;
      scripts) scripts/preflight.sh test-scripts ;;
      tools) uv run --locked --project tools pytest tools/tests ;;
      render)
        RILL_UI_SNAPSHOT_DIR="$PWD/.artifacts/ui-renders" \
          scripts/preflight.sh swift test --filter 'Render|UIRenderEvidence'
        ;;
      stress)
        RILL_RECORD_STRESS=1 scripts/preflight.sh swift test --filter RecordCatalogStressTests
        ;;
      *)
        echo "Supported test suites: desktop, scripts, tools, render, stress" >&2
        exit 2
        ;;
    esac

# Reproduce the local CI gate (`clean` rebuilds without worker artifact reuse).
[positional-arguments]
ci *args:
    #!/usr/bin/env bash
    set -euo pipefail
    case "${1:-}" in
      "") [[ $# -eq 0 ]] || { echo "Usage: just ci [clean]" >&2; exit 2; }
          clean=() ;;
      clean) [[ $# -eq 1 ]] || { echo "Usage: just ci [clean]" >&2; exit 2; }
          clean=(--clean) ;;
      *) echo "Usage: just ci [clean]" >&2; exit 2 ;;
    esac
    just check
    just docs
    bash scripts/preflight.sh "${clean[@]}"

# Inspect inactive shared worker artifacts (`clean` removes them).
[positional-arguments]
cache action="status":
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1" in
      status | clean) scripts/preflight.sh swift cache "$1" ;;
      *) echo "Usage: just cache [status|clean]" >&2; exit 2 ;;
    esac

# Assemble a local release artifact (`github TAG NOTES` uploads a draft).
[positional-arguments]
release *args:
    bash scripts/release.sh "$@"

# Run one explicit quality evaluation (real LLM calls are opt-in).
[positional-arguments]
eval-quality suite *args:
    uv run --locked --project tools rill-eval-quality "$@"

# Run one performance suite: asr, panel, or workloads.
[positional-arguments]
bench suite *args:
    #!/usr/bin/env bash
    set -euo pipefail
    suite="$1"
    shift
    case "$suite" in
      asr) uv run --locked --project tools rill-bench-asr "$@" ;;
      panel) bash scripts/benchmark_panel.sh "$@" ;;
      workloads) bash scripts/build_benchmarks.sh "$@" ;;
      *) echo "Supported performance suites: asr, panel, workloads" >&2; exit 2 ;;
    esac

# Apply the explicit ASR experiment admission policy to two matching reports.
[positional-arguments]
accept-asr *args:
    uv run --locked --project tools rill-accept-asr "$@"

# Replay authorized audio through the speech worker (`asr`) or host pipeline (`product`).
[positional-arguments]
replay target *args:
    #!/usr/bin/env bash
    set -euo pipefail
    target="$1"
    shift
    case "$target" in
      asr) uv run --locked --project tools rill-replay-asr "$@" ;;
      product) uv run --locked --project tools rill-replay-product "$@" ;;
      *) echo "Supported replay targets: asr, product" >&2; exit 2 ;;
    esac
