import AppKit
import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class SystemSymbolTests: XCTestCase {
    func testDirectLiteralSystemSymbolArgumentsResolveOnTheRuntimePlatform() throws {
        let occurrences = try directLiteralOccurrences()

        XCTAssertFalse(occurrences.isEmpty)
        for occurrence in occurrences {
            XCTAssertNotNil(
                NSImage(systemSymbolName: occurrence.name, accessibilityDescription: nil),
                "Missing system symbol '\(occurrence.name)' at \(occurrence.file):\(occurrence.line)"
            )
        }
    }

    func testApplicationOwnedComputedSystemSymbolValuesResolveOnTheRuntimePlatform() {
        var symbols = RillSystemSymbol.allCases.map(\.rawValue)
        symbols += VoiceTextStyle.allCases.map(\.systemImage)
        symbols += SidebarSection.allCases.map(\.symbolName)
        symbols += SettingsSection.allCases.map(\.symbolName)
        symbols += menuBarComputedSymbols()

        for symbol in Set(symbols).sorted() {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "Missing application-owned computed system symbol: \(symbol)"
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

    private func directLiteralOccurrences() throws -> [SymbolOccurrence] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        )
        let regex = try NSRegularExpression(
            pattern: #"(?:systemName|systemImage|symbolName|symbol|icon):\s*"([^"\n]+)""#
        )
        var occurrences: [SymbolOccurrence] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }

            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let sourceRange = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: sourceRange) {
                guard let symbolRange = Range(match.range(at: 1), in: source),
                      let matchRange = Range(match.range, in: source) else {
                    XCTFail("Invalid static system symbol match in \(fileURL.path)")
                    continue
                }
                let line = source[..<matchRange.lowerBound].reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                occurrences.append(SymbolOccurrence(
                    name: String(source[symbolRange]),
                    file: fileURL.path,
                    line: line
                ))
            }
        }

        return occurrences
    }

    private func menuBarComputedSymbols() -> [String] {
        let base: (Bool, String?, Int, MenuBarVoiceSetupStatus) -> MenuBarOperationPanelState = {
            isRunning, lastFailure, stackCount, voiceSetupStatus in
            MenuBarOperationPanelState(
                language: .english,
                isRunning: isRunning,
                lastFailure: lastFailure,
                stackCount: stackCount,
                canDeliverTopOfStack: stackCount > 0,
                preferredSpeechEngine: .local,
                outputMode: .pasteIntoApp,
                voiceSetupStatus: voiceSetupStatus
            )
        }
        var symbols = [
            base(false, "failure", 0, .ready).statusSystemImage,
            base(true, nil, 0, .ready).statusSystemImage,
            base(false, nil, 0, .loading).statusSystemImage,
            base(false, nil, 0, .incomplete).statusSystemImage,
            base(false, nil, 1, .ready).statusSystemImage,
            base(false, nil, 0, .ready).statusSystemImage,
        ]

        let captureStates: [ClipboardCaptureControlState] = [
            .active,
            .pausing,
            .paused,
            .resuming,
            .armingIgnoreNextExternalChange,
            .ignoringNextExternalChange,
        ]
        for captureState in captureStates {
            let state = MenuBarOperationPanelState(
                language: .english,
                isRunning: false,
                stackCount: 0,
                canDeliverTopOfStack: false,
                preferredSpeechEngine: .local,
                outputMode: .pasteIntoApp,
                clipboardCaptureState: captureState
            )
            symbols.append(state.clipboardCaptureStatusSystemImage)
            symbols.append(state.clipboardCaptureToggleSystemImage)
        }

        let degraded = MenuBarOperationPanelState(
            language: .english,
            isRunning: false,
            stackCount: 0,
            canDeliverTopOfStack: false,
            preferredSpeechEngine: .local,
            outputMode: .pasteIntoApp,
            localPersistenceStatus: .sessionOnly(reason: .persistentStorageUnavailable)
        )
        if let persistenceSymbol = degraded.persistenceStatusSystemImage {
            symbols.append(persistenceSymbol)
        }
        return symbols
    }
}

private struct SymbolOccurrence {
    let name: String
    let file: String
    let line: Int
}
