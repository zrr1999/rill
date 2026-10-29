import AppKit
import ApplicationServices
import RillTestSupport
import SwiftUI
import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class HistoryTextStepPrivacyRenderTests: NativeAccessibilityTestCase {
  func testTextStepUsesTheSamePrivacyPolicyForRenderedAndAccessibleText() async throws {
    _ = NSApplication.shared
    if !NSApp.isRunning { NSApp.finishLaunching() }
    guard try await requireInteractiveDesktop() else { return }

    let privateBody = String(repeating: "recognized words ", count: 45) + "PRIVATE-TAIL-SENTINEL"
    let step = WorkflowTextStep(
      kind: .llmRewrite,
      outputText: privateBody,
      durationMilliseconds: 300,
      tokenUsage: .init(inputTokens: 1, outputTokens: 2)
    )

    for language in AppLanguage.allCases {
      for mode in PrivacyHistoryPreviewMode.allCases {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
          styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "History text privacy " + UUID().uuidString
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
          rootView: HistoryTextStepsView(steps: [step], previewMode: mode, language: language)
            .padding(20)
        )
        window.makeKeyAndOrderFront(nil)
        await settle(window)
        let accessible = accessibilityText(window)
        switch mode {
        case .disabled:
          XCTAssertFalse(accessible.contains("recognized words"))
          XCTAssertFalse(accessible.contains("PRIVATE-TAIL-SENTINEL"))
        case .restricted:
          XCTAssertFalse(accessible.contains("PRIVATE-TAIL-SENTINEL"))
        case .full:
          XCTAssertTrue(accessible.contains("PRIVATE-TAIL-SENTINEL"))
        }
        window.close()
      }
    }
  }
}
