import XCTest

@testable import RillCore

final class ShutdownWaitersTests: XCTestCase {
    func testResumeAllReleasesEverySuspendedWaiterOnce() async {
        let gate = ShutdownGate()
        async let first: Void = gate.wait()
        async let second: Void = gate.wait()
        await gate.untilWaiting(2)
        await gate.resume()
        await first
        await second
        async let third: Void = gate.wait()
        await gate.untilWaiting(3)
        await gate.resume()
        await third
    }
}

private actor ShutdownGate {
    private var waiters = ShutdownWaiters()
    private var waiting = 0
    private var observers: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        waiting += 1
        let observers = observers
        self.observers.removeAll()
        for observer in observers { observer.resume() }
        await withCheckedContinuation { waiters.add($0) }
    }

    func untilWaiting(_ count: Int) async {
        while waiting < count {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    func resume() {
        waiters.resumeAll()
    }
}
