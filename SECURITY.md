# Security policy

## Supported versions

Rill is in development and has no stable release yet. Security fixes target
the `main` branch. After a stable release, maintenance will focus on the latest
stable version; older versions may not receive fixes.

## Reporting a vulnerability

A verified private reporting channel is not available yet. Do not disclose
vulnerability details, recordings, clipboard content, API keys, or other private
data in public issues, pull requests, or discussions.

Before public distribution, maintainers must enable GitHub private vulnerability
reporting or publish a monitored security email address here and verify that
reporters can use it. A link to an unavailable reporting page is not a channel.

Once a private channel is available, include the affected version or commit,
a description of the impact, and minimal reproduction steps using synthetic
data. Keep any proof of concept and sensitive details in that private channel.
Maintainers will coordinate verification, a fix, and disclosure with the reporter.

## Dependencies and privacy

Dependency updates are proposed through Renovate and checked against the locked
dependency graph, reviewed advisory baseline, and live OSV results in CI.
Passing those checks is not a claim that all dependencies are vulnerability-free.

For product data handling and user controls, see [PRIVACY.md](PRIVACY.md) and
the [README](README.md#隐私与数据).
