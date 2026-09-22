import Foundation

@main
struct RecordTextBenchmarks {
    static func main() throws {
        #if CODSPEED
        var reports: [[String: Any]] = []
        guard let hooks = instrument_hooks_init() else {
            fatalError("Could not initialize CodSpeed instrumentation")
        }
        defer { instrument_hooks_deinit(hooks) }
        let instrumented = instrument_hooks_is_instrumented(hooks)
        precondition(instrument_hooks_set_integration(
            hooks, CodSpeedResults.integrationName, CodSpeedResults.integrationVersion
        ) == 0)
        #endif

        for workload in workloads {
            var samples: [Double] = []
            #if CODSPEED
            if instrumented {
                _ = workload.__codspeed_root_frame__run()
                precondition(instrument_hooks_start_benchmark(hooks) == 0)
            }
            let rounds = instrumented ? 20 : 1
            #else
            let rounds = 1
            #endif

            for _ in 0..<rounds {
                let start = ContinuousClock.now
                let outputBytes = workload.__codspeed_root_frame__run()
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9)
                precondition(outputBytes == workload.expected.utf8.count * workload.iterations)
            }

            #if CODSPEED
            if instrumented {
                precondition(instrument_hooks_stop_benchmark(hooks) == 0)
                let uri = "Benchmarks/RecordTextBenchmarks.swift::\(workload.name)[\(workload.iterations)]"
                precondition(instrument_hooks_set_executed_benchmark(hooks, getpid(), uri) == 0)
                reports.append(CodSpeedResults.benchmark(name: workload.name, uri: uri, samples: samples))
            }
            #endif
            print("Validated \(workload.name): \(rounds) batches of \(workload.iterations) previews")
        }
        #if CODSPEED
        if !reports.isEmpty { try CodSpeedResults.write(reports) }
        #endif
    }

    private static var workloads: [PreviewWorkload] {
        [
            PreviewWorkload(
                name: "Plain text", iterations: 10_000,
                input: "  Clipboard history\n  keeps the original text.  ",
                expected: "Clipboard history keeps the original text."
            ),
            PreviewWorkload(
                name: "Markdown", iterations: 10_000,
                input: "# Clipboard history\n\n- **Keep** the [original](https://example.invalid) text.",
                expected: "Clipboard history Keep the original text."
            ),
            PreviewWorkload(
                name: "Long Unicode", iterations: 1_000,
                input: String(repeating: "剪贴板 👩🏽‍💻 e\u{301}\n", count: 128),
                expected: String(String(repeating: "剪贴板 👩🏽‍💻 e\u{301} ", count: 128).prefix(279))
                    .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            ),
        ]
    }
}

private struct PreviewWorkload {
    let name: String
    let iterations: Int
    let input: String
    let expected: String

    // CodSpeed recognizes this required prefix when trimming benchmark call stacks.
    @inline(never)
    func __codspeed_root_frame__run() -> Int {
        var outputBytes = 0
        for _ in 0..<iterations {
            let preview = RecordTextFormatting.previewText(input)
            precondition(preview == expected, "The preview workload produced an incorrect result")
            outputBytes += preview.utf8.count
        }
        return outputBytes
    }
}
