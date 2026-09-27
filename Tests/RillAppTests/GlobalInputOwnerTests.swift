@testable import RillWorkflows
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillPlatform

private final class GlobalInputOwnerProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var installationOutcomes: [Bool]
  private var installationCount = 0
  private var uninstallationCount = 0
  private var observedCapabilities: [GlobalInputCapability] = []
  private var cancelledRunIDs: [UUID] = []

  init(installationOutcomes: [Bool]) {
    self.installationOutcomes = installationOutcomes
  }

  func install() -> Bool {
    lock.withLock {
      installationCount += 1
      guard !installationOutcomes.isEmpty else { return false }
      return installationOutcomes.removeFirst()
    }
  }

  func uninstall() {
    lock.withLock {
      uninstallationCount += 1
    }
  }

  func record(_ capability: GlobalInputCapability) {
    lock.withLock {
      observedCapabilities.append(capability)
    }
  }

  func recordCancellation(runID: UUID) {
    lock.withLock {
      cancelledRunIDs.append(runID)
    }
  }

  var installCount: Int {
    lock.withLock { installationCount }
  }

  var uninstallCount: Int {
    lock.withLock { uninstallationCount }
  }

  var capabilities: [GlobalInputCapability] {
    lock.withLock { observedCapabilities }
  }

  var cancellations: [UUID] {
    lock.withLock { cancelledRunIDs }
  }
}

final class GlobalInputOwnerTests: XCTestCase {
  func testOwnerInstallsAndUninstallsSharedTapExactlyOnce() async {
    let hotkeyTap = HotkeyEventTap()
    let probe = GlobalInputOwnerProbe(installationOutcomes: [true])
    let owner = GlobalInputOwner(
      hotkeyTap: hotkeyTap,
      installTap: { probe.install() },
      uninstallTap: { probe.uninstall() },
      permissionChecker: { true },
      capabilityObserver: { capability in
        probe.record(capability)
      }
    )

    await owner.start()
    await owner.start()
    XCTAssertEqual(probe.installCount, 1)
    XCTAssertEqual(probe.capabilities, [.available])

    await owner.stop()
    await owner.stop()
    XCTAssertEqual(probe.uninstallCount, 1)
  }

  func testOwnerReportsTapFailureFromItsOwnTypedStream() async {
    let hotkeyTap = HotkeyEventTap()
    let diagnostics = DiagnosticsRecorder(eventBus: EventBus())
    let probe = GlobalInputOwnerProbe(installationOutcomes: [true, false])
    let owner = GlobalInputOwner(
      hotkeyTap: hotkeyTap,
      diagnostics: diagnostics,
      installTap: { probe.install() },
      uninstallTap: { probe.uninstall() },
      permissionChecker: { true },
      capabilityObserver: { capability in
        probe.record(capability)
      }
    )

    await owner.start()
    hotkeyTap.testingEmit(.globalInputUnavailable)
    for _ in 0..<200 {
      if probe.capabilities == [.available, .installationFailed] { break }
      await Task.yield()
    }

    XCTAssertEqual(probe.installCount, 2)
    XCTAssertEqual(probe.capabilities, [.available, .installationFailed])
    let events = await diagnostics.snapshot()
    XCTAssertTrue(events.contains { $0.event == "global-input.installed" })
    XCTAssertTrue(events.contains { $0.event == "global-input.unavailable" })

    await owner.stop()
    XCTAssertEqual(probe.uninstallCount, 1)
  }

  func testOwnerRoutesRunScopedEscapeCancellation() async {
    let hotkeyTap = HotkeyEventTap()
    let probe = GlobalInputOwnerProbe(installationOutcomes: [true])
    let owner = GlobalInputOwner(
      hotkeyTap: hotkeyTap,
      installTap: { probe.install() },
      uninstallTap: { probe.uninstall() },
      permissionChecker: { true },
      liveAudioCancellationHandler: { runID in
        probe.recordCancellation(runID: runID)
      }
    )
    let runID = UUID()

    await owner.start()
    hotkeyTap.testingEmit(.liveAudioCancellationRequested(runID))
    for _ in 0..<200 {
      if probe.cancellations == [runID] { break }
      await Task.yield()
    }

    XCTAssertEqual(probe.cancellations, [runID])
    await owner.stop()
  }
}
