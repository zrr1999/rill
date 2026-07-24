import XCTest
@testable import RillCore
@testable import RillRuntime

actor RuntimeTestSettingsStore: SettingsStore, ClipboardPersistenceStore {
    enum StoreError: Error {
        case readFailed
        case writeFailed
    }

    var storage: [AppSettingKey: String] = [:]
    var writeCounts: [AppSettingKey: Int] = [:]
    var unavailableKeys: Set<AppSettingKey> = []
    var remainingWriteFailures: Int
    var remainingRemovalFailures: Int
    var clipboardRemovalResult: ClipboardPersistenceRemovalResult
    var writeAttempts = 0
    var removalAttempts = 0
    var currentMetadata: Data?
    var currentRevision: Int64?
    var imageBlobsByID: [UUID: ClipboardPersistenceImageBlob] = [:]

    init(
        storage: [AppSettingKey: String] = [:],
        unavailableKeys: Set<AppSettingKey> = [],
        remainingWriteFailures: Int = 0,
        remainingRemovalFailures: Int = 0,
        clipboardRemovalResult: ClipboardPersistenceRemovalResult = .removed
    ) {
        self.storage = storage
        self.unavailableKeys = unavailableKeys
        self.remainingWriteFailures = remainingWriteFailures
        self.remainingRemovalFailures = remainingRemovalFailures
        self.clipboardRemovalResult = clipboardRemovalResult
        if let rawState = storage[.clipboardPersistedState] {
            let data = Data(rawState.utf8)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["schemaVersion"] as? Int == 8 {
                currentMetadata = data
                currentRevision = 1
            }
        }
    }

    func string(forKey key: AppSettingKey) async throws -> String? {
        storage[key]
    }

    func settingsSnapshot(
        forKeys keys: [AppSettingKey]
    ) async throws -> SettingsStoreReadSnapshot {
        let requestedKeys = Set(keys)
        return SettingsStoreReadSnapshot(
            values: storage.filter { requestedKeys.contains($0.key) },
            unavailableKeys: unavailableKeys.intersection(requestedKeys)
        )
    }

    func setString(_ value: String, forKey key: AppSettingKey) async throws {
        writeAttempts += 1
        if remainingWriteFailures > 0 {
            remainingWriteFailures -= 1
            throw StoreError.writeFailed
        }
        storage[key] = value
        if key == .clipboardPersistedState {
            currentMetadata = nil
            currentRevision = nil
            imageBlobsByID.removeAll()
        }
        writeCounts[key, default: 0] += 1
    }

    func setStringsAtomically(_ values: [AppSettingKey: String]) async throws {
        for (key, value) in values {
            storage[key] = value
            writeCounts[key, default: 0] += 1
        }
        if values[.clipboardPersistedState] != nil {
            currentMetadata = nil
            currentRevision = nil
            imageBlobsByID.removeAll()
        }
    }

    func removeValue(forKey key: AppSettingKey) async throws {
        removalAttempts += 1
        if remainingRemovalFailures > 0 {
            remainingRemovalFailures -= 1
            throw StoreError.writeFailed
        }
        storage.removeValue(forKey: key)
        unavailableKeys.remove(key)
        if key == .clipboardPersistedState {
            currentMetadata = nil
            currentRevision = nil
            imageBlobsByID.removeAll()
        }
    }

    func writeCount(forKey key: AppSettingKey) -> Int {
        writeCounts[key, default: 0]
    }

    func writeAttemptCount() -> Int {
        writeAttempts
    }

    func removalAttemptCount() -> Int {
        removalAttempts
    }

    func storedString(forKey key: AppSettingKey) -> String? {
        storage[key]
    }

    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot {
        guard !unavailableKeys.contains(.clipboardPersistedState) else {
            throw StoreError.readFailed
        }
        if let currentMetadata, let currentRevision {
            return .current(
                revision: currentRevision,
                metadata: currentMetadata,
                imageBlobs: imageBlobsByID.values.sorted {
                    $0.reference.blobID.uuidString < $1.reference.blobID.uuidString
                }
            )
        }
        guard let legacy = storage[.clipboardPersistedState] else {
            return .empty
        }
        return .legacy(metadata: Data(legacy.utf8))
    }

    func replaceClipboardPersistence(
        with snapshot: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64 {
        writeAttempts += 1
        if remainingWriteFailures > 0 {
            remainingWriteFailures -= 1
            throw StoreError.writeFailed
        }
        guard snapshot.expectedRevision == currentRevision else {
            throw StoreError.writeFailed
        }

        var nextBlobs: [UUID: ClipboardPersistenceImageBlob] = [:]
        for reference in snapshot.retainedImageBlobReferences {
            guard let blob = imageBlobsByID[reference.blobID],
                  blob.reference == reference else {
                throw StoreError.writeFailed
            }
            nextBlobs[reference.blobID] = blob
        }
        for blob in snapshot.newImageBlobs {
            guard blob.payload.count == blob.reference.byteCount,
                  imageBlobsByID[blob.reference.blobID] == nil,
                  nextBlobs[blob.reference.blobID] == nil else {
                throw StoreError.writeFailed
            }
            nextBlobs[blob.reference.blobID] = blob
        }

        let nextRevision = (currentRevision ?? 0) + 1
        currentMetadata = snapshot.metadata
        currentRevision = nextRevision
        imageBlobsByID = nextBlobs
        storage[.clipboardPersistedState] = String(decoding: snapshot.metadata, as: UTF8.self)
        unavailableKeys.remove(.clipboardPersistedState)
        writeCounts[.clipboardPersistedState, default: 0] += 1
        return nextRevision
    }

    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult {
        removalAttempts += 1
        if remainingRemovalFailures > 0 {
            remainingRemovalFailures -= 1
            throw StoreError.writeFailed
        }
        storage.removeValue(forKey: .clipboardPersistedState)
        unavailableKeys.remove(.clipboardPersistedState)
        currentMetadata = nil
        currentRevision = nil
        imageBlobsByID.removeAll()
        return clipboardRemovalResult
    }
}

struct LegacyPersistedClipboardState: Codable {
    struct GroupEntry: Codable {
        var groupID: UUID
        var itemIDs: [UUID]
    }

    var schemaVersion: Int
    var items: [ClipboardHistoryItem]
    var groups: [ClipboardGroup]
    var groupEntries: [GroupEntry]
    var defaultGroupEntries: [UUID]?
    var defaultGroupMode: ClipboardPasteMode?
    var appAssignments: [ClipboardAppAssignment]
}

final class DeliveryStackTests: XCTestCase {
}
