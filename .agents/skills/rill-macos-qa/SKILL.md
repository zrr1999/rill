---
name: rill-macos-qa
description: Verify Rill behavior at macOS boundaries such as Fn gestures, microphone permissions, paste, focus, IME, VoiceOver, and installation trust. Use for native interaction acceptance or release-artifact QA, not pure model or formatting changes.
---

# Rill macOS QA

Tie each acceptance claim to an observed interaction on an identified artifact.
Respond in the user's language.

## Set the evidence boundary

Read only the sections of [the QA checklist](../../../docs/release-qa-checklist.md)
that match the changed behavior. For UI and focus work, also read
[UI direction](../../../docs/ui-direction.md) and the focus contracts in
[CONTRIBUTING.md](../../../CONTRIBUTING.md). A targeted regression needs its
affected interaction matrix; a release sign-off needs the release checklist.

Identify the app path, bundle version/build, process, macOS version, architecture,
relevant permissions, and target application. Record the source revision or
artifact hash when available. If provenance is unknown, keep that uncertainty
in the result. Check for another running copy before attributing behavior to a
new build. Installing or signing a build is not an interaction test.

Keep distinct evidence for:

- Model and deterministic lifecycle tests.
- Render, AppKit integration, or accessibility-tree inspection.
- Observed interaction with the running app and macOS.
- Acceptance of the exact release candidate, including trust and installation.

A screenshot can establish visible state, not a completed gesture, focus
transition, spoken output, or VoiceOver experience. Local development signing
and a passing unit suite do not establish notarization or Gatekeeper acceptance.

## Exercise the affected interaction

Use harmless, identifiable sample content and describe the expected result
before performing the action. Choose the relevant cases from the current
checklist, for example:

- Fn press/release, toggle or hold semantics, cancellation, and cue timing.
- Microphone permission, denied access, capture start/stop, and cleanup.
- Native copy/paste versus explicit Rill insertion, focus changes, newer
  clipboard content, and IME composition in the target application.
- First and repeated search focus, list selection, keyboard routing, dismissal,
  and exact detail focus when changing shell or AppKit bridges.
- Keyboard access, VoiceOver labels/order, and announcements for touched UI.

Check the failure or interruption that threatens the changed contract rather
than repeating every checklist item for every patch. Preserve user data and
settings; clean up only test state created by this run. Do not send sample text
to a real recipient or change the user's system-wide setup to manufacture a pass.

Use available interaction tools only for actions they can actually perform and
observe. If physical Fn input, a locked-screen scenario, audible output, or
another required observation is unavailable, leave that case unverified and
give precise manual steps. Synthetic key events or a fake capture source are
evidence for their own path, not substitutes for the physical interaction.

## Record the result

For each tested case, capture artifact/environment, action, expected and observed
behavior, and evidence. Mark it passed, failed, or unverified; name the reason
when unverified. Report regressions with reproducible steps and the affected
boundary. Refer runtime failures back to their owning component for diagnosis
without speculating from the UI symptom alone.

Release claims apply only to the tested candidate and completed release matrix.
Report remaining device, OS, permission, accessibility, or trust checks explicitly;
neither source inspection nor local CI can sign off those missing observations.
