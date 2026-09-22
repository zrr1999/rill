# Performance benchmarks

The CodSpeed suite measures the production `RecordTextFormatting.previewText`
implementation used when building Record headers. Its fixed, offline workloads
cover 10,000 plain-text previews, 10,000 Markdown previews, and 1,000 long Unicode
previews. Every iteration checks its expected result, including grapheme-safe
truncation. No user clipboard, recordings, files, or network services are read.

Build and validate every workload locally:

```sh
bash scripts/build_benchmarks.sh
bash scripts/build_benchmarks.sh --codspeed
codspeed run --mode walltime -- .artifacts/benchmarks/record-text
```

The build script compiles the production Swift file directly with optimization,
without adding a shipping executable or compiling the MLX dependency graph.
`RecordTextBenchmarks.swift` is the benchmark inventory. With `--codspeed`, the
script downloads the official `instrument-hooks` C library at commit
`4c76dbb5b99fc4927289281c7b7ca71cc46e6836`, verifies its archive SHA-256, and
compiles it only into the benchmark binary. The downloaded archive includes its
[MIT and Apache-2.0 licenses](https://github.com/CodSpeedHQ/instrument-hooks/tree/4c76dbb5b99fc4927289281c7b7ca71cc46e6836).
Ordinary local CI validates workloads without this download or any CodSpeed login.

Native measurement hooks surround 20 timed batches after one warmup, excluding
process startup and fixture construction. Result validation is included in each measured batch;
these are batch costs, not per-item latency measurements. The custom harness
follows CodSpeed's supported C interface because exec-harness 1.3.0 does not
provide an Apple Silicon macOS binary.
`CodSpeedResults.swift` writes the same walltime result schema as the official
[Rust integration](https://github.com/CodSpeedHQ/codspeed-rust/blob/main/crates/codspeed/src/walltime_results.rs).
Reported times describe one complete batch; `iter_per_round` is therefore one.

The advisory GitHub workflow runs on `main`, on relevant pull requests, and on
manual dispatch. It pins CodSpeed and other actions to commits, uses tokenless
uploads for this public repository, and requests only `contents: read`.
GitHub-hosted macOS walltime can vary with host load. A successful `main` run is
needed before PR comparisons become meaningful; these measurements do not prove
native copy/paste latency, encrypted persistence performance, or application
compatibility. Those require the separate macOS and Record acceptance checks.

To extend coverage, add deterministic workloads that call the production owner,
verify the amount of work and resulting state, and register them in the Swift
harness. Keep setup outside the measured operation when reporting
operation latency; explicitly identify it when reporting an end-to-end batch.

References: [Spark's benchmark layout](https://github.com/zendev-lab/spark/tree/main/benchmarks)
and [CodSpeed's custom harness guide](https://github.com/CodSpeedHQ/instrument-hooks/blob/main/CUSTOM_HARNESS.md).
