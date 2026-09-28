# Performance benchmarks

The suite runs production Record code with synthetic, offline data. It does not
read user clipboard contents, recordings, files, Keychain keys or network services.

| Workload | Batch | CI role |
| --- | --- | --- |
| Plain text / Markdown | 10,000 `RecordTextFormatting.previewText` calls | Linux CPU simulation |
| Long Unicode | 1,000 grapheme-safe long-text previews | Linux CPU simulation |
| Stack / Queue enqueue | Insert 10,000 pending entries through `RecordStore` into AES-GCM SQLite | macOS correctness validation |
| Stack / Queue select | Select the next item 10,000 times with 10,000 entries pending | macOS correctness validation |
| Stack / Queue output | Begin and commit 10,000 entries, draining the container | macOS correctness validation |

Every workload checks its results. Buffer validation checks ordering, exact entry
identity, and restoration of the full and drained catalog. It sends no text to
other applications. GitHub-hosted macOS timing varies with runner load, so that
job runs without CodSpeed and makes no performance comparison. Its latency and
memory logs are diagnostics, not evidence of a regression or improvement.

## Run locally

Build and validate every workload on macOS:

```sh
just bench
```

Build and measure the portable preview workloads on Linux:

```sh
bash scripts/build_benchmarks.sh --codspeed --preview-only
codspeed run --mode simulation -- .artifacts/benchmarks/record-text
```

The build script compiles production code with optimization, without the app's
MLX dependency graph. Linux builds require `--preview-only`: encrypted storage
still depends on macOS APIs. The macOS-only `renderedMarkdown` attributed-text
API is excluded on Linux; both platforms run the same production `previewText`
implementation and validate the same expected outputs.

`--codspeed` downloads the official `instrument-hooks` C library at commit
`4c76dbb5b99fc4927289281c7b7ca71cc46e6836`, verifies the archive SHA-256, and links
it only into the benchmark binary. The archive includes its
[MIT and Apache-2.0 licenses](https://github.com/CodSpeedHQ/instrument-hooks/tree/4c76dbb5b99fc4927289281c7b7ca71cc46e6836).
The custom harness follows CodSpeed's supported C interface. Preview hooks
surround one batch after one warmup; URI construction, aggregate validation and
logging stay outside the window. Each preview checks its result inside the
workload. No walltime samples or walltime result JSON are emitted by this suite.

`just bench` needs neither the download nor a CodSpeed login. `just ci` includes
fast preview validation and tests buffer behavior through the Runtime tests.

## CI and interpretation

The workflow runs on `main`, relevant PRs and manual dispatch. Preview simulation
runs directly on Ubuntu 24.04 with Swift 6.2.1 and a commit-pinned setup action.
The native runner supports the simulator's `setarch` call. Actions are pinned to
commits; this public repository uses tokenless uploads and `contents: read`.

[CPU simulation](https://codspeed.io/docs/instruments/cpu) reduces sensitivity to
host load, but excludes system-call time. It measures the CPU cost of Linux
Swift/Foundation text processing, not Apple Silicon latency. The new instrument
needs a successful `main` baseline; old macOS walltime results are not comparable.

Actual SQLite I/O latency needs a separate experiment on a fixed, otherwise idle
Mac or a suitable dedicated runner. The experiment must fix data, toolchain and
cache conditions, compare both revisions on the same machine in interleaved
order, and establish the noise floor before drawing a conclusion. Shared-runner
walltime and CPU simulation cannot establish that latency. No new I/O measurement
tool is introduced here.

The buffer fixture uses a fixed synthetic key and temporary files. It does not
measure Keychain authorization, physical copy/paste or application compatibility;
those require the separate macOS and Record acceptance checks.

References: [Spark's benchmark layout](https://github.com/zendev-lab/spark/tree/main/benchmarks)
and [CodSpeed's custom harness guide](https://github.com/CodSpeedHQ/instrument-hooks/blob/main/CUSTOM_HARNESS.md).
