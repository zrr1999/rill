import Darwin
import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform

final class ExternalSystemOutputActionsTests: XCTestCase {
    func testShortcutsRunActionInvokesRunnerWithFinalText() async throws {
        let runner = ShortcutsRunnerSpy()
        let action = ShortcutsRunAction(runner: runner)
        let context = makeActionContext(
            actionID: ExternalOutputActionID.shortcutsRun,
            configuration: [ExternalOutputActionConfigurationKey.shortcutName: "Capture Note"]
        )

        let result = try await action.execute(text: "shortcut input", context: context)

        XCTAssertEqual(result, .externalOutput("Shortcut: Capture Note"))
        let invocations = await runner.invocationsSnapshot()
        XCTAssertEqual(invocations, [ShortcutInvocation(name: "Capture Note", inputText: "shortcut input")])
    }

    func testShortcutsRunActionReportsMissingNameAndRunnerFailure() async throws {
        let missingName = try await ShortcutsRunAction(runner: ShortcutsRunnerSpy()).execute(
            text: "hello",
            context: makeActionContext(actionID: ExternalOutputActionID.shortcutsRun)
        )
        assertFailed(missingName, contains: "Shortcut name is required")

        let failingRunner = ShortcutsRunnerSpy(errorMessage: "shortcut missing")
        let failedRun = try await ShortcutsRunAction(runner: failingRunner).execute(
            text: "hello",
            context: makeActionContext(
                actionID: ExternalOutputActionID.shortcutsRun,
                configuration: [ExternalOutputActionConfigurationKey.shortcutName: "Missing"]
            )
        )
        assertFailed(failedRun, contains: "shortcut missing")
    }

    func testShortcutsRunActionPropagatesCancellation() async throws {
        let action = ShortcutsRunAction(runner: CancelledShortcutsRunner())

        do {
            _ = try await action.execute(
                text: "cancelled input",
                context: makeActionContext(
                    actionID: ExternalOutputActionID.shortcutsRun,
                    configuration: [ExternalOutputActionConfigurationKey.shortcutName: "Cancelled"]
                )
            )
            XCTFail("Expected cancellation to propagate out of the output action.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSystemShortcutsRunnerReadsInputAndRemovesTemporaryFile() async throws {
        let fixture = try ShortcutProcessTestFixture()
        defer { fixture.remove() }
        let copiedInputURL = fixture.rootURL.appendingPathComponent("copied-input.txt")
        let runner = SystemShortcutsProcessRunner(
            timeout: .seconds(2),
            temporaryDirectory: fixture.inputDirectoryURL,
            commandBuilder: { _, inputURL in
                ShortcutProcessCommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        #"test -f "$1" && /bin/cp "$1" "$2""#,
                        "rill-shortcut-test",
                        inputURL.path,
                        copiedInputURL.path,
                    ]
                )
            }
        )

        try await runner.runShortcut(named: "Capture Note", inputText: "private shortcut input")

        XCTAssertEqual(
            try String(contentsOf: copiedInputURL, encoding: .utf8),
            "private shortcut input"
        )
        try fixture.assertInputDirectoryIsEmpty()
    }

    func testSystemShortcutsRunnerDrainsAndBoundsStderrWhileDiscardingStdout() async throws {
        let fixture = try ShortcutProcessTestFixture()
        defer { fixture.remove() }
        let runner = SystemShortcutsProcessRunner(
            timeout: .seconds(3),
            stderrByteLimit: 128,
            temporaryDirectory: fixture.inputDirectoryURL,
            commandBuilder: { _, _ in
                ShortcutProcessCommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        """
                        /usr/bin/yes stdout-data | /usr/bin/head -c 262144
                        /usr/bin/yes stderr-data | /usr/bin/head -c 262144 >&2
                        exit 7
                        """,
                    ]
                )
            }
        )

        do {
            try await runner.runShortcut(named: "Noisy", inputText: "input")
            XCTFail("Expected the noisy helper process to fail.")
        } catch let error as ExternalOutputActionError {
            guard case .shortcutFailed(let message) = error else {
                return XCTFail("Expected shortcutFailed, got \(error).")
            }
            let stderrMessage = try XCTUnwrap(message)
            XCTAssertTrue(stderrMessage.contains("stderr-data"))
            XCTAssertTrue(stderrMessage.contains("[stderr truncated]"))
            XCTAssertLessThanOrEqual(Data(stderrMessage.utf8).count, 160)
        }
        try fixture.assertInputDirectoryIsEmpty()
    }

    func testSystemShortcutsRunnerCancellationTerminatesProcessAndCleansInput() async throws {
        let fixture = try ShortcutProcessTestFixture()
        defer { fixture.remove() }
        let pidURL = fixture.rootURL.appendingPathComponent("cancel-pid.txt")
        let terminatedURL = fixture.rootURL.appendingPathComponent("terminated.txt")
        let runner = SystemShortcutsProcessRunner(
            timeout: .seconds(5),
            terminationGracePeriod: .milliseconds(250),
            stderrDrainGracePeriod: .milliseconds(25),
            temporaryDirectory: fixture.inputDirectoryURL,
            commandBuilder: { _, _ in
                ShortcutProcessCommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        #"echo $$ > "$1"; trap 'echo terminated > "$2"; exit 0' TERM; while :; do :; done"#,
                        "rill-shortcut-test",
                        pidURL.path,
                        terminatedURL.path,
                    ]
                )
            }
        )
        let task = Task {
            try await runner.runShortcut(named: "Cancelled", inputText: "cancel me")
        }
        let processIdentifier = try await readProcessIdentifier(from: pidURL)

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected the runner task to be cancelled.")
        } catch is CancellationError {
            // Expected.
        }

        try await waitForFile(at: terminatedURL)
        assertProcessHasExited(processIdentifier)
        try fixture.assertInputDirectoryIsEmpty()
    }

    func testSystemShortcutsRunnerTimeoutForceKillsTermIgnoringProcessAndCleansInput() async throws {
        let fixture = try ShortcutProcessTestFixture()
        defer { fixture.remove() }
        let pidURL = fixture.rootURL.appendingPathComponent("timeout-pid.txt")
        let runner = SystemShortcutsProcessRunner(
            timeout: .milliseconds(100),
            terminationGracePeriod: .milliseconds(100),
            stderrDrainGracePeriod: .milliseconds(25),
            temporaryDirectory: fixture.inputDirectoryURL,
            commandBuilder: { _, _ in
                ShortcutProcessCommand(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        #"echo $$ > "$1"; trap '' TERM; while :; do :; done"#,
                        "rill-shortcut-test",
                        pidURL.path,
                    ]
                )
            }
        )

        do {
            try await runner.runShortcut(named: "Hung", inputText: "timeout input")
            XCTFail("Expected the runner to time out.")
        } catch let error as ExternalOutputActionError {
            XCTAssertEqual(error, .shortcutTimedOut)
        }

        let processIdentifier = try await readProcessIdentifier(from: pidURL)
        assertProcessHasExited(processIdentifier)
        try fixture.assertInputDirectoryIsEmpty()
    }

    func testMarkdownAppendActionCreatesAndAppendsMarkdownFile() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-external-output-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let action = MarkdownAppendAction()
        let context = makeActionContext(
            actionID: ExternalOutputActionID.markdownAppend,
            configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
        )

        let first = try await action.execute(text: "First note", context: context)
        XCTAssertEqual(Darwin.chmod(fileURL.path, mode_t(0o640)), 0)
        let second = try await action.execute(text: "Second note", context: context)

        XCTAssertEqual(first, .externalOutput("Markdown append"))
        XCTAssertEqual(second, .externalOutput("Markdown append"))
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "First note\n\n---\n\nSecond note\n")
        var status = stat()
        XCTAssertEqual(Darwin.lstat(fileURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o640))
    }

    func testMarkdownAppendActionPreservesExistingFileMetadata() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let attributeName = "com.rill.tests.metadata"
        let attributeData = Data("metadata sentinel".utf8)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original".write(to: fileURL, atomically: false, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(fileURL.path, mode_t(0o640)), 0)
        XCTAssertEqual(Darwin.chflags(fileURL.path, UInt32(UF_NODUMP)), 0)
        try setExtendedAttribute(attributeData, named: attributeName, at: fileURL)
        var before = stat()
        XCTAssertEqual(Darwin.lstat(fileURL.path, &before), 0)

        let result = try await MarkdownAppendAction().execute(
            text: "appended",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(result, .externalOutput("Markdown append"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "original\n---\n\nappended\n")
        var after = stat()
        XCTAssertEqual(Darwin.lstat(fileURL.path, &after), 0)
        XCTAssertEqual(after.st_mode & mode_t(0o7777), before.st_mode & mode_t(0o7777))
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_flags & UInt32(UF_NODUMP), before.st_flags & UInt32(UF_NODUMP))
        XCTAssertEqual(after.st_birthtimespec.tv_sec, before.st_birthtimespec.tv_sec)
        XCTAssertEqual(after.st_birthtimespec.tv_nsec, before.st_birthtimespec.tv_nsec)
        XCTAssertEqual(
            try extendedAttribute(named: attributeName, at: fileURL),
            attributeData
        )
    }

    func testMarkdownAppendCompatibilityPathWorksWithoutModernUniqueFlags() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-compatibility-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let aliasURL = directory.appendingPathComponent("Capture-alias.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            filesystemCapabilities: .compatibility
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )
        let context = makeActionContext(
            actionID: ExternalOutputActionID.markdownAppend,
            configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
        )

        let firstResult = try await action.execute(text: "appended", context: context)
        XCTAssertEqual(firstResult, .externalOutput("Markdown append"))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original\n---\n\nappended\n"
        )
        try FileManager.default.linkItem(at: fileURL, to: aliasURL)

        let hardLinkResult = try await action.execute(text: "must not append", context: context)

        assertFailed(hardLinkResult, contains: "single-link regular file")
        XCTAssertEqual(try Data(contentsOf: fileURL), try Data(contentsOf: aliasURL))
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
    }

    func testMarkdownAppendActionReportsInvalidPath() async throws {
        let action = MarkdownAppendAction()
        let result = try await action.execute(
            text: "hello",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: "/tmp/Capture.txt"]
            )
        )
        assertFailed(result, contains: ".md or .markdown")
    }

    func testMarkdownAppendActionRejectsEmptyPath() async throws {
        let action = MarkdownAppendAction()

        for path in ["", "  \n\t"] {
            let result = try await action.execute(
                text: "must not be written",
                context: makeActionContext(
                    actionID: ExternalOutputActionID.markdownAppend,
                    configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: path]
                )
            )

            assertFailed(result, contains: "path is required")
        }
    }

    func testMarkdownAppendActionRejectsSymbolicLinkWithoutModifyingDestination() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = directory.appendingPathComponent("private-target.txt")
        let symbolicLinkURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "unrelated sentinel".write(to: destinationURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: destinationURL
        )

        let result = try await MarkdownAppendAction().execute(
            text: "must not follow the link",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [
                    ExternalOutputActionConfigurationKey.markdownAppendPath: symbolicLinkURL.path
                ]
            )
        )

        assertFailed(result, contains: "regular file")
        XCTAssertEqual(
            try String(contentsOf: destinationURL, encoding: .utf8),
            "unrelated sentinel"
        )
    }

    func testMarkdownAppendActionRejectsHardLinkWithoutModifyingEitherName() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-hardlink-tests-\(UUID().uuidString)", isDirectory: true)
        let targetURL = directory.appendingPathComponent("Capture.md")
        let aliasURL = directory.appendingPathComponent("unrelated-alias.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "unrelated sentinel".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: targetURL, to: aliasURL)

        let result = try await MarkdownAppendAction().execute(
            text: "must not modify a multiply linked file",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [
                    ExternalOutputActionConfigurationKey.markdownAppendPath: targetURL.path
                ]
            )
        )

        assertFailed(result, contains: "single-link regular file")
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "unrelated sentinel")
        XCTAssertEqual(try String(contentsOf: aliasURL, encoding: .utf8), "unrelated sentinel")
    }

    func testMarkdownAppendActionRejectsSymbolicLinkAncestor() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-parent-link-tests-\(UUID().uuidString)", isDirectory: true)
        let actualParentURL = directory.appendingPathComponent("actual", isDirectory: true)
        let linkedParentURL = directory.appendingPathComponent("linked", isDirectory: true)
        let linkedTargetURL = linkedParentURL.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: actualParentURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParentURL,
            withDestinationURL: actualParentURL
        )

        let result = try await MarkdownAppendAction().execute(
            text: "must not follow an ancestor link",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [
                    ExternalOutputActionConfigurationKey.markdownAppendPath: linkedTargetURL.path
                ]
            )
        )

        assertFailed(result, contains: "parent directory")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: actualParentURL.appendingPathComponent("Capture.md").path
            )
        )
    }

    func testMarkdownAppendActionRejectsFIFOAndDirectoryTargets() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-special-file-tests-\(UUID().uuidString)", isDirectory: true)
        let fifoURL = directory.appendingPathComponent("Pipe.md")
        let directoryTargetURL = directory.appendingPathComponent("Folder.md", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard Darwin.mkfifo(fifoURL.path, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fifoReader = Darwin.open(fifoURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fifoReader >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(fifoReader) }
        try FileManager.default.createDirectory(
            at: directoryTargetURL,
            withIntermediateDirectories: false
        )

        for targetURL in [fifoURL, directoryTargetURL] {
            let result = try await MarkdownAppendAction().execute(
                text: "must not be written",
                context: makeActionContext(
                    actionID: ExternalOutputActionID.markdownAppend,
                    configuration: [
                        ExternalOutputActionConfigurationKey.markdownAppendPath: targetURL.path
                    ]
                )
            )

            assertFailed(result, contains: "regular file")
        }
    }

    func testMarkdownAppendActionDoesNotCreateMissingParentDirectory() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-missing-parent-tests-\(UUID().uuidString)", isDirectory: true)
        let missingParentURL = directory.appendingPathComponent("missing", isDirectory: true)
        let fileURL = missingParentURL.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = try await MarkdownAppendAction().execute(
            text: "must not create directories implicitly",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "parent directory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParentURL.path))
    }

    func testMarkdownAppendActionRejectsInvalidUTF8WithoutChangingTarget() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-utf8-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let originalData = Data([0xFF, 0xFE, 0xFD])
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try originalData.write(to: fileURL)

        let result = try await MarkdownAppendAction().execute(
            text: "must not append to invalid text",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "valid UTF-8")
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testMarkdownAppendActionRejectsOversizedFileWithoutReadingOrChangingIt() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-size-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let oversizedByteCount = off_t(64 * 1_024 * 1_024 + 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let truncateResult = Darwin.ftruncate(descriptor, oversizedByteCount)
        let closeResult = Darwin.close(descriptor)
        guard truncateResult == 0, closeResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let result = try await MarkdownAppendAction().execute(
            text: "must not read an oversized file",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "64 MiB")
        var status = stat()
        XCTAssertEqual(Darwin.lstat(fileURL.path, &status), 0)
        XCTAssertEqual(status.st_size, oversizedByteCount)
    }

    func testMarkdownAppendShortWriteFailureLeavesOriginalUntouchedAndCleansTemporaryFile() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-short-write-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: true, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            payloadWriter: PartialThenFailMarkdownPayloadWriter()
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "must remain private until the transaction commits",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "private file transaction")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "original sentinel")
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
    }

    func testMarkdownAppendNewTargetCompetitionNeverOverwritesCompetitor() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-new-race-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforePublish: { context in
                    try writeMarkdownTestFile(
                        Data("competitor sentinel".utf8),
                        named: context.targetName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "must not replace the competitor",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "target changed")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "competitor sentinel")
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
    }

    func testMarkdownAppendPrePublishReplacementIsNeverDeletedByFailureCleanup() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-prepublish-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let privateBackupURL = directory.appendingPathComponent("private-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforePublish: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.temporaryName,
                        context.parentDescriptor,
                        privateBackupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("replacement sentinel".utf8),
                        named: context.temporaryName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "private entry",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "target changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try String(contentsOf: privateBackupURL, encoding: .utf8), "private entry\n")
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "replacement sentinel"
        )
    }

    func testMarkdownAppendReportsIndeterminatePublicationWithoutDeletingEitherFile() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-indeterminate-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let publishedBackupURL = directory.appendingPathComponent("published-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterPublishBeforeVerification: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.targetName,
                        context.parentDescriptor,
                        publishedBackupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("replacement sentinel".utf8),
                        named: context.targetName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "possibly published",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "inspect the target before retrying")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "replacement sentinel")
        XCTAssertEqual(
            try String(contentsOf: publishedBackupURL, encoding: .utf8),
            "possibly published\n"
        )
    }

    func testMarkdownAppendExistingTargetSwapNeverOverwritesReplacement() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-existing-race-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let backupURL = directory.appendingPathComponent("original-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: true, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforePublish: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.targetName,
                        context.parentDescriptor,
                        backupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("replacement sentinel".utf8),
                        named: context.targetName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "must not replace the new target",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "target changed")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "replacement sentinel")
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "original sentinel")
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
    }

    func testMarkdownAppendNeverPromotesAReplacementFromTheSwappedOutName() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-postswap-race-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let originalBackupURL = directory.appendingPathComponent("original-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let diagnosticProbe = MarkdownCleanupDiagnosticProbe()
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterPublishBeforeVerification: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.temporaryName,
                        context.parentDescriptor,
                        originalBackupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("replacement sentinel".utf8),
                        named: context.temporaryName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            ),
            diagnosticReporter: { await diagnosticProbe.record($0) }
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "possibly committed",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(
            result,
            .externalOutput("Markdown append committed; cleanup indeterminate")
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\npossibly committed\n"
        )
        XCTAssertEqual(try String(contentsOf: originalBackupURL, encoding: .utf8), "original sentinel")
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "replacement sentinel"
        )
        let diagnostics = await diagnosticProbe.snapshot()
        XCTAssertEqual(diagnostics.map(\.outcome), [.indeterminate])
        let diagnosticText = diagnostics.flatMap { [$0.event.rawValue, $0.message] }.joined(separator: " ")
        XCTAssertFalse(diagnosticText.contains(directory.path))
        XCTAssertFalse(diagnosticText.contains("possibly committed"))
    }

    func testMarkdownAppendNeverRollsBackOverAChangedPublishedTarget() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-published-target-race-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let publishedBackupURL = directory.appendingPathComponent("published-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterPublishBeforeVerification: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.targetName,
                        context.parentDescriptor,
                        publishedBackupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("competitor sentinel".utf8),
                        named: context.targetName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "possibly published",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        assertFailed(result, contains: "inspect the target before retrying")
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "competitor sentinel")
        XCTAssertEqual(
            try String(contentsOf: publishedBackupURL, encoding: .utf8),
            "original sentinel\n---\n\npossibly published\n"
        )
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "original sentinel"
        )
    }

    func testMarkdownAppendPreservesAnInPlaceOriginalUpdateDetectedAfterSwap() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-original-update-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterPublishBeforeVerification: { context in
                    try overwriteMarkdownTestFile(
                        Data("concurrent in-place update".utf8),
                        named: context.temporaryName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "must not erase the update",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(
            result,
            .externalOutput("Markdown append committed; cleanup indeterminate")
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\nmust not erase the update\n"
        )
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "concurrent in-place update"
        )
    }

    func testMarkdownAppendReportsIndeterminateWhenTheSwappedOutNameDisappears() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-rollback-failure-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterPublishBeforeVerification: { context in
                    guard Darwin.unlinkat(
                        context.parentDescriptor,
                        context.temporaryName,
                        0
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "committed entry",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(
            result,
            .externalOutput("Markdown append committed; cleanup indeterminate")
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\ncommitted entry\n"
        )
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
    }

    func testMarkdownAppendDoesNotDeleteAReplacementAtTheSwappedOutName() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-cleanup-race-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        let backupURL = directory.appendingPathComponent("original-backup.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeSwappedOutCleanup: { context in
                    guard Darwin.renameat(
                        context.parentDescriptor,
                        context.temporaryName,
                        context.parentDescriptor,
                        backupURL.lastPathComponent
                    ) == 0 else {
                        throw MarkdownTransactionTestError.requestedFailure
                    }
                    try writeMarkdownTestFile(
                        Data("replacement sentinel".utf8),
                        named: context.temporaryName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "appended",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(result, .externalOutput("Markdown append committed; cleanup pending"))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\nappended\n"
        )
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "original sentinel")
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "replacement sentinel"
        )
    }

    func testMarkdownAppendPreservesAnInPlaceUpdateImmediatelyBeforeCleanup() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-cleanup-update-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeSwappedOutCleanup: { context in
                    try overwriteMarkdownTestFile(
                        Data("late concurrent update".utf8),
                        named: context.temporaryName,
                        parentDescriptor: context.parentDescriptor
                    )
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )

        let result = try await action.execute(
            text: "possibly committed",
            context: makeActionContext(
                actionID: ExternalOutputActionID.markdownAppend,
                configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
            )
        )

        XCTAssertEqual(result, .externalOutput("Markdown append committed; cleanup pending"))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\npossibly committed\n"
        )
        let temporaryEntries = try markdownTemporaryEntries(in: directory)
        XCTAssertEqual(temporaryEntries.count, 1)
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(temporaryEntries.first), encoding: .utf8),
            "late concurrent update"
        )
    }

    func testMarkdownAppendRetriesDescriptorBoundCleanupWithoutAppendingAgain() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-cleanup-retry-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let failOnce = MarkdownCleanupFailOnce()
        let diagnosticProbe = MarkdownCleanupDiagnosticProbe()
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeSwappedOutCleanup: { _ in
                    try failOnce.failFirstAttempt()
                }
            ),
            diagnosticReporter: { await diagnosticProbe.record($0) }
        )

        let result = try await coordinator.append(text: "appended once", to: fileURL)

        XCTAssertEqual(result, .committedCleanupPending)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\nappended once\n"
        )
        XCTAssertEqual(try markdownTemporaryEntries(in: directory).count, 1)
        let pendingBeforeRetry = await coordinator.pendingPostCommitCleanupCount
        XCTAssertEqual(pendingBeforeRetry, 1)

        let pendingAfterRetry = await coordinator.retryPendingPostCommitCleanups()

        XCTAssertEqual(pendingAfterRetry, 0)
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
        let diagnostics = await diagnosticProbe.snapshot()
        XCTAssertEqual(
            diagnostics.map(\.outcome),
            [.retryPending, .completedAfterRetry]
        )
        let diagnosticText = diagnostics.flatMap { [$0.event.rawValue, $0.message] }.joined(separator: " ")
        XCTAssertFalse(diagnosticText.contains(fileURL.path))
        XCTAssertFalse(diagnosticText.contains("appended once"))
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\nappended once\n"
        )
    }

    func testMarkdownAppendReportsPendingDirectoryDurabilityAndRetriesOnlyCleanup() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-directory-sync-retry-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let failOnce = MarkdownCleanupFailOnce()
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeParentDirectorySync: { _ in
                    try failOnce.failFirstAttempt()
                }
            )
        )

        let result = try await coordinator.append(text: "appended once", to: fileURL)

        XCTAssertEqual(result, .committedCleanupPending)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "appended once\n")
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
        let pendingBeforeRetry = await coordinator.pendingPostCommitCleanupCount
        XCTAssertEqual(pendingBeforeRetry, 1)

        let pendingAfterRetry = await coordinator.retryPendingPostCommitCleanups()

        XCTAssertEqual(pendingAfterRetry, 0)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "appended once\n")
    }

    func testMarkdownAppendAutomaticCleanupRetryOutlivesCancelledCommitTask() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-automatic-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let failOnce = MarkdownCleanupFailOnce()
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeSwappedOutCleanup: { _ in
                    try failOnce.failFirstAttempt()
                },
                afterCommit: { _ in
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            ),
            automaticCleanupRetryDelays: [.milliseconds(10)]
        )
        let commitTask = Task {
            try await coordinator.append(text: "appended once", to: fileURL)
        }

        let result = try await commitTask.value

        XCTAssertEqual(result, .committedCleanupPending)
        for _ in 0..<100 {
            if await coordinator.pendingPostCommitCleanupCount == 0 {
                break
            }
            try await ContinuousClock().sleep(for: .milliseconds(10))
        }
        let pendingAfterAutomaticRetry = await coordinator.pendingPostCommitCleanupCount
        XCTAssertEqual(pendingAfterAutomaticRetry, 0)
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\nappended once\n"
        )
    }

    func testMarkdownAppendImmediateShutdownWaitsForAndDrainsPendingCleanup() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent(
                "rill-markdown-immediate-shutdown-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "original sentinel".write(to: fileURL, atomically: false, encoding: .utf8)
        let cleanupBlocker = MarkdownCleanupBlocker()
        let retryGate = MarkdownCleanupRetryGate()
        let completion = MarkdownCleanupCompletionProbe()
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforeSwappedOutCleanup: { _ in
                    try cleanupBlocker.failWhileBlocked()
                }
            ),
            drainInitialRetryDelay: .milliseconds(1),
            drainMaximumRetryDelay: .milliseconds(1),
            cleanupRetrySleep: { _ in await retryGate.wait() }
        )

        let result = try await coordinator.append(text: "committed before quit", to: fileURL)
        XCTAssertEqual(result, .committedCleanupPending)

        let shutdownTask = Task {
            await coordinator.sealAndDrain()
            await completion.markCompleted()
        }
        await retryGate.waitUntilWaiting()
        let completedWhileCleanupWasBlocked = await completion.isCompleted()
        let pendingWhileCleanupWasBlocked = await coordinator.pendingPostCommitCleanupCount
        XCTAssertFalse(completedWhileCleanupWasBlocked)
        XCTAssertEqual(pendingWhileCleanupWasBlocked, 1)

        cleanupBlocker.allowCleanup()
        await retryGate.open()
        await shutdownTask.value

        let completedAfterCleanup = await completion.isCompleted()
        let pendingAfterCleanup = await coordinator.pendingPostCommitCleanupCount
        XCTAssertTrue(completedAfterCleanup)
        XCTAssertEqual(pendingAfterCleanup, 0)
        XCTAssertTrue(try markdownTemporaryEntries(in: directory).isEmpty)
        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "original sentinel\n---\n\ncommitted before quit\n"
        )
    }

    func testMarkdownAppendCancellationBeforeCommitDoesNotCreateDestination() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-cancellation-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                beforePublish: { _ in
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(
                coordinator: coordinator
            )
        )
        let context = makeActionContext(
            actionID: ExternalOutputActionID.markdownAppend,
            configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
        )
        let task = Task {
            try await action.execute(text: "cancelled before commit", context: context)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate before the append commit point.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMarkdownAppendCancellationAfterCommitStillReportsSuccess() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-post-commit-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = MarkdownFileAppendCoordinator(
            hooks: MarkdownAppendTransactionHooks(
                afterCommit: { _ in
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
            )
        )
        let action = MarkdownAppendAction(
            appender: FileManagerMarkdownFileAppender(coordinator: coordinator)
        )
        let context = makeActionContext(
            actionID: ExternalOutputActionID.markdownAppend,
            configuration: [ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path]
        )
        let task = Task {
            try await action.execute(text: "committed", context: context)
        }

        let result = try await task.value
        XCTAssertEqual(result, .externalOutput("Markdown append"))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "committed\n")
    }

    func testMarkdownAppendSerializesConcurrentAppendsWithoutLoss() async throws {
        let directory = try physicalTemporaryDirectory()
            .appendingPathComponent("rill-markdown-concurrency-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("Capture.md")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expectedEntries = (0..<24).map { "entry-\($0)" }

        let results = try await withThrowingTaskGroup(of: ActionResult.self) { group in
            for entry in expectedEntries {
                group.addTask {
                    try await MarkdownAppendAction().execute(
                        text: entry,
                        context: makeActionContext(
                            actionID: ExternalOutputActionID.markdownAppend,
                            configuration: [
                                ExternalOutputActionConfigurationKey.markdownAppendPath: fileURL.path
                            ]
                        )
                    )
                }
            }

            var collected: [ActionResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, expectedEntries.count)
        XCTAssertTrue(results.allSatisfy { $0 == .externalOutput("Markdown append") })
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let storedEntries = contents
            .components(separatedBy: "\n\n---\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
        XCTAssertEqual(storedEntries.count, expectedEntries.count)
        XCTAssertEqual(Set(storedEntries), Set(expectedEntries))
    }
}

private enum MarkdownTransactionTestError: Error {
    case requestedFailure
}

private final class MarkdownCleanupFailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func failFirstAttempt() throws {
        lock.lock()
        defer { lock.unlock() }
        if !hasFailed {
            hasFailed = true
            throw MarkdownTransactionTestError.requestedFailure
        }
    }
}

private actor MarkdownCleanupDiagnosticProbe {
    private var diagnostics: [MarkdownPostCommitCleanupDiagnostic] = []

    func record(_ diagnostic: MarkdownPostCommitCleanupDiagnostic) {
        diagnostics.append(diagnostic)
    }

    func snapshot() -> [MarkdownPostCommitCleanupDiagnostic] {
        diagnostics
    }
}

private final class MarkdownCleanupBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var isBlocked = true

    func failWhileBlocked() throws {
        lock.lock()
        defer { lock.unlock() }
        if isBlocked {
            throw MarkdownTransactionTestError.requestedFailure
        }
    }

    func allowCleanup() {
        lock.lock()
        isBlocked = false
        lock.unlock()
    }
}

private actor MarkdownCleanupRetryGate {
    private var isOpen = false
    private var isWaiting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observationWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        isWaiting = true
        let observations = observationWaiters
        observationWaiters.removeAll()
        observations.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { continuation in
            observationWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MarkdownCleanupCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private struct PartialThenFailMarkdownPayloadWriter: MarkdownPayloadWriting {
    func write(_ data: Data, to descriptor: Int32) throws {
        let prefixCount = min(data.count, 5)
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, prefixCount)
        }
        guard written == prefixCount else {
            throw MarkdownTransactionTestError.requestedFailure
        }
        throw MarkdownTransactionTestError.requestedFailure
    }
}

private func writeMarkdownTestFile(
    _ data: Data,
    named name: String,
    parentDescriptor: Int32
) throws {
    let descriptor = Darwin.openat(
        parentDescriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        mode_t(0o600)
    )
    guard descriptor >= 0 else {
        throw MarkdownTransactionTestError.requestedFailure
    }
    do {
        try POSIXMarkdownPayloadWriter().write(data, to: descriptor)
    } catch {
        _ = Darwin.close(descriptor)
        _ = Darwin.unlinkat(parentDescriptor, name, 0)
        throw error
    }
    guard Darwin.close(descriptor) == 0 else {
        _ = Darwin.unlinkat(parentDescriptor, name, 0)
        throw MarkdownTransactionTestError.requestedFailure
    }
}

private func overwriteMarkdownTestFile(
    _ data: Data,
    named name: String,
    parentDescriptor: Int32
) throws {
    let descriptor = Darwin.openat(
        parentDescriptor,
        name,
        O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        throw MarkdownTransactionTestError.requestedFailure
    }
    do {
        try POSIXMarkdownPayloadWriter().write(data, to: descriptor)
    } catch {
        _ = Darwin.close(descriptor)
        throw error
    }
    guard Darwin.fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
        throw MarkdownTransactionTestError.requestedFailure
    }
}

private func markdownTemporaryEntries(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".rill-markdown-") }
}

private func setExtendedAttribute(_ data: Data, named name: String, at url: URL) throws {
    let result = data.withUnsafeBytes { bytes in
        Darwin.setxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private func extendedAttribute(named name: String, at url: URL) throws -> Data {
    let byteCount = Darwin.getxattr(url.path, name, nil, 0, 0, 0)
    guard byteCount >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var data = Data(count: byteCount)
    let readByteCount = data.withUnsafeMutableBytes { bytes in
        Darwin.getxattr(url.path, name, bytes.baseAddress, bytes.count, 0, 0)
    }
    guard readByteCount == byteCount else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return data
}

private struct ShortcutInvocation: Equatable, Sendable {
    var name: String
    var inputText: String
}

private actor ShortcutsRunnerSpy: ShortcutsProcessRunning {
    private let errorMessage: String?
    private var invocations: [ShortcutInvocation] = []

    init(errorMessage: String? = nil) {
        self.errorMessage = errorMessage
    }

    func runShortcut(named shortcutName: String, inputText: String) async throws {
        invocations.append(ShortcutInvocation(name: shortcutName, inputText: inputText))
        if let errorMessage {
            throw ShortcutRunnerTestError(message: errorMessage)
        }
    }

    func invocationsSnapshot() -> [ShortcutInvocation] {
        invocations
    }
}

private struct CancelledShortcutsRunner: ShortcutsProcessRunning {
    func runShortcut(named _: String, inputText _: String) async throws {
        throw CancellationError()
    }
}

private struct ShortcutRunnerTestError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

private struct ShortcutProcessTestFixture {
    let rootURL: URL
    let inputDirectoryURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-shortcut-process-tests-\(UUID().uuidString)", isDirectory: true)
        inputDirectoryURL = rootURL.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectoryURL, withIntermediateDirectories: true)
    }

    func assertInputDirectoryIsEmpty(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(contents.isEmpty, "Temporary shortcut input was not removed.", file: file, line: line)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func physicalTemporaryDirectory() throws -> URL {
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.realpath(FileManager.default.temporaryDirectory.path, &resolvedPath) != nil else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let terminatorIndex = resolvedPath.firstIndex(of: 0) ?? resolvedPath.endIndex
    let bytes = resolvedPath[..<terminatorIndex].map(UInt8.init(bitPattern:))
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
}

private func readProcessIdentifier(from url: URL) async throws -> pid_t {
    for _ in 0..<200 {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let processIdentifier = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return processIdentifier
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ShortcutProcessTestError.timedOutWaitingForProcess
}

private func waitForFile(at url: URL) async throws {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ShortcutProcessTestError.timedOutWaitingForProcess
}

private func assertProcessHasExited(
    _ processIdentifier: pid_t,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    errno = 0
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1, file: file, line: line)
    XCTAssertEqual(errno, ESRCH, file: file, line: line)
}

private enum ShortcutProcessTestError: Error {
    case timedOutWaitingForProcess
}

private func makeActionContext(
    actionID: String,
    configuration: [String: String] = [:]
) -> ActionContext {
    let workflow = WorkflowDefinition(
        name: "External Output Test",
        pipeline: PipelineDeclaration(
            recognizerID: "test.recognizer",
            outputActions: [OutputActionReference(id: actionID, configuration: configuration)]
        ),
        ui: WorkflowUIConfig(symbolName: "square.and.arrow.up", accentColorName: "green")
    )
    return ActionContext(
        runID: UUID(),
        workflow: workflow,
        contextSnapshot: .empty,
        recognitionResult: RecognitionResult(rawText: "hello", bestText: "hello"),
        finalText: "hello",
        startedAt: Date(timeIntervalSince1970: 1),
        finishedAt: Date(timeIntervalSince1970: 2)
    )
}

private func assertFailed(
    _ result: ActionResult,
    contains expectedSubstring: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let reason) = result else {
        return XCTFail("Expected failed result, got \(result)", file: file, line: line)
    }
    XCTAssertTrue(
        reason.contains(expectedSubstring),
        "Expected failure reason to contain \(expectedSubstring), got \(reason)",
        file: file,
        line: line
    )
}
