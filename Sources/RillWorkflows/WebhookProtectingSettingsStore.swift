import Foundation
import RillCore

public enum WebhookConfigurationProtectionState: String, Sendable, Equatable {
    case pendingV1 = "pending-v1"
    case completeV1 = "complete-v1"
}

public enum WebhookConfigurationMigrationBlockReason: Sendable, Equatable {
    case settingsReadFailed
    case invalidWorkflowLibrary
    case duplicateWorkflowID(UUID)
    case invalidWorkflowEnabledStates
    case invalidSecureReference(workflowID: UUID, actionIndex: Int)
    case secureReadFailed(WebhookConfigurationReference)
    case secureWriteFailed(WebhookConfigurationReference)
    case secureVerificationFailed(WebhookConfigurationReference)
    case secureValueConflict(WebhookConfigurationReference)
    case settingsWriteFailed
}

public enum WebhookConfigurationMigrationResult: Sendable, Equatable {
    case ready(protectedActionCount: Int)
    case purgePending(protectedActionCount: Int)
    case blocked(WebhookConfigurationMigrationBlockReason)

    public var allowsWorkflowLibraryReads: Bool {
        switch self {
        case .ready, .purgePending:
            return true
        case .blocked:
            return false
        }
    }

    public var allowsWorkflowLibraryWrites: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum WebhookConfigurationMigrationEvent: Sendable, Equatable {
    case completed(protectedActionCount: Int)
    case purgePending(protectedActionCount: Int)
    case blocked(WebhookConfigurationMigrationBlockReason)
}

public actor WebhookConfigurationMigrator {
    public typealias EventReporter = @Sendable (WebhookConfigurationMigrationEvent) async -> Void

    private struct MigrationPlan: Sendable {
        let workflowIndex: Int
        let actionIndex: Int
        let reference: WebhookConfigurationReference
        let protectedConfiguration: WebhookProtectedConfiguration
    }

    private let settingsStore: any SensitiveSettingsStore
    private let secureStore: any SecureWebhookConfigurationStore
    private let eventReporter: EventReporter

    public init(
        settingsStore: any SensitiveSettingsStore,
        secureStore: any SecureWebhookConfigurationStore,
        eventReporter: @escaping EventReporter = { _ in }
    ) {
        self.settingsStore = settingsStore
        self.secureStore = secureStore
        self.eventReporter = eventReporter
    }

    public func migrateIfNeeded() async -> WebhookConfigurationMigrationResult {
        let storedValues: [AppSettingKey: String]
        do {
            storedValues = try await settingsStore.strings(forKeys: [
                .customWorkflows,
                .workflowLibrary,
                .workflowEnabledStates,
                .webhookConfigurationProtectionState,
            ])
        } catch {
            return await block(.settingsReadFailed)
        }

        let workflows: [WorkflowDefinition]
        let workflowLibrary: WorkflowLibraryDocument?
        do {
            if let rawLibrary = storedValues[.workflowLibrary], !rawLibrary.isEmpty {
                let decodedLibrary = try JSONDecoder().decode(
                    WorkflowLibraryDocument.self,
                    from: Data(rawLibrary.utf8)
                )
                workflowLibrary = decodedLibrary
                workflows = decodedLibrary.customWorkflows
            } else {
                workflowLibrary = nil
                workflows = try Self.decodeWorkflows(storedValues[.customWorkflows])
            }
        } catch {
            return await block(.invalidWorkflowLibrary)
        }

        var seenWorkflowIDs: Set<UUID> = []
        for workflow in workflows where !seenWorkflowIDs.insert(workflow.id).inserted {
            return await block(.duplicateWorkflowID(workflow.id))
        }

        var enabledStates: [String: Bool]
        do {
            enabledStates = try Self.decodeEnabledStates(storedValues[.workflowEnabledStates])
        } catch {
            return await block(.invalidWorkflowEnabledStates)
        }
        let originalEnabledStates = enabledStates

        var plans: [MigrationPlan] = []
        var secureReferences: Set<WebhookConfigurationReference> = []
        var seenSecureReferences: Set<WebhookConfigurationReference> = []
        var webhookWorkflowIDs: Set<UUID> = []

        for (workflowIndex, workflow) in workflows.enumerated() {
            for (actionIndex, action) in workflow.plan.output.actions.enumerated() {
                guard action.id == ExternalOutputActionID.webhookPost else { continue }
                webhookWorkflowIDs.insert(workflow.id)

                guard
                    let expectedReference = WebhookConfigurationReference(
                        workflowID: workflow.id,
                        actionIndex: actionIndex
                    )
                else {
                    return await block(
                        .invalidSecureReference(workflowID: workflow.id, actionIndex: actionIndex)
                    )
                }
                let storedReference: WebhookConfigurationReference?
                if let rawReference = action.configuration[
                    ExternalOutputActionConfigurationKey.webhookSecureReference
                ] {
                    guard
                        let reference = WebhookConfigurationReference(rawValue: rawReference),
                        reference.workflowID == workflow.id
                    else {
                        return await block(
                            .invalidSecureReference(
                                workflowID: workflow.id, actionIndex: actionIndex)
                        )
                    }
                    storedReference = reference
                } else {
                    storedReference = nil
                }

                let protectedConfiguration: WebhookProtectedConfiguration?
                do {
                    protectedConfiguration = try WebhookProtectedConfiguration.extractingPlaintext(
                        from: action.configuration
                    )
                } catch {
                    return await block(.invalidWorkflowLibrary)
                }
                let resolvedReference =
                    storedReference ?? (protectedConfiguration == nil ? nil : expectedReference)
                if let resolvedReference {
                    guard seenSecureReferences.insert(resolvedReference).inserted else {
                        return await block(
                            .invalidSecureReference(
                                workflowID: workflow.id, actionIndex: actionIndex)
                        )
                    }
                    secureReferences.insert(resolvedReference)
                }
                guard
                    let protectedConfiguration,
                    let resolvedReference
                else { continue }
                plans.append(
                    MigrationPlan(
                        workflowIndex: workflowIndex,
                        actionIndex: actionIndex,
                        reference: resolvedReference,
                        protectedConfiguration: protectedConfiguration
                    )
                )
            }
        }

        for workflowID in webhookWorkflowIDs {
            let matchingKeys = enabledStates.keys.filter { UUID(uuidString: $0) == workflowID }
            for key in matchingKeys {
                enabledStates.removeValue(forKey: key)
            }
            enabledStates[workflowID.uuidString] = false
        }

        for plan in plans {
            let existing: WebhookProtectedConfiguration?
            do {
                existing = try await secureStore.configuration(for: plan.reference)
            } catch {
                return await block(.secureReadFailed(plan.reference))
            }

            if let existing {
                guard existing == plan.protectedConfiguration else {
                    return await block(.secureValueConflict(plan.reference))
                }
                continue
            }

            do {
                try await secureStore.setConfiguration(
                    plan.protectedConfiguration,
                    for: plan.reference
                )
            } catch {
                return await block(.secureWriteFailed(plan.reference))
            }

            do {
                guard
                    try await secureStore.configuration(for: plan.reference)
                        == plan.protectedConfiguration
                else {
                    return await block(.secureVerificationFailed(plan.reference))
                }
            } catch {
                return await block(.secureVerificationFailed(plan.reference))
            }
        }

        let plannedReferences = Set(plans.map(\.reference))
        for reference in secureReferences.subtracting(plannedReferences) {
            do {
                guard try await secureStore.configuration(for: reference) != nil else {
                    return await block(.secureVerificationFailed(reference))
                }
            } catch {
                return await block(.secureReadFailed(reference))
            }
        }

        var sanitizedWorkflows = workflows
        for plan in plans {
            var configuration = sanitizedWorkflows[plan.workflowIndex]
                .plan.output.actions[plan.actionIndex].configuration
            configuration.removeValue(forKey: ExternalOutputActionConfigurationKey.webhookURL)
            configuration.removeValue(
                forKey: ExternalOutputActionConfigurationKey.webhookHeadersJSON)
            configuration[ExternalOutputActionConfigurationKey.webhookSecureReference] =
                plan.reference.rawValue
            sanitizedWorkflows[plan.workflowIndex]
                .plan.output.actions[plan.actionIndex].configuration = configuration
        }

        let storedState = storedValues[.webhookConfigurationProtectionState]
            .flatMap(WebhookConfigurationProtectionState.init(rawValue:))
        let protectedActionCount = secureReferences.count
        let requiresPurge =
            !plans.isEmpty
            || storedState == .pendingV1
            || (!secureReferences.isEmpty && storedState != .completeV1)
        let enabledStatesChanged = enabledStates != originalEnabledStates

        var atomicValues: [AppSettingKey: String] = [:]
        do {
            if !plans.isEmpty {
                if var workflowLibrary {
                    workflowLibrary.customWorkflows = sanitizedWorkflows
                    atomicValues[.workflowLibrary] = try Self.encode(workflowLibrary)
                } else {
                    atomicValues[.customWorkflows] = try Self.encode(sanitizedWorkflows)
                }
            }
            if enabledStatesChanged {
                atomicValues[.workflowEnabledStates] = try Self.encode(enabledStates)
            }
        } catch {
            return await block(.invalidWorkflowLibrary)
        }

        if requiresPurge {
            atomicValues[.webhookConfigurationProtectionState] =
                WebhookConfigurationProtectionState.pendingV1.rawValue
        } else if enabledStatesChanged {
            atomicValues[.webhookConfigurationProtectionState] =
                WebhookConfigurationProtectionState.completeV1.rawValue
        }

        if !atomicValues.isEmpty {
            do {
                try await settingsStore.setStringsAtomically(atomicValues)
            } catch {
                return await block(.settingsWriteFailed)
            }
        }

        guard requiresPurge else {
            return await complete(protectedActionCount: protectedActionCount)
        }

        do {
            try await settingsStore.purgeSensitiveStorageResidue()
        } catch {
            return await markPurgePending(protectedActionCount: protectedActionCount)
        }

        do {
            try await settingsStore.setStringsAtomically([
                .webhookConfigurationProtectionState:
                    WebhookConfigurationProtectionState.completeV1.rawValue
            ])
        } catch {
            return await markPurgePending(protectedActionCount: protectedActionCount)
        }

        return await complete(protectedActionCount: protectedActionCount)
    }

    private func block(
        _ reason: WebhookConfigurationMigrationBlockReason
    ) async -> WebhookConfigurationMigrationResult {
        await eventReporter(.blocked(reason))
        return .blocked(reason)
    }

    private func markPurgePending(
        protectedActionCount: Int
    ) async -> WebhookConfigurationMigrationResult {
        await eventReporter(.purgePending(protectedActionCount: protectedActionCount))
        return .purgePending(protectedActionCount: protectedActionCount)
    }

    private func complete(
        protectedActionCount: Int
    ) async -> WebhookConfigurationMigrationResult {
        await eventReporter(.completed(protectedActionCount: protectedActionCount))
        return .ready(protectedActionCount: protectedActionCount)
    }

    private static func decodeWorkflows(_ rawValue: String?) throws -> [WorkflowDefinition] {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return try JSONDecoder().decode([WorkflowDefinition].self, from: Data(rawValue.utf8))
    }

    private static func decodeEnabledStates(_ rawValue: String?) throws -> [String: Bool] {
        guard let rawValue, !rawValue.isEmpty else { return [:] }
        return try JSONDecoder().decode([String: Bool].self, from: Data(rawValue.utf8))
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum WebhookProtectingSettingsStoreError: Error, LocalizedError, Sendable, Equatable {
    case workflowLibraryLocked
    case reservedProtectionState
    case plaintextWorkflowWriteRejected
    case invalidWorkflowEnabledStatesWrite

    public var errorDescription: String? {
        switch self {
        case .workflowLibraryLocked:
            return
                "Workflow library writes are locked until Webhook configuration protection succeeds."
        case .reservedProtectionState:
            return "Webhook configuration protection state is managed internally."
        case .plaintextWorkflowWriteRejected:
            return "Plaintext Webhook configuration cannot be written to settings storage."
        case .invalidWorkflowEnabledStatesWrite:
            return "Workflow enabled states are not valid JSON."
        }
    }
}

public actor WebhookProtectingSettingsStore: SettingsStore {
    private let settingsStore: any SensitiveSettingsStore
    private let migrator: WebhookConfigurationMigrator
    private var migrationResult: WebhookConfigurationMigrationResult?

    public init(
        settingsStore: any SensitiveSettingsStore,
        secureStore: any SecureWebhookConfigurationStore,
        eventReporter: @escaping WebhookConfigurationMigrator.EventReporter = { _ in }
    ) {
        self.settingsStore = settingsStore
        self.migrator = WebhookConfigurationMigrator(
            settingsStore: settingsStore,
            secureStore: secureStore,
            eventReporter: eventReporter
        )
    }

    public func string(forKey key: AppSettingKey) async throws -> String? {
        if key == .webhookConfigurationProtectionState {
            return nil
        }
        if Self.requiresProtection(for: key) {
            let result = await ensureProtection()
            if key == .customWorkflows || key == .workflowLibrary,
                !result.allowsWorkflowLibraryReads
            {
                return nil
            }
        }
        return try await settingsStore.string(forKey: key)
    }

    public func strings(forKeys keys: [AppSettingKey]) async throws -> [AppSettingKey: String] {
        let result =
            keys.contains(where: { Self.requiresProtection(for: $0) })
            ? await ensureProtection()
            : nil
        var values = try await settingsStore.strings(forKeys: keys)
        if let result, !result.allowsWorkflowLibraryReads {
            values.removeValue(forKey: .customWorkflows)
            values.removeValue(forKey: .workflowLibrary)
        }
        values.removeValue(forKey: .webhookConfigurationProtectionState)
        return values
    }

    public func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let result =
            keys.contains(where: { Self.requiresProtection(for: $0) })
            ? await ensureProtection()
            : nil
        let storedSnapshot = try await settingsStore.settingsSnapshot(forKeys: keys)
        var values = storedSnapshot.values
        var unavailableKeys = storedSnapshot.unavailableKeys
        if let result, !result.allowsWorkflowLibraryReads {
            if keys.contains(.customWorkflows) {
                values.removeValue(forKey: .customWorkflows)
                unavailableKeys.insert(.customWorkflows)
            }
            if keys.contains(.workflowLibrary) {
                values.removeValue(forKey: .workflowLibrary)
                unavailableKeys.insert(.workflowLibrary)
            }
        }
        values.removeValue(forKey: .webhookConfigurationProtectionState)
        unavailableKeys.remove(.webhookConfigurationProtectionState)
        return SettingsStoreReadSnapshot(
            values: values,
            unavailableKeys: unavailableKeys
        )
    }

    public func setString(_ value: String, forKey key: AppSettingKey) async throws {
        try rejectReservedKey(key)
        try await authorizeWrite(to: [key])
        if key == .customWorkflows || key == .workflowLibrary {
            try Self.rejectPlaintextWebhookConfiguration(in: value, key: key)
            let webhookWorkflowIDs = try Self.webhookWorkflowIDs(in: value, key: key)
            guard !webhookWorkflowIDs.isEmpty else {
                try await settingsStore.setString(value, forKey: key)
                return
            }
            let rawEnabledStates = try await settingsStore.string(forKey: .workflowEnabledStates)
            let enabledStates = try Self.protectedEnabledStatesValue(
                rawEnabledStates,
                webhookWorkflowIDs: webhookWorkflowIDs
            )
            try await settingsStore.setStringsAtomically([
                key: value,
                .workflowEnabledStates: enabledStates,
            ])
            return
        }
        if key == .workflowEnabledStates {
            let webhookWorkflowIDs = try await storedWebhookWorkflowIDs()
            let enabledStates = try Self.protectedEnabledStatesValue(
                value,
                webhookWorkflowIDs: webhookWorkflowIDs
            )
            try await settingsStore.setString(enabledStates, forKey: key)
            return
        }
        try await settingsStore.setString(value, forKey: key)
    }

    public func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        if values.keys.contains(.webhookConfigurationProtectionState) {
            throw WebhookProtectingSettingsStoreError.reservedProtectionState
        }
        guard values.keys.contains(where: { Self.requiresProtection(for: $0) }) else {
            try await settingsStore.setStringsAtomically(values)
            return
        }
        try await authorizeWrite(to: Array(values.keys))
        var protectedValues = values
        let webhookWorkflowIDs: Set<UUID>
        if let workflows = values[.workflowLibrary] {
            try Self.rejectPlaintextWebhookConfiguration(
                in: workflows,
                key: .workflowLibrary
            )
            webhookWorkflowIDs = try Self.webhookWorkflowIDs(
                in: workflows,
                key: .workflowLibrary
            )
        } else if let workflows = values[.customWorkflows] {
            try Self.rejectPlaintextWebhookConfiguration(
                in: workflows,
                key: .customWorkflows
            )
            webhookWorkflowIDs = try Self.webhookWorkflowIDs(
                in: workflows,
                key: .customWorkflows
            )
        } else {
            webhookWorkflowIDs = try await storedWebhookWorkflowIDs()
        }
        if let enabledStates = values[.workflowEnabledStates] {
            protectedValues[.workflowEnabledStates] = try Self.protectedEnabledStatesValue(
                enabledStates,
                webhookWorkflowIDs: webhookWorkflowIDs
            )
        } else if values[.customWorkflows] != nil || values[.workflowLibrary] != nil,
            !webhookWorkflowIDs.isEmpty
        {
            let rawEnabledStates = try await settingsStore.string(forKey: .workflowEnabledStates)
            protectedValues[.workflowEnabledStates] = try Self.protectedEnabledStatesValue(
                rawEnabledStates,
                webhookWorkflowIDs: webhookWorkflowIDs
            )
        }
        try await settingsStore.setStringsAtomically(protectedValues)
    }

    public func removeValue(forKey key: AppSettingKey) async throws {
        try rejectReservedKey(key)
        try await authorizeWrite(to: [key])
        if key == .workflowEnabledStates {
            let webhookWorkflowIDs = try await storedWebhookWorkflowIDs()
            guard !webhookWorkflowIDs.isEmpty else {
                try await settingsStore.removeValue(forKey: key)
                return
            }
            let enabledStates = try Self.protectedEnabledStatesValue(
                nil,
                webhookWorkflowIDs: webhookWorkflowIDs
            )
            try await settingsStore.setString(enabledStates, forKey: key)
            return
        }
        try await settingsStore.removeValue(forKey: key)
    }

    @discardableResult
    public func retryProtection() async -> WebhookConfigurationMigrationResult {
        let result = await migrator.migrateIfNeeded()
        migrationResult = result
        return result
    }

    public func currentMigrationResult() -> WebhookConfigurationMigrationResult? {
        migrationResult
    }

    private func ensureProtection() async -> WebhookConfigurationMigrationResult {
        if let migrationResult { return migrationResult }
        return await retryProtection()
    }

    private func authorizeWrite(to keys: [AppSettingKey]) async throws {
        guard keys.contains(where: { Self.requiresProtection(for: $0) }) else { return }
        guard (await ensureProtection()).allowsWorkflowLibraryWrites else {
            throw WebhookProtectingSettingsStoreError.workflowLibraryLocked
        }
    }

    private func rejectReservedKey(_ key: AppSettingKey) throws {
        if key == .webhookConfigurationProtectionState {
            throw WebhookProtectingSettingsStoreError.reservedProtectionState
        }
    }

    private static func requiresProtection(for key: AppSettingKey) -> Bool {
        key == .customWorkflows || key == .workflowLibrary
            || key == .workflowEnabledStates
    }

    private static func rejectPlaintextWebhookConfiguration(
        in rawValue: String,
        key: AppSettingKey = .customWorkflows
    ) throws {
        let workflows: [WorkflowDefinition]
        do {
            workflows =
                key == .workflowLibrary
                ? try decodeWorkflowLibrary(rawValue).customWorkflows
                : try JSONDecoder().decode(
                    [WorkflowDefinition].self,
                    from: Data(rawValue.utf8)
                )
        } catch {
            throw WebhookProtectingSettingsStoreError.plaintextWorkflowWriteRejected
        }
        let containsPlaintext = workflows.contains { workflow in
            workflow.plan.output.actions.contains { action in
                action.id == ExternalOutputActionID.webhookPost
                    && (action.configuration.keys.contains(
                        ExternalOutputActionConfigurationKey.webhookURL
                    )
                        || action.configuration.keys.contains(
                            ExternalOutputActionConfigurationKey.webhookHeadersJSON
                        ))
            }
        }
        if containsPlaintext {
            throw WebhookProtectingSettingsStoreError.plaintextWorkflowWriteRejected
        }
    }

    private func storedWebhookWorkflowIDs() async throws -> Set<UUID> {
        if let rawLibrary = try await settingsStore.string(forKey: .workflowLibrary),
            !rawLibrary.isEmpty
        {
            return try Self.webhookWorkflowIDs(in: rawLibrary, key: .workflowLibrary)
        }
        let rawWorkflows = try await settingsStore.string(forKey: .customWorkflows)
        return try Self.webhookWorkflowIDs(in: rawWorkflows)
    }

    private static func webhookWorkflowIDs(
        in rawValue: String?,
        key: AppSettingKey = .customWorkflows
    ) throws -> Set<UUID> {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        let workflows: [WorkflowDefinition]
        do {
            workflows =
                key == .workflowLibrary
                ? try decodeWorkflowLibrary(rawValue).customWorkflows
                : try JSONDecoder().decode(
                    [WorkflowDefinition].self,
                    from: Data(rawValue.utf8)
                )
        } catch {
            throw WebhookProtectingSettingsStoreError.plaintextWorkflowWriteRejected
        }
        return Set(
            workflows.compactMap { workflow in
                workflow.plan.output.actions.contains(where: {
                    $0.id == ExternalOutputActionID.webhookPost
                }) ? workflow.id : nil
            })
    }

    private static func decodeWorkflowLibrary(
        _ rawValue: String
    ) throws -> WorkflowLibraryDocument {
        try JSONDecoder().decode(
            WorkflowLibraryDocument.self,
            from: Data(rawValue.utf8)
        )
    }

    private static func protectedEnabledStatesValue(
        _ rawValue: String?,
        webhookWorkflowIDs: Set<UUID>
    ) throws -> String {
        var enabledStates: [String: Bool]
        do {
            if let rawValue, !rawValue.isEmpty {
                enabledStates = try JSONDecoder().decode(
                    [String: Bool].self,
                    from: Data(rawValue.utf8)
                )
            } else {
                enabledStates = [:]
            }
        } catch {
            throw WebhookProtectingSettingsStoreError.invalidWorkflowEnabledStatesWrite
        }
        for workflowID in webhookWorkflowIDs {
            let matchingKeys = enabledStates.keys.filter { UUID(uuidString: $0) == workflowID }
            for key in matchingKeys {
                enabledStates.removeValue(forKey: key)
            }
            enabledStates[workflowID.uuidString] = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(enabledStates), as: UTF8.self)
    }
}
