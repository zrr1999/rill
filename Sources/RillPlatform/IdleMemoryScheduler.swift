import AppKit
import CoreGraphics

@MainActor
public final class IdleMemoryScheduler {
    private let scheduler = NSBackgroundActivityScheduler(identifier: "dev.zrr.Rill.memory-maintenance")
    private var sleepObserver: NSObjectProtocol?
    private let interrupt: @Sendable () async -> Void

    public init(run: @escaping @Sendable () async -> Void, interrupt: @escaping @Sendable () async -> Void) {
        self.interrupt = interrupt
        scheduler.interval = 15 * 60
        scheduler.tolerance = 5 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .background
        scheduler.schedule { completion in
            Task {
                await run()
                completion(.finished)
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in Task { await interrupt() } }
    }

    public nonisolated static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }

    public func stop() {
        scheduler.invalidate()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        Task { await interrupt() }
    }
}
