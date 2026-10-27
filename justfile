# List the available repository commands.
default:
    @just --list

# Install the pre-commit and commit-message hooks.
install:
    uvx prek==0.5.7 install --prepare-hooks

# Run maintained formatting and configuration hooks.
check:
    uvx prek==0.5.7 validate-config prek.toml
    uvx prek==0.5.7 -c prek.toml run --all-files

# Apply format changes explicitly; CI uses read-only hooks.
format:
    uv run --project tools ruff check --fix tools
    uv run --project tools ruff format tools
    uvx prek==0.5.7 run swift-format --hook-stage manual --all-files
    uvx --from shfmt-py==4.2.0 shfmt -w -i 2 -bn scripts/*.sh scripts/tests/*.sh

# Offline Python tests and real Swift domain coverage, excluding provider evaluations.
coverage:
    uv run --project tools --frozen pytest --cov=tools/src/rill_dev --cov-config=tools/pyproject.toml --cov-report=xml:.artifacts/quality/python-coverage.xml --cov-report=term-missing tools/tests
    bash scripts/check_coverage.sh

# Exercise only the edit-distance scorer; model output quality has its own evaluations.
mutation:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .artifacts/quality
    UV_PROJECT_ENVIRONMENT="$PWD/.artifacts/quality/python" uv run --directory tools --python 3.13 --frozen --group quality mutmut run 'rill_dev.evaluation.asr_quality.x_distance*' --max-children 2 2>&1 | tee .artifacts/quality/mutation.log
    UV_PROJECT_ENVIRONMENT="$PWD/.artifacts/quality/python" uv run --directory tools --python 3.13 --frozen --group quality mutmut export-cicd-stats

# Structure metrics are advisory until a project-specific budget is established.
reports:
    mkdir -p .artifacts/quality
    npx --yes jscpd@5.4.2 --reporters json --output .artifacts/quality/jscpd Sources scripts tools/src
    uvx lizard==1.24.3 --ignore_warnings -1 --xml Sources > .artifacts/quality/swift-complexity.xml
    UV_PROJECT_ENVIRONMENT="$PWD/.artifacts/quality/python" uv run --directory tools --python 3.13 --frozen --group quality radon cc --json src > .artifacts/quality/python-complexity.json

# Active documentation links; archived notes preserve their original references.
links:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p .artifacts/quality
    # GitHub repository settings require an administrator's authenticated browser.
    git ls-files -z '*.md' ':(exclude).agents/notes/**' | xargs -0 uvx --from lychee-bin==0.24.2 lychee --scheme https --scheme http --exclude '^https://github.com/zrr1999/rill/settings/' --timeout 20 --max-retries 1 --no-progress --format json --output .artifacts/quality/links.json

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
