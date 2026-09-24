# Performance benchmarks

The CodSpeed suite measures production Record code with synthetic, offline data.
No user clipboard, recordings, files, Keychain keys, or network services are read
by the workloads.

| Workload | Measured batch |
| --- | --- |
| Plain text / Markdown | 10,000 `RecordTextFormatting.previewText` calls |
| Long Unicode | 1,000 grapheme-safe long-text previews |
| Stack / Queue enqueue | Insert 10,000 pending entries through `RecordStore` into AES-GCM SQLite |
| Stack / Queue select | Select the next item 10,000 times with 10,000 entries pending |
| Stack / Queue output | Begin and commit 10,000 output entries, draining the container |

Every workload checks its results. The buffer workloads verify Stack/Queue
ordering, exact entry identity, and restoration of both the full and drained
catalog. Output measures state transitions and persistence; it sends nothing to
other applications.

Build and validate every workload locally:

```sh
bash scripts/build_benchmarks.sh
bash scripts/build_benchmarks.sh --codspeed
codspeed run --mode walltime -- bash -c '.artifacts/benchmarks/record-text && .artifacts/benchmarks/record-buffer'
```

The build script compiles production code with optimization. Buffer benchmarks
link the Core, Runtime and Persistence modules, without a shipping executable
or the MLX dependency graph. The two `Record*Benchmarks.swift` files own the
workload inventories; `CodSpeedRecorder.swift` owns the shared instrumentation
lifecycle. With `--codspeed`, the
script downloads the official `instrument-hooks` C library at commit
`4c76dbb5b99fc4927289281c7b7ca71cc46e6836`, verifies its archive SHA-256, and
compiles it only into the benchmark binary. The downloaded archive includes its
[MIT and Apache-2.0 licenses](https://github.com/CodSpeedHQ/instrument-hooks/tree/4c76dbb5b99fc4927289281c7b7ca71cc46e6836).
`just bench` validates all workloads without this download or any CodSpeed login.
Regular `just ci` retains the fast preview validation with `--preview-only` and
tests buffer behavior through the Runtime tests. The dedicated benchmark workflow
builds and measures both suites when the affected production modules, benchmarks
or their build workflow change; unrelated PRs do not rebuild the benchmark modules.

Preview hooks surround 20 timed batches after one warmup. Buffer benchmarks run
five independent, fresh-database rounds; each round warms one write/output cycle
before measuring the three batches. Catalog seeding, initialization, warmup and
restart verification are outside the timed batches. Result validation and sample
bookkeeping are included in each measured batch. These are batch costs, not
per-item latency measurements. The custom harness
follows CodSpeed's supported C interface because exec-harness 1.3.0 does not
provide an Apple Silicon macOS binary.
`CodSpeedResults.swift` writes the same walltime result schema as the official
[Rust integration](https://github.com/CodSpeedHQ/codspeed-rust/blob/main/crates/codspeed/src/walltime_results.rs).
Reported times describe one complete batch; `iter_per_round` is therefore one.

Buffer run logs also report per-operation P50/P95/P99 for enqueue, select,
output preparation and consumption commit, plus RSS and checkpointed database
growth after enqueue. RSS is a process observation that includes measurement
bookkeeping and allocator reuse; a zero delta does not mean entries use no memory.
These optimized measurements replace the opt-in debug-only buffer benchmark;
older debug observations remain historical evidence, not comparable CodSpeed baselines.

The advisory GitHub workflow runs on `main`, on relevant pull requests, and on
manual dispatch. It pins CodSpeed and other actions to commits, uses tokenless
uploads for this public repository, and requests only `contents: read`.
GitHub-hosted macOS walltime can vary with host load. A successful `main` run is
needed before PR comparisons become meaningful; these measurements do not prove
native copy/paste latency or application compatibility. The encrypted SQLite
measurements use a fixed synthetic key and local temporary files; they do not
measure Keychain authorization or real application input. Those require the
separate macOS and Record acceptance checks.

To extend coverage, add deterministic workloads that call the production owner,
verify the amount of work and resulting state, and register them in the Swift
harness. Keep setup outside the measured operation when reporting
operation latency; explicitly identify it when reporting an end-to-end batch.

References: [Spark's benchmark layout](https://github.com/zendev-lab/spark/tree/main/benchmarks)
and [CodSpeed's custom harness guide](https://github.com/CodSpeedHQ/instrument-hooks/blob/main/CUSTOM_HARNESS.md).
