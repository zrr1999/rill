# Rill

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS, implemented with SwiftUI and AppKit, requiring macOS 26.0 or later.

## Users and purpose

People working across Mac applications who want to dictate without interrupting
their work, then find, edit, and reuse voice and clipboard content when needed.
Everyday speech input must remain usable without learning workflow internals.

## Capabilities and constraints

The existing project contracts remain authoritative:

- [Architecture and ownership](docs/architecture.md)
- [Record storage and delivery](docs/record-architecture.md)
- [Editable drafts and continuous output](docs/continuous-output.md)
- [Workflow behavior](docs/workflow-toml.md)
- [UI direction](docs/ui-direction.md)
- [Native acceptance](docs/release-qa-checklist.md)

The optimization starts from the existing App and preserves effective layouts
and habits, especially the recording overlay. It retains the Rill identity,
icon assets, and documentation website framework, along with capture, privacy,
target validation, persistence, and workflow semantics.

The user's second review groups All Records, Activity, and Workflows at the top
of the sidebar. The quick panel hosts Collections and Drafts as two modes of one
panel and can collapse to a small persistent pending strip. This is presentation
consolidation using the existing Record and draft state, not new content storage.

## Confirmed process

The user reviewed the visual direction and authorized implementation on 2026-09-28.
Native implementation refines existing surfaces; static mockups and automated
renders do not replace the interaction and release acceptance contracts.

## Accessibility and inclusion

English and Simplified Chinese; keyboard and VoiceOver access; light and dark
appearance; reduced motion, reduced transparency, and increased contrast.
