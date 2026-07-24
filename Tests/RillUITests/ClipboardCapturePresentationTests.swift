import XCTest
@testable import RillUI

final class ClipboardCapturePresentationTests: XCTestCase {
    func testDisabledBannerExplainsHistoryRemainsAvailable() {
        XCTAssertEqual(
            ClipboardCaptureDisabledPresentation.make(language: .english),
            ClipboardCaptureDisabledPresentation(
                title: "Automatic clipboard capture is off",
                detail: "Existing history remains available in the main window. New external copies are not " +
                    "captured, and the global panel shortcut is off.",
                actionTitle: "Turn On Capture"
            )
        )
        XCTAssertEqual(
            ClipboardCaptureDisabledPresentation.make(language: .simplifiedChinese),
            ClipboardCaptureDisabledPresentation(
                title: "剪贴板自动捕获已关闭",
                detail: "现有历史仍可从主窗口访问；新的外部复制内容不会被捕获，全局面板快捷键也已停用。",
                actionTitle: "开启捕获"
            )
        )
    }

    func testClipboardPanelShortcutSurfacesFollowCaptureState() {
        XCTAssertEqual(
            ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
                clipboardCaptureEnabled: true
            ),
            ClipboardPanelShortcutSurfaceVisibility(
                dashboardCard: true,
                settingsRecorder: true,
                menuShortcutAnnotation: true
            )
        )
        XCTAssertEqual(
            ClipboardPanelShortcutPresentationPolicy.surfaceVisibility(
                clipboardCaptureEnabled: false
            ),
            ClipboardPanelShortcutSurfaceVisibility(
                dashboardCard: false,
                settingsRecorder: false,
                menuShortcutAnnotation: false
            )
        )
    }

    func testGlobalInputReadyCopyKeepsVoiceShortcutWhenClipboardShortcutIsHidden() {
        let voiceOnlyDetail = ClipboardPanelShortcutPresentationPolicy.globalInputReadyDetail(
            clipboardCaptureEnabled: false
        )
        XCTAssertEqual(
            UIStrings.text(voiceOnlyDetail, language: .english),
            "Ready for Fn push-to-talk."
        )
        XCTAssertEqual(
            UIStrings.text(voiceOnlyDetail, language: .simplifiedChinese),
            "已可使用 Fn 按住说话。"
        )

        let combinedDetail = ClipboardPanelShortcutPresentationPolicy.globalInputReadyDetail(
            clipboardCaptureEnabled: true
        )
        XCTAssertEqual(
            UIStrings.text(combinedDetail, language: .english),
            "Ready for Fn push-to-talk and global clipboard shortcuts."
        )
    }

    func testClipboardSettingsUseCanonicalChineseTerminology() {
        let copy = [
            UIStrings.text(.settingsClipboardPanel, language: .simplifiedChinese),
            UIStrings.text(.settingsClipboardPanelDescription, language: .simplifiedChinese),
            UIStrings.text(.settingsClipboardCaptureEnabled, language: .simplifiedChinese),
        ].joined(separator: " ")

        XCTAssertTrue(copy.contains("剪贴板"))
        XCTAssertFalse(copy.contains("剪切板"))
    }
}
