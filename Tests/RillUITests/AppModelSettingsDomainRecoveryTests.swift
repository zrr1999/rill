import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class AppModelSettingsDomainRecoveryTests: XCTestCase {
    func testDuplicateStableIdentifiersLeaveCollectionDomainsUnavailable() async throws {
        let duplicateWorkflow = WorkflowDefinition(
            name: "Duplicate workflow identity",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "ui.test.recognizer",
                outputActions: [OutputActionReference(id: "ui.test.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let duplicateWorkflowPayload = String(
            decoding: try JSONEncoder().encode([duplicateWorkflow, duplicateWorkflow]),
            as: UTF8.self
        )
        let workflowStore = UITestSettingsStore(storage: [
            .customWorkflows: duplicateWorkflowPayload,
        ])
        let workflowHarness = makeHarness(settingsStore: workflowStore)
        let workflowDomainFailedClosed = await waitUntil {
            !workflowHarness.model.isLoadingSettings
                && workflowHarness.model.workflowLibraryAvailability == .unavailable
        }
        XCTAssertTrue(workflowDomainFailedClosed)
        XCTAssertTrue(workflowHarness.model.customWorkflows.isEmpty)

        let duplicateModelsPayload = String(
            decoding: try JSONEncoder().encode(["same-model", "same-model"]),
            as: UTF8.self
        )
        let modelStore = UITestSettingsStore(storage: [
            .localSpeechDownloadedModels: duplicateModelsPayload,
        ])
        let modelHarness = makeHarness(settingsStore: modelStore)
        let modelDomainFailedClosed = await waitUntil {
            !modelHarness.model.isLoadingSettings
                && modelHarness.model.downloadedLocalSpeechModelsAvailability == .unavailable
        }
        XCTAssertTrue(modelDomainFailedClosed)
        XCTAssertTrue(modelHarness.model.downloadedLocalSpeechModels.isEmpty)

        let vocabularyID = UUID()
        let firstRule = VocabularyRule(
            id: vocabularyID,
            pattern: "first",
            replacement: "one"
        )
        let secondRule = VocabularyRule(
            id: vocabularyID,
            pattern: "second",
            replacement: "two"
        )
        let duplicateVocabularyPayload = String(
            decoding: try JSONEncoder().encode([firstRule, secondRule]),
            as: UTF8.self
        )
        let vocabularyStore = UITestSettingsStore(storage: [
            AppModel.vocabularyRulesSettingKey: duplicateVocabularyPayload,
        ])
        let vocabularyHarness = makeHarness(settingsStore: vocabularyStore)
        let vocabularyDomainFailedClosed = await waitUntil {
            !vocabularyHarness.model.isLoadingSettings
                && vocabularyHarness.model.vocabularyRulesAvailability == .unavailable
        }
        XCTAssertTrue(vocabularyDomainFailedClosed)
        XCTAssertTrue(vocabularyHarness.model.vocabularyRules.isEmpty)

        for (store, key, expectedPayload) in [
            (workflowStore, AppSettingKey.customWorkflows, duplicateWorkflowPayload),
            (modelStore, .localSpeechDownloadedModels, duplicateModelsPayload),
            (vocabularyStore, AppModel.vocabularyRulesSettingKey, duplicateVocabularyPayload),
        ] {
            let activity = await store.activitySnapshot()
            XCTAssertEqual(activity.storage[key], expectedPayload)
            XCTAssertNil(activity.setCounts[key])
            XCTAssertNil(activity.removeCounts[key])
        }
    }

    func testWorkflowEnabledStateLoaderRejectsInvalidAndNormalizedDuplicateIdentifiers() throws {
        XCTAssertThrowsError(
            try AppModel.loadWorkflowEnabledStates(
                from: "{\"not-a-workflow-id\":false}"
            )
        )

        let workflowID = UUID()
        let uppercase = workflowID.uuidString.uppercased()
        let lowercase = workflowID.uuidString.lowercased()
        XCTAssertNotEqual(uppercase, lowercase)
        XCTAssertThrowsError(
            try AppModel.loadWorkflowEnabledStates(
                from: "{\"\(uppercase)\":true,\"\(lowercase)\":false}"
            )
        )
    }

    func testCorruptWorkflowCollectionBlocksMutationAndRecoversWithoutOverwriting() async throws {
        for corruptKey in [AppSettingKey.customWorkflows, .workflowEnabledStates] {
            let recoveredWorkflow = WorkflowDefinition(
                name: "Recovered workflow",
                trigger: .manual,
                pipeline: PipelineDeclaration(
                    recognizerID: "ui.test.recognizer",
                    outputActions: [OutputActionReference(id: "ui.test.action")]
                ),
                ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
            )
            let workflowPayload = String(
                decoding: try JSONEncoder().encode([recoveredWorkflow]),
                as: UTF8.self
            )
            let enabledPayload = String(
                decoding: try JSONEncoder().encode([recoveredWorkflow.id.uuidString: false]),
                as: UTF8.self
            )
            let corruptPayload = "{not-valid-json"
            let settingsStore = UITestSettingsStore(storage: [
                .customWorkflows: corruptKey == .customWorkflows
                    ? corruptPayload
                    : workflowPayload,
                .workflowEnabledStates: corruptKey == .workflowEnabledStates
                    ? corruptPayload
                    : enabledPayload,
            ])
            let harness = makeHarness(settingsStore: settingsStore)

            let didLoadUnavailableWorkflowDomain = await waitUntil {
                !harness.model.isLoadingSettings
                    && harness.model.workflowLibraryAvailability == .unavailable
            }
            XCTAssertTrue(didLoadUnavailableWorkflowDomain)
            XCTAssertTrue(harness.model.customWorkflows.isEmpty)
            XCTAssertNotNil(harness.model.workflowLibraryError)

            var draft = harness.model.defaultWorkflowDraft()
            draft.name = "Must not overwrite"
            await harness.model.saveWorkflowDraft(draft)
            await waitForEventProcessing()

            XCTAssertTrue(harness.model.customWorkflows.isEmpty)
            XCTAssertNotNil(harness.model.workflowEditorError)
            var activity = await settingsStore.activitySnapshot()
            XCTAssertEqual(activity.storage[corruptKey], corruptPayload)
            XCTAssertNil(activity.setCounts[.customWorkflows])
            XCTAssertNil(activity.removeCounts[.customWorkflows])
            XCTAssertNil(activity.setCounts[.workflowEnabledStates])
            XCTAssertNil(activity.removeCounts[.workflowEnabledStates])

            try await settingsStore.setString(
                corruptKey == .customWorkflows ? workflowPayload : enabledPayload,
                forKey: corruptKey
            )
            harness.model.retryUnavailableStoredSettingsDomains()

            let didRecoverWorkflowDomain = await waitUntil {
                harness.model.workflowLibraryAvailability == .available
                    && harness.model.customWorkflows.map(\.id) == [recoveredWorkflow.id]
            }
            XCTAssertTrue(didRecoverWorkflowDomain)
            XCTAssertNil(harness.model.workflowLibraryError)
            XCTAssertFalse(harness.model.isWorkflowEnabled(recoveredWorkflow))
            activity = await settingsStore.activitySnapshot()
            XCTAssertEqual(activity.setCounts[corruptKey], 1)
            XCTAssertNil(activity.removeCounts[corruptKey])
        }
    }

    func testCorruptVocabularyCollectionBlocksMutationAndRecoversWithoutOverwriting() async throws {
        let corruptPayload = "[not-valid-json"
        let settingsStore = UITestSettingsStore(storage: [
            AppModel.vocabularyRulesSettingKey: corruptPayload,
        ])
        let source = VocabularyRuleSource(initialRules: [])
        let harness = makeHarness(
            settingsStore: settingsStore,
            vocabularyRuleSource: source
        )

        let didLoadUnavailableVocabularyDomain = await waitUntil {
            !harness.model.isLoadingSettings
                && harness.model.vocabularyRulesAvailability == .unavailable
        }
        XCTAssertTrue(didLoadUnavailableVocabularyDomain)
        XCTAssertNotNil(harness.model.vocabularyRulesError)
        XCTAssertThrowsError(try source.currentRules())

        harness.model.addVocabularyRule(
            kind: .mapping,
            pattern: "unsafe",
            replacement: "write",
            matchMode: .exactPhrase,
            caseSensitive: false,
            scope: .init()
        )
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.vocabularyRules.isEmpty)
        var activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.storage[AppModel.vocabularyRulesSettingKey], corruptPayload)
        XCTAssertNil(activity.setCounts[AppModel.vocabularyRulesSettingKey])
        XCTAssertNil(activity.removeCounts[AppModel.vocabularyRulesSettingKey])

        let recoveredRule = VocabularyRule(
            kind: .mapping,
            pattern: "Vox Type",
            replacement: "Rill"
        )
        let recoveredPayload = String(
            decoding: try JSONEncoder().encode([recoveredRule]),
            as: UTF8.self
        )
        try await settingsStore.setString(
            recoveredPayload,
            forKey: AppModel.vocabularyRulesSettingKey
        )
        harness.model.retryUnavailableStoredSettingsDomains()

        let didRecoverVocabularyDomain = await waitUntil {
            harness.model.vocabularyRulesAvailability == .available
                && harness.model.vocabularyRules.map(\.id) == [recoveredRule.id]
        }
        XCTAssertTrue(didRecoverVocabularyDomain)
        XCTAssertNil(harness.model.vocabularyRulesError)
        XCTAssertEqual(try source.currentRules().map(\.id), [recoveredRule.id])
        activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.setCounts[AppModel.vocabularyRulesSettingKey], 1)
        XCTAssertNil(activity.removeCounts[AppModel.vocabularyRulesSettingKey])
    }

    func testCorruptDownloadedModelMetadataCannotBeOverwrittenAndCanRecover() async throws {
        let corruptPayload = "{not-an-array}"
        let settingsStore = UITestSettingsStore(storage: [
            .localSpeechDownloadedModels: corruptPayload,
        ])
        let harness = makeHarness(settingsStore: settingsStore)

        let didLoadUnavailableModelMetadata = await waitUntil {
            !harness.model.isLoadingSettings
                && harness.model.downloadedLocalSpeechModelsAvailability == .unavailable
        }
        XCTAssertTrue(didLoadUnavailableModelMetadata)
        XCTAssertNotNil(harness.model.downloadedLocalSpeechModelsError)

        harness.model.recordDownloadedLocalSpeechModel("must-not-overwrite")
        await waitForEventProcessing()

        XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
        var activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.storage[.localSpeechDownloadedModels], corruptPayload)
        XCTAssertNil(activity.setCounts[.localSpeechDownloadedModels])
        XCTAssertNil(activity.removeCounts[.localSpeechDownloadedModels])

        let recoveredModels = ["reviewed-local-model"]
        let recoveredPayload = String(
            decoding: try JSONEncoder().encode(recoveredModels),
            as: UTF8.self
        )
        try await settingsStore.setString(
            recoveredPayload,
            forKey: .localSpeechDownloadedModels
        )
        harness.model.retryUnavailableStoredSettingsDomains()

        let didRecoverModelMetadata = await waitUntil {
            harness.model.downloadedLocalSpeechModelsAvailability == .available
                && harness.model.downloadedLocalSpeechModels == recoveredModels
        }
        XCTAssertTrue(didRecoverModelMetadata)
        XCTAssertNil(harness.model.downloadedLocalSpeechModelsError)
        activity = await settingsStore.activitySnapshot()
        XCTAssertEqual(activity.setCounts[.localSpeechDownloadedModels], 1)
        XCTAssertNil(activity.removeCounts[.localSpeechDownloadedModels])
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<300 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
