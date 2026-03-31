import XCTest
@testable import VoxTypePlatform

final class TextInjectionEngineTests: XCTestCase {
    func testInjectFailsWhenAccessibilityPermissionIsMissing() async {
        let pasteboard = await MainActor.run { PasteboardController() }
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { false }
        )

        do {
            try await engine.inject("hello")
            XCTFail("Expected injection to fail without Accessibility permission.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .accessibilityPermissionRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKeyboardChunkingSplitsLongTextIntoSupportedEventSizes() {
        let text = String(repeating: "a", count: 45)
        let chunks = TextInjectionEngine.utf16Chunks(for: text)

        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(chunks.flatMap { $0 }.count, text.utf16.count)
    }
}
