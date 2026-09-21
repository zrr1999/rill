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
membership lease → sink → content-free receipt.

## Invariants

- A Record payload never changes. Edit and Replace create a derived Record.
- A membership belongs to exactly one Record and one collection and carries a
  stable ordinal, active/consumed state, and revision.
- All Records is a virtual de-duplicated timeline, not a privileged collection.
- Removing a membership never deletes its Record; global deletion is explicit.
- Selection and consumption are independent policies. Stack, Queue, and List
  are only presets.
- Capture routing creates one Record and the stable union of every matched
  destination. Delivery routing uses highest priority, then stable rule ID, and
  retains the rule's ordered collection list.
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

## Persistence and migration

SQLite schema 13 stores encrypted catalog nodes and immutable payload blobs
separately. The catalog holds headers and previews; payloads are loaded on demand
through a bounded cache. Metadata-only changes retain the payload ciphertext.

The pre-Record clipboard graph is decoded only by `LegacyClipboardMigration`.
Record graph v1 remains readable and is converted to catalog v2 on the next
commit. Catalog mutations, payload writes, and legacy-row removal share one
transaction with revision checks and authenticated readback. A failed commit
rolls back the database transaction and the RecordStore's committed graph state.

The migration is forward-only. There is no dual runtime or downgrade contract.
Old workflow TOML names remain accepted at the file-loader boundary and are
normalized immediately; canonical serialization uses Record terminology only.

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
