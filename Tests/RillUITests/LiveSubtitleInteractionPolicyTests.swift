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

  func testProviderDisclosureDistinguishesCloudAndOnDeviceCapture() {
    XCTAssertEqual(
      LiveSubtitleInteractionPolicy.providerDisclosureTitle(
        providerID: "deepgram.live",
        language: .english
      ),
      "Cloud · Deepgram"
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

  func testCloudDisclosureUsesSemanticHighContrastStyleOnlyWhenRequested() {
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.providerDisclosureStyle(
        providerID: "deepgram.live",
        increasedContrast: true
      ),
      .highContrast
    )
    XCTAssertEqual(
      LiveSubtitlePresentationPolicy.providerDisclosureStyle(
        providerID: "deepgram.live",
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
