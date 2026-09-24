# Rill icon family

The editable sources are `Rill.svg` (application icon) and `RillMenuBar.svg`
(menu bar). These are original vector drawings that refine the existing
“routed voice cursor” identity: a voice pulse and a lower input lane merge at
one node and become text at an insertion cursor.

The application icon uses ink teal, warm ivory `#F4EEDC`, and coral `#FF7466`.
It has no lettering or fine bevel details. Its opaque 1024 px PNG feeds the
existing ICNS renderer, which adds the transparent rounded body, shadow, and
optical crops for 16–1024 px renditions.

## Menu bar

The 20 × 18 pt monochrome PDF is drawn specifically for the menu bar, with
2 pt rounded strokes and more open spacing. The colored junction is omitted
at this scale. SwiftUI renders it as a template so macOS supplies the tint for
light, dark, and selected appearances. It has no background tile.

- `RillMenuBarTemplate.pdf`: voice input ready, including when clipboard
  capture is off or paused.
- `RillMenuBarRecordsTemplate.pdf`: the same mark with a small dot when
  clipboard capture is active and records are available. The dot is enabled
  from the SVG's `records-indicator` element by the generator stylesheet.
- Active recording, permission failures, setup checks, and temporary capture
  states retain their existing SF Symbols and priority policy.

Both PDFs are bundled in `Sources/RillApp/Resources`, loaded once through
`Bundle.module.image(forResource:)`, and passed to SwiftUI as `NSImage` values.
SwiftUI's named-image initializer does not resolve these loose PDF exports.
The application name remains the menu label for accessibility.

## Regeneration

Install librsvg (`brew install librsvg`) when editing the artwork, then run:

```bash
scripts/render_brand_assets.sh
bash scripts/tests/app_icon_test.sh
```

The generator writes the PNG and both PDFs and prints their SHA-256 values.
`SOURCE_DATE_EPOCH=0` fixes the PDF creation timestamp. Normal builds and CI
consume the committed exports and need no SVG conversion tools. Commit the
SVG sources, exports, this provenance, and the updated PNG hash in
`generate_app_icon.sh` and `tests/app_icon_test.sh` together.

| File | Reviewed SHA-256 |
| --- | --- |
| `Rill.svg` | `8d68b101dba2818f6312a38f92d3128be91e6ed1483d87cbc4ef9fac89fe494e` |
| `AppIcon-1024-routed-voice-cursor.png` | `c6c6bd3647ca2cc2ae860c27832d2f8150c5832320ed7b4b7b95eae902fe2642` |
| `RillMenuBar.svg` | `7b0c39721acffe472f39125ed3db33a7d7b64a7d7c53571ddfec8b4189361388` |
| `RillMenuBarTemplate.pdf` | `868bc83786453d77c52659e1d545f3c6780da0548dc4d1f350824dfe22304480` |
| `RillMenuBarRecordsTemplate.pdf` | `b048f2ae23909b39d5d9d01232dd6f98ae62aac9f8174ac20b6c79aa8384c749` |

The prior generated raster and its image-generation prompts are preserved in
Git history. `AppIcon-1024.png` remains an unbundled earlier exploration; it is
not an input to either generator.

Rendered previews and automated ICNS checks establish artwork and packaging
properties. Installed Finder/Dock/menu-bar behavior on supported macOS versions
and VoiceOver interaction remain separate checks in
[the release QA checklist](../../docs/release-qa-checklist.md).
