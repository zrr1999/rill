import AppKit
import SwiftUI
import XCTest

@testable import RillUI

func containsHan(_ text: String) -> Bool {
  text.unicodeScalars.contains { scalar in
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
      true
    default:
      false
    }
  }
}

final class LocalizationSurfaceTests: XCTestCase {
  func testEnglishSurfaceTablesContainNoHan() {
    for key in SurfaceText.allCases {
      assertEnglishHasNoHan(L10n.surface(key, language: .english))
    }
    for key in JevText.allCases {
      assertEnglishHasNoHan(L10n.jev(key, language: .english))
    }
    for key in InputMethodText.allCases {
      assertEnglishHasNoHan(L10n.inputMethod(key, language: .english))
    }
    assertEnglishHasNoHan(L10n.cloudPrivacyTitle(language: .english))
    assertEnglishHasNoHan(L10n.cloudPrivacyAllowAndRemember(language: .english))
    assertEnglishHasNoHan(L10n.cloudPrivacyAllowOnce(language: .english))
    assertEnglishHasNoHan(L10n.cloudPrivacyCancel(language: .english))
    assertEnglishHasNoHan(L10n.cloudPrivacyAuthorization(language: .english))
    assertEnglishHasNoHan(
      L10n.cloudPrivacyProcessing(
        workflowName: "Speech", sendsSpeech: true, sendsText: false, language: .english))
    assertEnglishHasNoHan(L10n.inputMethodSuggestionDetail(count: 2, applications: "Notes", language: .english))
  }

  func testSurfaceTableCoversEveryKeyWithoutLiteralEscapes() {
    for key in SurfaceText.allCases {
      XCTAssertNotEqual(L10n.surface(key, language: .simplifiedChinese), String(describing: key))
      for language in AppLanguage.allCases {
        XCTAssertFalse(L10n.surface(key, language: language).contains("\\"), "\(key)")
      }
    }
  }

  private func assertEnglishHasNoHan(_ english: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(containsHan(english), english, file: file, line: line)
  }
}

@MainActor
final class EnglishSurfaceAccessibilityTests: XCTestCase {
  func testEnglishSettingsExposeNoHan() async {
    let model = makeHarness().model
    model.applyLanguage(.english)
    model.presentSettings()
    model.selectedSettingsPane = .input
    let settings = hosted(MainShellView(model: model), size: NSSize(width: 960, height: 720))
    defer { settings.close() }
    await settle(settings)
    let settingsLabels = accessibilityStrings(in: settings.contentView)
    XCTAssertFalse(settingsLabels.isEmpty)
    assertNoHan(settingsLabels)
  }

  private func hosted<V: View>(_ view: V, size: NSSize) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.makeKeyAndOrderFront(nil)
    return window
  }

  private func settle(_ window: NSWindow) async {
    for _ in 0..<4 {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(30))
      window.contentView?.layoutSubtreeIfNeeded()
    }
  }

  private func accessibilityStrings(in root: NSView?) -> [String] {
    var strings: [String] = []
    func visit(_ view: NSView) {
      if let label = view.accessibilityLabel(), !label.isEmpty { strings.append(label) }
      if let value = view.accessibilityValue() as? String, !value.isEmpty { strings.append(value) }
      if let field = view as? NSTextField, !field.stringValue.isEmpty { strings.append(field.stringValue) }
      if let button = view as? NSButton, !button.title.isEmpty { strings.append(button.title) }
      for subview in view.subviews { visit(subview) }
    }
    if let root { visit(root) }
    return strings
  }

  private func assertNoHan(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
    for string in strings {
      XCTAssertFalse(containsHan(string), string, file: file, line: line)
    }
  }
}
