import XCTest
@testable import RillCore
@testable import RillRuntime

final class WebhookProtectingSettingsStoreTests: XCTestCase {
    func testMigrationProtectsPayloadAtomicallyAndForcesWorkflowDisabled() async throws {
        let workflowID = UUID()
        let rawURL = " https://example.com/private-hook?token=exact "
        let rawHeaders = #"{"X-Exact":"  preserve  "}"#
        let workflow = makeWebhookWorkflow(
            id: workflowID,
            url: rawURL,
            headersJSON: rawHeaders
        )
        let operationLog = WebhookMigrationOperationLog()
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [
                .customWorkflows: try encode([workflow]),
                .workflowEnabledStates: try encode([workflowID.uuidString.lowercased(): true]),
            ],
            operationLog: operationLog
        )
        let secureStore = WebhookMigrationSecureStore(operationLog: operationLog)
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .ready(protectedActionCount: 1))
        let protected = await secureStore.storedConfiguration(for: reference)
        XCTAssertEqual(protected?.values, [
            ExternalOutputActionConfigurationKey.webhookURL: rawURL,
            ExternalOutputActionConfigurationKey.webhookHeadersJSON: rawHeaders,
        ])
        let snapshot = await settingsStore.snapshot()
        let migratedWorkflow = try XCTUnwrap(
            try decodeWorkflows(snapshot.storage[.customWorkflows]).first
        )
        let migratedConfiguration = try XCTUnwrap(
            migratedWorkflow.pipeline.outputActions.first?.configuration
        )
        XCTAssertNil(migratedConfiguration[ExternalOutputActionConfigurationKey.webhookURL])
        XCTAssertNil(migratedConfiguration[ExternalOutputActionConfigurationKey.webhookHeadersJSON])
        XCTAssertEqual(
            migratedConfiguration[ExternalOutputActionConfigurationKey.webhookSecureReference],
            reference.rawValue
        )
        let enabledStates = try decodeEnabledStates(snapshot.storage[.workflowEnabledStates])
        XCTAssertEqual(enabledStates, [workflowID.uuidString: false])
        XCTAssertEqual(
            snapshot.storage[.webhookConfigurationProtectionState],
            WebhookConfigurationProtectionState.completeV1.rawValue
        )
        XCTAssertEqual(snapshot.atomicWriteCount, 2)
        XCTAssertEqual(snapshot.purgeCount, 1)
        let operations = await operationLog.snapshot()
        XCTAssertEqual(
            operations,
            [
                "settings.read",
                "secure.read:\(reference.rawValue)",
                "secure.set:\(reference.rawValue)",
                "secure.read:\(reference.rawValue)",
                "settings.atomic",
                "settings.purge",
                "settings.atomic",
            ]
        )

        let secondResult = await migrator.migrateIfNeeded()
        XCTAssertEqual(secondResult, .ready(protectedActionCount: 1))
        let secondSnapshot = await settingsStore.snapshot()
        XCTAssertEqual(secondSnapshot.atomicWriteCount, 2)
        XCTAssertEqual(secondSnapshot.purgeCount, 1)
        let secureSetCount = await secureStore.setCount()
        XCTAssertEqual(secureSetCount, 1)
    }

    func testDuplicateWorkflowIDBlocksBeforeSecureOrAtomicWrites() async throws {
        let workflowID = UUID()
        let first = makeWebhookWorkflow(id: workflowID, url: "https://one.example")
        let second = makeWebhookWorkflow(id: workflowID, url: "https://two.example")
        let originalLibrary = try encode([first, second])
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: originalLibrary]
        )
        let secureStore = WebhookMigrationSecureStore()
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .blocked(.duplicateWorkflowID(workflowID)))
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], originalLibrary)
        XCTAssertEqual(snapshot.atomicWriteCount, 0)
        let secureOperationCount = await secureStore.operationCount()
        XCTAssertEqual(secureOperationCount, 0)
    }

    func testIdenticalSecureValueIsReusedWithoutRewrite() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://same.example")
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let payload = try XCTUnwrap(
            WebhookProtectedConfiguration.extractingPlaintext(
                from: workflow.pipeline.outputActions[0].configuration
            )
        )
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: try encode([workflow])]
        )
        let secureStore = WebhookMigrationSecureStore(storage: [reference: payload])
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .ready(protectedActionCount: 1))
        let secureSetCount = await secureStore.setCount()
        XCTAssertEqual(secureSetCount, 0)
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.atomicWriteCount, 2)
    }

    func testConflictingSecureValueLeavesSettingsUntouched() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://legacy.example")
        let originalLibrary = try encode([workflow])
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let conflictingPayload = try WebhookProtectedConfiguration(values: [
            ExternalOutputActionConfigurationKey.webhookURL: "https://keychain.example",
        ])
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: originalLibrary]
        )
        let secureStore = WebhookMigrationSecureStore(storage: [reference: conflictingPayload])
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .blocked(.secureValueConflict(reference)))
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], originalLibrary)
        XCTAssertEqual(snapshot.atomicWriteCount, 0)
        let secureSetCount = await secureStore.setCount()
        XCTAssertEqual(secureSetCount, 0)
    }

    func testSecureWriteFailureOccursBeforeAnySettingsMutation() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://preserved.example")
        let originalLibrary = try encode([workflow])
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: originalLibrary]
        )
        let secureStore = WebhookMigrationSecureStore(failWrites: true)
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .blocked(.secureWriteFailed(reference)))
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], originalLibrary)
        XCTAssertEqual(snapshot.atomicWriteCount, 0)
    }

    func testAtomicSettingsFailureKeepsLegacyLibraryAndRetainsVerifiedSecureCopy() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://atomic.example")
        let originalLibrary = try encode([workflow])
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: originalLibrary],
            failAtomicWriteCalls: [1]
        )
        let secureStore = WebhookMigrationSecureStore()
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .blocked(.settingsWriteFailed))
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], originalLibrary)
        XCTAssertNil(snapshot.storage[.webhookConfigurationProtectionState])
        let protected = await secureStore.storedConfiguration(for: reference)
        XCTAssertEqual(
            protected?.values[ExternalOutputActionConfigurationKey.webhookURL],
            "https://atomic.example"
        )
    }

    func testStoredReferenceRemainsAuthoritativeAfterActionReordering() async throws {
        let workflowID = UUID()
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let payload = try WebhookProtectedConfiguration(values: [
            ExternalOutputActionConfigurationKey.webhookURL: "https://stable.example",
        ])
        let workflow = WorkflowDefinition(
            id: workflowID,
            name: "Reordered Legacy Webhook",
            pipeline: PipelineDeclaration(
                recognizerID: "test.recognizer",
                outputActions: [
                    OutputActionReference(id: ExternalOutputActionID.shortcutsRun),
                    OutputActionReference(
                        id: ExternalOutputActionID.webhookPost,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookSecureReference:
                                reference.rawValue,
                        ]
                    ),
                ]
            ),
            ui: WorkflowUIConfig(symbolName: "network", accentColorName: "orange")
        )
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [
                .customWorkflows: try encode([workflow]),
                .webhookConfigurationProtectionState:
                    WebhookConfigurationProtectionState.completeV1.rawValue,
            ]
        )
        let secureStore = WebhookMigrationSecureStore(storage: [reference: payload])
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .ready(protectedActionCount: 1))
        let snapshot = await settingsStore.snapshot()
        let storedWorkflow = try XCTUnwrap(
            try decodeWorkflows(snapshot.storage[.customWorkflows]).first
        )
        XCTAssertEqual(
            storedWorkflow.pipeline.outputActions[1]
                .configuration[ExternalOutputActionConfigurationKey.webhookSecureReference],
            reference.rawValue
        )
        let enabledStates = try decodeEnabledStates(snapshot.storage[.workflowEnabledStates])
        XCTAssertEqual(enabledStates[workflowID.uuidString], false)
        XCTAssertEqual(snapshot.purgeCount, 0)
    }

    func testMigrationIgnoresWebhookNamedConfigurationOwnedByAnotherAction() async throws {
        let workflow = WorkflowDefinition(
            name: "Shortcut With Unrelated Configuration",
            pipeline: PipelineDeclaration(
                recognizerID: "test.recognizer",
                outputActions: [
                    OutputActionReference(
                        id: ExternalOutputActionID.shortcutsRun,
                        configuration: [
                            ExternalOutputActionConfigurationKey.webhookURL:
                                "https://unrelated.example",
                            ExternalOutputActionConfigurationKey.webhookSecureReference:
                                "not-a-webhook-action-reference",
                        ]
                    ),
                ]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "blue")
        )
        let originalLibrary = try encode([workflow])
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: originalLibrary]
        )
        let secureStore = WebhookMigrationSecureStore()
        let migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let result = await migrator.migrateIfNeeded()

        XCTAssertEqual(result, .ready(protectedActionCount: 0))
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], originalLibrary)
        XCTAssertEqual(snapshot.atomicWriteCount, 0)
        XCTAssertEqual(snapshot.purgeCount, 0)
        let secureOperationCount = await secureStore.operationCount()
        XCTAssertEqual(secureOperationCount, 0)
    }

    func testEnabledStateWritesCannotReenableProtectedWebhookWorkflow() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://disabled.example")
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: try encode([workflow])]
        )
        let protectingStore = WebhookProtectingSettingsStore(
            settingsStore: settingsStore,
            secureStore: WebhookMigrationSecureStore()
        )
        _ = try await protectingStore.strings(forKeys: [
            .customWorkflows,
            .workflowEnabledStates,
        ])

        try await protectingStore.setString(
            try encode([workflowID.uuidString.lowercased(): true]),
            forKey: .workflowEnabledStates
        )
        var snapshot = await settingsStore.snapshot()
        var enabledStates = try decodeEnabledStates(snapshot.storage[.workflowEnabledStates])
        XCTAssertEqual(enabledStates, [workflowID.uuidString: false])

        try await protectingStore.setStringsAtomically([
            .workflowEnabledStates: try encode([workflowID.uuidString: true]),
            .interfaceLanguage: "english",
        ])
        snapshot = await settingsStore.snapshot()
        enabledStates = try decodeEnabledStates(snapshot.storage[.workflowEnabledStates])
        XCTAssertEqual(enabledStates, [workflowID.uuidString: false])
        XCTAssertEqual(snapshot.storage[.interfaceLanguage], "english")

        try await protectingStore.removeValue(forKey: .workflowEnabledStates)
        snapshot = await settingsStore.snapshot()
        enabledStates = try decodeEnabledStates(snapshot.storage[.workflowEnabledStates])
        XCTAssertEqual(enabledStates, [workflowID.uuidString: false])
    }

    func testUnrelatedAtomicSettingsWriteDoesNotParseOrLockDamagedWorkflowLibrary() async throws {
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [.customWorkflows: "not valid workflow JSON"]
        )
        let protectingStore = WebhookProtectingSettingsStore(
            settingsStore: settingsStore,
            secureStore: WebhookMigrationSecureStore()
        )
        let privacyValues: [AppSettingKey: String] = [
            .privacyCloudConfirmationRequired: "true",
            .privacyHistoryPreviewMode: PrivacyHistoryPreviewMode.restricted.rawValue,
        ]

        try await protectingStore.setStringsAtomically(privacyValues)

        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(snapshot.storage[.customWorkflows], "not valid workflow JSON")
        XCTAssertEqual(snapshot.storage[.privacyCloudConfirmationRequired], "true")
        XCTAssertEqual(
            snapshot.storage[.privacyHistoryPreviewMode],
            PrivacyHistoryPreviewMode.restricted.rawValue
        )
        let migrationResult = await protectingStore.currentMigrationResult()
        XCTAssertNil(migrationResult)
    }

    func testPurgePendingAllowsSanitizedReadsLocksWorkflowWritesAndCanRetry() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://purge.example")
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [
                .customWorkflows: try encode([workflow]),
                .interfaceLanguage: "english",
            ],
            failPurge: true
        )
        let secureStore = WebhookMigrationSecureStore()
        let protectingStore = WebhookProtectingSettingsStore(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let values = try await protectingStore.strings(forKeys: [
            .customWorkflows,
            .workflowEnabledStates,
            .interfaceLanguage,
        ])

        XCTAssertEqual(values[.interfaceLanguage], "english")
        let sanitizedWorkflow = try XCTUnwrap(
            try decodeWorkflows(values[.customWorkflows]).first
        )
        XCTAssertNil(
            sanitizedWorkflow.pipeline.outputActions[0]
                .configuration[ExternalOutputActionConfigurationKey.webhookURL]
        )
        let pendingResult = await protectingStore.currentMigrationResult()
        XCTAssertEqual(
            pendingResult,
            .purgePending(protectedActionCount: 1)
        )
        do {
            try await protectingStore.setString(
                try encode([sanitizedWorkflow]),
                forKey: .customWorkflows
            )
            XCTFail("Expected workflow writes to remain locked while purge is pending")
        } catch {
            XCTAssertEqual(
                error as? WebhookProtectingSettingsStoreError,
                .workflowLibraryLocked
            )
        }

        try await protectingStore.setString("simplifiedChinese", forKey: .interfaceLanguage)
        let updatedLanguage = try await protectingStore.string(forKey: .interfaceLanguage)
        XCTAssertEqual(updatedLanguage, "simplifiedChinese")

        await settingsStore.setFailPurge(false)
        let retryResult = await protectingStore.retryProtection()
        XCTAssertEqual(
            retryResult,
            .ready(protectedActionCount: 1)
        )
        let snapshot = await settingsStore.snapshot()
        XCTAssertEqual(
            snapshot.storage[.webhookConfigurationProtectionState],
            WebhookConfigurationProtectionState.completeV1.rawValue
        )
        try await protectingStore.setString(
            try encode([sanitizedWorkflow]),
            forKey: .customWorkflows
        )
    }

    func testBlockedMigrationQuarantinesWorkflowLibraryButLeavesOtherSettingsUsable() async throws {
        let workflowID = UUID()
        let workflow = makeWebhookWorkflow(id: workflowID, url: "https://blocked.example")
        let reference = try XCTUnwrap(
            WebhookConfigurationReference(workflowID: workflowID, actionIndex: 0)
        )
        let conflictingPayload = try WebhookProtectedConfiguration(values: [
            ExternalOutputActionConfigurationKey.webhookURL: "https://different.example",
        ])
        let settingsStore = WebhookMigrationSettingsStore(
            storage: [
                .customWorkflows: try encode([workflow]),
                .interfaceLanguage: "english",
            ]
        )
        let secureStore = WebhookMigrationSecureStore(storage: [reference: conflictingPayload])
        let protectingStore = WebhookProtectingSettingsStore(
            settingsStore: settingsStore,
            secureStore: secureStore
        )

        let values = try await protectingStore.strings(forKeys: [
            .customWorkflows,
            .workflowEnabledStates,
            .interfaceLanguage,
        ])

        XCTAssertNil(values[.customWorkflows])
        XCTAssertEqual(values[.interfaceLanguage], "english")
        let readSnapshot = try await protectingStore.settingsSnapshot(forKeys: [
            .customWorkflows,
            .interfaceLanguage,
        ])
        XCTAssertNil(readSnapshot.values[.customWorkflows])
        XCTAssertEqual(readSnapshot.values[.interfaceLanguage], "english")
        XCTAssertEqual(readSnapshot.unavailableKeys, [.customWorkflows])
        let blockedResult = await protectingStore.currentMigrationResult()
        XCTAssertEqual(
            blockedResult,
            .blocked(.secureValueConflict(reference))
        )
        do {
            try await protectingStore.removeValue(forKey: .workflowEnabledStates)
            XCTFail("Expected enabled-state writes to remain locked")
        } catch {
            XCTAssertEqual(
                error as? WebhookProtectingSettingsStoreError,
                .workflowLibraryLocked
            )
        }
        try await protectingStore.setString("simplifiedChinese", forKey: .interfaceLanguage)
        let updatedLanguage = try await protectingStore.string(forKey: .interfaceLanguage)
        XCTAssertEqual(updatedLanguage, "simplifiedChinese")
    }
}

private enum WebhookMigrationTestError: Error {
    case requestedFailure
}

private actor WebhookMigrationOperationLog {
    private var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }

    func snapshot() -> [String] {
        entries
    }
}

private struct WebhookMigrationSettingsSnapshot {
    let storage: [AppSettingKey: String]
    let atomicWriteCount: Int
    let purgeCount: Int
}

private actor WebhookMigrationSettingsStore: SensitiveSettingsStore {
    private var storage: [AppSettingKey: String]
    private var failPurge: Bool
    private var atomicWriteCount = 0
    private var purgeCount = 0
    private let failAtomicWriteCalls: Set<Int>
    private let operationLog: WebhookMigrationOperationLog?

    init(
        storage: [AppSettingKey: String] = [:],
        failPurge: Bool = false,
        failAtomicWriteCalls: Set<Int> = [],
        operationLog: WebhookMigrationOperationLog? = nil
    ) {
        self.storage = storage
        self.failPurge = failPurge
        self.failAtomicWriteCalls = failAtomicWriteCalls
        self.operationLog = operationLog
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        await operationLog?.append("settings.read")
        return keys.reduce(into: [:]) { values, key in
            values[key] = storage[key]
        }
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        storage[key] = value
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        await operationLog?.append("settings.atomic")
        atomicWriteCount += 1
        if failAtomicWriteCalls.contains(atomicWriteCount) {
            throw WebhookMigrationTestError.requestedFailure
        }
        for (key, value) in values {
            storage[key] = value
        }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        storage.removeValue(forKey: key)
    }

    func purgeSensitiveStorageResidue() async throws {
        await operationLog?.append("settings.purge")
        purgeCount += 1
        if failPurge {
            throw WebhookMigrationTestError.requestedFailure
        }
    }

    func setFailPurge(_ value: Bool) {
        failPurge = value
    }

    func snapshot() -> WebhookMigrationSettingsSnapshot {
        WebhookMigrationSettingsSnapshot(
            storage: storage,
            atomicWriteCount: atomicWriteCount,
            purgeCount: purgeCount
        )
    }
}

private actor WebhookMigrationSecureStore: SecureWebhookConfigurationStore {
    private var storage: [WebhookConfigurationReference: WebhookProtectedConfiguration]
    private let failWrites: Bool
    private var operations = 0
    private var writes = 0
    private let operationLog: WebhookMigrationOperationLog?

    init(
        storage: [WebhookConfigurationReference: WebhookProtectedConfiguration] = [:],
        failWrites: Bool = false,
        operationLog: WebhookMigrationOperationLog? = nil
    ) {
        self.storage = storage
        self.failWrites = failWrites
        self.operationLog = operationLog
    }

    func configuration(
        for reference: WebhookConfigurationReference
    ) async throws -> WebhookProtectedConfiguration? {
        operations += 1
        await operationLog?.append("secure.read:\(reference.rawValue)")
        return storage[reference]
    }

    func setConfiguration(
        _ configuration: WebhookProtectedConfiguration,
        for reference: WebhookConfigurationReference
    ) async throws {
        operations += 1
        writes += 1
        await operationLog?.append("secure.set:\(reference.rawValue)")
        if failWrites {
            throw WebhookMigrationTestError.requestedFailure
        }
        storage[reference] = configuration
    }

    func storedConfiguration(
        for reference: WebhookConfigurationReference
    ) -> WebhookProtectedConfiguration? {
        storage[reference]
    }

    func operationCount() -> Int {
        operations
    }

    func setCount() -> Int {
        writes
    }
}

private func makeWebhookWorkflow(
    id: UUID,
    url: String,
    headersJSON: String? = nil
) -> WorkflowDefinition {
    var configuration = [ExternalOutputActionConfigurationKey.webhookURL: url]
    if let headersJSON {
        configuration[ExternalOutputActionConfigurationKey.webhookHeadersJSON] = headersJSON
    }
    return WorkflowDefinition(
        id: id,
        name: "Legacy Webhook",
        pipeline: PipelineDeclaration(
            recognizerID: "test.recognizer",
            outputActions: [
                OutputActionReference(
                    id: ExternalOutputActionID.webhookPost,
                    configuration: configuration
                ),
            ]
        ),
        ui: WorkflowUIConfig(symbolName: "network", accentColorName: "orange")
    )
}

private func encode<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decodeWorkflows(_ rawValue: String?) throws -> [WorkflowDefinition] {
    guard let rawValue else { return [] }
    return try JSONDecoder().decode([WorkflowDefinition].self, from: Data(rawValue.utf8))
}

private func decodeEnabledStates(_ rawValue: String?) throws -> [String: Bool] {
    guard let rawValue else { return [:] }
    return try JSONDecoder().decode([String: Bool].self, from: Data(rawValue.utf8))
}
