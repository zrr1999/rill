# Clipboard image and file preview verification

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

Date: 2026-09-21. Base: `0143854dd9bbe6ffc61e978f90710a3f2f9657d2`.
Environment: macOS 27.0 (26A428), arm64; deployment target remains macOS 14.

## Automated and rendering evidence

- `RecordContentPreviewTests`: image downsampling limits, corrupt/cancelled image
  decoding, fresh metadata after file deletion, folders/non-file URLs, preview
  selection/close/deletion, and unchanged Record catalog revision after preview.
- Existing quick-panel and panel-controller regressions cover search, selection,
  modal dismissal policy, and presentation. Native stress timing remains opt-in.
- `RecordQuickPanelRenderTests/testRenderImageAndFilePreviews`: eight AppKit
  renders at 620/900 pt, light/dark, Chinese/English, for image and multi-file
  records. The fixtures include PNG, PDF, text, and a missing file. Visual
  inspection caught and fixed the compact image preview hiding its expand button.
- Evidence and logs live under the owning checkout's ignored
  `.artifacts/clipboard-preview-*` paths. These are rendering evidence, not an
  installed-app or VoiceOver acceptance claim.

## Observed native component interaction

A disposable `RillPreviewQA.app` (bundle ID `dev.rill.preview-qa`, build 1) compiled
`Sources/RillUI/RecordFilePreview.swift` directly with presentation-only string,
spacing, and symbol stand-ins. The source SHA-256 was
`a566faa7448b61454a065f512c8054f327dc58fc396f608ef383e27b1cc7fa72`.
It used only generated sample files and did not load Rill settings, start capture,
request permissions, or install/replace Rill. The harness was closed afterwards.

Observed through native UI controls and accessibility state:

- Open PNG: the Quick Look sheet exposes the expected image preview.
- Next: PDF document preview, then readable sample text.
- Next: explicit unavailable state for a missing file and disabled final Next.
- Escape: the sheet closes while the parent file list remains available.
- Reopen PDF, then Previous: the image preview loads again; no closed Quick Look
  view is reused.

Quick Look's remotely rendered content was not captured reliably by the static
AppKit bitmap helper; blank bitmap exports were not counted as passing evidence.

## Remaining acceptance

The exact installed Rill app was not replaced. Full floating-panel target
restoration, keyboard/IME routing with an attached preview sheet, VoiceOver spoken
output, macOS 14, remote/cloud file providers, and media playback controls still
need acceptance on the corresponding artifact. See `docs/release-qa-checklist.md`.
