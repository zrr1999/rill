import Foundation

final class CodSpeedRecorder {
    #if CODSPEED
    private let hooks: OpaquePointer
    #endif
    let isInstrumented: Bool
    private var reports: [[String: Any]] = []

    init() {
        #if CODSPEED
        guard let hooks = instrument_hooks_init() else {
            fatalError("Could not initialize CodSpeed instrumentation")
        }
        self.hooks = hooks
        isInstrumented = instrument_hooks_is_instrumented(hooks)
        precondition(instrument_hooks_set_integration(
            hooks, CodSpeedResults.integrationName, CodSpeedResults.integrationVersion
        ) == 0)
        #else
        isInstrumented = false
        #endif
    }

    deinit {
        #if CODSPEED
        instrument_hooks_deinit(hooks)
        #endif
    }

    func begin() {
        #if CODSPEED
        if isInstrumented { precondition(instrument_hooks_start_benchmark(hooks) == 0) }
        #endif
    }

    func end(uri: String) {
        #if CODSPEED
        if isInstrumented {
            precondition(instrument_hooks_stop_benchmark(hooks) == 0)
            precondition(instrument_hooks_set_executed_benchmark(hooks, getpid(), uri) == 0)
        }
        #endif
    }

    func record(name: String, uri: String, samples: [Double], warmupIterations: Int = 1) {
        if isInstrumented {
            reports.append(CodSpeedResults.benchmark(
                name: name, uri: uri, samples: samples, warmupIterations: warmupIterations
            ))
        }
    }

    func write() throws {
        if !reports.isEmpty { try CodSpeedResults.write(reports) }
    }
}
