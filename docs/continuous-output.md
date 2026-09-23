# Continuous output

Command-V remains native paste. Command-Shift-V is a separate, configurable
Output Next command. Its text, drag, retry, cancellation, and confirmation paths
have no general-pasteboard write or temporary paste/restore fallback. Existing
explicit Copy and historical delivery workflows keep their own semantics.

## Pending content

`RecordStore` owns buffers, entries, input sequence allocation, the exact active
entry, and persistence. Collections continue to organize Records; changing or
consuming a buffer entry never removes a collection membership or duplicates a
payload. New collections default to the reusable List preset in the UI. Legacy
collection routing policies remain readable for existing explicit workflows;
Output Next does not consult those routes or membership consumption flags.

The default clipboard buffer is a Stack and the collected-speech buffer is a
Queue. The enabled, nonempty buffer with the greatest remaining input sequence
wins. A Stack selects its tail; a Queue selects its head. Linked indexes cache
both ends, count, and maximum remaining sequence, so selection does not scan
entries. Sets deduplicate by RecordID, require manual selection, and retain the
entry after use. Sets are excluded from automatic selection.

An entry's identity is `(bufferID, UInt64 sequence)`. Input sequences are global,
monotonic, and persisted with the entry. Observing an input assigns its position
without waiting for the database. Reservation transactions are serialized in
that order; payload reads can continue while a write is blocked. Clipboard read
retries keep the original reservation. Collected speech reserves at submission
to the captured-audio queue, before deferred audio resolution and recognition.
Final `record.store` atomically fills that position. Direct input does not reserve
a speech entry. Collection mode uses overlay preview, never cursor mutation.
Failed/cancelled recognition removes its unfilled slot, with owned cleanup retry
when persistence is temporarily unavailable.

There is no expiry, inactivity window, or automatic batch reset. Pending Records
are protected from automatic cleanup. An explicit, confirmed Record deletion
removes its buffer references in the same transaction, unless that Record is
currently being delivered or awaiting confirmation. Examples: `A B L C H I` yields `LHICBA`; copying D
after L yields `LDHICBA`; input ending at C yields `CLBA`.

## One output attempt

Before touching the target, the store persists a `delivering` marker for the
exact entry. New inputs affect subsequent choices, not the current attempt.
Repeated shortcuts cannot acquire another entry while that marker is active.

Text captures the application PID and AX control before waiting for shortcut
release. It checks secure input and focus at each effect boundary. Settable AX
selected text is replaced and read back. A failed or unverifiable AX replacement
is ambiguous and never falls through to a second transport. Unsupported AX
replacement uses Unicode key events with cleared modifiers, scalar-safe UTF-16
chunks, and no Return-key submission. Posting events produces **confirmation
required**, since the receiver may [ignore Unicode event text](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring%28stringlength%3Aunicodestring%3A%29). Focus drift after
any chunk also requires confirmation.

The user confirms insertion to consume, or explicitly chooses Retry. Retry pins
that same entry; the user focuses the target and presses the shortcut again.
Manual Set selection uses the same target-focus handoff. Rill's own controls are
never selected as output targets.

Images and files present a fixed-entry native drag surface. Images can be dragged
as an image or a promised PNG file. Promised images are validated and encoded as
PNG on the file-promise worker queue. Files use `NSFilePromiseProvider` and copy
into the receiver-provided destination. The drag operation mask is copy only.
All requested file writes must complete successfully before an accepted drag
consumes the entry. Partial writes require confirmation. Rejection/cancellation
retains the entry. A promised-file write never overwrites an existing file.
The native [drag pasteboard](https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/drag)
is independent from the general pasteboard.

Verified delivery is latched before its settlement transaction. If settlement
fails, the same entry remains guarded: another request retries only the state
commit. A process interruption during delivery restores a confirmation state,
not an automatic resend. Unfinished recognition/read placeholders are discarded
on restart because their producing process no longer exists; completed pending
entries survive.

## Persistence and migration

Catalog v3 adds encrypted `buffer`, `bufferEntry`, and `bufferClock` nodes to the
existing SQLite catalog, using the same connection, CAS revision, transaction,
and authenticated readback. Buffer-only mutations update changed nodes and the
revision without decoding, reserializing, or rewriting the catalog manifest or
payloads. Record creation plus reservation fulfillment is one transaction.

Catalog v2 and legacy graphs migrate active Stack/Queue memberships into named
legacy buffers. Consumed members are excluded. Every legacy buffer is disabled
by default; fresh default buffers start empty. Raycast List history is not
backfilled. Users can enable a legacy buffer or add an existing Record manually.
Migration failure rolls back the transaction and fails initialization closed.
The migration is forward-only; older binaries must not write a v3 catalog.

## Evidence and acceptance

Deterministic coverage includes ordering, delayed clipboard reads, blocked disk
writes, async speech positions, Set reuse, exact consumption, uncertain output,
restart, migration rollback, failed settlement, native key pass-through, Unicode
chunking, focus drift, secure input, copy-only file promises, and file-write errors.
Controller tests install forbidden clipboard-writing actions and callbacks, then
exercise repeat suppression, explicit retry after newer input, confirmation,
partial cancellation, empty buffers, and unstarted image/file drag cancellation.
They also check that the general pasteboard changeCount stays unchanged.

On 2026-09-22, commit `11037bd` was checked on macOS 27.0 (26A428), arm64.
A debug benchmark with 10,000 pending entries and a real AES-GCM SQLite catalog
measured the following P50 / P95 / P99 milliseconds:

| Operation | P50 | P95 | P99 |
| --- | ---: | ---: | ---: |
| Enqueue existing Record | 0.154 | 0.188 | 0.711 |
| Next projection | 0.004 | 0.011 | 0.027 |
| Load payload and persist attempt | 0.149 | 0.363 | 0.817 |
| Commit consumption | 0.121 | 0.261 | 0.749 |

The measured resident-memory increment was 1,720,320 bytes. The database increment
was 4,759,552 bytes after equivalent WAL truncation checkpoints. These are
run-specific process/database observations, not estimates from field layouts.
The fixture starts with 10,000 immutable text Records; it measures the additional
buffer indexes and encrypted entries without counting payload creation again.

A separate 24-sample named-pasteboard-to-encrypted-history test on the same machine
measured baseline P50/P95/max 57.206/61.596/82.824 ms, and updated
58.864/63.079/63.484 ms on the initial continuous-output implementation
(`7b0d5db`). An earlier updated run measured
54.526/56.505/57.903 ms. This includes the 50 ms polling cadence and scheduling
jitter; the later P95 was 1.483 ms above the baseline in this small sample.
It is not a physical copy/paste keystroke latency measurement, and does not prove
the absence of a native copy/paste latency regression.

Reproduce with:

```sh
RILL_BUFFER_BENCHMARK=1 RILL_CLIPBOARD_LATENCY=1 scripts/swift_locked.sh test \
  --filter 'RecordBuffer|RecordBufferTextOutput|ClipboardCaptureLatency|BufferHotkey|BufferFilePromise'
just ci
```

Native application compatibility remains **unverified**. No application is claimed to
support image/file drop or text insertion based only on these tests. On an
unlocked Mac, use an isolated data directory and the exact candidate artifact to
verify Chinese IME, emoji, long multiline text, selection replacement, focus
changes, drag acceptance/cancellation, and an external copy during every output
kind. Record general-pasteboard content and changeCount before and after, and
verify that only deliberate external copies change them. Never submit sample
chat messages or forms. See the [macOS acceptance checklist](release-qa-checklist.md).
