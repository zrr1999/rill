---
name: rill-record-change
description: Change Rill Record ingestion, immutable payloads, collection memberships, routes, leases, delivery, or encrypted persistence. Use for changes to Record state and clipboard capture semantics, not presentation-only Record UI edits.
---

# Rill Record Change

Preserve the Record graph and its transaction boundaries from capture through
delivery. Respond in the user's language.

Read [Record architecture](../../../docs/record-architecture.md) and the affected
ownership rules in [architecture](../../../docs/architecture.md). Locate the
production path through `RecordStore`, `RecordIngestionCoordinator`,
`RecordDeliveryCoordinator`, and the persistence or platform adapter involved.
Read current types, schema, and constants rather than hardcoding their versions
or limits from an earlier design note.

## Model the state transition

Identify the Record, exact membership, route, lease, persistence revision, and
event affected by the request. For each write, establish what becomes committed
and what must remain unchanged if persistence fails.

- `RecordStore` owns the catalog graph. Do not add another authoritative copy
  of membership, consumption, or routing state in the UI, clipboard adapter, or
  a reconciliation loop.
- Record payloads are immutable. Editing content creates a derived Record;
  removing a membership does not delete the Record globally. All Records is a
  deduplicated projection, not another owning collection or payload copy.
- Selection order and consumption policy are separate decisions. Capture may
  fan out to multiple destinations; delivery leases one exact origin membership.
  Successful consumption affects that origin, not every membership of the Record.
- A sink failure persists its allowed failure code before releasing the origin
  membership lease. If settlement persistence fails, preserve that lease for
  settlement retry. Distinguish retrying settlement from repeating an already
  acknowledged external effect. Check stale completions and cancellation
  separately; neither selection nor an attempted output establishes success.

## Keep commit, publication, and cleanup ordered

Persist the graph before publishing catalog changes or domain events. Events
must identify the committed Record, membership, and revision. Test a rejected
write for both persistent rollback and unchanged in-memory state; checking only
the returned error misses phantom records or consumption.

SQLite domain extensions share one connection and transaction owner. Do not
split actors or suspend between transaction statements to shorten a file. For
migration, follow the current atomic update, revision comparison, encryption,
and authenticated readback contract. Preserve rollback on failure and the
forward-only migration boundary; avoid dual runtime models as compatibility.
Keep workflow execution receipts in their existing history model rather than
creating a second Record timeline.

## Preserve the native clipboard boundary

Ordinary copy, cut, and paste belong to the foreground app. Passive capture is
asynchronous and read-only; previews, capture toggles, privacy updates, and
shutdown must not write to the clipboard or intercept and replay ordinary paste.
Exercise consecutive copies and retry after a failed capture write when changing
capture scheduling.

Explicit copy or insertion uses the delivery path with target and privacy checks.
Any temporary clipboard transaction must preserve a newer external copy when
restoring state. Pausing passive capture does not disable an explicitly requested
output. Trace these as separate operations even when they use the same adapter.

## Verify and report

Choose deterministic tests for the affected state transition: multiple
memberships, lease success/failure, route ordering, rejected transactions,
migration rollback, or rapid capture. Observe the catalog, persisted graph,
events, and sink calls that matter; avoid source-text assertions and timing sleeps.
Use [CONTRIBUTING.md](../../../CONTRIBUTING.md) for validation commands.

Report the invariant preserved or changed and the actual checks. Native copy,
paste, focus, and IME behavior requires macOS interaction evidence in addition
to store or adapter tests.
