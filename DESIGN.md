---
name: Rill native macOS
description: A quiet native Mac workspace for dictation, content reuse, and editable drafts.
typography:
  title:
    fontFamily: "system-ui"
    fontWeight: 600
  headline:
    fontFamily: "system-ui"
    fontWeight: 600
  body:
    fontFamily: "system-ui"
  supporting:
    fontFamily: "system-ui"
  subtitle:
    fontFamily: "system-ui"
    fontWeight: 500
  timer:
    fontFamily: "system-ui"
    fontWeight: 600
    fontFeature: "tnum"
  key-hint:
    fontFamily: "ui-monospace"
    fontWeight: 500
  draft-editor:
    fontFamily: "system-ui"
    fontSize: "14pt"
rounded:
  chip: "6pt"
  badge: "8pt"
  row: "10pt"
  section: "12pt"
  card: "14pt"
  panel: "16pt"
  recorder-compact: "24pt"
  recorder-expanded: "20pt"
spacing:
  compact: "4pt"
  row: "8pt"
  card: "12pt"
  panel: "16pt"
  section: "20pt"
  page: "24pt"
components:
  main-window:
    width: "960pt"
    height: "720pt"
  main-sidebar:
    width: "200pt"
  settings-window:
    width: "760pt"
    height: "640pt"
  settings-sidebar:
    width: "176pt"
  unified-panel:
    width: "668pt"
    height: "468pt"
    rounded: "19pt"
  unified-panel-compact:
    width: "620pt"
    height: "320pt"
  panel-sidebar:
    width: "194pt"
  panel-mode-control:
    width: "192pt"
  pending-strip:
    width: "260pt"
    height: "48pt"
    padding: "0pt 12pt"
  panel-search:
    height: "30pt"
    padding: "{spacing.panel}"
  draft-editor:
    typography: "{typography.draft-editor}"
    padding: "4pt 22pt"
  card:
    rounded: "{rounded.card}"
    padding: "{spacing.panel}"
  recorder-compact:
    width: "248pt"
    height: "48pt"
    rounded: "{rounded.recorder-compact}"
    padding: "0pt 12pt"
  recorder-expanded:
    width: "360pt"
    height: "96pt"
    rounded: "{rounded.recorder-expanded}"
    padding: "10pt 14pt"
---

# Design System: Rill

## Overview

**Creative North Star: "Quiet native Mac workspace"**

Rill uses SwiftUI and AppKit on macOS 26 or later. System typography, semantic
colors, native selection, and compact controls keep dictation and content reuse
close to the user's current task. The existing Rill identity and recording
overlay remain the visual baseline. Content, its current state, and the next
useful action establish hierarchy.

This document records the approved implementation, replacing the earlier visual
seed. [PRODUCT.md](PRODUCT.md) provides product constraints;
[UI direction](docs/ui-direction.md) owns navigation and interaction contracts.
The tokens above describe current source values in logical macOS points. Window
and sidebar tokens are default or preferred sizes, except the explicitly named
minimum and fixed recording/strip surfaces. `system-ui` and `ui-monospace` name
native font families; the SwiftUI roles remain authoritative. Semantic colors
cannot be represented faithfully as fixed CSS colors, so they are mapped below
without invented RGB values or tonal ramps.

**Key Characteristics:**

- Native navigation and controls, with opaque reading and editing surfaces.
- All Records, Activity, and Workflows grouped above Collections.
- Collections and Drafts share one panel and retain their native view state.
- The existing compact and expanded recording overlay remains recognizable.

The floating panel has compositor-rendered evidence from temporary synthetic
windows on macOS 27.0 (26A428), using Xcode 27.0 (27A5228h). Captures cover both
modes, English and Chinese, light and dark appearances, three page sizes, and
focused scenes for native control states. Those captures are visual evidence,
not installed-app or release acceptance. Record automated validation with the
reviewed change and pull request. Physical macOS 26, Fn, IME,
VoiceOver, cross-application output, and multi-display acceptance remain pending.
Use the [release acceptance contract](docs/release-qa-checklist.md); local
galleries are review aids, not durable design authority.

## Colors

The palette follows the current system appearance and user accent. Background,
text, selection, and status use their native semantic roles.

| Role | Native mapping | Use |
| --- | --- | --- |
| Primary accent | `Color.accentColor` | Primary actions, selected custom controls, pending-content entry |
| Primary text | `.primary`, `NSColor.labelColor` | Labels, content, and the normal recording waveform |
| Supporting text | `.secondary`, `NSColor.secondaryLabelColor` | Sources, time, save state, keyboard hints, recognition hypothesis |
| Window surface | `NSColor.windowBackgroundColor` | Opaque workspace/panel base and recorder transparency fallback |
| Control surface | `NSColor.controlBackgroundColor` | Floating header/strip accessibility fallback and key hints |
| Editor surface | `NSColor.textBackgroundColor` with `NSColor.textColor` | Native editable draft text |
| Separation | `NSColor.separatorColor`, native `Divider` | Boundaries between controls and content |
| Selection | Native `List(selection:)` and native controls | Emphasized and inactive selection, including the corresponding text color |
| Warning / failure | `Color.orange` / `Color.red` | Actionable warnings, failed saves, recording duration limits |

**The Native Selection Rule.** Let native lists and controls resolve selection
background and foreground together. Custom row selection uses `rillSelection`;
its accent wash and contrast-aware border are a separate treatment, not a
replacement for native list selection.

Status includes text and an action or symbol; color alone does not communicate
failure or confirmation. Resolve SwiftUI colors in the view's current environment
before passing them to fixed-color Core Animation layers, as
[VoiceActivityIndicator](Sources/RillUI/VoiceActivityIndicator.swift) does for
the recording waveform.

## Typography

Use the macOS system font and platform Chinese fallback. There is no separate
display face. The floating workspace is a local exception to default control
metrics: its approved B preview uses 17pt document headings, 14pt body text with
7pt added line spacing, 12pt actions and list titles, and 11pt supporting text.
These values belong to this compact surface, not an application-wide type scale.

| Token role | Source role | Use |
| --- | --- | --- |
| `title` | `.title2.weight(.semibold)` | Sheet and content-operation titles |
| `headline` | `.headline` | Section and disclosure headings |
| `body` | `.body` or native default | Record text and ordinary labels |
| `supporting` | `.caption` | Source, time, save state, and action hints |
| `subtitle` | `.callout.weight(.medium)` | Live recognition text |
| `timer` | `.caption.monospacedDigit().weight(.semibold)` | Stable recording time and countdown |
| `key-hint` | `.caption2.monospaced().weight(.medium)` | Recorder Esc key hint |
| `draft-editor` | `NSFont.systemFont(ofSize:)` | Native `NSTextView`; explicit size is in frontmatter |

The editor's exact font and text insets come from
[BufferDraftTextEditor](Sources/RillUI/BufferDraftTextEditor.swift). SwiftUI
supporting variants also use `.subheadline.weight(.medium)`, `.caption2`, and
semibold captions where needed; they are native roles rather than another
application-wide size scale.

**The Stable Label Rule.** Preserve functional labels and counts at their
intrinsic width. Truncate the next-item preview, not the Drafts entry name;
allow longer English and Chinese labels to wrap where the control permits it.

## Layout

Spacing follows [RillSpacing](Sources/RillUI/RillCard.swift): compact inline
gaps, row gaps, card insets, panel insets, section gaps, and page margins. Reuse
those named steps. Component-specific dimensions, such as the recorder's text
insets and the native editor's padding, remain local to their owners.

| Surface | Implemented layout | Source |
| --- | --- | --- |
| Main window | Default size in frontmatter; sidebar min/ideal/max 180/200/260pt | [App scene](Sources/RillApp/VoiceInputApplication.swift), [MainShellView](Sources/RillUI/MainShellView.swift) |
| Records | Split list/detail at 700pt of record content width; narrower content shows list or selected detail | [RecordWorkspaceView](Sources/RillUI/RecordWorkspaceView.swift) |
| Settings | Same main window; settings sidebar min/ideal/max 160/176/220pt; Back returns to the previous page | [MainShellView](Sources/RillUI/MainShellView.swift), [SettingsDetailView](Sources/RillUI/SettingsWindowView.swift) |
| Unified panel | Default and compact verification sizes in frontmatter; geometry is selected before opening and stays fixed during interaction | [RecordPanelPlacement](Sources/RillApp/RecordPanelPlacement.swift), [RecordPanelController](Sources/RillApp/RecordPanelController.swift) |
| Collections preview | Fixed 194pt list column beside an opaque content preview | [RecordQuickPanelView](Sources/RillUI/RecordQuickPanelView.swift) |
| Drafts | Fixed 194pt native list with single-line titles and metadata beside the native editor | [RecordBufferDraftView](Sources/RillUI/RecordBufferDraftView.swift) |
| Pending strip | Fixed capsule, separate from the page; drag, hover, accessible open, and close | [RecordPanelCapsuleView](Sources/RillUI/RecordPanelCapsuleView.swift), [RecordPanelController](Sources/RillApp/RecordPanelController.swift) |
| Recording overlay | Fixed compact/expanded surface sizes in frontmatter; shadow insets are outside those surfaces | [LiveSubtitleOverlay](Sources/RillUI/LiveSubtitleOverlay.swift) |

The six Settings panes are General, Input, Voice & Models, Vocabulary & Memory,
Privacy, and Data. They replace the main sidebar until Back. The selected pane
is the window subtitle; mounted hidden panes preserve drafts while remaining
outside hit testing and accessibility navigation.

Main-window navigation keeps All Records, Activity, and Workflows in one top
group, Collections below, and Settings in the bottom inset. A single toolbar
search opens grouped results. The Records compact Back path preserves selection;
exact record navigation opens detail again even for the same selected record.

## Elevation & Depth

Native window and panel depth carries the hierarchy. The unified panel uses a
standard material backdrop, with Liquid Glass on the pending capsule, navigation
sidebar, selected mode, and action buttons. Each mounted mode owns a separate
`GlassEffectContainer` so hidden effects cannot join the visible pane. The header
has its own container. Custom effects apply directly to their content;
native `.glass` and `.glassProminent` button styles own pointer, pressed, and
disabled feedback. The primary action uses the system accent color. Reading
surfaces, record previews, and draft editing stay opaque; individual records do
not receive glass shells.

The sidebar and paper are inset 8pt. `ConcentricRectangle` resolves their corners
inside the panel's container shape. The selected mode uses `glassEffectID` and
a short matched geometry transition, without animating the editor or window
geometry. This follows Apple's [Liquid Glass guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
and [material hierarchy](https://developer.apple.com/design/human-interface-guidelines/materials).

**The Content Surface Rule.** Keep text and payloads on their own opaque surface.
Apply translucent material to navigation and controls without lowering the
opacity of their text or icons.

The preserved recorder uses `.thinMaterial` with a semantic window-color tint.
Reduce Transparency changes it to an opaque window background. Increase Contrast
strengthens its tint and separator border. For the unified panel's custom glass,
either Reduce Transparency or Increase Contrast selects an opaque control
background. Native materials and glass buttons also retain their system
accessibility adaptations.

The recorder has one soft black shadow and a separator stroke; its exact shadow,
tint, and border values are in the sidecar. The floating panel uses
`NSPanel.hasShadow`. Shared cards use quaternary tonal fills through
`RillCardProminence`, not a shadow stack.

Reduce Motion disables the custom card/selection transitions, panel fades, and
meter interpolation. The recorder's geometry transition has one AppKit owner.
Motion constants and their source symbols are recorded in the sidecar; none of
these transitions delays capture, editing, or output authorization.

## Shapes

[RillRadius](Sources/RillUI/RillSelection.swift) supplies the chip, badge, row,
section, card, and panel radii in frontmatter. Rounded rectangles use continuous
corners where specified by the source. Native buttons, lists, fields, and window
chrome keep their platform geometry instead of being wrapped in new borders.

The recorder is the explicit local exception to the shared radius scale: its
compact capsule and expanded surface use the two recorder radii. Preserve that
silhouette and the space reserved for timer, Esc hint, and near-limit action.

## Components

### Native actions and navigation

Use native buttons and menus. Explicit output uses `.borderedProminent`;
secondary copy and administration remain separate actions. Compact panel controls
use `.controlSize(.small)`. Records keeps Copy reachable and secondary actions in
the More menu. Selection, hover, keyboard focus, and inactive-window appearance
come from native controls. Functional icons use SF Symbols through existing
project conventions; icon-only buttons retain help and accessibility labels.

The floating workspace follows the approved B preview: a quiet text action for
finishing editing or adding a draft, a subtle outlined Copy button, and a solid
foreground-colored Send button. `RecordPanelActionStyle` styles native Buttons
without replacing their activation or accessibility semantics. Their 31pt height
and fixed widths do not change with selection, status, or output confirmation.

### Search and text input

`RecordSearchField` and the global-search bridge retain `NSSearchField` focus and
keyboard handling. The panel search height and padding are extracted above;
global search remains navigation and does not paste a selected result.

Drafts uses one mounted `NSTextView` with native selection, undo, scrolling, and
IME composition. Return inserts a newline in the editor; Command-Return sends
explicitly outside composition. The list's Return action, layered Escape, and
target handoff follow [continuous output](docs/continuous-output.md). Preserve
the editor, query, selection, and undo state across panel mode changes.

### Unified panel and pending strip

[UnifiedRecordPanelView](Sources/RillUI/UnifiedRecordPanelView.swift) hosts
Collections and Drafts behind one segmented control and one
[RecordPanelController](Sources/RillApp/RecordPanelController.swift) lifecycle.
Hidden content remains mounted but cannot receive interaction or accessibility
focus. Collections keeps Copy, Add to Drafts, and explicit output distinct.

Drafts retains two independent native checkbox controls for collecting voice and
clipboard content. Voice collection changes the built-in Fn output mode; turning
it off returns Fn dictation to the current application while Record new item
still collects into Drafts. Clipboard collection admits new copies after it is
enabled and follows existing privacy exclusions. Each control uses its existing
settings command and mutation availability. The item list uses `.listStyle(.inset)`
with native selection colors. See
[RecordBufferDraftView](Sources/RillUI/RecordBufferDraftView.swift).

The pending capsule shows a count, reserved attention mark, and close. It is
separate from the recorder's position and state. When a collection source is
restored as enabled after settings load, or is newly enabled while the panel is
hidden, the controller shows the collapsed strip without taking keyboard focus.
An already open editor retains its current input. Send selected collapses the
editor and keeps the strip visible; confirmation and recovery continue through
the existing output state. Expanding or switching modes does not send content.

The draft output target is captured when the panel begins a new active editing
visit, immediately before becoming the key window. Background presentation,
mode changes within the same editing visit, and Send do not recapture or retarget
it. The displayed target remains controller-owned and is revalidated at the
output boundary. A persistent strip does not authorize reuse of a stale target.

The capsule retains its position under `RillRecordCapsule`. Hover opens a separate
668×468pt page after 300ms; available screen space may reduce its size before
opening. Crossing the gap keeps the page visible, and leaving both windows starts
a 700ms delay. Editing, pointer presses, composition, sheets, and pinning hold the
page open. Dragging moves the two windows together. The page has no collapse
button, and content changes never move its controls. These behaviors are owned by
[RecordPanelController](Sources/RillApp/RecordPanelController.swift).

### Cards and disclosure

`rillCard` uses the frontmatter padding and radius by default, with prominent,
regular, and subdued quaternary fills. Use it for existing grouped or actionable
content. Native lists and forms do not need additional card wrappers.
`RillCardButtonStyle` supplies a hover border and a small press response for
interactive cards, with reduced-motion behavior.

Record bodies and Copy lead the detail view; collection membership and metadata
use disclosure. Activity emphasizes current work, pending choices, and recovery,
while successful runs stay compact. Workflow details lead with purpose, trigger,
output, and enabled state before optional technical steps. Setup sheets fit their
missing-condition content with a bounded scroll area and a visible skip action.

### Recording overlay

Preserve the incumbent compact/expanded composition, measured waveform,
streaming text, network disclosure, monospaced timer, Esc hint, and near-limit
continue action. It remains an active-recording surface, not the Drafts editor.
The waveform stays neutral until measured levels arrive; its environment-resolved
semantic color follows the current appearance. See
[LiveSubtitleOverlay](Sources/RillUI/LiveSubtitleOverlay.swift),
[VoiceActivityIndicator](Sources/RillUI/VoiceActivityIndicator.swift), and
[LiveSubtitlePanelController](Sources/RillApp/LiveSubtitlePanelController.swift).

## Do's and Don'ts

### Do

- **Do** preserve native controls, semantic colors, system typography, and the existing Rill icon assets.
- **Do** keep content and editing opaque, with accessibility fallbacks local to the material owner.
- **Do** preserve RecordStore, draft revision, privacy, capture, and delivery ownership while changing presentation.
- **Do** preserve search focus, exact navigation, Settings deep links, native undo, IME precedence, and layered Escape.
- **Do** keep Copy, Add to Drafts, and explicit output distinct, with save and copy feedback based on actual results.
- **Do** preserve the current recording overlay structure and use measured audio levels for its waveform.
- **Do** verify English and Chinese, light and dark appearance, compact widths, and each accessibility display setting in the native app.

### Don't

- **Don't** replace semantic colors with a fixed RGB palette or synthesize a native tonal ramp from mockups.
- **Don't** force a selected text color independently of the native selection background and window emphasis.
- **Don't** create another content store, editor window, or output target when switching Collections and Drafts.
- **Don't** turn workflow descriptions into visual editing controls or model summaries into a new global selector.
- **Don't** treat static renders, synthetic browser previews, or local checks as physical macOS or release acceptance.
