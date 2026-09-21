import AppKit
import SwiftUI
import XCTest
@testable import RillUI

/// Opt-in rendered evidence with ephemeral test services, never the user's settings.
@MainActor
final class UIRenderEvidenceTests: XCTestCase {
    func testRenderManagementSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set RILL_UI_SNAPSHOT_DIR to export native render evidence.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                for width in [960, 1280] {
                    for section in [SidebarSection.stream, .workflows, .settings, .records, .diagnostics] {
                        let harness = makeHarness()
                        let model = harness.model
                        model.setInterfaceLanguage(language)
                        model.selectSidebarSection(section)
                        let size = NSSize(width: width, height: width == 960 ? 720 : 800)
                        let view = NSHostingView(rootView: MainShellView(model: model)
                            .environment(\.colorScheme, dark ? .dark : .light)
                            .background(dark ? Color(nsColor: .darkGray) : .white))
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        window.isReleasedWhenClosed = false
                        window.contentView = view
                        view.frame = NSRect(origin: .zero, size: size)
                        window.layoutIfNeeded()
                        for _ in 0..<5 { await Task.yield() }
                        view.layoutSubtreeIfNeeded()
                        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: representation)
                        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                        let name = "\(section.rawValue)-\(language.rawValue)-\(dark ? "dark" : "light")-\(width).png"
                        try png.write(to: output.appendingPathComponent(name))
                        window.orderOut(nil)
                        window.close()
                    }
                }
            }
        }
    }
}
