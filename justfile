# List the available repository commands.
default:
    @just --list

# Install the pre-commit and commit-message hooks.
install:
    uvx --isolated prek install --prepare-hooks

# Run maintained formatting and configuration hooks.
check:
    uvx --isolated prek validate-config prek.toml
    uvx --isolated prek -c prek.toml run --all-files

# Apply format changes explicitly; CI uses read-only hooks.
format:
    uv run --project tools ruff check --fix tools
    uv run --project tools ruff format tools
    uvx --isolated prek run swift-format --hook-stage manual --all-files
    uvx --from shfmt-py==4.2.0 shfmt -w -i 2 -bn scripts/*.sh scripts/tests/*.sh

# Offline Python tests and real Swift domain coverage, excluding provider evaluations.
coverage:
    uv run --project tools --frozen pytest --cov=tools/src/rill_dev --cov-config=tools/pyproject.toml --cov-report=xml:.artifacts/quality/python-coverage.xml --cov-report=term-missing tools/tests
    bash scripts/check_coverage.sh

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

# Reproduce the local CI gate, including hosted stress and render evidence.
# `clean` rebuilds without worker artifact reuse.
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
    RILL_RECORD_STRESS=1 RILL_UI_SNAPSHOT_DIR="$PWD/.artifacts/ui-renders" \
      bash scripts/preflight.sh "${clean[@]}"

# Run one performance suite: asr, panel, or workloads.
[positional-arguments]
benchmark suite *args:
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
