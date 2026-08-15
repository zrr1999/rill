import AppKit
import XCTest
@testable import RillCore
@testable import RillPlatform

final class TextInjectionEngineTests: XCTestCase {
    func testInjectFailsWhenAccessibilityPermissionIsMissing() async {
        let pasteboard = await MainActor.run { SystemClipboardPort() }
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

    func testTemporaryPreservationBudgetFailureUsesFixedErrorAndKeepsClipboard() async {
        let fixture = await MainActor.run {
            let name = "dev.rill.tests.\(UUID().uuidString)"
            let systemPasteboard = NSPasteboard(name: .init(name))
            let item = NSPasteboardItem()
            item.setData(
                Data([0x01, 0x02]),
                forType: .init("com.example.over-budget")
            )
            systemPasteboard.clearContents()
            XCTAssertTrue(systemPasteboard.writeObjects([item]))
            var limits = SystemClipboardPort.TemporaryPreservationLimits.productDefault
            limits.maximumRepresentationByteCount = 1
            return LosslessPasteboardFixture(
                controller: SystemClipboardPort(
                    pasteboard: systemPasteboard,
                    temporaryPreservationLimits: limits
                ),
                name: name,
                originalContents: Self.rawContents(of: systemPasteboard)
            )
        }
        let engine = TextInjectionEngine(
            pasteboard: fixture.controller,
            accessibilityChecker: { true },
            pasteCommandSender: {
                XCTFail("Paste must not be attempted after preservation rejection.")
                return true
            }
        )

        do {
            try await engine.inject("must not win")
            XCTFail("Expected the preservation budget to reject temporary injection.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .clipboardContentsCannotBePreserved)
            XCTAssertEqual(
                error.localizedDescription,
                "The current clipboard cannot be preserved losslessly for temporary text injection."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let unchanged = await rawContents(ofPasteboardNamed: fixture.name)
        XCTAssertEqual(unchanged, fixture.originalContents)
    }

    func testKeyboardChunkingSplitsLongTextIntoSupportedEventSizes() {
        let text = String(repeating: "a", count: 45)
        let chunks = TextInjectionEngine.utf16Chunks(for: text)

        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(chunks.flatMap { $0 }.count, text.utf16.count)
    }

    func testProtectedClipboardKeyboardFallbackRestoresAndVerifiesTarget() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writeSnapshot(
            SystemClipboardSnapshot(
                plainText: "protected clipboard",
                changeCount: 0,
                protections: [.concealed]
            )
        )
        let target = makeFocus(bundleIdentifier: "com.example.target", processIdentifier: 42)
        let focus = TextInjectionFocusProbe(
            currentIdentity: .init(
                bundleIdentifier: "com.example.other",
                processIdentifier: 7
            ),
            activationResult: true,
            updateIdentityOnActivation: true
        )
        let keyboard = TextInjectionKeyboardProbe()
        let diagnostics = TextInjectionDiagnosticProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                await diagnostics.record(event)
            },
            focusController: makeFocusController(focus),
            keyboardChunkSender: { chunk in
                _ = await keyboard.send(chunk)
                return true
            }
        )

        try await engine.inject("protected fallback", targetFocus: target)

        let focusState = await focus.snapshot()
        let sentChunks = await keyboard.snapshot()
        let preserved = await pasteboard.currentSnapshot()
        let events = await diagnostics.snapshot()
        XCTAssertEqual(focusState.activationRequestCount, 1)
        XCTAssertEqual(sentChunks.count, 1)
        XCTAssertEqual(preserved.plainText, "protected clipboard")
        XCTAssertEqual(preserved.protections, [.concealed])
        XCTAssertTrue(events.contains { $0.event == "clipboard.inject.keyboard-fallback" })
        XCTAssertFalse(events.contains { event in
            event.metadata.keys.contains("bundleID")
                || event.metadata.keys.contains("frontmostBundleIdentifier")
                || event.metadata.keys.contains("targetBundleIdentifier")
                || event.metadata.values.contains("com.example.target")
        })
    }

    func testExplicitKeyboardInjectionFailsClosedWhenTargetActivationFails() async throws {
        let pasteboard = await makePasteboard()
        let target = makeFocus(bundleIdentifier: "com.example.target", processIdentifier: 42)
        let focus = TextInjectionFocusProbe(
            currentIdentity: .init(
                bundleIdentifier: "com.example.other",
                processIdentifier: 7
            ),
            activationResult: false
        )
        let keyboard = TextInjectionKeyboardProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: makeFocusController(focus),
            keyboardChunkSender: { chunk in
                _ = await keyboard.send(chunk)
                return true
            }
        )

        do {
            try await engine.inject("must not be sent", method: .keyboard, targetFocus: target)
            XCTFail("Expected target activation failure to block keyboard injection.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .targetFocusActivationFailed)
        }

        let sentChunks = await keyboard.snapshot()
        XCTAssertTrue(sentChunks.isEmpty)
    }

    func testExplicitKeyboardInjectionStopsWhenFocusDriftsBetweenChunks() async throws {
        let pasteboard = await makePasteboard()
        let targetIdentity = TextInjectionEngine.FocusIdentity(
            bundleIdentifier: "com.example.target",
            processIdentifier: 42
        )
        let focus = TextInjectionFocusProbe(currentIdentity: targetIdentity)
        let keyboard = TextInjectionKeyboardProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: makeFocusController(focus),
            keyboardChunkSender: { chunk in
                let sentCount = await keyboard.send(chunk)
                if sentCount == 1 {
                    await focus.setCurrentIdentity(
                        .init(
                            bundleIdentifier: "com.example.other",
                            processIdentifier: 7
                        )
                    )
                }
                return true
            }
        )

        do {
            try await engine.inject(
                String(repeating: "a", count: 45),
                method: .keyboard,
                targetFocus: makeFocus(targetIdentity)
            )
            XCTFail("Expected focus drift to stop the remaining keyboard chunks.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .targetFocusChanged)
        }

        let sentChunks = await keyboard.snapshot()
        XCTAssertEqual(sentChunks.map(\.count), [20])
    }

    func testClipboardPasteReverifiesTargetAndRestoresClipboardOnFocusDrift() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let targetIdentity = TextInjectionEngine.FocusIdentity(
            bundleIdentifier: "com.example.target",
            processIdentifier: 42
        )
        let focus = TextInjectionFocusProbe(
            currentIdentity: targetIdentity,
            queuedCurrentIdentities: [
                targetIdentity,
                .init(bundleIdentifier: "com.example.other", processIdentifier: 7),
            ]
        )
        let paste = TextInjectionPasteProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: makeFocusController(focus),
            pasteCommandSender: {
                await paste.send()
            }
        )

        do {
            try await engine.inject(
                "temporary injection",
                targetFocus: makeFocus(targetIdentity)
            )
            XCTFail("Expected the final target check to block paste delivery.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .targetFocusChanged)
        }

        let pasteSendCount = await paste.snapshot()
        let restoredClipboard = await pasteboard.currentSnapshot()
        XCTAssertEqual(pasteSendCount, 0)
        XCTAssertEqual(restoredClipboard.plainText, "original clipboard")
    }

    func testKeyboardInjectionWithoutTargetUsesCurrentApplicationWithoutFocusChecks() async throws {
        let pasteboard = await makePasteboard()
        let focus = TextInjectionFocusProbe(
            currentIdentity: nil,
            activationResult: false
        )
        let keyboard = TextInjectionKeyboardProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: makeFocusController(focus),
            keyboardChunkSender: { chunk in
                _ = await keyboard.send(chunk)
                return true
            }
        )

        try await engine.inject(
            String(repeating: "a", count: 45),
            method: .keyboard,
            targetFocus: nil
        )

        let focusState = await focus.snapshot()
        XCTAssertEqual(focusState.currentIdentityRequestCount, 0)
        XCTAssertEqual(focusState.activationRequestCount, 0)
        let sentChunks = await keyboard.snapshot()
        XCTAssertEqual(sentChunks.map(\.count), [20, 20, 5])
    }

    func testNonIdentifiableTargetFailsClosedBeforeKeyboardInjection() async throws {
        let pasteboard = await makePasteboard()
        let focus = TextInjectionFocusProbe(currentIdentity: nil)
        let keyboard = TextInjectionKeyboardProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            focusController: makeFocusController(focus),
            keyboardChunkSender: { chunk in
                _ = await keyboard.send(chunk)
                return true
            }
        )
        let target = makeFocus(bundleIdentifier: nil, processIdentifier: nil)

        do {
            try await engine.inject("must not be sent", method: .keyboard, targetFocus: target)
            XCTFail("Expected a target without identity to fail closed.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .targetFocusCannotBeVerified)
        }

        let focusState = await focus.snapshot()
        XCTAssertEqual(focusState.currentIdentityRequestCount, 0)
        let sentChunks = await keyboard.snapshot()
        XCTAssertTrue(sentChunks.isEmpty)
    }

    func testClipboardChangeInPrewriteWindowFailsClosedWithoutOverwriteOrRestore() async {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("authorized baseline")
        let paste = TextInjectionPasteProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                guard event.event == "clipboard.inject.text.prepare" else { return }
                _ = await pasteboard.writePlainText("external winner")
            },
            pasteCommandSender: {
                await paste.send()
            }
        )

        do {
            try await engine.inject("must not overwrite")
            XCTFail("Expected the conditional temporary write to reject stale authorization.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .clipboardChangedBeforeTemporaryWrite)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let current = await pasteboard.currentSnapshot()
        let pasteSendCount = await paste.snapshot()
        XCTAssertEqual(current.plainText, "external winner")
        XCTAssertEqual(pasteSendCount, 0)
    }

    func testProtectedClipboardChangeInPrewriteWindowFallsBackWithoutOverwrite() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("authorized baseline")
        let paste = TextInjectionPasteProbe()
        let keyboard = TextInjectionKeyboardProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                guard event.event == "clipboard.inject.text.prepare" else { return }
                _ = await pasteboard.writeSnapshot(
                    SystemClipboardSnapshot(
                        plainText: "protected winner",
                        changeCount: 0,
                        protections: [.concealed]
                    )
                )
            },
            pasteCommandSender: {
                await paste.send()
            },
            keyboardChunkSender: { chunk in
                _ = await keyboard.send(chunk)
                return true
            }
        )

        try await engine.inject("keyboard fallback")

        let current = await pasteboard.currentSnapshot()
        let pasteSendCount = await paste.snapshot()
        let keyboardChunks = await keyboard.snapshot()
        XCTAssertEqual(current.plainText, "protected winner")
        XCTAssertEqual(current.protections, [.concealed])
        XCTAssertEqual(pasteSendCount, 0)
        XCTAssertEqual(keyboardChunks.count, 1)
    }

    func testRichClipboardChangeInPrewriteWindowFailsClosedWithoutOverwrite() async {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("authorized baseline")
        let paste = TextInjectionPasteProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                guard event.event == "clipboard.inject.snapshot.prepare" else { return }
                _ = await pasteboard.writePlainText("external rich winner")
            },
            pasteCommandSender: {
                await paste.send()
            }
        )

        do {
            try await engine.injectClipboardSnapshot(
                SystemClipboardSnapshot(
                    plainText: "",
                    imagePNGData: Data([0x89, 0x50, 0x4E, 0x47]),
                    changeCount: 0
                )
            )
            XCTFail("Expected the conditional rich write to reject stale authorization.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .clipboardChangedBeforeTemporaryWrite)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let current = await pasteboard.currentSnapshot()
        let pasteSendCount = await paste.snapshot()
        XCTAssertEqual(current.plainText, "external rich winner")
        XCTAssertEqual(pasteSendCount, 0)
    }

    func testFailedPlainTextPasteRestoresOriginalClipboard() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: { false }
        )

        do {
            try await engine.inject("temporary injection")
            XCTFail("Expected the simulated paste failure.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .unableToCreatePasteEvent)
        }

        let restored = await pasteboard.currentSnapshot()
        XCTAssertEqual(restored.plainText, "original clipboard")
    }

    func testSuccessfulPlainTextPasteRestoresOriginalClipboard() async throws {
        let fixture = await makeLosslessPasteboard()
        let pasteboard = fixture.controller
        let diagnostics = TextInjectionDiagnosticProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                await diagnostics.record(event)
            },
            pasteCommandSender: { true }
        )

        try await engine.inject("temporary injection")

        let restored = await rawContents(ofPasteboardNamed: fixture.name)
        let events = await diagnostics.snapshot()
        let restoreEvent = try XCTUnwrap(events.first { event in
            event.event == "clipboard.inject.restore"
        })
        XCTAssertEqual(restored, fixture.originalContents)
        XCTAssertEqual(restoreEvent.level, .debug)
        XCTAssertEqual(
            restoreEvent.metadata,
            [
                "outcome": "restored",
                "reason": "paste-finished",
            ]
        )
    }

    func testSuccessfulDeliveryWithRestoreWriteFailureReturnsNonRetryableFixedError() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let diagnostics = TextInjectionDiagnosticProbe()
        let paste = TextInjectionPasteProbe()
        let payloadCanary = "delivered-payload-canary"
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                await diagnostics.record(event)
            },
            pasteCommandSender: {
                await paste.send()
            },
            temporaryClipboardRestorer: { _, expectedChangeCount in
                .writeFailed(retryChangeCount: expectedChangeCount + 1)
            }
        )

        do {
            try await engine.inject(payloadCanary)
            XCTFail("A failed exact restore after delivery must not report success.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .deliveredButClipboardRestorationFailed)
            XCTAssertEqual(
                error.localizedDescription,
                CommittedOutputFailure
                    .clipboardRestorationFailedAfterInjection
                    .message
            )
            XCTAssertFalse(error.localizedDescription.contains(payloadCanary))
            XCTAssertEqual(
                HistoryFailureSanitizer.sanitize(error.localizedDescription),
                error.localizedDescription,
                "Run history must not turn a committed injection into a retry prompt."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pasteSendCount = await paste.snapshot()
        let current = await pasteboard.currentSnapshot()
        let events = await diagnostics.snapshot()
        let restoreEvent = try XCTUnwrap(events.first { event in
            event.event == "clipboard.inject.restore"
        })
        let sanitizedRestoreEvent = DiagnosticEventSanitizer.sanitize(restoreEvent)
        XCTAssertEqual(pasteSendCount, 1, "The error describes an already-completed delivery.")
        XCTAssertEqual(current.plainText, payloadCanary)
        XCTAssertEqual(restoreEvent.level, .error)
        XCTAssertEqual(
            restoreEvent.metadata,
            [
                "deliveryCompleted": "true",
                "outcome": "write-failed",
                "reason": "paste-finished",
                "retrySafe": "false",
            ]
        )
        XCTAssertEqual(sanitizedRestoreEvent.metadata, restoreEvent.metadata)
        XCTAssertFalse(events.contains { event in
            event.message.contains(payloadCanary)
                || event.metadata.values.contains(payloadCanary)
        })

        do {
            try await engine.inject("new delivery must remain blocked")
            XCTFail("Pending clipboard recovery must settle before another delivery starts.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .temporaryClipboardTransactionInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let pasteCountAfterBlockedRecovery = await paste.snapshot()
        XCTAssertEqual(pasteCountAfterBlockedRecovery, 1)
    }

    func testRestoreWriteFailureRetriesWithoutRepeatingDeliveredPaste() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let paste = TextInjectionPasteProbe()
        let restore = TextInjectionRestoreProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: { await paste.send() },
            temporaryClipboardRestorer: { transaction, expectedChangeCount in
                let attempt = await restore.begin(expectedChangeCount: expectedChangeCount)
                if attempt == 1 {
                    let retryChangeCount = await pasteboard.writePlainText("partial restore")
                    await restore.recordRetryChangeCount(retryChangeCount)
                    return .writeFailed(retryChangeCount: retryChangeCount)
                }
                return await pasteboard.restore(
                    transaction,
                    ifChangeCountIs: expectedChangeCount
                )
            }
        )

        try await engine.inject("delivered once")

        let current = await pasteboard.currentSnapshot()
        let pasteSendCount = await paste.snapshot()
        let restoreSnapshot = await restore.snapshot()
        XCTAssertEqual(current.plainText, "original clipboard")
        XCTAssertEqual(pasteSendCount, 1)
        XCTAssertEqual(restoreSnapshot.expectedChangeCounts.count, 2)
        XCTAssertEqual(
            restoreSnapshot.expectedChangeCounts.last,
            restoreSnapshot.retryChangeCount
        )
    }

    func testRestoreRetryNeverOverwritesExternalClipboardWinner() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let paste = TextInjectionPasteProbe()
        let restore = TextInjectionRestoreProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: { await paste.send() },
            temporaryClipboardRestorer: { transaction, expectedChangeCount in
                let attempt = await restore.begin(expectedChangeCount: expectedChangeCount)
                if attempt == 1 {
                    let retryChangeCount = await pasteboard.writePlainText("partial restore")
                    await restore.recordRetryChangeCount(retryChangeCount)
                    return .writeFailed(retryChangeCount: retryChangeCount)
                }
                _ = await pasteboard.writePlainText("external winner")
                return await pasteboard.restore(
                    transaction,
                    ifChangeCountIs: expectedChangeCount
                )
            }
        )

        try await engine.inject("delivered once")

        let current = await pasteboard.currentSnapshot()
        let pasteSendCount = await paste.snapshot()
        let restoreSnapshot = await restore.snapshot()
        XCTAssertEqual(current.plainText, "external winner")
        XCTAssertEqual(pasteSendCount, 1)
        XCTAssertEqual(restoreSnapshot.expectedChangeCounts.count, 2)
    }

    func testApplicationShutdownDrainsPendingArchiveWithoutRepeatingDelivery() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let paste = TextInjectionPasteProbe()
        let restoreFailures = TextInjectionRestoreFailureBudget(count: 3)
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: { await paste.send() },
            temporaryClipboardRestorer: { transaction, expectedChangeCount in
                if await restoreFailures.consumeFailure() {
                    let retryChangeCount = await pasteboard.writePlainText("partial restore")
                    return .writeFailed(retryChangeCount: retryChangeCount)
                }
                return await pasteboard.restore(
                    transaction,
                    ifChangeCountIs: expectedChangeCount
                )
            }
        )

        do {
            try await engine.inject("delivered once")
            XCTFail("The initial bounded retries should leave recovery pending.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .deliveredButClipboardRestorationFailed)
        }

        await engine.drainPendingClipboardRecoveryForApplicationShutdown()

        let current = await pasteboard.currentSnapshot()
        var pasteSendCount = await paste.snapshot()
        XCTAssertEqual(current.plainText, "original clipboard")
        XCTAssertEqual(pasteSendCount, 1)

        do {
            try await engine.inject("must not start after shutdown")
            XCTFail("Shutdown must seal new clipboard deliveries.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .temporaryClipboardTransactionInProgress)
        }
        pasteSendCount = await paste.snapshot()
        XCTAssertEqual(pasteSendCount, 1)
    }

    func testSuccessfulDeliveryPreservesExternalClipboardWinner() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let diagnostics = TextInjectionDiagnosticProbe()
        let paste = TextInjectionPasteProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                await diagnostics.record(event)
            },
            pasteCommandSender: {
                _ = await paste.send()
                _ = await pasteboard.writePlainText("external winner")
                return true
            }
        )

        try await engine.inject("temporary injection")

        let pasteSendCount = await paste.snapshot()
        let current = await pasteboard.currentSnapshot()
        let events = await diagnostics.snapshot()
        let restoreEvent = try XCTUnwrap(events.first { event in
            event.event == "clipboard.inject.restore"
        })
        XCTAssertEqual(pasteSendCount, 1)
        XCTAssertEqual(current.plainText, "external winner")
        XCTAssertEqual(restoreEvent.level, .debug)
        XCTAssertEqual(
            restoreEvent.metadata,
            [
                "outcome": "skipped-change-count",
                "reason": "paste-finished",
            ]
        )
    }

    func testFailedRichSnapshotPasteRestoresAllOriginalRepresentations() async throws {
        let fixture = await makeLosslessPasteboard()
        let pasteboard = fixture.controller
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: { false }
        )

        do {
            try await engine.injectClipboardSnapshot(
                SystemClipboardSnapshot(
                    plainText: "temporary rich injection",
                    imagePNGData: Data([0x01, 0x02]),
                    changeCount: 0
                )
            )
            XCTFail("Expected the simulated paste failure.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .unableToCreatePasteEvent)
        }

        let restored = await rawContents(ofPasteboardNamed: fixture.name)
        XCTAssertEqual(restored, fixture.originalContents)
    }

    func testExternalClipboardChangeDuringFailureIsNeverOverwritten() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let diagnostics = TextInjectionDiagnosticProbe()
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            diagnosticReporter: { event in
                await diagnostics.record(event)
            },
            pasteCommandSender: {
                _ = await pasteboard.writePlainText("user copied while paste was pending")
                return false
            }
        )

        do {
            try await engine.inject("temporary injection")
            XCTFail("Expected the simulated paste failure.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .unableToCreatePasteEvent)
        }

        let current = await pasteboard.currentSnapshot()
        let events = await diagnostics.snapshot()
        XCTAssertEqual(current.plainText, "user copied while paste was pending")
        XCTAssertTrue(events.contains { event in
            event.event == "clipboard.inject.restore"
                && event.metadata["outcome"] == "skipped-change-count"
                && event.metadata["reason"] == "paste-failed"
        })
        XCTAssertFalse(events.contains { event in
            event.message.contains("temporary injection")
                || event.metadata.values.contains("temporary injection")
        })
    }

    func testCancellationRestoresOriginalClipboard() async throws {
        let fixture = await makeLosslessPasteboard()
        let pasteboard = fixture.controller
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        )
        let injection = Task {
            try await engine.inject("temporary injection")
        }

        try await waitForClipboardText("temporary injection", on: pasteboard)
        injection.cancel()

        do {
            try await injection.value
            XCTFail("Expected cancellation to leave the paste command incomplete.")
        } catch is CancellationError {
            // Expected. Restoration must happen before the cancellation escapes.
        }

        let restored = await rawContents(ofPasteboardNamed: fixture.name)
        XCTAssertEqual(restored, fixture.originalContents)
    }

    func testConcurrentTemporaryInjectionIsRejectedWithoutTouchingClipboard() async throws {
        let pasteboard = await makePasteboard()
        _ = await pasteboard.writePlainText("original clipboard")
        let engine = TextInjectionEngine(
            pasteboard: pasteboard,
            accessibilityChecker: { true },
            pasteCommandSender: {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        )
        let firstInjection = Task {
            try await engine.inject("first temporary injection")
        }
        try await waitForClipboardText("first temporary injection", on: pasteboard)

        do {
            try await engine.inject("second temporary injection")
            XCTFail("Expected the overlapping transaction to be rejected.")
        } catch let error as TextInjectionEngine.InjectionError {
            XCTAssertEqual(error, .temporaryClipboardTransactionInProgress)
        }
        let duringFirstInjection = await pasteboard.currentSnapshot()
        XCTAssertEqual(duringFirstInjection.plainText, "first temporary injection")

        firstInjection.cancel()
        _ = try? await firstInjection.value
        let restored = await pasteboard.currentSnapshot()
        XCTAssertEqual(restored.plainText, "original clipboard")
    }

    private func makePasteboard() async -> SystemClipboardPort {
        await MainActor.run {
            let systemPasteboard = NSPasteboard(
                name: NSPasteboard.Name("dev.rill.tests.\(UUID().uuidString)")
            )
            systemPasteboard.clearContents()
            return SystemClipboardPort(pasteboard: systemPasteboard)
        }
    }

    private func makeLosslessPasteboard() async -> LosslessPasteboardFixture {
        await MainActor.run {
            let name = "dev.rill.tests.\(UUID().uuidString)"
            let systemPasteboard = NSPasteboard(name: .init(name))
            let firstItem = NSPasteboardItem()
            firstItem.setData(Data("{\\rtf1 original}".utf8), forType: .rtf)
            firstItem.setData(
                Data([0x00, 0xFF, 0x10, 0x80]),
                forType: .init("com.example.rill-private")
            )
            firstItem.setString("original clipboard", forType: .string)
            let secondItem = NSPasteboardItem()
            secondItem.setData(
                Data("second-item".utf8),
                forType: .init("com.example.rill-second-item")
            )
            systemPasteboard.clearContents()
            XCTAssertTrue(systemPasteboard.writeObjects([firstItem, secondItem]))
            return LosslessPasteboardFixture(
                controller: SystemClipboardPort(pasteboard: systemPasteboard),
                name: name,
                originalContents: Self.rawContents(of: systemPasteboard)
            )
        }
    }

    private func rawContents(
        ofPasteboardNamed name: String
    ) async -> [LosslessPasteboardItem] {
        await MainActor.run {
            Self.rawContents(of: NSPasteboard(name: .init(name)))
        }
    }

    @MainActor
    private static func rawContents(of pasteboard: NSPasteboard) -> [LosslessPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            LosslessPasteboardItem(
                representations: item.types.map { type in
                    LosslessPasteboardRepresentation(
                        typeName: type.rawValue,
                        data: item.data(forType: type)
                    )
                }
            )
        }
    }

    private func makeFocusController(
        _ probe: TextInjectionFocusProbe
    ) -> TextInjectionEngine.FocusController {
        TextInjectionEngine.FocusController(
            currentIdentity: {
                await probe.readCurrentIdentity()
            },
            activate: { target in
                await probe.activate(target)
            }
        )
    }

    private func makeFocus(
        bundleIdentifier: String?,
        processIdentifier: Int32?
    ) -> FocusSnapshot {
        makeFocus(
            .init(
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
        )
    }

    private func makeFocus(
        _ identity: TextInjectionEngine.FocusIdentity
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "Target",
            bundleIdentifier: identity.bundleIdentifier,
            processIdentifier: identity.processIdentifier,
            focusedRole: "AXTextArea",
            selectedText: "",
            secureInput: false
        )
    }

    private func waitForClipboardText(
        _ expectedText: String,
        on pasteboard: SystemClipboardPort
    ) async throws {
        for _ in 0..<100 {
            let snapshot = await pasteboard.currentSnapshot()
            if snapshot.plainText == expectedText {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the temporary clipboard write.")
    }
}

private struct LosslessPasteboardFixture: Sendable {
    let controller: SystemClipboardPort
    let name: String
    let originalContents: [LosslessPasteboardItem]
}

private struct LosslessPasteboardItem: Sendable, Equatable {
    let representations: [LosslessPasteboardRepresentation]
}

private struct LosslessPasteboardRepresentation: Sendable, Equatable {
    let typeName: String
    let data: Data?
}

private actor TextInjectionFocusProbe {
    struct Snapshot: Sendable {
        let currentIdentityRequestCount: Int
        let activationRequestCount: Int
    }

    private var currentIdentity: TextInjectionEngine.FocusIdentity?
    private var queuedCurrentIdentities: [TextInjectionEngine.FocusIdentity?]
    private let activationResult: Bool
    private let updateIdentityOnActivation: Bool
    private var currentIdentityRequestCount = 0
    private var activationRequestCount = 0

    init(
        currentIdentity: TextInjectionEngine.FocusIdentity?,
        queuedCurrentIdentities: [TextInjectionEngine.FocusIdentity?] = [],
        activationResult: Bool = false,
        updateIdentityOnActivation: Bool = false
    ) {
        self.currentIdentity = currentIdentity
        self.queuedCurrentIdentities = queuedCurrentIdentities
        self.activationResult = activationResult
        self.updateIdentityOnActivation = updateIdentityOnActivation
    }

    func readCurrentIdentity() -> TextInjectionEngine.FocusIdentity? {
        currentIdentityRequestCount += 1
        if !queuedCurrentIdentities.isEmpty {
            return queuedCurrentIdentities.removeFirst()
        }
        return currentIdentity
    }

    func activate(_ target: TextInjectionEngine.FocusIdentity) -> Bool {
        activationRequestCount += 1
        if activationResult, updateIdentityOnActivation {
            currentIdentity = target
        }
        return activationResult
    }

    func setCurrentIdentity(_ identity: TextInjectionEngine.FocusIdentity?) {
        currentIdentity = identity
    }

    func snapshot() -> Snapshot {
        Snapshot(
            currentIdentityRequestCount: currentIdentityRequestCount,
            activationRequestCount: activationRequestCount
        )
    }
}

private actor TextInjectionKeyboardProbe {
    private var chunks: [[UInt16]] = []

    @discardableResult
    func send(_ chunk: [UInt16]) -> Int {
        chunks.append(chunk)
        return chunks.count
    }

    func snapshot() -> [[UInt16]] {
        chunks
    }
}

private actor TextInjectionPasteProbe {
    private var sendCount = 0

    func send() -> Bool {
        sendCount += 1
        return true
    }

    func snapshot() -> Int {
        sendCount
    }
}

private actor TextInjectionRestoreProbe {
    struct Snapshot: Sendable {
        var expectedChangeCounts: [Int]
        var retryChangeCount: Int?
    }

    private var expectedChangeCounts: [Int] = []
    private var retryChangeCount: Int?

    func begin(expectedChangeCount: Int) -> Int {
        expectedChangeCounts.append(expectedChangeCount)
        return expectedChangeCounts.count
    }

    func recordRetryChangeCount(_ changeCount: Int) {
        retryChangeCount = changeCount
    }

    func snapshot() -> Snapshot {
        Snapshot(
            expectedChangeCounts: expectedChangeCounts,
            retryChangeCount: retryChangeCount
        )
    }
}

private actor TextInjectionRestoreFailureBudget {
    private var remainingFailures: Int

    init(count: Int) {
        remainingFailures = count
    }

    func consumeFailure() -> Bool {
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
    }
}

private actor TextInjectionDiagnosticProbe {
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.append(event)
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }
}
