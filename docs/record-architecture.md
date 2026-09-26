# Record architecture

Status: accepted, Record catalog v2 / SQLite schema 13.

## Decision

Rill is a local-first Record flow and Record routing system. The system
clipboard is one source and one sink. It does not own stored content, grouping,
routing, delivery state, or workflow history.

`RecordStore` is the single actor that owns immutable Records and the mutable
metadata, activity, membership, collection, route, lease, and persistence CAS
coordinates around them. `RecordIngestionCoordinator` owns source → privacy →
route → atomic ingest. `RecordDeliveryCoordinator` owns target route → exact
membership lease → sink → content-free receipt. Sink identities are checked once at construction; duplicate
identities return `RegistrationError.duplicateSink` before any lease or output.
The sink registry is immutable for the coordinator lifetime.

## Invariants

- A Record payload never changes. Edit and Replace create a derived Record.
- A membership belongs to exactly one Record and one collection and carries an
  ordinal, active/consumed state, and revision. Reactivating a consumed
  membership keeps its identity and assigns a new ordinal.
- All Records is a virtual de-duplicated timeline, not a privileged collection.
- Removing a membership never deletes its Record; global deletion is explicit.
- Selection and consumption are independent policies. Stack, Queue, and List
  are only presets.
- Capture routing creates one Record and the stable union of every matched
  destination, unless the canonical payload matches an existing Record. A match
  reuses the earliest Record: its SHA-256 selects candidates and exact payload
  equality confirms them. Provenance and creation time stay with that Record.
  Missing destination memberships are added. A consumed membership in a requested
  destination becomes active and receives a new ordinal at the front of that
  collection. Edit and Replace still create a derived Record and are not folded
  into an existing payload. Delivery routing uses highest priority, then stable
  rule ID, and retains the rule's ordered collection list.
- A successful delivery consumes only the leased origin membership. A failed
  delivery releases the lease and records only a closed failure code.
- Workflow execution history remains `WorkflowResultRecord` plus
  `WorkflowRunReceipt`; Record delivery does not create a second timeline.
- Collection membership events are published only after the graph commit and
  carry exact Record, membership, membership revision, and store revision
  coordinates. Legacy automation actions that were never executable remain
  fail-closed, but their trigger decisions still produce durable run receipts.

## System clipboard boundary

Native copy, cut, and paste remain owned by the foreground application. Rill
asynchronously reads clipboard changes and records permitted content. Collection
previews, capture controls, privacy changes, and shutdown never write back to
the clipboard. The capture port exposes reads only; the global input tap has no
native paste interception or replay path.

Only explicitly requested output uses the shared delivery workflow. Text,
images, and files all use its target checks and conditional clipboard transaction;
restoration must preserve a newer external copy. Pausing history capture does
not disable explicit output.

## Content previews

The quick panel and record inspector share `RecordContentPreview`. Opening the
quick-panel preview loads only the selected immutable payload; changing selection,
closing the panel, or refreshing the catalog cancels the previous request. A
refresh keeps an already loaded preview when its exact subject remains valid. Preview
reads do not acquire delivery leases, consume memberships, or touch the clipboard.

Images are decoded off the main actor with ImageIO downsampling (768 pixels for
the inline preview, at most 2048 for the expanded sheet). Decoded images belong
to visible views and are released when those views disappear, without writing
plaintext image files or maintaining a process-wide image cache.

Visible file rows read metadata and request cancellable Quick Look thumbnails.
Full Quick Look views are created only when explicitly opened, do not autoplay,
and close with their sheet. File URLs reference current filesystem contents,
not captured copies; missing or unreadable files show an unavailable state. Rill
does not persist file thumbnails or contents. macOS Quick Look and file providers
manage their own rendering, caches, and access behavior.

## Persistence and migration

SQLite schema 13 stores encrypted catalog nodes and immutable payload blobs
separately. The catalog holds headers and previews; payloads are loaded on demand
through a bounded cache. Metadata-only changes retain the payload ciphertext.

Record headers store a SHA-256 of the canonical payload bytes. Headers written
before the digest existed are filled from the stored payload on the next
non-derived ingest and committed with that graph write. A failed commit rolls
the digest fill back with the rest of the graph.

The pre-Record clipboard graph is decoded only by `LegacyClipboardMigration`.
Record graph v1 remains readable and is converted to catalog v2 on the next
commit. Catalog mutations, payload writes, and legacy-row removal share one
transaction with revision checks and authenticated readback. A failed commit
rolls back the database transaction and the RecordStore's committed graph state.

The migration is forward-only. There is no dual runtime or downgrade contract.
Old workflow TOML names remain accepted at the file-loader boundary and are
normalized immediately; canonical serialization uses Record terminology only.

## Local quick-panel search

`RecordQuery` defaults to case- and accent-insensitive literal AND matching
across payload text, file names, source identity, and tags. Source, kind, pin,
and collection filters apply before reading a payload. Results retain recency
order; each store call scans at most 256 records. The quick panel scans further
pages until it fills 50 results or reaches the end.

Only when the entire literal search is empty does the quick panel retry with
`matching: .approximate`. This mode adds ASCII word prefixes, anchored
subsequences, bounded adjacent-transposition/edit matching, and Chinese full
pinyin or initials from Foundation transliteration. All query terms must match.
It does not score or reorder literal results. Pagination retains the matching
mode and rejects pages from a different catalog revision. Other callers keep
literal behavior unless they explicitly opt in.

Approximation accepts up to eight ASCII terms and 160 UTF-8 bytes. URL queries,
absolute paths, and single-token queries containing three consecutive digits
remain literal. Numeric terms in an expanded multi-term query must retain a
whole token match. Pinyin terms require 3–40 letters, full syllable boundaries,
and common CJK characters; polyphonic names, dialects, Chinese synonyms, and
semantic paraphrases are not guaranteed. No result is an acceptable outcome.

`RecordStore` owns a transient FIFO cache of folded payload text and derived
search data, budgeted together at 16 MiB of logical content (not heap RSS).
Payloads are immutable; deleted records lose their cached data, while mutable
tags are read from the current catalog. Transliteration runs off the store
actor, checks cancellation between bounded chunks, and validates the catalog
revision before publishing results. A cold full-history miss can read and
prepare every eligible payload; this is not a persistent inverted index.

This path uses no model, downloaded data, server, telemetry, or new persistent
index. Clipboard capture and explicit output retain their existing owners.
Store/model tests do not establish physical keyboard, IME, focus, or paste
acceptance; those require the macOS checklist.

### Optional semantic candidates

`RecordSemanticSearch` receives a Core `RecordEmbeddingProvider` port; AppBootstrap injects
`RecordWorkerEmbedder` with its own supervised helper process. The panel's explicit
meaning-search action leaves literal/approximate results first and appends a deduplicated
candidate section without replacing the selected ID. Missing weights show a separate
1.2 GB download action. Neither opening the App nor typing invokes a download.

The actor serializes superseding searches through cancellation and a drained predecessor,
applies source/kind/pin/collection filters before payload reads, and checks the catalog
revision before returning. Numeric identifier tokens with three consecutive digits must
match exactly; standalone URLs and absolute paths remain on the literal path. Image content
is excluded. File records contribute names only. Scores are maximum chunk cosine similarities,
not calibrated probabilities or acceptance thresholds; the ten nearest eligible records
may include unrelated candidates.
The validated 1,024-dimension vectors are scored with Swift SIMD, keeping platform math
SDKs out of Runtime.

Qwen3-Embedding-0.6B runs in the helper via the existing locked MLX graph. Queries have a
256-token limit; document windows are 248 tokens with stride 192 and a maximum of 16
(first 15 plus last). Large UTF-8/JSON inputs are bounded before IPC. Partial coverage is
reported rather than presented as exhaustive. The 128 MiB logical vector cache is transient,
observes committed catalog changes for deletion/tag invalidation, and is cleared at shutdown.
Resident vectors are scored before admitting missing records, so crossing the cache budget
does not turn every warm query into a full re-encode. Failed or cancelled searches reconcile
against the current catalog and retain only still-valid vectors for the next query.
Cold indexing may visit every eligible record. UI progress is throttled and cancellation
retains the task until its worker operation settles. The workspace owns final shutdown;
the provider retires the helper after 30 idle seconds.

Model downloads use an exact revision and file inventory with size/SHA-256 verification,
reject links and extra model-loader inputs, and publish only verified staging. A filesystem
lock excludes concurrent publishers and allows the next explicit download to reclaim
abandoned staging. No record text is sent to the model host. See `LOCAL_MODEL_NOTICES.md`
and `PRIVACY.md` for the model and data boundaries.

### Optional cloud comparison

`RecordCloudRanking` owns the transient Jev credential and one active operation behind the
Core `RecordRankingProvider` port. AppBootstrap injects `JevRecordRankingProvider`; the
workspace owns service shutdown and panel models own cancelled tasks until drained.
The ordinary local search path never calls the service. The explicit comparison action
interleaves the current filtered literal and semantic lists, deduplicates IDs and selects
at most ten non-image records. Runtime resolves payloads from RecordStore, clips text/file
basenames to 1,800 UTF-8 bytes without splitting scalars, and returns an immutable preview.
A single-use, ten-minute review must be explicitly confirmed before the fixed HTTPS request.

Source identity, capture exclusions, current focus policy and catalog revision are checked
before sending and after receiving. Query/filter/catalog changes and panel closure invalidate
the UI review and cancel outstanding work. A provider that ignores cancellation retains the
single active slot until it settles; late results cannot publish. Privacy changes after send
cannot retract data already received by TypeSafe. No automatic retries or remote error bodies
reach UI/diagnostics. The provider refuses redirects and validates bounded JSON, model identity,
score IDs, ranges and probability consistency. Neither the key nor scores are persisted.

The sheet shows separate 0–2 scores, elapsed request/validation time and token usage. Selecting
a candidate only sets the existing quick-panel selected ID; it does not reorder the local list,
write the clipboard, deliver a record, consume membership, or change the Record graph.
Real-key network acceptance and macOS keyboard/secure-field behavior require separate QA.

## Limits

`RecordStorageLimits.productDefault` admits up to 10,000 Records and 512 MiB of
payload, with per-item limits of 1 MiB text and 32 MiB images. Each Record may
have at most 32 memberships, the graph at most 320,000 memberships, and each
route at most 32 collection references. Pinned Records and Records with any
active membership are protected from automatic retention. Clipboard transfer
budgets are separate from the durable catalog's storage limits.

## Module and lifecycle boundaries

`GlobalInputSource` and focus identity values live in Core. Runtime consumes
those contracts; App wires platform input and recording cues. SQLite history,
settings, and catalog queries share one connection owner so graph migration and
clear barriers retain their transactional guarantees. UI persistence task
ownership is separate from AppModel's settings presentation and retry policy.

See [Architecture](architecture.md) for the dependency graph and state owners.


### Explicit recognition corrections

`RecordStore.saveTextCorrection` resolves the original immutable text by workflow
run ID and creates a new user-derived Record. It preserves the source and its
memberships. The correction has no collection membership, so saving it cannot
trigger routing or repeat delivery. An operation ID makes retries idempotent;
a deleted original is not resurrected. The workspace owns and drains the accepted
write. Remembering vocabulary is a separate, scope-visible command.
