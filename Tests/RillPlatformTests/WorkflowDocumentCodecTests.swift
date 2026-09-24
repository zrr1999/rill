import Foundation
import RillCore
import RillPlatform
import Testing

struct WorkflowDocumentCodecTests {
    @Test(arguments: ["speech_to_text", "speech_to_text_polish"])
    func speechTemplatesStoreAndDeliverTheSameResult(_ name: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RillApp/Resources/WorkflowTemplates/\(name).toml")
        let document = try WorkflowDocumentCodec().decode(String(contentsOf: url, encoding: .utf8))
        #expect(document.workflow.plan.output.actions.map(\.id) == ["record.store", "focused-application.insert"])
        #expect(document.workflow.plan.output.deliveryPolicy.strategy == .immediate)
        #expect(document.workflow.targetRecordCollectionIDs == [RecordCollection.voiceInputID])
    }

    static let source = """
        schema_version = 2
        id = "11111111-2222-3333-4444-555555555555"
        name = "Structured text"
        enabled = false
        [trigger]
        kind = "manual"
        [input]
        kind = "text"
        [[process]]
        id = "choose"
        kind = "if"
        condition = { all = [{ field = "text", op = "contains", value = "Rill" }, { not = [{ field = "context.selected_text", op = "exists" }] }] }
        [[process.then]]
        id = "clean"
        kind = "normalize-whitespace"
        [[process.else]]
        id = "answer"
        kind = "llm-answer"
        prompt = "Answer directly."
        [output]
        strategy = "immediate"
        [[output.actions]]
        id = "copy"
        kind = "system-clipboard.copy"
        condition = { field = "text", op = "exists" }
        [[output.actions]]
        id = "store"
        kind = "record.store"
        [metadata]
        "user.team" = "design"
        """

    @Test func timingSelectionRoundTripsAndDefaultsToSpeechAndLanguageModelCalls() throws {
        let codec = WorkflowDocumentCodec()
        let source = Self.source
            .replacingOccurrences(of: "kind = \"normalize-whitespace\"", with: "kind = \"normalize-whitespace\"\nrecord_duration = true")
            .replacingOccurrences(of: "kind = \"llm-answer\"", with: "kind = \"llm-answer\"\nrecord_duration = false")
        let document = try codec.decode(source)
        let steps = document.workflow.plan.process.allSteps
        #expect(steps.map(\.recordsDuration) == [false, true, false])
        #expect(steps.map(\.recordDuration) == [nil, true, false])
        #expect(try codec.decode(codec.encode(document)) == document)
        #expect(WorkflowProcessStep(kind: .recognizeSpeech).recordsDuration)
        #expect(WorkflowProcessStep(kind: .llmRewrite).recordsDuration)
        #expect(WorkflowProcessStep(kind: .llmAnswer).recordsDuration)
        #expect(!WorkflowProcessStep(kind: .applyVocabulary).recordsDuration)
    }

    @Test func rejectsNonBooleanTimingSelection() {
        let source = Self.source.replacingOccurrences(
            of: "kind = \"normalize-whitespace\"", with: "kind = \"normalize-whitespace\"\nrecord_duration = \"true\"")
        #expect(throws: (any Error).self) { try WorkflowDocumentCodec().decode(source) }
    }

    @Test func roundTripPreservesBranchesOrderAndMetadata() throws {
        let codec = WorkflowDocumentCodec()
        let document = try codec.decode(Self.source)
        let canonical = try codec.encode(document)
        #expect(try codec.decode(canonical) == document)
        #expect(try codec.encode(codec.decode(canonical)) == canonical)
        #expect(
            document.workflow.plan.process.allSteps.map(\.documentID) == [
                "choose", "clean", "answer",
            ])
        #expect(document.workflow.plan.output.actions.map(\.documentID) == ["copy", "store"])
        #expect(document.workflow.metadata["user.team"] == "design")
        #expect(
            try document.workflow.plan.process.steps[0].condition?.evaluate(
                text: "Rill", context: .empty) == true)
    }

    @Test func rejectsUnknownFieldsFutureVersionsAndDuplicateIDs() throws {
        let codec = WorkflowDocumentCodec()
        for source in [
            "unexpected = true\n" + Self.source,
            Self.source.replacingOccurrences(
                of: "kind = \"manual\"", with: "kind = \"manual\"\ntypo = true"),
            Self.source.replacingOccurrences(of: "schema_version = 2", with: "schema_version = 3"),
            Self.source.replacingOccurrences(of: "id = \"store\"", with: "id = \"clean\""),
            Self.source.replacingOccurrences(
                of: "kind = \"normalize-whitespace\"",
                with: "kind = \"normalize-whitespace\"\nbranches = []"),
        ] { #expect(throws: (any Error).self) { try codec.decode(source) } }
    }

    @Test func missingContextRequiresExistsGuardAndConditionsShortCircuit() throws {
        let unavailable = WorkflowCondition.comparison(
            field: .appBundleID, operation: .equals, value: "app")
        #expect(throws: WorkflowDocumentError.self) {
            try unavailable.evaluate(text: "", context: .empty)
        }
        let guarded = WorkflowCondition.all([
            .comparison(field: .appBundleID, operation: .exists, value: nil), unavailable,
        ])
        #expect(try !guarded.evaluate(text: "", context: .empty))
        #expect(throws: WorkflowDocumentError.self) { try WorkflowCondition.all([]).validate() }
        #expect(throws: WorkflowDocumentError.self) {
            try WorkflowCondition.comparison(field: .text, operation: .exists, value: "unexpected")
                .validate()
        }
    }

    @Test func discoveryDoesNotCreateOrChangeDirectoryPermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
        let empty = await store.load()
        #expect(empty.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750]
        )
        _ = await store.load()
        let permissions =
            try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o750)
    }

    @Test func savesUseCASAndBoundedHistoryAndPrivateFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
        var document = try store.decodeDocument(Self.source)
        var record = try await store.saveDocument(document, replacing: nil, expected: .missing)
        let original = try #require(record.source)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: record.fileURL.path)[
                .posixPermissions] as? NSNumber)?.intValue == 0o600)
        for index in 1...22 {
            document.workflow.name = "Revision \(index)"
            record = try await store.saveDocument(
                document, replacing: record.fileURL, expected: .source(try #require(record.source)))
        }
        let versions = try await store.versions(for: document.workflow.id)
        #expect(versions.count == 20)
        #expect(versions.first?.source.contains("Revision 21") == true)
        await #expect(throws: WorkflowFileConflict.self) {
            try await store.saveDocument(
                document, replacing: record.fileURL, expected: .source(original))
        }
        #expect(try await store.readSource(at: record.fileURL) == record.source)
    }

    @Test func invalidOverrideRetainsItsIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
        let document = try store.decodeDocument(Self.source)
        let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
        try (Self.source + "\nbroken = [").write(
            to: record.fileURL, atomically: true, encoding: .utf8)
        let loaded = await store.load()
        #expect(loaded.records.isEmpty)
        #expect(loaded.issues.first?.workflowID == document.workflow.id)
    }

    @Test func watchesCreationAtomicReplacementAndInPlaceEdits() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = XDGWorkflowFileStore(configurationDirectoryURL: directory)
        let stream = await store.changes()
        let document = try store.decodeDocument(Self.source)
        let record = try await store.saveDocument(document, replacing: nil, expected: .missing)
        let original = try #require(record.source)
        let replacement = Self.source + "\n# atomic"
        let observed = Task {
            var changes = stream.makeAsyncIterator()
            try #require(await observesSource(original, in: store, from: &changes))

            try replacement.write(to: record.fileURL, atomically: true, encoding: .utf8)
            try #require(await observesSource(replacement, in: store, from: &changes))

            let handle = try FileHandle(forWritingTo: record.fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n# in place".utf8))
            try handle.close()
            try #require(await observesSource(replacement + "\n# in place", in: store, from: &changes))
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            observed.cancel()
        }
        defer {
            observed.cancel()
            timeout.cancel()
        }
        try await observed.value
    }

    private func observesSource(
        _ expected: String,
        in store: XDGWorkflowFileStore,
        from changes: inout AsyncStream<Void>.Iterator
    ) async -> Bool {
        while await changes.next() != nil {
            let loaded = await store.load()
            if loaded.records.first?.source == expected { return true }
        }
        return false
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-document-\(UUID().uuidString)/workflows", isDirectory: true)
    }
}
