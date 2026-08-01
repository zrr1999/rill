import XCTest

@testable import RillCore
@testable import RillUI

final class LiveSubtitleInteractionPolicyTests: XCTestCase {
  func testActiveCapturePhasesExposeStopInsteadOfDismiss() {
    for phase in [
      LiveSubtitlePhase.preparing,
      .recording,
      .listening,
      .transcribing,
    ] {
      XCTAssertTrue(LiveSubtitleInteractionPolicy.showsStopControl(for: phase))
      XCTAssertTrue(LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: phase))
    }

    for phase in [
      LiveSubtitlePhase.hidden,
      .finalizing,
      .processing,
      .failed,
    ] {
      XCTAssertFalse(LiveSubtitleInteractionPolicy.showsStopControl(for: phase))
      XCTAssertFalse(LiveSubtitlePresentationPolicy.isAudioCaptureActive(phase: phase))
    }
  }

  func testStandardLiveTextPreservesLatestContentWithinBoundedHeight() {
    XCTAssertEqual(LiveSubtitlePresentationPolicy.standardLiveTextLineLimit, 4)
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

    let expired = try XCTUnwrap(
      LiveSubtitlePresentationPolicy.recordingTimerState(
        for: snapshot,
        now: startedAt.addingTimeInterval(130)
      )
    )
    XCTAssertEqual(expired.elapsedSeconds, 120)
    XCTAssertEqual(expired.remainingSeconds, 0)
    XCTAssertTrue(expired.isNearLimit)
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

  func testProviderDisclosureIdentifiesOnDeviceCapture() {
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.providerDisclosureTitle(
        providerID: "sherpa-onnx.local",
        language: .english
      ),
      "On-device"
    )
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.providerDisclosureTitle(
        providerID: "sherpa-onnx.local",
        language: .simplifiedChinese
      ),
      "本机处理"
    )
    XCTAssertNil(
      LiveSubtitleInteractionPolicy.providerDisclosureTitle(
        providerID: nil,
        language: .english
      )
    )
  }

  func testLocalDisclosureUsesTintedStyleEvenAtHighContrast() {
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.providerDisclosureStyle(
        providerID: "sherpa-onnx.local",
        increasedContrast: true
      ),
      .tinted
    )
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.providerDisclosureStyle(
        providerID: "sherpa-onnx.local",
        increasedContrast: false
      ),
      .tinted
    )
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.providerDisclosureStyle(
        providerID: "sherpa-onnx.local",
        increasedContrast: true
      ),
      .tinted
    )
  }
}
