# Release QA Checklist

This checklist keeps two evidence layers together without treating them as
interchangeable. Automated prerequisites prove deterministic state-machine,
filesystem, packaging-policy, and hosted AppKit contracts. The checkboxes record
what was exercised with the exact packaged release candidate on real systems.
Copy this file for each candidate and keep it with both evidence sets.

## Automated prerequisite evidence

Attach evidence from the exact candidate commit before beginning device QA:

- `just ci`: maintained prek hooks, generated artifacts, offline dependency policy,
  full Git/source secret scans, release-policy tests, an arm64 Release build,
  bundle and signing smoke checks, and the complete Swift test suite.
- `bash scripts/check_commit_messages.sh`: complete messages validated with the
  pinned ZenDev profile.
- `uv run --script scripts/check_dependency_security.py --live-osv`: current
  advisory results for the exact locked dependency revisions.
- The corresponding successful GitHub checks and the final DMG SHA-256.

Preserve logs, toolchain versions, expected skips, source commit, and artifact
hashes together. Local development runs and historical WhisperKit/sherpa-onnx
results do not satisfy current MLX speech-worker candidate gates. The current
source and locked model catalog determine which tests and models apply.

Automated checks do not prove Gatekeeper behavior after a real download,
permission prompts, physical Fn or input-method behavior, acoustic quality,
or VoiceOver usability. Record those results below with the packaged candidate.

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
| Latest macOS supported by the candidate, Apple Silicon |  |  |  |
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

- [ ] Dashboard and Settings identify trusted local speech as unavailable; model
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
- [ ] Dashboard remains incomplete when Input Monitoring preflight passes but
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

- [ ] Dashboard, the History page with Recent Runs/Recent Results filters,
      Clipboard, Workflows, Diagnostics, and Settings have a coherent VoiceOver
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
      Dashboard → Clipboard keeps sidebar focus.
- [ ] Empty states, loading counts, privacy reasons, destructive confirmations,
      progress, success, and failure states are announced once and remain
      understandable without color.
- [ ] Escape, Tab, Shift-Tab, Space, Return, and arrow-key behavior is predictable.
- [ ] In the main window, with the Dashboard sidebar row focused, Down opens the
      Clipboard page directly below Dashboard and a second Down opens History;
      entering Clipboard does not move focus into Search or clear the sidebar
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
- [ ] For `cloud + trusted local`, cancelling MLX speech-model preparation immediately
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
      larger than the candidate schema's metadata/blob bounds and confirm startup fails
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
