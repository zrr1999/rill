# VoxType

A new native macOS voxtype repository implementing the Scheme-B architecture direction:

- Swift + Swift Package Manager + SwiftUI + AppKit
- explicit `Core / Platform / Providers / Runtime / UI / App` boundaries
- workflow-driven execution instead of a single session god object
- first-class candidate resolution and clipboard delivery seams

## Current scope

This repository currently proves the architecture with a compilable, testable prototype:

- rich domain model for workflows, recognition results, candidates, delivery items, and diagnostics
- runtime services for event distribution, clipboard history / group routing, candidate resolution, and session coordination
- platform facades for focus tracking, clipboard control, permissions, and text injection
- built-in demo recognizers, transformers, and output actions
- a NavigationSplitView-based app shell with Dashboard, Clipboard, Run History, and Settings sections, plus a menu bar entry
- in-memory history tracking for completed and failed workflow runs
- clipboard history capture for VoxType output and external system clipboard changes, including text, images, and copied files
- clipboard mirroring for the active group item plus Command-V group-aware paste interception
- bilingual UI switching for English / Simplified Chinese
- permission onboarding for Accessibility and Microphone access

## Package layout

- `VoxTypeCore`: domain types and service contracts
- `VoxTypePlatform`: macOS-specific integrations and facades
- `VoxTypeProviders`: built-in recognizers, transformers, and output actions
- `VoxTypeRuntime`: event bus, clipboard store, candidate resolver, registries, session coordinator
- `VoxTypeUI`: observable app model and SwiftUI views
- `VoxTypeApp`: composition root and app entry point

## Technical selection

- See `docs/technology-selection.md` for the current stack decision record and rationale.

## Demo workflows

- `Capture Selection`: pulls the current selection (or current clipboard text) into the assigned clipboard group
- `Fn Dictation`: hold the push-to-talk hotkey and send the recognized text into the assigned clipboard group
- `Polish Draft`: run dictation through the lightweight rewrite transform before it lands in the clipboard group

## Implemented interaction model

- Voice workflows with `stack.push` place their final text into the clipboard store and keep legacy stack-first behavior through the default group.
- External clipboard copies are captured into the same history and are tagged separately from VoxType-generated items.
- Every app belongs to exactly one clipboard group. Groups keep isolated `stack` / `queue` / `list` paste state, and apps can be reassigned from the Clipboard view.
- Clipboard state persists across restarts through the existing settings store, including groups, app assignments, and captured items.
- Pressing `Command-V` triggers group-aware delivery: VoxType resolves the focused app's assigned group, mirrors the next item into the system clipboard, and injects it into the focused app.
- Each clipboard item can be replayed through any registered workflow, or replaced in place by the transformed result, directly from the Clipboard view.
- Clipboard history now renders Markdown text more readably in the detail pane; image entries participate in grouped stack / queue / list delivery with richer previews; and routing cards surface several upcoming items per group instead of only the next one.
- Workflow-authored clipboard output can now explicitly opt out of workflow capture through workflow metadata. The editor defaults this protection to on, but turning it off allows clipboard-driven chaining again.
- VoxType-authored clipboard writes carry hidden metadata only when the originating workflow requests capture exclusion, which prevents mirrored/output clipboard content from feeding capture workflows back into themselves.
- Custom workflows now support `manual`, `hotkey`, and `menuBar` triggers end-to-end. `wakeWord` still exists in the domain model, but the detector/runtime path is not wired yet.
- The clipboard queue card now opens the clipboard panel directly, and the panel shortcut is configurable from Settings with shortcut recording support. The default remains double-`Command`.
- When the active group becomes empty, the clipboard is restored with change-count fencing so unrelated clipboard updates are not overwritten.
- Ambiguous transcripts surface a candidate panel with confidence/source metadata and a live resolved preview.
- The dashboard exposes explicit permission actions so the app can request Accessibility access and appear in macOS Privacy settings.

## Next implementation steps

1. replace demo recognizers with real streaming recognizers
2. deepen `PasteboardController` to capture/restore all pasteboard item types
3. decide whether non-text items should eventually join group delivery semantics instead of staying history-only
4. add smarter group management, smart collections, and workflow editor
5. replace the demo LLM transformer with a real provider-backed uncertainty rewrite path
