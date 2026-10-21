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

# Format every tracked Swift file, matching the swift-format hook scope.
fmt:
    git ls-files -z '*.swift' | xargs -0 swift format --configuration .swift-format --in-place

# Build the documentation and reject broken links and anchors.
docs:
    uv run --no-build --locked --script scripts/docs.py build

# Preview documentation and refresh when its Markdown sources change.
docs-serve port="8000":
    uv run --no-build --locked --script scripts/docs.py serve --port {{quote(port)}}

# Build one Debug product; application changes do not compile MLX.
build product="RillApp":
    scripts/preflight.sh swift build --product {{quote(product)}}

# Run domain and native tests that do not require desktop interaction.
test:
    scripts/preflight.sh test

# Test real window focus and keyboard routing in an unlocked macOS session.
test-desktop:
    scripts/preflight.sh test-desktop

# Test build, release, security, and asset scripts without building the app.
test-scripts:
    scripts/preflight.sh test-scripts

# Test the internal evaluation and replay tools without model or provider access.
test-tools:
    uv run --locked --project tools pytest tools/tests

# Build and validate the production performance workloads.
validate-performance-workloads:
    bash scripts/build_benchmarks.sh

# Run one explicit quality evaluation (real LLM calls are opt-in).
[positional-arguments]
eval-quality suite *args:
    uv run --locked --project tools rill-eval-quality "$@"

# Compare paired ASR performance or measure native panel presentation.
[positional-arguments]
bench-performance suite *args:
    #!/usr/bin/env bash
    set -euo pipefail
    suite="$1"
    shift
    case "$suite" in
      asr) uv run --locked --project tools rill-bench-asr "$@" ;;
      panel) bash scripts/benchmark_panel.sh "$@" ;;
      *) echo "Supported performance suites: asr, panel" >&2; exit 2 ;;
    esac

# Apply the explicit ASR experiment admission policy to two matching reports.
[positional-arguments]
accept-asr *args:
    uv run --locked --project tools rill-accept-asr "$@"

# Replay authorized audio through a verified Release speech worker.
[positional-arguments]
replay-asr *args:
    uv run --locked --project tools rill-replay-asr "$@"

# Replay authorized audio through the host pipeline with isolated output.
[positional-arguments]
replay-product *args:
    uv run --locked --project tools rill-replay-product "$@"

# Reproduce the complete local CI gate.
ci:
    just check
    just docs
    bash scripts/preflight.sh

# Reproduce the clean CI gate, without worker artifact reuse.
ci-clean:
    just check
    just docs
    bash scripts/preflight.sh --clean

# Build and validate the arm64 release products.
build-release:
    scripts/preflight.sh swift release

# Inspect or clear inactive shared worker artifacts.
cache-status:
    scripts/preflight.sh swift cache status

cache-clean:
    scripts/preflight.sh swift cache clean

# Assemble a local release artifact.
release:
    bash scripts/release.sh

# Build, notarize, and upload a new GitHub Release draft.
release-github tag notes:
    bash scripts/release.sh github {{quote(tag)}} {{quote(notes)}}

# Export native UI render evidence for review.
test-render:
    RILL_UI_SNAPSHOT_DIR="$PWD/.artifacts/ui-renders" scripts/preflight.sh swift test --filter 'Render|UIRenderEvidence'

# Exercise the large catalog fixture separately from the fast suite.
test-stress:
    RILL_RECORD_STRESS=1 scripts/preflight.sh swift test --filter RecordCatalogStressTests
