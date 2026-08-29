# Release QA Checklist

This checklist keeps two evidence layers together without treating them as
interchangeable. Automated prerequisites prove deterministic state-machine,
filesystem, packaging-policy, and hosted AppKit contracts. The checkboxes record
what was exercised with the exact packaged release candidate on real systems.
Copy this file for each candidate and keep it with both evidence sets.

## Automated prerequisite evidence

Attach the exact logs below before beginning candidate QA. A unit or policy test
does not tick a manual checkbox; it establishes the baseline that the packaged
candidate must then confirm.

> **Migration note.** Dated passages below that name `WhisperKit`, Argmax, or a
> Whisper model are retained only as historical evidence for superseded builds.
> They do not satisfy any current sherpa-onnx candidate gate. Current evidence
> must name the fixed public Qwen3-ASR catalog entry and the installed App.
> SenseVoice is an internal preview identity and cannot satisfy a public candidate gate.

> **Architecture note.** Current release candidates support Apple Silicon only
> and must contain exactly one `arm64` Mach-O slice. Dated Universal/Intel
> passages below are retained as historical evidence for superseded builds and
> do not satisfy the current arm64-only release gate.

> **2026-07-28 KWS working-source evidence — not candidate evidence.** The
> production downloader fetched the pinned 32,885,699-byte bilingual KWS
> archive, verified its archive and retained-file SHA-256 values, published the
> actual chunk-8 `left-64` inventory with a schema-2 receipt that binds the
> pinned Apache-2.0 evidence, encoded `Hey Rill`, and initialized/reset the
> production sherpa keyword spotter. A second run encoded `Light Up` and detected
> that phrase in upstream fixture `en_0.wav` through the same native runtime.
> This proves download, installation, tokenization, native configuration, and
> fixture detection only. It does not tick the real-microphone, false-wake,
> latency, multi-device, or minimum-macOS candidate checks below.

> **Completed working-source baseline — not candidate evidence.** On
> 2026-07-16, two complete preflight runs from the dirty development source each
> passed the complete Swift suite plus the expected opt-in ASR dogfood skip.
> `prek validate-config prek.toml` and
> `prek -c prek.toml run --all-files` also passed. These results establish that
> the named automated suites below passed in this development cycle; their exact
> logs and hashes were not retained as clean-candidate evidence. Test discovery
> and counts can change, so rerun every prerequisite from the final clean,
> uniquely tagged candidate and attach that candidate's logs and SHA-256 values.

> On 2026-07-16, the release script installed dirty-source build
> `0.0.0-dev+7703f9ef8121.dirty` with an Apple Development identity. The installed
> executable passed strict code-signature verification and had SHA-256
> `b4c20bc40143865dd472a868f1eb2206653e7062706d9327a5a606a0e359f422`.
> Qwen and the now-internal SenseVoice preview then completed an installed-App run in which macOS
> system TTS was played through the speaker and recaptured by the microphone; the
> resulting transcripts reached the reserved voice group and merged Recent
> Results surface. This completes evidence for that installed
> capture/runtime/storage loop only. System TTS → speaker → microphone is not
> human speech, does not measure human editing cost or model quality, and does not
> satisfy human-consented, multi-device, clean-candidate, notarization, or GA
> thresholds. It therefore does not tick any candidate checkbox below.

> A later 2026-07-16 working-source install included the local finalization fix
> and the disabled clipboard-shortcut presentation policy. Its preflight passed
> all 1,629 discovered Swift tests, and the Apple Development-signed installed
> executable had SHA-256
> `c73465d626481509ce975206ef98e1017836eadf7bd6c3f6cc1fba001eb6afaa`.
> Cold-start UI inspection confirmed clipboard capture off, no Dashboard
> clipboard card, no Settings hotkey recorder or Double-Command label, no menu
> shortcut annotation, and an intact Fn push-to-talk readiness path. For the
> installed Breeze smoke run, automation first observed the explicit
> `Stop and Transcribe` recording state and only then started speaker playback.
> The run completed through file-backed batch recognition and the reserved voice
> group, but its partial acoustic transcript still failed the reference. The
> same source audio transcribed nearly verbatim through the no-network batch
> harness. This isolates the former live-hypothesis finalization defect and
> validates ordering, while deliberately leaving microphone acoustics and human
> quality as open acceptance gates.

> A final 2026-07-16 working-source installation tightened the readiness
> contract: `recording` is now published only after the first accepted microphone
> buffer, and startup cancellation drains any late audio-engine start. The
> release preflight completed all 1,642 discovered Swift tests without failure;
> the installed Apple Development-signed executable had SHA-256
> `6aeb5884706fed5b61109297d0cd4ec67bffda691ffe9e63b5a58056d9b0c2bb` and passed
> strict signature verification outside the test sandbox. This supersedes the
> preceding smoke run's use of `Stop and Transcribe` as sufficient readiness
> evidence because that older UI state could precede the real audio-engine start.
> In the replacement installed Breeze run, the exact chain was first-buffer DB
> event `1784209545.781834` -> AX `Stop and Transcribe` observation
> `1784209546.025` -> playback launch `1784209571.414747` -> capture queued
> `1784209592.728913`. Run `6CEE378D-E1BC-40FD-B621-A8515146E178` completed with
> `whisperkit.local`, `pushedToStack`, and non-empty final text: `阿巴阿巴
> 今天下午三點我們同步一下 VoxTry 工作流程設計然後運行 Swift Test`. This proves
> installed capture ordering and the local runtime/storage path, not human speech
> quality; the `Rill` -> `VoxTry` substitution remains model-quality evidence.

> A subsequent 2026-07-16 working-source installation extended strict
> first-buffer readiness to the realtime local capture path. The AVAudio
> diagnostics fallback instead waits for `AVAudioRecorder.currentTime` to advance
> above zero before reporting readiness; that is a recorder-progress gate, not a
> strict first-accepted-buffer signal. The same installation removed diagnostic
> I/O from the hotkey press/release critical path, installed the shared event tap
> only after the recording consumer had subscribed, and made sidebar route focus
> ownership synchronous. Its release preflight completed all 1,660 discovered
> Swift tests without failure. The
> Apple Development-signed installed executable had SHA-256
> `6990a40ab823f6de80ede35887473f806de8834a5551a986555ea7ff4d1940fd` and passed
> strict signature verification. Installed-App inspection confirmed Clipboard
> Capture remained off and the panel shortcut remained disabled. A real mouse
> click changed the main-window route from Dashboard to Clipboard; the immediate
> Down-arrow action then selected Run History, proving the sidebar first responder
> survived the detail replacement in this run. A local Breeze recording exposed
> `Stop and Transcribe` before system TTS playback was launched and completed the
> capture/recognition lifecycle. The speaker signal was not picked up by the
> microphone and the run correctly ended as `No speech was detected`; no model
> tuning followed. Computer Use cannot hold or release Fn and its synthetic
> compatibility shortcut did not traverse the global event tap, so the physical
> Fn press/release or toggle check remains a separate candidate checkbox rather
> than being inferred from this automation.

> On 2026-07-17, another working-source installation focused only on global
> shortcut recording and main-window focus ownership; recognition-quality
> tuning remained paused. Slow workflow/preflight work no longer serializes the
> hotkey event stream, release and second-toggle intent remain ordered while a
> start is pending, and event-tap loss now publishes a gestureless
> `globalInputUnavailable` event. That event cancels pending, preparing, hold,
> and toggle capture without the ordinary 140 ms release debounce, and it
> immediately downgrades the global-input capability. Route repair now preserves
> a detail/search responder acquired while a delayed sidebar repair is waiting,
> and keyboard focus no longer claims independent VoiceOver focus. The focused
> regression set passed 200 tests; the complete Swift suite and required release
> preflight each completed 1,691 tests with 3 explicit opt-in skips and no
> failures. `prek` and diff checks passed. The Apple Development-signed installed
> executable had SHA-256
> `a52f363b4975f0945176f3a93da1cd19360efa9e9c5c0c28eeb33daae7ff9756`, was a
> universal x86_64/arm64 binary, and passed strict signature verification outside
> the test sandbox. This remains dirty working-source evidence, not clean tagged,
> notarized candidate evidence.

> Later on 2026-07-17, the short-dictation capture path added request-scoped
> speech endpoint ownership and Apple Voice Processing. WhisperKit live now
> measures activity in exact 1,600-sample/100 ms frames after 16 kHz conversion;
> a normal short recording requires 300 ms of speech and finishes after 1.4 s of
> trailing silence, while 12 s of initial silence cancels without enqueueing
> blank audio. Hold-to-talk remains release-owned and long/toggle recording
> remains second-press-owned. Capture stop/cancel retains the process-wide audio
> slot until the microphone boundary has actually closed, and runtime conversion,
> route, receive, send, or buffer failures terminate once instead of leaving a
> false recording state. Configured local live failures no longer downgrade
> to raw `AVAudioRecorder`. The focused regression set passed 165 tests; the
> complete Swift suite and required release preflight each completed 1,771 tests
> with 3 explicit opt-in skips and no failures. `prek` passed. The final
> Apple Development-signed installed executable had SHA-256
> `c50c3d7c500e1bb62879840b7c7e39bda4f6df1fce24011385dd8ba4d8e09ea9`, was a
> universal x86_64/arm64 binary, and passed strict signature verification outside
> the test sandbox. This is still dirty working-source evidence rather than a
> clean, tagged, notarized candidate. Installed microphone behavior remains a
> separate candidate check below.

> On 2026-07-18, the sherpa-onnx/Silero VAD working source completed the exact
> `./scripts/release.sh --install` path. The Universal Release build produced no
> effective compiler warnings; preflight passed 46 release-policy, 12 NOTICE,
> 23 security, 1,714 XCTest, and 17 Swift Testing checks. The installed
> Apple Development-signed App was
> `0.0.0-dev+7703f9ef8121.dirty`, its executable SHA-256 was
> `e71550bf356333aae2c4d1ee98fe59e1494c3a6e760b679a548913852a964aae`, and
> strict signature verification plus `lipo` confirmed a valid Universal
> `x86_64 arm64` executable. A combined Qwen/VAD/capture/hotkey/focus dogfood
> selection passed 191 XCTest and 10 Swift Testing checks; the final capture
> concurrency selection passed 75 ordinary tests and 58 Thread Sanitizer tests
> without a sanitizer report. The installed Silero VAD model was 643,854 bytes
> with SHA-256
> `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`, and
> its 1,076-byte license had SHA-256
> `51c19c8be941a3fb00ccf58f0bf9053de9f7237a0b37327896eabad32dffe873`;
> both files were regular single-link bundle resources. Both executable slices
> exported the sherpa offline-recognizer and voice-activity-detector entry
> points. Installed startup diagnostics then reported the fixed public
> `qwen3-asr-0.6b-int8` default, available `silero-vad-v4`, Clipboard capture
> paused, the Clipboard panel shortcut disabled by preference, and Fn
> push-to-talk active. This is comprehensive automated and installed-resource
> evidence from dirty working source, not a clean Developer ID-signed,
> notarized candidate. Real-microphone speech detection and automatic stop,
> controlled-noise behavior, physical Fn press/release, the final main-window
> focus path remained separate manual gates; Intel execution belonged to that
> superseded Universal support scope and is no longer a current candidate gate.

> A later 2026-07-18 working-source audit removed full-recording PCM retention
> from the local Core Audio callback. Accepted chunks now pass through the
> existing 32-chunk fail-closed stream into a private incremental WAV; normal
> finish seals the producer, drains every accepted tail chunk without running
> endpoint detection again, and only then finalizes the artifact. Cancellation,
> readiness timeout, writer initialization/append/finalize failure, producer
> failure, and overflow close and transfer the partial file to the cleanup owner.
> Local Qwen now advertises a 20-second provider limit, with a bounded 3.1-second
> capture-startup tolerance accepted consistently by capture and recognition.
> Other local recognizers retain their own explicit capability limits.
> The focused provider set passed 82 tests, the combined capture/hotkey/focus
> set passed 210 tests, and the 160-test Thread Sanitizer selection produced no
> report. The production `SherpaOnnxRecognizer` then re-ran the pinned
> `codeswitch.wav` fixture in 2.859 seconds and preserved `all by myself`. An
> independent read-only review found no Critical, High, or Medium issue in the
> new lifecycle. Recognition still loads one bounded full sample array for the
> native offline API; this evidence does not claim constant-memory decoding or
> replace the installed real-microphone checks below.

> The exact `./scripts/release.sh --install` rerun after those source changes
> passed 46 release-policy, 23 security, 12 NOTICE, 1,731 XCTest, and 17 Swift
> Testing checks, with no effective Universal Release compiler warning. The
> installed development build retained source revision `7703f9ef8121`, reported
> the dirty working-source label `0.0.0-dev+7703f9ef8121.dirty`, and had executable
> SHA-256 `be13eedde7f581ed5abe08ac15fe8f61996dfac055f743ca72cc596c4bf070e3`.
> Strict code-signature verification and `lipo` confirmed `x86_64 arm64`. The
> installed ICNS SHA-256 was
> `744c795f174a1d6b2ea204a73b37891b48e6b54f33a6e384fd5389989b345af5`;
> the pinned Silero model/license hashes remained unchanged. Fresh startup
> diagnostics reported Qwen and Silero available, Clipboard capture paused,
> the panel shortcut disabled by preference, and Fn push-to-talk active. The Mac
> locked before UI acceptance, so this install does not tick the microphone,
> physical Fn, or main-window focus checkboxes.

> A 2026-07-19 follow-up rebuilt and installed the same dirty source with the
> required `./scripts/release.sh --install` path. The release preflight passed
> 1,762 XCTest and 18 Swift Testing checks; strict signing verification passed,
> and the installed executable SHA-256 was
> `a2468e0cfec000dd62dd369164dab66016be758df787cf44ef3bdb61c4c1163a`.
> With the reviewed Qwen model selected, a consented real-microphone Settings
> run reached `workflow.audio-recording.started` 179.8 ms after recognition-hint
> resolution, observed 6.56 seconds of audio including 4.0 seconds classified as
> speech, terminated once with `speechEnded`, and persisted one completed record
> with non-empty final text. No transcript body is retained in this QA evidence.
> The installed overlay appeared during capture, its shadow followed the rounded
> surface without a rectangular edge, and Dashboard -> Clipboard -> Down moved
> keyboard selection to Run History without losing focus. This working-source
> evidence covers real local capture, automatic endpointing, the reported panel
> regression, and the visible-sidebar focus path; physical Fn press/release,
> controlled noise, pause-between-clauses, collapsed-sidebar focus, and clean
> signed-candidate checks remain separate gates.

In the automated table, **working-source complete; candidate pending** means the
suite passed in the 2026-07-16 full run above, while the required exact log and
hash from one clean, uniquely tagged candidate still need to be attached.

| Required automated evidence | Result / evidence path |
| --- | --- |
| `scripts/preflight.sh` passes from the candidate source, including locked-dependency notice provenance, secret scanning, the complete release-policy suite, arm64-only Release build, App assembly, signing-policy checks, and the complete Swift suite | **Working-source complete; candidate pending.** Rerun after the local-speech migration and attach the candidate's exact log and SHA-256. |
| `prek validate-config prek.toml` and `prek -c prek.toml run --all-files` pass against the same source tree | **Working-source complete; candidate pending.** Both commands passed against the dirty development source; attach the clean candidate's exact log and SHA-256. |
| `TrustedLocalSpeechCatalogTests`, `SherpaOnnxModelInstallerTests`, `SherpaOnnxRecognizerTests`, `SherpaOfflineRecognizerTests`, and `SessionCoordinatorTests` prove the fixed public Qwen catalog, public rejection of the internal SenseVoice identity, exact archive and installed-tree verification, typed no-speech handling, bounded Qwen hotwords, native runtime configuration, and persisted local speech selection | **Working-source complete; candidate pending.** Focused migration suites passed; rerun from the final candidate. Installed first-capture, silence, and quality behavior remain separate manual checks below. |
| `RealtimeAudioCaptureServiceTests` and `LocalSpeechVoiceCaptureRuntimeTests` prove the realtime local path waits for its first accepted microphone buffer; `AVAudioCaptureServiceReadinessTests` proves the diagnostics fallback waits for `AVAudioRecorder.currentTime > 0`, a recorder-progress gate rather than a strict buffer signal; `RecordingSessionManagerTimingTests` and `ApplicationStartupTaskCoordinatorTests` prove startup cancellation drains late audio-engine work, the recording consumer is subscribed before the shared event tap starts, diagnostics cannot delay hotkey capture or cues, stopped runs never promote live subtitle hypotheses to final text, finalization drains the live task before handing a file-backed complete-sample capture to batch recognition, and start/stop cues cannot reverse across cancellation or replacement | **Working-source complete; candidate pending.** Rerun against and attach evidence for the clean candidate. |
| `AudioCaptureEndpointingTests`, `WorkflowAudioRunControllerTests`, `RecordingSessionManagerTests`, `RecordingSessionManagerToggleTests`, and `AppModelLiveAudioStopTests` prove first-terminal-wins signaling, exact short-dictation timing, automatic/manual stop races, microphone-boundary ownership, initial-silence discard, visible recording-to-transcribing projection, and isolation of hold and long/toggle gesture semantics | **Working-source complete; candidate pending.** Included in the 1,771-test 2026-07-17 working-source install; installed short dictation, silence, and physical Fn checks remain required below. |
| `AppleVoiceProcessingAudioProcessorTests`, `LocalSpeechIncrementalWaveWriterTests`, `LocalSpeechVoiceCaptureRuntimeTests`, and `RealtimeAudioCaptureServiceTests` prove Apple Voice Processing activation on both I/O nodes, bypass disabled, AGC enabled, strongest-channel selection, exact 16 kHz energy framing, bounded realtime PCM/RMS retention, private incremental WAV output, accepted-tail drain, late-buffer rejection, permission/readiness races, exact frame ceilings, partial-file cleanup, explicit route/conversion failure, local-model injection, configured-live fail-closed behavior, and run/generation-scoped terminal cleanup | **Working-source complete; candidate pending.** This proves frontend configuration and lifecycle, not controlled acoustic denoise effectiveness or constant-memory native offline decoding. |
| `HotkeyEventTapTests`, `RecordingSessionManagerTests`, and `StackPasteControllerTests` prove the shared producer must be valid and enabled before it is reported available; slow start preparation cannot block later release or second-toggle intent; tap interruption, failed re-enable, and teardown clear recognizer latches; producer loss cancels pending, hold, and toggle capture without waiting for a physical key-up; shutdown drains every derived start/release task; and the visible global-input capability downgrades after producer loss | **Working-source complete; candidate pending.** Included in the 1,691-test 2026-07-17 working-source install; real physical Fn behavior and system-level tap failure remain manual candidate checks. |
| `SherpaOnnxModelInstallerTests` proves pinned archive size/SHA verification, safe archive inspection, canonical installed-file inventory verification, private atomic publication, corruption rejection and clean repair, cancellation of the external tar child, and verified offline cache reuse | **Working-source complete; candidate pending.** Focused migration suite passed, including a real pinned Qwen archive install; rerun deterministic tests from the candidate and attach the explicit model-install dogfood log separately. |
| `MainShellFocusIntegrationTests` and `HistoryRetryFocusPolicyTests` prove the main-window sidebar Activity → Clipboard → Workflows focus path across hosted AppKit detail replacement and mouse-event tracking, that Clipboard does not steal first responder into Search, and per-channel keyboard/VoiceOver focus rehoming when transient Retry controls disappear without stealing unrelated focus | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `ExternalOutputActionsTests` proves Markdown pre/post-commit cancellation, pre-publication short-write rejection, single-SWAP atomic publication without post-SWAP rollback, descriptor-bound displaced-file cleanup and retry, cancellation-resistant post-commit cleanup without duplicate append, existing-file metadata preservation, macOS 14 compatibility fallback, hard-link and any-level symlink rejection, special-file/UTF-8/size bounds, indeterminate-race evidence preservation with inspect-before-retry reporting, and serialized concurrent append | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| The `AppModelTests` retention cases in `Tests/RillUITests/AppModelHistoryRetentionTests.swift` and `ApplicationTerminationCoordinatorTests` prove history-maintenance drain precedes event and persistence shutdown barriers | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `PasteboardControllerTests`, `TextInjectionEngineTests`, `StackPasteControllerTests`, and termination tests prove temporary paste restores every item/type/data representation and order after success, failure, and cancellation without overwriting a newer user copy; the raw archive enforces 128-item, 32-representation-per-item, 256-total-representation, per-representation/item, and 64 MiB total bounds before replacement; ImageIO runs off MainActor with one single-flight worker; failed exact restores retain the archive, retry without repeating delivery, and drain inner TextInjection before outer StackPaste during shutdown | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `AppModelSettingsSaveStateTests` proves ordinary scalar and collection settings remain visibly unsaved, never expose storage errors or values, and clear only after a verified retry succeeds | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `AppModelSettingsDomainRecoveryTests`, `AppModelScalarSettingsAvailabilityTests`, `AppModelSettingsSaveStateTests`, `AppModelSettingsReadTaskOwnerTests`, and `AppModelSettingsReadShutdownTests` prove collection/scalar domains fail closed independently, late reads cannot overwrite current state, failed exact writes remain recoverable, and shutdown rejects then drains settings reads and saves | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `AppModelClipboardMutationShutdownTests` and `ApplicationTerminationCoordinatorTests` prove clipboard mutations are sealed, accepted work drains before scheduler/listener/persistence barriers, and post-seal UI writes are rejected | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| The persistence and capacity cases in `DeliveryStackTests`, together with `DeliveryStackSQLitePersistenceIntegrationTests`, `AppModelClipboardPersistenceTests`, `ClipboardPersistencePresentationTests`, and `ApplicationTerminationCoordinatorTests`, prove atomic schema 7 → 8 migration, protected metadata/image-blob separation, fail-closed raw-before-encode limits, 256 custom-group / 1024 App-route caps, oldest-history-only eviction, active/lease protection, atomic assignment and group creation without history reactivation, full-graph load validation, original-byte preservation, observable save failure/retry, confirmed destructive `loadUnavailable` reset with capture/lease/reset linearization, and final shutdown drain | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `EventBusTests` and `StackPasteControllerTests` prove Clipboard snapshots and their debug diagnostics use latest-wins coalescing only within semantic segments, queue dequeue is amortized O(1), StackPaste consumes a content-free `bufferingNewest(1)` revision stream, consecutive high-frequency state projections remain bounded, and ordinary diagnostics, terminal events, receipts, lifecycle barriers, and different run IDs retain ordering | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `StackPasteControllerTests`, `AppBootstrapTests`, `AppModelClipboardCapturePreferenceTests`, and `ClipboardCapturePresentationTests` prove disabled clipboard capture performs no pasteboard, focus, or privacy polling from cold start; preference revisions reject stale startup state; re-enabling establishes a new baseline without backfilling changes made while disabled; and Settings, menu bar, and the Clipboard page expose one persistent state | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `SQLitePersistenceStoreTests` and `RunHistoryBrowsingUITests` prove receipt-primary snapshot/keyset pagination, 50-row page bounds, stable same-timestamp ordering, clear invalidation, runID/recordID deep links, privacy-bounded body access, cancellable full-history search, and failure-without-false-empty presentation | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `ClipboardInputMethodGuardTests`, `ClipboardFocusPolicyTests`, and `L10nTests` prove destructive clipboard actions share one confirmation contract, disclose merged-item scope, and cannot escape active text/input-method or modal editing | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `GlobalSearchIndexTests` retry-policy cases and `MainShellFocusIntegrationTests` prove only the current visible failed query can retry, cancelled or stale generations cannot publish, static destinations survive history failure, Retry-to-loading focus returns to the stable search field, the visible overlay removes sidebar/detail/toolbar background interaction and accessibility, and repeated Command-F refocuses without resetting search state | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |
| `ManagedTemporaryAudioCleanupOwnerTests` plus AVAudio, local realtime, and controller lifecycle tests prove managed plaintext audio survives caller cancellation, retries transient deletion failures, emits path-free diagnostics, and drains at shutdown | **Working-source complete; candidate pending.** Rerun from and attach evidence for the clean candidate. |
| The local-model preparation lifecycle tests (currently `AppModelWhisperKitPreparationShutdownTests` until the persisted-settings compatibility surface is renamed) prove user cancellation returns to idle, retired tasks cannot publish late progress or completion over replacements, and shutdown drains active and retired manual/warmup tasks | **Working-source complete; candidate pending.** Rerun from and attach evidence for the candidate. |
| `UserVisibleErrorPrivacyTests` proves the covered Settings, privacy, retention, workflow, provider, runtime-failure, and action-result paths expose only fixed bilingual stage/reason copy | **Working-source complete; candidate pending.** Included in the 2026-07-16 full suite; rerun from and attach evidence for the clean candidate. |

Machine evidence cannot prove Gatekeeper behavior after a real download, TCC
prompts, physical keyboard/input-method behavior, service availability, model
quality, or whether VoiceOver phrasing is understandable to a user. Those remain
required below.

## Release identity

- Candidate version:
- Commit SHA:
- Source tree SHA-256:
- Dependency notice manifest SHA-256 (`scripts/third_party_notices_manifest.json`):
- Speech scope (`cloud-only` or `cloud + trusted local`):
- Local catalog maturity (`technical-preview`, `production-ready`, or `N/A`):
- Catalog model IDs and order:
- Default local model ID (`N/A` when local is opt-in preview only):
- Per-model manifest SHA-256 (`N/A` only for a declared `cloud-only` candidate):
- Per-source evidence SHA-256:
- DMG SHA-256 / sidecar path:
- Signing identity fingerprint:
- Notarization request ID:
- Preflight log / SHA-256:
- Tester and date:

All applicable fields above must identify the same clean, uniquely tagged source
commit. The speech scope is immutable candidate identity: changing between
`cloud-only` and `cloud + trusted local` requires a new candidate. Any rebuild,
model-manifest change, signing change, or DMG change invalidates the remaining
results.

## Test matrix

Record the exact hardware model, architecture, macOS build, input method, App
language, and whether the account was newly created.

| Required environment | Hardware / OS evidence | Result | Evidence path |
| --- | --- | --- | --- |
| macOS 14, Apple Silicon |  |  |  |
| macOS 15, Apple Silicon |  |  |  |
| Latest supported macOS (macOS 26 for this checklist), Apple Silicon |  |  |  |
| Clean local account |  |  |  |

`LC_BUILD_VERSION minos` and deployment-target checks are build evidence only;
they do not replace running the notarized candidate on macOS 14.

## Installation and trust

- [ ] Download the final DMG through the intended distribution channel.
- [ ] Verify its sidecar checksum before opening it.
- [ ] Confirm Gatekeeper accepts the DMG and installed App without an override.
- [ ] Confirm the stapled ticket and Developer ID identity match the release
      record.

For a declared `cloud-only` candidate:

- [ ] The Activity page and Settings identify trusted local speech as unavailable; model
      preparation performs no model-host request, and an old downloaded-model ID
      cannot make the App report Ready.

For a declared `cloud + trusted local` candidate:

- [ ] Record each catalog model's maturity, exact ID, manifest digest, source
      revisions, evidence digests, download size and retained-storage size.
- [ ] Launch once online, complete the reviewed model download, quit, disconnect
      networking, and confirm a second launch uses the verified local snapshot.
- [ ] Corrupt a disposable test snapshot and confirm the App never loads it and
      performs at most one authorized rebuild.
- [ ] Repeat online preparation, no-network restart, installed-App microphone
      input, cancellation and shutdown separately for every selectable model.
- [ ] Record synthetic technical-audio evidence separately from human-consented
      corpus results; speaker playback captured by a microphone proves the
      hardware/runtime path but does not satisfy model-quality thresholds.

## App icon surfaces

Run these checks on macOS 14, macOS 15, and the latest supported macOS with the
exact installed candidate. Clear stale Finder/Dock icon caches or reinstall the
candidate before recording a failure.

- [ ] Applications, Finder, Dock, Launchpad, Spotlight, and the App switcher all
      show the routed voice cursor artwork rather than a generic or stale icon.
- [ ] On macOS 14 and 15, every surface shows a transparent rounded icon body
      with no opaque square corners, fringe, or clipped shadow.
- [ ] At 16 px and 32 px, two input lanes, a separate coral routing node, and a
      separate coral insertion cursor remain distinguishable in light and dark
      appearances.
- [ ] On macOS 26, system adaptation does not add a double mask, unwanted
      background plate, excessive inset, or material that obscures the glyph.
- [ ] Finder Get Info reports `Rill.icns`, and the installed ICNS SHA-256
      matches the release artifact recorded above.

## Clean-account first run

- [ ] The App does not request Input Monitoring, microphone, or Accessibility permission before the
      user initiates the corresponding setup action.
- [ ] Denying each permission produces an actionable state and does not loop.
- [ ] Granting each permission recovers without deleting user settings.
- [ ] The Activity page remains incomplete when Input Monitoring preflight passes but
      the shared active event tap cannot be installed; retrying after permission
      changes must activate Fn. With Clipboard Capture enabled it must also
      activate the clipboard-panel shortcut and Command-V interception; with
      capture disabled those two surfaces must remain inactive.
- [ ] Keychain creation, restart, logout/login, and App relaunch preserve readable
      encrypted state.
- [ ] Revoking a permission while recording or delivering fails closed and cleans
      temporary audio.

## Input and global shortcuts

Run each case with the Simplified Chinese and US input sources and with at least
TextEdit, Safari, and a password field as the foreground target. Exercise the
clipboard-panel shortcut cases only while Clipboard Capture is enabled, then
repeat the explicit disabled-state check with capture off.

- [ ] With Clipboard Capture on, Left Command double tap opens the clipboard
      panel once.
- [ ] With Clipboard Capture on, Right Command double tap opens the clipboard
      panel once.
- [ ] Mixed left/right Command taps follow the same one-pair behavior.
- [ ] `Command tap → unrelated key/modifier → Command tap` does not open it.
- [ ] Holding Fn with either Command tap does not open it.
- [ ] A mouse click or scroll between Command taps resets the pair.
- [ ] A Command hold longer than 350 ms, or a next press more than 350 ms after
      the previous release, does not open it.
- [ ] A third Command tap does not overlap with the completed pair.
- [ ] With Clipboard Capture off, left, right, and mixed Command double taps do
      not open the panel; Settings hides the shortcut recorder and the menu bar
      shows no panel-shortcut annotation.
- [ ] Push-to-talk press/release, event-tap interruption, and permission loss do
      not leave recording latched.
- [ ] With Toggle Recording off, physical Fn release is the authoritative stop and
      a new recording can start immediately after the microphone boundary closes.
- [ ] With Toggle Recording on, Fn release does not stop; the second press stops
      exactly once. Local Qwen still stops automatically at 20 seconds; other
      recognizers retain their provider limits. Restore Toggle Recording off before
      the short-dictation pass.
- [ ] Text is never delivered after the target App, PID, or secure-input state
      changes.

## Clipboard capture control

Run this pass with pre-existing Clipboard history so disabling automatic capture
cannot be confused with deleting stored content.

- [ ] Turn Clipboard Capture off in Settings and confirm the menu-bar control and
      main Clipboard page immediately show the same disabled state while existing
      history remains readable and explicit history actions remain available.
- [ ] With capture off, copy a unique canary in another App, wait at least two
      monitor intervals, and confirm no new Clipboard item, route assignment, or
      debug payload is created.
- [ ] Quit and relaunch the installed candidate, confirm capture is still off,
      then copy a second unique canary and confirm the disabled behavior persists
      from cold start without a transient capture.
- [ ] Re-enable capture and confirm neither disabled-period canary is backfilled;
      only a new copy made after re-enabling is captured. Turn capture off again
      before completing a voice-focused candidate pass.
- [ ] While capture is off, confirm the shared event tap still supports the voice
      hotkey and that explicit copy, paste, and delivery operations do not silently
      re-enable background capture.

## VoiceOver and keyboard navigation

Complete the pass in both App languages.

- [ ] The Activity page (including the run timeline with Recent Runs/Recent
      Results filters), Clipboard, Workflows, Diagnostics, and Settings have a coherent VoiceOver
      reading and focus order.
- [ ] Restricted history previews expose only the same truncated text shown
      visually; disabled previews expose no body text.
- [ ] Run History can move Older then Newer without duplicates or jumps, a new
      run offers an explicit refresh to the newest snapshot, and an expired
      deep link is explained instead of showing a false empty state.
- [ ] Global search remains responsive while searching a large retained history;
      a superseded query never publishes stale matches, and a history failure
      leaves page, workflow, and settings results usable.
- [ ] Global-search arrow selection moves VoiceOver focus to exactly one current
      result; Return opens the announced result, and refreshed results never
      leave focus on an item that disappeared.
- [ ] When Global History Retry is focused and activation removes it, keyboard and
      VoiceOver focus returns to the global search field. When the main Clipboard
      persistence Retry disappears after recovery, focus returns to Search in
      Current/History or the section picker in Routing; if Retry was not focused,
      Activity → Clipboard keeps sidebar focus.
- [ ] Empty states, loading counts, privacy reasons, destructive confirmations,
      progress, success, and failure states are announced once and remain
      understandable without color.
- [ ] Escape, Tab, Shift-Tab, Space, Return, and arrow-key behavior is predictable.
- [ ] In the main window, with the Activity sidebar row focused, Down opens the
      first collection directly below Activity and a second Down selects the next
      collection; entering Clipboard does not move focus into Search or clear the sidebar
      first responder after the mouse event finishes.
- [ ] Selecting top-level Clipboard exits any selected clipboard group. Search
      gains a visible focus ring only after explicit focus, and Tab/Shift-Tab use
      the native key-view order.
- [ ] History empty-state → Dashboard, Dashboard setup → Settings/Diagnostics,
      and Diagnostics → Settings move keyboard and VoiceOver focus to the newly
      selected sidebar row. Re-selecting the current route does not steal focus
      from a control being edited in its detail.
- [ ] Floating panels restore focus and do not pass keystrokes into the foreground
      App. No disabled sheet entry is reachable through keyboard or accessibility
      actions.
- [ ] Clipboard deletion opened by the detail button, context menu, and Delete key
      uses the same confirmation, announces merged-item count and irreversibility,
      and Cancel preserves every item. Delete does not escape a Chinese or English
      text/input-method edit, and parent shortcuts stay inactive while a sheet or
      confirmation is present.

## Speech and privacy paths

- [ ] For `cloud-only`, local setup and preparation remain unavailable across
      restart and never fall back to an ambient cache, legacy loader, or model
      network request.
- [ ] For `cloud + trusted local`, reviewed model setup, first load, offline
      restart, dictation, local recording/level/processing overlay, cancellation,
      and shutdown pass on each required architecture. Local partial-text subtitles
      are tested separately; local batch recognition is not labeled live.
- [ ] With a trusted local engine persisted and model prewarm disabled, relaunch
      the installed candidate and confirm the model reaches an observable ready
      state before the first voice-hotkey capture; that first capture must not be
      discarded merely to trigger background model loading.
- [ ] Submit silence and non-speech room noise through each enabled speech path;
      the App reports that no speech was detected, performs no transformation or
      output action, creates no failed-audio recovery offer, and remains ready for
      an immediate retry.
- [ ] With the trusted local engine, start a main-window short dictation, speak
      for at least 300 ms, then stop speaking. Recording leaves the recording
      state without a second click within 2.5 s, creates exactly one result, and
      records terminal reason `speechEnded`.
- [ ] Repeat with a roughly 700 ms pause between two spoken clauses. The pause
      does not end capture; the final 1.4 s trailing silence ends it once.
- [ ] Start trusted-local short dictation and remain silent. It cancels in the
      12–13.5 s window, creates no transform/output/recovery artifact, records
      terminal reason `initialSilenceTimedOut`, and permits an immediate retry.
- [ ] Record the microphone model, input route, approximate mouth distance, and
      repeatable background-noise source. Voice Processing activation failure,
      route change, conversion failure, or input loss is explicit and never
      downgrades to an unprocessed live path.
- [ ] For `cloud + trusted local`, cancelling sherpa-onnx model preparation immediately
      returns Settings to an actionable state; reconfiguration can start a
      replacement without old progress or completion appearing, and quitting
      waits for both active and retired provider work.
- [ ] For every speech path enabled by this candidate, Chinese-first,
      English-first, and mixed-language dogfood evidence is attached together
      with explicit acceptance thresholds approved before the run.
      `docs/asr-dogfood-results.md` is historical exploratory TTS evidence and
      is not a release threshold or candidate result.
- [ ] Sensitive App, unknown focus, Secure Input, disabled preview, and revoked
      credentials all fail closed without body text in diagnostics.
- [ ] Wake word is off by default. Enabling it explains continuous in-memory
      microphone use, requires the selected local Qwen ASR, exposes model and
      listening status, and provides an immediate stop control. After model
      preparation, an offline relaunch starts listening without network access.
      With wake listening enabled, start and record from another microphone App:
      it must remain eligible to acquire input. Rill uses the coexistence-friendly
      input-only frontend while idle, switches to VoiceProcessingIO only for an
      explicit recognition run, and fully releases VPIO when that run ends.
      The in-app readiness card must also agree with the activation gate for
      microphone permission, local ASR, LLM configuration, cloud privacy, and
      system/local speech output. A known-invalid or failed-verification LLM
      configuration must leave listening off; missing local TTS must remain an
      explicit system-voice fallback rather than a blocker.
- [ ] In quiet and repeatable everyday-noise conditions, the configured default
      wake phrase triggers on at least 90% of first attempts. Record phrase,
      speaker, distance, input route, background source, attempt count, hits,
      false accepts, and measured wake-to-command-listening latency.
- [ ] Run 30 consecutive real-microphone `wake phrase + command` attempts,
      including short pauses between phrase and command. Every accepted combined
      utterance preserves the command and enters the workflow without a second
      STT pass. Separately verify phrase-only activation: speech during or after
      the cue preserves the perceptual first syllable, 12 s initial silence
      cancels cleanly, and 1.4 s trailing silence finishes exactly once.
- [ ] While a non-matching wake candidate is still being recognized, speak the
      configured wake phrase again. The listener remains truthful and eventually
      evaluates the newest complete candidate; it retains at most one queued
      managed WAV, removes any displaced candidate, and never replays stale audio.
- [ ] Run an eight-hour negative set containing ordinary conversation, music,
      television, and silence. Record the exact audio environment and allow at
      most one false wake; do not substitute upstream fixtures or synthetic
      noise for this candidate gate.
- [ ] While capture is busy, TTS is playing, microphone permission is revoked,
      or the input route changes, no new wake is emitted. The VAD/ASR gate resets rather than
      replaying buffered audio. Fn/interactive capture preempts ambient wake
      listening immediately and ambient listening resumes when microphone
      capture ownership ends, without waiting for recognition, LLM, delivery,
      or playback to finish.
- [ ] With wake listening enabled, run 30 ordinary Fn dictations that do not
      begin with a configured wake phrase. None starts an assistant run or cue.
      While one assistant LLM request is still pending, complete another Fn
      recording and verify its STT result proceeds on the interactive lane;
      diagnostics identify `interactive` and `assistant` processing lanes, and
      TTS model work never queues on the ASR worker supervisor.
- [ ] During a long streaming hypothesis, the live-subtitle panel keeps its
      standard fixed frame; text preserves the latest two lines without width
      or height growth. Preparing/processing compact states use their own fixed
      frame and neither layout steals key focus from the foreground App.
- [ ] Record wake-listening idle CPU and memory, cold model preparation time,
      warm startup time, and detection latency on every supported Mac tier.
      Repeat the chain with built-in microphone/speaker and headphones, on the
      minimum supported macOS as well as the primary development system.
- [ ] `speech.speak` follows configured copy/inject/stack actions and reads the
      final result once with Qwen3-TTS in Chinese and English using reviewed
      preset voices. Stopping from UI and Esc cancels playback, cleans the
      managed WAV, and restores wake listening without replaying the text.
- [ ] With macOS output unmuted and at an audible level, Fn capture and wake-word
      activation use the same start cue. A voice-assistant run speaks its LLM
      answer once; History shows the recognized input for older records and the
      exact ordered text sent to each LLM step for new records, without exposing
      those bodies when history preview is restricted or disabled.
- [ ] With Qwen TTS absent, unsupported, damaged, or failing before playback,
      system speech is used once. A failure after playback begins never repeats
      the result with system speech; action receipts and temporary-file cleanup
      remain correct for success, cancellation, failure, and App quit.

## External output actions

Use disposable local destinations and remove them after the candidate is signed
off. Do not use a real automation, note archive, or sensitive transcription as
test data.

- [ ] A disposable Shortcut receives one intended transcription through the
      configured `Run Shortcut` workflow and runs exactly once. A missing or
      renamed Shortcut fails visibly without exposing its input in diagnostics.
- [ ] Cancelling or quitting during a long-running Shortcut terminates the
      subprocess, records cancellation rather than failure, runs no later output
      action, and leaves no `rill-shortcut-*` plaintext file in the temporary
      directory.
- [ ] `Append to Markdown` creates an isolated `.md` file, appends a second run
      with the documented separator, and leaves valid UTF-8 with neither a
      duplicate nor a truncated entry.
- [ ] If displaced-original cleanup is forced to fail after a committed append,
      the UI reports committed cleanup pending, retry removes only the verified
      old inode, and cancelling the caller never re-appends the logical entry.
- [ ] Empty paths, non-Markdown extensions, unwritable destinations, cancellation,
      and quit are visible and fail closed without modifying an unrelated file.
- [ ] Shortcuts and Markdown runs respect the same sensitive-App, unknown-focus,
      Secure Input, cloud-confirmation, receipt, and history-preview policies as
      built-in delivery actions.

## Persistence and lifecycle

- [ ] Quit during recording, queued recognition, clipboard paste, model preload,
      and history clearing either completes safely or cancels the quit while
      cleanup continues.
- [ ] Relaunch shows only durable current-generation history, receipts, and
      diagnostics; cleared generations do not reappear.
- [ ] Clipboard Stack / Queue / List behavior survives restart without duplicating
      or consuming an item twice.
- [ ] Make the persisted clipboard state unreadable, structurally invalid, or
      larger than the schema 8 metadata/blob bounds and confirm startup fails
      closed: existing durable data is not overwritten and session changes are
      clearly identified as non-persistent. Open Reset Storage and verify the
      confirmation names both
      saved and session-only items, groups, and App routing as irreversible;
      Cancel preserves everything, forced storage deletion failure preserves the
      protected row and complete session state, and a successful retry clears the
      old row and session graph exactly once before restoring availability.
- [ ] With a Stack / Queue paste lease in flight, try to reassign its App and to
      create a group with that assignment. Both mutations fail without a partial
      route/group/item change; the paste completes or returns its exact lease, and
      a consumed history-only item is never reactivated by a later assignment.
- [ ] Copy a multi-item rich clipboard and large image near the temporary archive
      and image budgets. The main UI remains responsive while ImageIO works,
      in-budget content restores every original representation, over-budget or
      invalid content fails before replacement, and an external copy during image
      processing wins without being overwritten.
- [ ] Force a clipboard save failure and confirm the main Clipboard page retains
      the warning, automatic retry and the single-flight immediate Retry do not
      duplicate state, successful recovery clears the warning, and the floating
      panel never presents a second banner.
- [ ] Make one collection setting and one scalar setting unreadable, then force a
      settings save failure. Unaffected domains still load, unavailable values are
      not replaced by defaults, failed current-session values remain visibly
      unsaved, and retry/restart recovers without exposing a key, value, path, or
      raw storage error.
- [ ] Quit while clipboard mutations, clipboard persistence, settings reads, and
      settings saves are in flight. Work accepted before shutdown drains before
      termination; new mutation/read/save requests are rejected, and a candidate
      that cannot prove the drain complete refuses or cancels that quit rather
      than silently losing state.
- [ ] Failed-audio recovery remains off by default and, when enabled, respects its
      TTL, capacity, retry authorization, and deletion behavior.

## Sign-off

Apple Voice Processing and AGC are capture-frontend controls. Until controlled
raw-versus-processed acoustic A/B evidence is attached, release notes must not
describe them as a dedicated broadband denoiser, claim a quantitative noise
reduction level, or imply that every diagnostics/prerecorded path is processed.

- Product:
- Privacy/security:
- Release engineering:
- Accessibility:
- Known limitations linked from release notes:

Any unchecked required or scope-applicable item is a release blocker. Mark the
other speech-scope branch `N/A` in the copied candidate checklist; leaving both
branches unresolved is not acceptable. A feature can be treated as out of scope
only when its UI, documentation, and stored-configuration migration are updated
in the same release.
