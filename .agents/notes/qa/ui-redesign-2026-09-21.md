# Rill UI redesign — local verification

Source: `codex/ui-redesign`, based on `cb5bff3`, working-tree implementation.
Environment: macOS 27.0 (26A428), arm64, Swift 6.4.0 / Xcode.
The installed app was not replaced or relaunched; no second Rill instance with global input ownership was started.

## Completed evidence

- 31 AppKit integration tests passed: sidebar arrows/list selection, event-tracking and run-loop focus repair, superseded routes, global search retaining focus, independent Settings-window navigation.
- 11 unified-workspace tests passed: all-records default, settings-pane mapping and content-route preservation, repeated record deep links, deleted targets, filtering reset, full-content search past empty storage batches, pagination beyond the store's single-page limit, stale-query isolation, partial-source failure, exact preview width boundary, explicit copying and honest output feedback.
- Existing AppModel tests (131) and subtitle interaction-policy tests (10) passed in the targeted run.
- Both native render test cases passed. 82 PNG files were produced at `/tmp/rill-ui-redesign-evidence`: English/Chinese, light/dark, 960/1280pt main windows, all six settings panes, text/image/files/long content, empty search results, search errors, compact details, quick-panel previews at 620/900pt, and cleanup.
- Render inspection can establish content grouping and preview layout. AppKit vibrancy/selection and window toolbar compositing are incomplete in bitmap exports; these exports do not prove physical-window appearance or exact VoiceOver focus. The fixture has no microphone service or packaged privacy resource.
- `just ci` passed, including all configured prek hooks, dependency/security/secret checks, generated artifacts, arm64 Release build, resource/license verification, temporary bundle signing, the complete test suite, and diff whitespace checks.
- Independent source review found and resolved compact/repeated Record deep-link focus and collapsed-memory-section navigation defects; the final review found no additional confirmed issue.

## Manual acceptance remaining

Use one build with a known source revision, retaining only one global-input-owning Rill process. Use harmless sample records.

1. First and repeated Cmd-F: type, switch queries, use arrows/Return/Esc, reveal a record, copy it; confirm searching/revealing alone never pastes.
2. Resize below 700pt content width; return to the list, repeat a deep link to the selected record, and verify selection, position, and keyboard/VoiceOver focus.
3. Cmd-comma: open each pane, follow memory and diagnostics deep links (including after collapsing memory), close Settings, and confirm the main collection/selection is retained. Verify a failed save remains visible and retryable.
4. Quick panel: Return paste, Copy only, pinning, Cmd-1…9, IME composition, and the displayed delivery target while activating/closing another application. Compare 620pt and at least 760pt previews.
5. Inspect dark/light, increased contrast, reduced motion, and reduced transparency in a real window; complete VoiceOver reading order and exact destination focus on macOS 14 as well as the current OS.

These are not release/notarization or Gatekeeper acceptance claims.
