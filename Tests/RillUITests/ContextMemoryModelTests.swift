import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RillCore
@testable import RillUI

@MainActor
struct ContextMemoryModelTests {
    @Test func vocabularyOnlyConsentPersistsWithoutRequestingScreenPermission() async throws {
        let store = UITestSettingsStore(storage: [:])
        var screenRequests = 0
        let model = ContextMemoryModel(repository: ContextUIRepository(), settingsStore: store,
            activate: { $0.vocabularyCorrectionEnabled && $0.providerFingerprint == "fixture" }, revoke: {}, fingerprint: { "fixture" },
            screenPermission: { request in if request { screenRequests += 1 }; return false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.settings.vocabularyCorrectionEnabled)
        model.apply(screen: false, memory: false, workflowIDs: [UUID()], vocabulary: true)
        while model.isSaving && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isAuthorized)
        #expect(screenRequests == 0)
        #expect(!model.settings.screenContextEnabled && !model.settings.memoryEnabled)
        await model.shutdown()
        let encoded = try #require(try await store.string(forKey: .contextFeatureSettings))
        #expect(try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(encoded.utf8)).vocabularyCorrectionEnabled)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"] != nil))
    func renderVocabularyConsentSettings() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RILL_UI_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = ContextMemoryModel(repository: ContextUIRepository(), settingsStore: UITestSettingsStore(storage: [:]),
            activate: { _ in false }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        let app = makeHarness().model
        await app.waitForInitialVoiceConfiguration()
        app.contextMemory = model
        for language in AppLanguage.allCases {
            app.setInterfaceLanguage(language)
            for dark in [false, true] {
                let size = NSSize(width: 560, height: 650)
                let view = NSHostingView(rootView: SettingsView(model: app, pane: .vocabulary)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: size)
                window.orderFront(nil)
                for _ in 0..<12 { await waitForMainRunLoopDefaultMode() }
                window.layoutIfNeeded()
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                window.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("vocabulary-settings-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                window.close()
            }
        }
        await app.stopSettingsReadTasksForApplicationShutdown()
        await app.flushPendingPersistenceWrites()
        await model.shutdown()
    }

    @Test func failedSaveRetainsAnActionableResult() async {
        let repository = ContextUIRepository(failsWrites: true)
        let model = ContextMemoryModel(repository: repository, settingsStore: UITestSettingsStore(storage: [:]),
            activate: { _ in true }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Retained draft", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        #expect(await model.save(memory) == .failed(.mutation))
        #expect(model.error == .mutation)
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func shutdownFlushesAcceptedEditsAndRejectsNewOnes(deleting: Bool) async throws {
        let repository = ContextUIRepository()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.providerFingerprint = "fixture"
        let store = UITestSettingsStore(storage: [.contextFeatureSettings: String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)])
        let model = ContextMemoryModel(repository: repository, settingsStore: store, activate: { _ in true },
            revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Rill", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        let operation = Task {
            if deleting { await model.delete(memory) } else { await model.save(memory) }
        }
        while await !repository.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await repository.entered)
        var shutdownStarted = false
        var shutdownCompleted = false
        let shutdown = Task { shutdownStarted = true; await model.shutdown(); shutdownCompleted = true }
        while !shutdownStarted { await Task.yield() }
        #expect(!shutdownCompleted)
        await repository.release()
        #expect(await operation.value == .saved)
        await shutdown.value
        #expect(shutdownCompleted)
        #expect(await model.save(memory) == .stopped)
        #expect(await model.delete(memory) == .stopped)
        model.invalidateAuthorization()
        model.recordCorrection(.init(original: "Ril", corrected: "Rill"), recordID: UUID())
        model.scheduleMaintenance()
        #expect(await repository.writeCount == 1)
        let stored = try #require(try await store.string(forKey: .contextFeatureSettings))
        #expect(try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(stored.utf8)).providerFingerprint == "fixture")
    }

    @Test(arguments: [false, true])
    func revokedConfigurationCannotBeReauthorizedByAnOlderEdit(deleting: Bool) async throws {
        let repository = ContextUIRepository()
        var settings = ContextFeatureSettings()
        settings.memoryEnabled = true
        settings.providerFingerprint = "fixture"
        let store = UITestSettingsStore(storage: [.contextFeatureSettings: String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)])
        var activations = 0
        let model = ContextMemoryModel(repository: repository, settingsStore: store, activate: { value in
            activations += 1
            return value.providerFingerprint != nil
        }, revoke: {}, fingerprint: { "fixture" }, screenPermission: { _ in false }, maintain: {})
        model.load()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isLoading && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isAuthorized)
        let memory = LongTermMemory(scope: .init(workflowID: UUID(), applicationBundleID: nil, language: nil),
            summary: "Rill", evidenceKind: .userStatement, sources: [.init(sourceID: UUID(), revision: 1)])
        let operation = Task {
            if deleting { await model.delete(memory) } else { await model.save(memory) }
        }
        while await !repository.entered && ContinuousClock.now < deadline { await Task.yield() }
        #expect(await repository.entered)
        model.invalidateAuthorization()
        await repository.release()
        #expect(await operation.value == .saved)
        #expect(!model.isAuthorized)
        #expect(activations == 1)
        await model.shutdown()
        let stored = try #require(try await store.string(forKey: .contextFeatureSettings))
        #expect(try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(stored.utf8)).providerFingerprint == nil)
    }
}

private actor ContextUIRepository: ContextMemoryRepository {
    private(set) var entered = false
    private(set) var writeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private let failsWrites: Bool
    init(failsWrites: Bool = false) { self.failsWrites = failsWrites }
    private func pause() async {
        entered = true
        writeCount += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func setContextAuthorization(_ id: UUID?) async throws {}
    func recordForegroundContextRequest(authorization: ContextReferenceAuthorization, now: Date) async throws {}
    func memories() async throws -> [LongTermMemory] { [] }
    func saveMemory(_ memory: LongTermMemory, expectedRevision: Int64) async throws {
        if failsWrites { throw ContextCorrectionError.authorizationChanged }
        await pause()
    }
    func deleteMemory(id: UUID, expectedRevision: Int64) async throws {
        if failsWrites { throw ContextCorrectionError.authorizationChanged }
        await pause()
    }
    func relevantMemories(scope: ContextMemoryScope, now: Date) async throws -> [LongTermMemory] { [] }
    func prepareMemoryBatch(authorizationID: UUID, allowedWorkflowIDs: Set<UUID>, excludedApplications: Set<String>, now: Date) async throws -> MemoryConsolidationBatch? { nil }
    func commitMemoryBatch(_ batch: MemoryConsolidationBatch, result: MemoryConsolidationResult) async throws {}
    func memoryMaintenanceStatus(now: Date) async throws -> MemoryMaintenanceStatus { .init() }
    func appendScreenSummary(_ summary: ScreenReferenceSummary, runID: UUID, generation: RunHistoryWriteGeneration, authorization: ContextReferenceAuthorization) async throws {}
    func recordUserCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) async throws {}
}
