# Record architecture

Status: accepted, Record graph v1 / SQLite schema 12.

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

## Persistence and migration

SQLite schema 12 separates encrypted immutable payload blobs from the encrypted
Record graph. Metadata-only changes retain the payload blob and ciphertext.
The pre-Record clipboard graph is decoded only by `LegacyClipboardMigration`.
The repository writes, decrypts, and validates the complete Record graph and all
payloads in one transaction before deleting the legacy rows. Any decode, key,
reference, size, CAS, or readback failure rolls the transaction back.

The migration is forward-only. There is no dual runtime or downgrade contract.
Old workflow TOML names remain accepted at the file-loader boundary and are
normalized immediately; canonical serialization uses Record terminology only.

## Limits

Content keeps the shipped 1 MiB text, 32 MiB image, and 64 MiB total budget.
Each Record may have at most 32 memberships, the graph at most 8,192
memberships, and each route at most 32 collection references. Pinned Records and
Records with any active membership are protected from automatic retention.

## Deferred debt

Global input contracts should move to Core so Runtime no longer imports the
platform hotkey implementation. SQLite should later split into one connection /
migration owner and records, history, and settings repositories. Remaining
settings, workflow, and voice projections should continue moving out of the
global AppModel.
