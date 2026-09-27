# Clipboard upgrade — 2026-09-15

> 历史材料，保留原始研究、计划或验收范围；不代表当前功能或发布结论。
> 归档基线：main `9e786a6`。当前使用说明见 [用户指南](../../usage.md)。

## Implemented contracts

- Product Record limits: 10,000 records and 512 MiB of encoded payload. Both active and history-only records share the same budget. Each record still permits at most 32 memberships, and existing per-item content limits apply.
- Capacity warns when either count or bytes reaches 50%. Admission rejects a new record without eviction when either hard budget is insufficient. The warning and cleanup entry are inline; cleanup is always available.
- Cleanup creates a revision-bound plan before confirmation. Single-record, membership, collection, capacity and expired-history operations all show their scope. Changed candidates require review again; refreshed history plans can only retain original candidates and never add newly captured records. Ordinary-history suggestions retain pinned, tagged, user-organized and leased records. Old maintenance entry points no longer delete records; run-history maintenance retains its prior semantics.
- The quick panel has an independent query, filters, selection and preview. Search matches text, file names, source names/IDs and tags, including Chinese substrings and multiple keywords. Enter and Command+1–9 freeze a displayed Record identity. Unmodified digits and marked-text Enter remain text input. Escape closes the preview first.
- Reuse has an independent lease and no fabricated membership. It uses the existing privacy checks, focused-target validation, output transactions and run receipts. Repeated reuse leaves Stack/Queue memberships unchanged. A committed side effect with failed local recovery is reported without reissuing the output.
- SQLite schema 13 authenticates the new catalog and installs a new writer capability. The previous writer capability alone cannot modify an upgraded database. Catalog v2 migration preserves v1 IDs, order, metadata, routing, membership and payload ciphertext; the transaction validates readback before retiring legacy data.
- SQLite retains one connection/transaction/crypto owner, with separate Record catalog, settings and run-history domain extensions. Settings batch writes now use the same transaction helper.
- Record lists and subscriptions carry summaries. Body and normalized-search caches are bounded to 64 MiB and 16 MiB; thumbnail storage is bounded to 8 MiB. Image decoding/downsampling runs off the main actor. Search yields bounded batches and cancels superseded work. No plaintext disk search index is created.
- Accepted management edits, confirmed collection deletions and panel pin operations have an explicit shutdown drain. Sealed models reject new writes, and retired panel sessions remain owned until their accepted work settles.
- Runtime global input depends on a Core protocol rather than the platform event tap. Subtitle, speech, workflow and vocabulary lifecycles are separated from settings serialization; generation checks and startup write protection remain with the original owner.

## Evidence

Artifacts live under `.artifacts/clipboard-upgrade-20260915/` (ignored local evidence).

| Check | Evidence |
| --- | --- |
| Pre-change baseline | 1,714 Swift tests; `git diff --check`; Record boundary and shell syntax checks |
| Input/persistence/Record regression | `focused-regression2.log` and subsequent final regression logs |
| 10,000 mixed records | `final-stress-app-tests-verified.log`: 520,813,484 encoded bytes, approximately 496.7 MiB |
| Cold catalog open | 359.22 ms on this host in the debug test build |
| Warm catalog read p95 | 8.95 ms over 30 samples |
| Warm first search page p95 | 0.288 ms over 30 samples; 50 matching summaries |
| Native panel ready p95 | `final-stress-app-tests-verified.log`: 56.71 ms for 10,000 summaries, first page and search field focus, 30 warm samples, Reduce Motion on |
| IME/key routing | NSTextView marked-text Enter does not submit; only Command+digits invoke direct paste |
| Cleanup/restart under stress | Confirmed cleanup, reopened store, zero records and payload bytes |
| Native render evidence | `render/quick-panel-{light,dark}.png`, `render/cleanup-{light,dark}.png` |

The native panel timing is an AppKit test-harness measurement, not physical hotkey-to-window latency. The data-layer timings are measured separately. The pressure fixture uses large opaque image payloads to exercise storage; it does not establish image delivery correctness.

## Outstanding acceptance to record

The final CI and bundle coordinates are recorded in `.artifacts/clipboard-upgrade-20260915/delivery-status.md`. Physical hotkey/IME/VoiceOver behavior, text/image/file delivery in TextEdit/Safari/Finder, multi-display/full-screen spaces, and physical Fn dictation must be recorded separately. Unit tests and offscreen renders do not establish those results. During device QA, run only one Rill instance.

## Workspace preservation

The initial 50-file working-tree snapshot, hashes and tracked patch are in `baseline/`. Existing UI work and concurrently edited workflow files were retained. Implementation evidence must be compared against that baseline, not interpreted as ownership of every current Git difference.

Native UI automation first timed out; later attempts explicitly reported that the Mac is locked and automatic unlock failed. Manual unlock is required to continue device QA. The installed process was left running; no second Rill instance was launched. The review app is a locally signed development artifact and has not been installed. Device delivery and Fn acceptance remain unverified.

Draft PR delivery is blocked by the missing repository PR template: neither the checkout nor the remote `.github` directory contains one, and the account's default `.github` repository is empty. No unrelated working-tree changes were committed or pushed.
