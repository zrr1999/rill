# Transcript-first contextual correction

Screen context, long-term memory and vocabulary correction are separate, opt-in
controls in Settings. Screen and memory references apply to authorized voice workflows whose only LLM step is one rewrite and
which have no snippet-expansion step. Voice-assistant workflows and historical
audio replay do not capture a screen. Changing the
provider, credentials or privacy configuration revokes the grant. Enabling the
feature requires a new grant for the selected provider and current workflows.

The recognized transcript is the sole content source. References can resolve
clear recognition errors in names, homophones and identifiers; they cannot add
facts, answer questions, change tone, remove uncertainty, or substitute a newer
fact for the user's words. The provider receives this fixed contract independently
of user-controlled reference data. Ambiguous evidence must preserve the transcript.
A numeric mismatch additionally falls back to the complete transcript locally.
This guard does not prove semantic correctness; model behavior needs live evaluation.

## Vocabulary references

Vocabulary correction applies only to new recordings using the canonical builtin
Smart Cleanup with its default cleanup instruction. Custom workflows, altered
rewrite prompts, text input and historical audio do not acquire this reference.
It uses its own default-off consent switch and the existing provider-bound grant;
no screen permission or memory access is required. Sensitive source applications,
Secure Input, cloud privacy restrictions and revoked grants prevent its use.

`VocabularyRecognitionHintResolver` retains all enabled, applicable, deduplicated
hotwords after workflow binding and scope filtering. `ResolvedWorkflowPlan` keeps
this complete list separately from the existing 50-candidate ASR projection,
even when the recognizer does not support hotwords. `PrivacyRunGate` passes the
admission snapshot to `ContextMemoryController`; no second vocabulary read occurs.
ASR provider limits, Jev ranking and local mapping rules remain unchanged.

`CorrectionVocabularyReference` packs whole terms in existing priority order into
at most 12,000 UTF-8 bytes, including the encoded glossary object's JSON overhead
and escaping. Oversized terms are skipped and packing continues. This is an LLM
reference budget, not a claim about the ASR model's context capacity. Vocabulary
edits during recording apply to the next run. No extra model call is introduced.

`RunContextPreparation` owns the ready glossary alongside the optional tasks.
A failed or timed-out screen/memory preparation preserves it. Freezing transfers
it into `ContextualCorrectionRequest.vocabularyReference`; the shared
`hasCorrectionReferences` predicate bypasses the Jev polishing gate only when
usable references exist. Empty references preserve the normal cleanup path.
The provider serializes terms under `reference_data.vocabulary`, never as
instructions or mandatory replacements. The main request retains its 5-second
budget, one-call behavior and conservative transcript fallback.

History stores only eligible/included/omitted counts, encoded size and reference
status. Complete reference lists are absent from traces, receipts and memory
consolidation inputs; a term actually spoken can still occur in normal history.
Older settings decode with vocabulary correction disabled, and older receipts
have no vocabulary section. No persistence schema or source-version change is
needed for these optional fields.

## Request ownership and timing

- `ScreenContextCapture` locates the display from the focused input element,
  excludes Rill and enabled sensitive applications, and produces an in-memory
  JPEG no larger than 2560 pixels / 2 MiB. AX IPC has short timeouts, and both AX
  work and JPEG encoding run off the main actor.
- `PrivacyRunGate` prepares the snapshot before microphone start. The 250 ms
  deadline includes optional provider/history lookups and discards late frames.
  Missing permissions or capture failures skip
  context without preventing recording.
- `RunContextPreparation` starts independent image and memory summary requests
  after microphone capture starts. Each has a 10-second deadline. It freezes
  already-completed results synchronously when recognition ends. No task group
  teardown or join delays the main request; unused memory work is cancelled.
  Explicit candidate choices, vocabulary replacements and local cleanup still
  determine the transcript passed to the rewrite; they do not refresh references.
- `CapturedAudioProcessingQueue` transfers that same preparation to
  `SessionCoordinator`. The Responses request has a 5-second budget and runs once.
  Recoverable errors retain the existing transcript fallback; cancellation and
  privacy failures stop delivery. A late result never changes delivered text.
- Successful screen summaries can update the same still-current encrypted history
  source within the auxiliary lifetime. Source revisions advance; evidence counts
  do not. Images, base64, temporary memory summaries and glossary reference lists are never persisted.

History lists reference readiness/sending states. Sending a reference is not a
claim that a correction is verified. Failed requests have an unconfirmed-delivery
state. The stored LLM trace contains transcript text, not the full multimodal input.

## Memory ownership and forgetting

`SQLitePersistenceStore` remains the sole transaction owner. Schema 14 adds
protected memories, source revisions/cursors, authorization and daily counters,
and permanent-deletion exclusions. Its authenticated schema and writer barriers
prevent old writers from silently bypassing source revision tracking.

Sources are grouped by recording ID, including revisions, cleanup outputs,
explicit vocabulary corrections, and screen observations. Screen observations
remain a separate evidence kind. Runtime extraction receives only matching terms
and confirmed corrections from at most five active memories, never broader
personal summaries. Existing vocabulary rules continue to own term replacement.

Automatic consolidation can merge only compatible unconfirmed, unlocked entries.
New correction/replacement proposals need confirmation. Editing a candidate and
confirming it activates it; locks prevent automatic replacement. Users can set an
explicit expiry in the editor. Expiry and confirmed replacement archive memories;
inactivity changes ranking only. History deletion preserves committed memories.
Memory deletion also excludes every contributing source from future learning.
Temporary runtime memory summaries never enter the source table.

Each commit atomically verifies the authorization permit, history generation,
source versions and memory revision before advancing the cursor. Revocation and
commit share a synchronous lock boundary after acquiring the database write lock,
so a busy database does not stall input freezing or revocation. UI operation generations prevent an old
save/load completion from silently reauthorizing after a configuration change.
Each recording has a child permit: cancelling it also rejects queued screen-summary
writes at commit without revoking other recordings or the user's grant.

## Idle organization

The macOS scheduler requests work every 15 minutes with 5 minutes of tolerance.
It starts only after 5 minutes of continuous system idle and when both recording
controllers, both audio queues, session coordinator, playback and history
maintenance are idle. Activity, a recording start, sleep or revocation cancels
work; interrupted batches remain pending across restart.

Batches contain at most 10 sources and 12,000 encoded UTF-8 bytes, with a 30-second
model deadline. Eight daily background reservations include failures/cancellation.
A UTC date boundary resets this budget; rolling the clock backwards cannot refill
it. Frontend summaries have a separate counter; main request usage appears in
history. No pending eligible sources means no model request. Ineligible local
pages can be scanned without a model call, and only an actual scope change retries
them. Normal maintenance produces no notification.

## Validation and manual acceptance

The targeted tests cover freezing without waiting, ignored cancellation, independent
summaries, queue-to-provider delivery, encoding and redaction, source deduplication,
provenance, encrypted persistence, clear/revoke/delete races, expiry, daily limits,
background preemption, and stale UI authorization completions.

`Tests/Fixtures/ContextCorrection/cases.json` contains 40 fixed synthetic cases.
The opt-in provider test renders each reference in memory and compares the existing
text-only cleanup with reference-assisted cleanup. It writes only text outcomes,
content-match judgments, fallback counts and latency to
`.artifacts/contextual-memory-20260920/live-evaluation.json`:

```sh
# Supply DEEPSEEK_API_KEY securely in this process environment.
RILL_CONTEXT_LIVE_EVALUATION=1 scripts/swift_locked.sh test --filter ContextualCorrectionEvaluationTests
RILL_CONTEXT_MAC_PROBE=1 scripts/swift_locked.sh test --filter ScreenContextCaptureTests
```

The fixed expected-content match ignores whitespace, punctuation and letter case.
It is a regression signal, not a human semantic judgment. Review mismatches for
improvements, unnecessary changes, invented facts and lost negation/conditions;
report latency and fallback rate alongside accuracy. The dataset is intentionally
small and cannot establish production accuracy.

The vocabulary-only corpus in `Tests/Fixtures/VocabularyCorrection/cases.json`
contains 40 fixed synthetic cases covering names beyond the ASR candidate cap,
identifiers, irrelevant terms, renamed projects, negation, numbers and reference
injection. Its opt-in evaluation holds the correction prompt, transcript and
5-second deadline constant while varying only reference data. It repeats each
case three times and reverses group order on the second repetition. This isolates
reference value; the text group is not a measurement of Jev or the old workflow
prompt. Empty transcription makes no request.

```sh
# Supply DEEPSEEK_API_KEY securely in this process environment.
RILL_VOCABULARY_LIVE_EVALUATION=1 scripts/swift_locked.sh test --filter VocabularyCorrectionEvaluationTests
```

The report at `.artifacts/vocabulary-correction/live-evaluation.json` contains
per-call output, exact matches, fallback flags, reported token usage, reference
counts and P50/P95 request latency. Missing token usage stays null. Exact matches
ignore only surrounding whitespace, preserving identifier case and punctuation;
manual review must distinguish harmless formatting from semantic overcorrection.
These request measurements do not measure microphone-to-insertion latency or ASR
accuracy. The normal run history continues to record ASR and LLM time separately.

The third group uses **actual ASR terms only when known**. The synthetic corpus
has no actual ASR witness, so its report explicitly lists skipped comparisons.
An explicitly supplied `RILL_VOCABULARY_EVALUATION_CASES` JSON path may add
`asrEvidence: {terms, usedCount, omittedCount, provenance}` per sample. The terms
must come from the final provider/worker input, with matching usage counters and
zero further omissions; a pre-tokenizer candidate list is insufficient. Running
that opt-in test uploads the selected corpus. Never infer this evidence from the
first 16/50 candidates or substitute a mock result for live evaluation.

For vocabulary acceptance, start with screen permission denied and screen/memory
features off. Enable only vocabulary correction, record a clearly spoken project
name beyond the ASR budget in builtin Smart Cleanup, and inspect reference counts
plus separate ASR/LLM durations in that run's history. Edit the vocabulary during
recording and verify only the next recording sees it. Disable the switch or revoke
the provider during a request and verify no stale result is delivered. Repeat a
custom workflow, text replay and failed-audio retry to confirm no glossary upload.
These checks require the candidate App, microphone and actual target text field;
the opt-in settings render does not establish their result.

Physical acceptance needs an unlocked Mac with Accessibility and Screen Recording
permissions: record short and long utterances in a real text field, move the input
between displays, put a sensitive window on the captured display, revoke permission
while summaries are in flight, and start recording during idle maintenance. Check
that the mic starts after capture/skip, the correct display is selected, excluded
windows are absent, and no old result is inserted after cancellation. The automated
Mac probe reports permission/display availability and capture metadata; it does not
replace microphone, insertion or multi-display acceptance.

API shape: [DeepSeek Responses](https://api-docs.deepseek.com/guides/responses_api/).
