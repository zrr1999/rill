import SwiftUI
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class MenuBarOperationPanelStateTests: XCTestCase {
  func testStatusDetailUsesStableWidthForShortAndLongContent() {
    let shortText = NSHostingView(rootView: MenuBarFixedWidthText(text: "Ready"))
    let longText = NSHostingView(
      rootView: MenuBarFixedWidthText(
        text: String(repeating: "简体中文 and English ", count: 20)
      )
    )
    let longLabel = NSHostingView(
      rootView: MenuBarFixedWidthLabel(
        title: String(repeating: "Long workflow name ", count: 20),
        systemImage: "waveform"
      )
    )

    XCTAssertEqual(
      shortText.fittingSize.width,
      MenuBarLayoutMetrics.contentWidth,
      accuracy: 0.5
    )
    XCTAssertEqual(
      longText.fittingSize.width,
      MenuBarLayoutMetrics.contentWidth,
      accuracy: 0.5
    )
    XCTAssertEqual(
      longLabel.fittingSize.width,
      MenuBarLayoutMetrics.contentWidth,
      accuracy: 0.5
    )
  }

  func testPersistentSymbolPrioritizesActiveVoiceRun() {
    let symbol = MenuBarSystemSymbolPolicy.symbol(
      isVoiceRunActive: true,
      globalInputCapability: .installationFailed,
      systemClipboardCaptureEnabled: false,
      clipboardCaptureState: .paused,
      recordCount: 3
    )

    XCTAssertEqual(symbol.rawValue, RillSystemSymbol.micFill.rawValue)
  }

  func testPersistentSymbolNeverLooksReadyWhenGlobalInputFailed() {
    for capability in [
      GlobalInputCapability.permissionRequired,
      .installationFailed,
    ] {
      let symbol = MenuBarSystemSymbolPolicy.symbol(
        isVoiceRunActive: false,
        globalInputCapability: capability,
        systemClipboardCaptureEnabled: true,
        clipboardCaptureState: .active,
        recordCount: 4
      )

      XCTAssertEqual(
        symbol.rawValue,
        RillSystemSymbol.exclamationmarkCircleFill.rawValue
      )
    }
  }

  func testPersistentSymbolShowsCheckingAsNotReady() {
    let symbol = MenuBarSystemSymbolPolicy.symbol(
      isVoiceRunActive: false,
      globalInputCapability: .checking,
      systemClipboardCaptureEnabled: false,
      clipboardCaptureState: .paused,
      recordCount: 0
    )

    XCTAssertEqual(symbol.rawValue, RillSystemSymbol.questionmarkBubble.rawValue)
  }

  func testPersistentSymbolKeepsFnReadyWhenClipboardCaptureIsOff() {
    let symbol = MenuBarSystemSymbolPolicy.symbol(
      isVoiceRunActive: false,
      globalInputCapability: .available,
      systemClipboardCaptureEnabled: false,
      clipboardCaptureState: .paused,
      recordCount: 0
    )

    XCTAssertEqual(symbol.rawValue, RillSystemSymbol.waveform.rawValue)
    XCTAssertNotEqual(symbol.rawValue, RillSystemSymbol.pauseCircleFill.rawValue)
  }

  func testPersistentSymbolUsesClipboardStateOnlyAfterVoiceIsAvailable() {
    XCTAssertEqual(
      MenuBarSystemSymbolPolicy.symbol(
        isVoiceRunActive: false,
        globalInputCapability: .available,
        systemClipboardCaptureEnabled: true,
        clipboardCaptureState: .active,
        recordCount: 2
      ).rawValue,
      RillSystemSymbol.squareStack3dUpFill.rawValue
    )
    XCTAssertEqual(
      MenuBarSystemSymbolPolicy.symbol(
        isVoiceRunActive: false,
        globalInputCapability: .available,
        systemClipboardCaptureEnabled: true,
        clipboardCaptureState: .ignoringNextExternalChange,
        recordCount: 2
      ).rawValue,
      RillSystemSymbol.eyeSlashFill.rawValue
    )
  }

  func testGlobalInputCheckingKeepsMenuSetupStatusLoading() {
    let readiness = VoiceSetupReadiness(
      globalInput: .checking,
      microphone: .granted,
      accessibility: .granted,
      accessibilityRequired: true,
      preferredSpeechEngine: .local,
      provider: .localReady,
      privacy: .available(cloudConfirmationRequired: false)
    )

    XCTAssertEqual(MenuBarVoiceSetupStatus(readiness: readiness), .loading)
  }

  func testIncompleteVoiceSetupIsActionableInsteadOfShowingAReadyCheckmark() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 4,
      canDeliverNextRecord: true,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      voiceSetupStatus: .incomplete
    )

    XCTAssertEqual(state.statusTitle, "Finish Voice Setup")
    XCTAssertEqual(state.statusSystemImage, "exclamationmark.circle.fill")
    XCTAssertEqual(
      state.statusDetail,
      "Open Rill to complete the required permission and speech setup steps."
    )
  }

  func testLoadingVoiceSetupDoesNotClaimIdleOrReady() {
    let state = MenuBarOperationPanelState(
      language: .simplifiedChinese,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .saveToVoiceGroup,
      voiceSetupStatus: .loading
    )

    XCTAssertEqual(state.statusTitle, "正在加载语音设置")
    XCTAssertEqual(state.statusSystemImage, "hourglass.circle")
    XCTAssertEqual(state.statusDetail, "正在检查已保存设置、凭据和隐私保护。")
  }

  func testCopyLastResultRemainsAvailableWithoutExposingItInStatusDetail() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      lastCompletedText: "  hello menu  \n",
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp
    )

    XCTAssertTrue(state.canCopyLastResult)
    XCTAssertEqual(state.trimmedLastResult, "hello menu")
    XCTAssertNil(state.statusDetail)
  }

  func testFailureStatusTakesPriorityOverRunningAndStackState() {
    let state = MenuBarOperationPanelState(
      language: .simplifiedChinese,
      isRunning: true,
      lastCompletedText: "old result",
      lastFailure: "Microphone access is unavailable.",
      recordCount: 3,
      canDeliverNextRecord: true,
      preferredSpeechEngine: .local,
      outputMode: .saveToVoiceGroup
    )

    XCTAssertEqual(state.statusTitle, "需要处理")
    XCTAssertEqual(state.statusSystemImage, "exclamationmark.triangle.fill")
    XCTAssertEqual(state.statusDetail, "Microphone access is unavailable.")
    XCTAssertEqual(state.outputModeTitle, "保存到语音剪贴板组")
  }

  func testStackStatusUsesLocalizedItemCountWhenIdle() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 2,
      canDeliverNextRecord: true,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp
    )

    XCTAssertEqual(state.statusTitle, "Rill Idle")
    XCTAssertEqual(state.statusSystemImage, "square.stack.3d.up.fill")
    XCTAssertEqual(state.statusDetail, "Ready to paste: 2 items")
  }

  func testLongRecordingModeTitleReflectsToggleState() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      longRecordingModeEnabled: true
    )

    XCTAssertEqual(state.longRecordingModeTitle, "Press Once to Start/Stop")
  }

  func testRunningStatusExplainsCurrentActivity() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: true,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .saveToVoiceGroup
    )

    XCTAssertEqual(state.statusTitle, "Voice run active")
    XCTAssertEqual(state.statusSystemImage, "waveform.circle.fill")
    XCTAssertEqual(state.statusDetail, "Recording, transcribing, or delivering text.")
  }

  func testDisabledClipboardCapturePreferenceUsesOffLanguageAndDisablesIgnoreNext() {
    let state = MenuBarOperationPanelState(
      language: .simplifiedChinese,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      systemClipboardCaptureEnabled: false,
      clipboardCaptureState: .paused
    )

    XCTAssertEqual(state.clipboardCaptureStatusTitle, "剪贴板捕获已关闭")
    XCTAssertEqual(state.clipboardCaptureToggleTitle, "开启剪贴板捕获")
    XCTAssertEqual(state.clipboardCaptureStatusSystemImage, "power.circle.fill")
    XCTAssertFalse(state.canIgnoreNextExternalCopy)
  }

  func testIgnoreNextClipboardStateIsVisibleUntilConsumed() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      clipboardCaptureState: .ignoringNextExternalChange
    )

    XCTAssertEqual(state.clipboardCaptureStatusTitle, "Next external copy will be ignored")
    XCTAssertEqual(state.clipboardCaptureToggleTitle, "Turn Off Clipboard Capture")
    XCTAssertEqual(state.clipboardCaptureStatusSystemImage, "eye.slash.fill")
    XCTAssertFalse(state.canIgnoreNextExternalCopy)
  }

  func testClipboardCaptureTransitionShowsRequestedOnStateAndAllowsLatestPreference() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      clipboardCaptureState: .pausing
    )

    XCTAssertEqual(state.clipboardCaptureStatusTitle, "Turning on clipboard capture…")
    XCTAssertTrue(state.canToggleClipboardCapture)
    XCTAssertFalse(state.canIgnoreNextExternalCopy)
  }

  func testUnavailableClipboardSettingsLockMenuToggle() {
    let state = MenuBarOperationPanelState(
      language: .english,
      isRunning: false,
      recordCount: 0,
      canDeliverNextRecord: false,
      preferredSpeechEngine: .local,
      outputMode: .pasteIntoApp,
      systemClipboardCaptureEnabled: false,
      clipboardSettingsAvailable: false,
      clipboardCaptureState: .paused
    )

    XCTAssertEqual(state.clipboardCaptureStatusTitle, "Clipboard capture off")
    XCTAssertFalse(state.canToggleClipboardCapture)
    XCTAssertFalse(state.canIgnoreNextExternalCopy)
  }
}
