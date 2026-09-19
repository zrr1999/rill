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

# Run the locked Swift test suite.
test:
    scripts/swift_locked.sh test --parallel

# Reproduce the complete local CI gate.
ci:
    just check
    bash scripts/preflight.sh

# Build and validate the arm64 release products.
build-release:
    bash scripts/build_xcode_release.sh

# Assemble a local release artifact.
release:
    bash scripts/release.sh
