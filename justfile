# List the available repository commands.
default:
    @just --list

# Install the pre-commit and commit-message hooks.
install:
    uvx prek==0.5.3 install --prepare-hooks --hook-type pre-commit --hook-type commit-msg

# Run maintained formatting and configuration hooks.
check:
    uvx prek==0.5.3 validate-config prek.toml
    uvx prek==0.5.3 -c prek.toml run --all-files

# Build the documentation and reject broken links and anchors.
docs:
    uv run --no-build --locked --script scripts/docs.py build

# Preview documentation and refresh when its Markdown sources change.
docs-serve port="8000":
    uv run --no-build --locked --script scripts/docs.py serve --port {{quote(port)}}

# Build one Debug product; application changes do not compile MLX.
build product="RillApp":
    scripts/preflight.sh swift build --product {{quote(product)}}

# Run the locked Swift test suite.
test:
    scripts/preflight.sh test

# Test build, release, security, and asset scripts without building the app.
test-scripts:
    scripts/preflight.sh test-scripts

# Build and validate the production performance workloads.
bench:
    bash scripts/build_benchmarks.sh

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
