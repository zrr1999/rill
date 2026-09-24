# Voice latency diagnostics

Run an explicit, one-shot scan on the Mac running Rill:

```bash
uv run --script scripts/analyze_diagnostics.py --refresh
```

The scripts read the current history generation through a read-only SQLite
transaction. They replace a rolling seven-day snapshot under
`~/Library/Application Support/Rill/Diagnostics/`. The directory is private
(0700), and exports and reports are private files (0600). No timer or monitoring
service is installed. They export already-sanitized diagnostic events, omit
free-text messages, and never read encrypted receipts, transcripts, credentials,
or recordings. Export failures leave the previous snapshot intact; the scan
must not treat an old export as fresh evidence.

`diagnostics.jsonl` contains an export header followed by events; `summary.json`
contains counts. `performance-scan.json` preserves per-run measurements, and
`performance-scan.md` contains sample counts and P50/P95 tables. The installed
app revision is a snapshot coordinate, not proof of every historical run's build.

## Timing boundaries

| Event / field | Meaning |
| --- | --- |
| `recording.finishing` / `captureFinishMillis` | Capture service finalization, after the stop gesture |
| `recording.finishing` / `captureSealMillis` | Capture authorization sealing |
| `recording.finishing` / `captureCueMillis` | Stop feedback |
| `audio-processing.capture-timing` / `captureStopMillis` | Stop audio source |
| `audio-processing.capture-timing` / `captureDrainMillis` | Drain accepted PCM frames |
| `audio-processing.capture-timing` / `capturePreviewRetireMillis` | Await the existing preview finish/worker retirement path |
| `audio-processing.capture-timing` / `captureFinalizeMillis` | Finalize the managed WAV |
| `session.process.timing` / `durationMillis` | Recorded process operation, identified by stepKind and resultCode |
| `session.action` / `durationMillis` | Action including receipt coordination, when recorded |
| `provider.openai.rewrite.completed` / `durationMillis` | Full response and parsing, not time to first token |
| `clipboard.inject.paste.posted` / `pasteDispatchMillis` | Paste command sent, not confirmation that target text is visible |
| `clipboard.inject.paste.end` / `pasteSettleMillis` | Post-paste protection wait |
| `clipboard.inject.restore` / `durationMillis` | One restore attempt; retries remain separate |

These duration fields use monotonic clocks. Cross-event gaps use wall-clock
observations and are labeled separately. Parent spans include child spans:
never add captureFinishMillis to its component timings. Missing or repeated
endpoints are excluded from the relevant metric, not reported as zero.
Diagnostics do not establish target application consumption or visible latency.

Injection run IDs are scoped to the operation, not mutable actor state. Pending
recovery retains its original run ID so a later request does not claim the old
transaction's restore diagnostics. Clipboard preservation, external-copy wins,
focus checks and the 100/800 ms protection waits are preserved. The posted-event
write falls inside the post-paste protection window instead of extending it.

## Optimization and next measurement

Capture already performs authoritative offline recognition. The unused final
preview text no longer gets trimmed, copied or attached to captured audio.
The preview finish operation is still awaited: the worker already cancels the
incremental decoder and waits 250 ms because its upstream cancellation API does
not join the detached inference task. Sending the cancellation command instead
would bypass that protection, so this change does not do that.

Measure fresh runs on the changed build before claiming a latency improvement.
The first scan of the prior installed build found roughly 283 ms capture
finalization and 1,002 ms injection completion (24-hour cohort, 23 successful
voice runs). The latter includes a deliberate 800 ms post-paste wait; it is not
measured text visibility. The worker's 250 ms guard is a strong candidate for most of the 283 ms capture
finalization, but the new per-span measurements are required to establish that.
With the new coordinates, evaluate preview retirement,
audio source stop, and paste dispatch separately before proposing a reduction of
clipboard waits. Validate any future reduction with actual target apps, focus,
IME, external-copy races and shutdown; model tests cannot replace macOS QA.

A follow-up performance PR should first establish an actual decoder-exit/join
signal in the worker dependency. A protocol cancellation acknowledgement alone
does not prove that detached MLX work has drained. Replace the 250 ms guard only
after proving model reuse and shutdown cannot overlap that work.
