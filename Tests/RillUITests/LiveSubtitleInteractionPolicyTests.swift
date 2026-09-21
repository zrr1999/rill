import XCTest

@testable import RillCore
@testable import RillUI

final class LiveSubtitleInteractionPolicyTests: XCTestCase {
  func testSurfaceUsesComfortableTransparencyWithAccessibleFallbacks() {
    XCTAssertEqual(
      LiveSubtitleSurfaceStyle.resolve(
        reduceTransparency: false,
        increasedContrast: false
      ),
      LiveSubtitleSurfaceStyle(material: .thin, tintOpacity: 0.08)
    )
    XCTAssertEqual(
      LiveSubtitleSurfaceStyle.resolve(
        reduceTransparency: false,
        increasedContrast: true
      ),
      LiveSubtitleSurfaceStyle(material: .thin, tintOpacity: 0.16)
    )
    XCTAssertEqual(
      LiveSubtitleSurfaceStyle.resolve(
        reduceTransparency: true,
        increasedContrast: false
      ),
      LiveSubtitleSurfaceStyle(material: .opaque, tintOpacity: 0)
    )
  }

  func testAudioCaptureActivityIsLimitedToRecordingLifecyclePhases() {
    for phase in [
      LiveSubtitlePhase.preparing,
      .recording,
      .listening,
      .transcribing,
    ] {
      XCTAssertTrue(LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: phase))
    }

    for phase in [
      LiveSubtitlePhase.hidden,
      .finalizing,
      .processing,
      .failed,
    ] {
      XCTAssertFalse(LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: phase))
    }
  }

  func testStandardLiveTextPreservesLatestContentWithinBoundedHeight() {
    XCTAssertEqual(LiveSubtitlePresentationPolicy.standardLiveTextLineLimit, 2)
    XCTAssertTrue(LiveSubtitlePresentationPolicy.standardLiveTextPreservesLatestContent)
  }

  func testRecordingTimerShowsElapsedAndMaximumDurationBeforeWarningWindow() throws {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let snapshot = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .recording,
      recordingStartedAt: startedAt,
      maximumRecordingDurationSeconds: 120
    )

    let state = try XCTUnwrap(
      LiveSubtitlePresentationPolicy.recordingTimerState(
        for: snapshot,
        now: startedAt.addingTimeInterval(67.9)
      )
    )

    XCTAssertEqual(state.elapsedSeconds, 67)
    XCTAssertEqual(state.maximumSeconds, 120)
    XCTAssertEqual(state.remainingSeconds, 53)
    XCTAssertFalse(state.isNearLimit)
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds),
      "1:07"
    )
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.formattedDuration(try XCTUnwrap(state.maximumSeconds)),
      "2:00"
    )
    XCTAssertFalse(state.isUnlimited)
  }

  func testRecordingTimerTurnsCriticalForLastTenPercentAndClampsAtLimit() throws {
    let startedAt = Date(timeIntervalSince1970: 2_000)
    let snapshot = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .recording,
      recordingStartedAt: startedAt,
      maximumRecordingDurationSeconds: 120
    )

    let warning = try XCTUnwrap(
      LiveSubtitlePresentationPolicy.recordingTimerState(
        for: snapshot,
        now: startedAt.addingTimeInterval(108)
      )
    )
    XCTAssertEqual(warning.remainingSeconds, 12)
    XCTAssertTrue(warning.isNearLimit)
    XCTAssertEqual(warning.warningLevel, .warning)

    let expired = try XCTUnwrap(
      LiveSubtitlePresentationPolicy.recordingTimerState(
        for: snapshot,
        now: startedAt.addingTimeInterval(130)
      )
    )
    XCTAssertEqual(expired.elapsedSeconds, 120)
    XCTAssertEqual(expired.remainingSeconds, 0)
    XCTAssertTrue(expired.isNearLimit)
    XCTAssertEqual(expired.warningLevel, .critical)
  }

  func testOverlayTextExpandsButCursorPreviewStaysCompact() {
    let overlay = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .transcribing,
      hypothesisText: "Preview",
      livePreviewPlacement: .overlay
    )
    var cursor = overlay
    cursor.livePreviewPlacement = .cursor

    XCTAssertTrue(LiveSubtitlePresentationPolicy.usesExpandedLayout(overlay))
    XCTAssertFalse(LiveSubtitlePresentationPolicy.usesExpandedLayout(cursor))
  }

  func testUnlimitedRecordingTimerKeepsElapsedTimeWithoutWarningOrRemainingTime() throws {
    let startedAt = Date(timeIntervalSince1970: 3_000)
    let snapshot = LiveSubtitleSnapshot(
      runID: UUID(),
      phase: .recording,
      recordingStartedAt: startedAt,
      recordingDurationIsUnlimited: true
    )

    let state = try XCTUnwrap(
      LiveSubtitlePresentationPolicy.recordingTimerState(
        for: snapshot,
        now: startedAt.addingTimeInterval(3_725.8)
      )
    )

    XCTAssertEqual(state.elapsedSeconds, 3_725)
    XCTAssertNil(state.maximumSeconds)
    XCTAssertNil(state.remainingSeconds)
    XCTAssertFalse(state.isNearLimit)
    XCTAssertTrue(state.isUnlimited)
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.formattedDuration(state.elapsedSeconds),
      "1:02:05"
    )
  }

  func testFinalizingUsesAProcessingSymbolInsteadOfARecordingSymbol() {
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.statusSymbol(for: .recording),
      .waveform
    )
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.statusSymbol(for: .finalizing),
      .forwardEnd
    )
  }

  func testNetworkDisclosureDistinguishesOfflineAndOnlineWorkflows() {
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureTitle(
        .offline,
        language: .english
      ),
      "Offline — processed entirely on this Mac"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureTitle(
        .online,
        language: .simplifiedChinese
      ),
      "联网 — 此工作流会使用网络服务"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureShortTitle(
        .offline,
        language: .simplifiedChinese
      ),
      "离线"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureShortTitle(
        .online,
        language: .english
      ),
      "Online"
    )
  }

  func testNetworkDisclosureUsesDistinctSymbolsAndFailsClosedForUnknownUsage() {
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureSymbolName(.offline),
      "lock.fill"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureSymbolName(.online),
      "network"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.networkDisclosureTitle(
        .unknown,
        language: .simplifiedChinese
      ),
      "联网状态无法确定"
    )
  }
}
