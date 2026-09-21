import Foundation
import Observation
import RillCore

@MainActor @Observable
public final class ContextMemoryModel {
    public private(set) var settings = ContextFeatureSettings()
    public private(set) var memories: [LongTermMemory] = []
    public private(set) var status = MemoryMaintenanceStatus()
    public private(set) var isLoading = true
    public private(set) var isSaving = false
    public private(set) var isAuthorized = false
    public private(set) var hasScreenPermission = false
    public private(set) var error: String?
    private let repository: any ContextMemoryRepository
    private let settingsStore: any SettingsStore
    private let activate: @MainActor (ContextFeatureSettings) async throws -> Bool
    private let revoke: @MainActor () -> Void
    private let fingerprint: @MainActor () async throws -> String
    private let screenPermission: @MainActor (Bool) -> Bool
    private let maintain: @MainActor () -> Void
    private var loadTask: Task<Void, Never>?
    private let writes = PersistenceWriteCoordinator()
    private var settingsWrite: Task<Void, Error>?
    private var revision = 0
    private var stopped = false

    public init(repository: any ContextMemoryRepository, settingsStore: any SettingsStore,
                activate: @escaping @MainActor (ContextFeatureSettings) async throws -> Bool,
                revoke: @escaping @MainActor () -> Void,
                fingerprint: @escaping @MainActor () async throws -> String,
                screenPermission: @escaping @MainActor (Bool) -> Bool,
                maintain: @escaping @MainActor () -> Void) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.activate = activate
        self.revoke = revoke
        self.fingerprint = fingerprint
        self.screenPermission = screenPermission
        self.maintain = maintain
    }

    public func load() {
        guard loadTask == nil else { return }
        let revision = revision
        loadTask = Task {
            defer { isLoading = false; loadTask = nil }
            do {
                if let value = try await settingsStore.string(forKey: .contextFeatureSettings) {
                    let loaded = try JSONDecoder().decode(ContextFeatureSettings.self, from: Data(value.utf8))
                    guard revision == self.revision, !stopped else { return }
                    settings = loaded
                }
                try Task.checkCancellation()
                guard revision == self.revision, !stopped else { return }
                let authorized = try await activate(settings)
                guard revision == self.revision, !stopped else { return }
                isAuthorized = authorized
                hasScreenPermission = screenPermission(false)
                await refresh()
            } catch is CancellationError { return }
            catch {
                self.error = "Context settings could not be loaded. 上下文设置读取失败。"
            }
        }
    }

    public func invalidateAuthorization() {
        _ = suspendAuthorization()
        settings.providerFingerprint = nil
        let value = settings
        let write = persist(value)
        let task = Task {
            do { try await write.value }
            catch { self.error = "Authorization revocation could not be saved. 撤权设置保存失败。" }
        }
        writes.track(task)
    }

    private func suspendAuthorization() -> Int {
        revision += 1
        revoke()
        isAuthorized = false
        return revision
    }

    private func persist(_ value: ContextFeatureSettings) -> Task<Void, Error> {
        let previous = settingsWrite
        let task = Task { [settingsStore] in
            _ = try? await previous?.value
            let encoded = try JSONEncoder().encode(value)
            try await settingsStore.setString(String(decoding: encoded, as: UTF8.self), forKey: .contextFeatureSettings)
        }
        settingsWrite = task
        return task
    }

    public func apply(screen: Bool, memory: Bool, workflowIDs: Set<UUID>) {
        guard !isLoading, !isSaving, !stopped else { return }
        let revision = suspendAuthorization()
        isSaving = true
        let task = Task {
            defer { isSaving = false }
            do {
                var proposed = ContextFeatureSettings()
                proposed.screenContextEnabled = screen
                proposed.memoryEnabled = memory
                proposed.authorizedWorkflowIDs = workflowIDs
                if screen || memory { proposed.providerFingerprint = try await fingerprint() }
                if screen { hasScreenPermission = screenPermission(true) }
                guard revision == self.revision, !stopped else { return }
                try await persist(proposed).value
                guard revision == self.revision, !stopped else { return }
                settings = proposed
                let authorized = try await activate(proposed)
                guard revision == self.revision, !stopped else { return }
                isAuthorized = authorized
                error = nil
            } catch {
                self.error = "Context settings could not be saved or authorized. 上下文设置保存或授权失败。"
            }
        }
        writes.track(task)
    }

    public func refresh() async {
        do {
            memories = try await repository.memories()
            status = try await repository.memoryMaintenanceStatus(now: Date())
            hasScreenPermission = screenPermission(false)
        } catch { self.error = "Memory storage is unavailable. 记忆存储不可用。" }
    }

    public func save(_ memory: LongTermMemory) async {
        await mutateMemory { [repository] in
            try await repository.saveMemory(memory, expectedRevision: memory.revision)
        }
    }

    public func delete(_ memory: LongTermMemory) async {
        await mutateMemory { [repository] in
            try await repository.deleteMemory(id: memory.id, expectedRevision: memory.revision)
        }
    }

    private func mutateMemory(_ operation: @escaping @Sendable () async throws -> Void) async {
        guard !stopped else { return }
        let revision = suspendAuthorization()
        let task = Task {
            do {
                try await operation()
                guard revision == self.revision, !stopped else { return }
                let authorized = try await activate(settings)
                guard revision == self.revision, !stopped else { return }
                isAuthorized = authorized
                await refresh()
            } catch { self.error = "Memory could not be changed. 请刷新后重试。" }
        }
        writes.track(task)
        await task.value
    }

    public func recordCorrection(_ correction: ConfirmedMemoryCorrection, recordID: UUID) {
        let task = Task {
            do { try await repository.recordUserCorrection(correction, recordID: recordID) }
            catch { self.error = "Correction could not be linked to history. 无法将纠正关联到历史。" }
        }
        writes.track(task)
    }

    public func scheduleMaintenance() { maintain() }

    public func shutdown() async {
        stopped = true
        _ = suspendAuthorization()
        loadTask?.cancel()
        await loadTask?.value
        await writes.flush()
        _ = try? await settingsWrite?.value
        _ = suspendAuthorization()
    }
}
