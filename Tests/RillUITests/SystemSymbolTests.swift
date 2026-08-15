import AppKit
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class SystemSymbolTests: XCTestCase {
    func testApplicationOwnedSystemSymbolCatalogResolvesOnTheRuntimePlatform() {
        for symbol in RillSystemSymbol.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil),
                "Missing application-owned system symbol: \(symbol.rawValue)"
            )
        }
    }

    func testRillOwnedWorkflowSymbolsArePartOfTheValidatedCatalog() {
        for symbol in WorkflowUISymbol.allCases {
            XCTAssertNotNil(
                RillSystemSymbol(rawValue: symbol.rawValue),
                "Workflow symbol is outside the validated UI catalog: \(symbol.rawValue)"
            )
        }
    }

    func testDataDrivenSystemSymbolsFailClosedToAValidatedFallback() {
        XCTAssertEqual(
            RillSystemSymbol.resolvedName("not.a.real.rill.system.symbol"),
            RillSystemSymbol.waveform.rawValue
        )
        XCTAssertEqual(
            RillSystemSymbol.resolvedName(RillSystemSymbol.micFill.rawValue),
            RillSystemSymbol.micFill.rawValue
        )
        XCTAssertEqual(
            RillSystemSymbol.resolvedName(
                "not.a.real.rill.system.symbol",
                fallback: .docOnClipboard
            ),
            RillSystemSymbol.docOnClipboard.rawValue
        )
    }

}
