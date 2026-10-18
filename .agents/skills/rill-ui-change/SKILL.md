---
name: rill-ui-change
description: Change Rill visual presentation, materials, type, empty states, motion, or floating-panel chrome. Use for SwiftUI or AppKit appearance work, not copy-only edits, Record data, or workflow TOML.
---

# Rill UI Change

Keep the visible surface on the current system design without moving focus,
input, undo, search, delivery, or privacy behavior. Respond in the user's
language.

## Read the visual contract

Read [DESIGN.md](../../../DESIGN.md) and [UI direction](../../../docs/ui-direction.md)
before editing. Overturning a visual decision means updating both documents in
the same change. Leave behavior sections alone unless the request changes them.

Use semantic colors, system type, and SF Symbols through `RillSystemSymbol`.
Navigation and controls may use Liquid Glass through `RillGlass`. Reading,
preview, and editing surfaces stay opaque. Reduce Transparency and Increase
Contrast stay on the opaque fallback inside `RillGlass`.

## Keep the native boundaries

Do not replace these without a regression that covers the documented contract:

- Global search stays on the AppKit `NSSearchField` bridge. Do not switch it to
  `.searchable` without the focus, arrow, Return, and Escape coverage in
  [CONTRIBUTING.md](../../../CONTRIBUTING.md).
- Draft editing stays on `NSTextView`, including undo, marked text, and
  Command-Return send.
- File preview keeps `QLPreviewView.autostarts = false` until SwiftUI preview
  exposes that control.
- Shortcut recording stays in `HotkeyRecorderView` until a public recorder can
  express the global-gesture pause lease.

Settings stay in the main window. Do not add a separate Settings scene.

## Verify presentation

Check English and Chinese, light and dark appearance, and the compact window.
Also check Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate
Without Color, and a larger text size when the change touches type or material.

Render evidence can show layout. It does not accept Fn, IME composition,
VoiceOver, paste, or a release candidate. Use
[macOS QA](../rill-macos-qa/SKILL.md) when the change crosses one of those
boundaries.

Report the visual decision changed, the documents updated, the checks run, and
any physical interaction still unverified.
