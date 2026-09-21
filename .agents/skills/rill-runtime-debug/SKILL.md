---
name: rill-runtime-debug
description: Diagnose Rill recording, speech-worker, cancellation, timeout, stale-result, or shutdown failures. Use for an observed runtime symptom or its fix, not a speculative architecture proposal or ordinary feature implementation.
---

# Rill Runtime Debug

Find the first divergence between the expected lifecycle and the observed run.
Follow the requested scope: diagnosis ends with evidence and a repair direction;
an authorized fix continues through implementation and verification. Respond in
the user's language.

## Identify the failing run

Record the reproduction, expected result, and observed failure. Establish the
running app's path, version/build, process identity, worker identity where
relevant, selected provider, permissions, and source or artifact revision when
known. A newly built binary does not prove the running app contains that code.

Use existing diagnostics and harmless test input. Keep transcripts, audio,
clipboard bodies, credentials, and unrelated application content out of logs.
Do not reset user databases, remove permissions, or kill unrelated processes as
a diagnostic shortcut. Reproduce in a disposable fixture or a specifically
identified process when the task requires intervention.

## Trace ownership across suspension

Read [architecture](../../../docs/architecture.md) and locate the relevant
owner, such as `RecordingSessionManager`, `SessionCoordinator`,
`SpeechWorkerSupervisor`, or `PersistenceWriteCoordinator`. Follow the actual
event chain from trigger and authorization through capture, provider request,
result, persistence, delivery, and cleanup, skipping stages unrelated to the
symptom. Correlate request/run identity and ordering rather than matching only
similar timestamps or error strings.

Compare the last confirmed transition with the first missing, duplicate, or
stale one. Form a falsifiable hypothesis about that boundary and select the
smallest observation or controlled reproduction that can reject it. Label
hypotheses separately from demonstrated causes; missing logs are not proof of
a worker, permission, or concurrency failure.

Cancellation requests termination; it does not establish that work has drained.
Check which owner retains every accepted task, resource, lease, callback, and
cleanup action until completion. Inspect identity checks after suspension,
replaced operations whose stores ignore cancellation, shutdown admission of new
work, and cleanup that itself suspends. Reject stale results without losing the
ability to await their cleanup. Check the final synchronous effect boundary for
cues or output that can become stale during a MainActor hop.

## Prove a repair

Use a controlled fake, barrier, or lease to hold the suspect operation at the
boundary, trigger cancellation/replacement/shutdown, and then release it. Observe
the user-visible outcome plus resource cleanup and pending-task ownership.
Prefer this to longer timeouts, retries, or sleeps that merely hide ordering.

Repair the owner or transition responsible for the failure and verify the
production caller uses it. Run targeted regression checks through the locked
Swift wrapper described in [CONTRIBUTING.md](../../../CONTRIBUTING.md). Add
macOS interaction checks only for the native boundary the repair crosses; use
[the QA checklist](../../../docs/release-qa-checklist.md) for that evidence.

Report the reproduction and exact artifact when known, the demonstrated cause
or remaining hypotheses, changes made within scope, verification, and unresolved
evidence. A successful fake-worker test does not establish that microphone input,
global Fn gestures, or the installed app now work on the user's machine.
