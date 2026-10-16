# Documentation and code-map acceptance — 2026-10-16

This record describes the work based on source revision
`0aa792c6fad8d6c5a4728eab71e364773a9e4118`. It is historical validation evidence,
not a release or native-interaction sign-off.

## Source and navigation

The atlas contains 19 source targets, one external-dependency group, 72 declared
relationships and four ordered flows. The 726-file SHA-256 manifest covers the
complete Sources inventory, Tests inventory and the map's evidence/generated
files. The inventory and representative test declarations were refreshed against
this revision. Runtime relationships were checked through AppBootstrap,
WorkflowOutputExecutor, RecordStore and the independent input-method controller;
they do not imply compile-time imports. The dictation trace explicitly selects
the local-model path. GRDB is included in the external dependency description.

`python3 scripts/codemap.py check` validates inventory, paths, declaration lines,
content hashes and generated HTML. Locked offline Zensical 0.0.70 builds pass.
Lock schema version 2 stores `path` and `sha256` separately; a filename such as
`JevAPIKey.swift` is not represented as an apparent key/value credential.
Map links encode path segments and anchor components separately, so filenames
containing `+`, spaces, `#` or `?` retain their intended URL meaning.

## Browser acceptance

The existing headless Chromium 153.0.8010.12 runtime was reused without installing
a browser or dependencies. Viewports were 1440 × 1000 and 390 × 844. The map was
opened through both `file://` and a loopback asset preview; the complete generated
Zensical site was also served over loopback.

All 31 map checks passed, with zero browser errors or missing baseline paths.
Two additional checks verified special filename URL components and malformed
hash navigation. Map checks cover every module in both relationship lenses, all four workflows,
module/file/no-result searches, Space/Enter navigation, selected detail focus,
narrow-screen detail jumps, overflow, evidence file existence and hosted source
paths in the baseline commit. Test declarations are navigation evidence, not
executed test or coverage claims. External GitHub HTTP reachability and production
deployment are outside these checks.

The complete documentation site passed 23 browser checks: guide → map → guide,
map downloads, four maintainer search queries, native dialog/combobox/listbox
semantics, Enter/Space filter activation, modal Tab boundaries, synthetic
composition Escape, repeated opens, close-button and Escape focus restoration,
ArrowDown/Enter result navigation, light/dark and reduced-motion behavior at both
viewports, instantaneous page navigation with keyboard disclosure controls, and
TOML/Schema downloads. No uncaught page errors were observed.

The old theme adapter duplicated behavior that Zensical 0.0.70 now owns. It was
reduced to localized names, recovery guidance, reduced motion and focus
restoration after the native dialog's close event. The obsolete dialog role on
the header trigger wrapper was removed. Navigation enhancement now follows the
theme's `document$` page lifecycle, so keyboard behavior survives instantaneous
navigation. Before/after captures and the complete check results remain in the
coordinating task's local evidence bundle.

## Native boundary

`UV_OFFLINE=1 RILL_RECORD_STRESS=1 just ci` was attempted with Xcode 27.0
(27A5228h), Swift 6.4 and macOS 27.0.1. Repository hooks and documentation passed;
the preflight toolchain stage passed, then the repository stage stopped at the
history secret scan. Its 16 matches are SHA-256 entries in the retained local
stash's old code-map lock, each independently verified against the recorded Git
baseline. The stash is preserved and the scanning policy is unchanged. Scanning
the complete current source snapshot with Gitleaks 8.30.1 passed after the lock
schema change. Domain/native/desktop/Release stages were not reached by that
local preflight, so it is not a complete local CI pass.

The current Mac was inspected during this run. Xcode and Metal are installed,
but the native computer-use surface reported a locked Mac and could not expose
applications. This is a fresh observation, not the earlier missing-Xcode result.
Browser composition events do not establish physical IME behavior, and browser
screenshots do not establish application, microphone, Fn, paste, VoiceOver,
multi-display or notarized-release acceptance.

The repository's desktop test and Release panel benchmark require an unlocked,
otherwise idle desktop. A successful map or documentation build does not satisfy
those gates. The remaining native matrix is the current release QA checklist;
benchmark comparison requires base/head runs on the same machine with retained
raw samples and matching toolchain/session conditions. No application was
installed and no user records or settings were changed by this documentation
work.
