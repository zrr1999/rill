import Foundation

/// Coordinates for an image blob in the pre-Record graph. These values only
/// cross the one-way migration boundary and are never exposed by the Record
/// runtime after migration succeeds.
public struct LegacyRecordGraphBlobReference: Sendable, Equatable, Hashable {
    public let blobID: UUID
    public let itemID: UUID
    public let byteCount: Int

    public init(blobID: UUID, itemID: UUID, byteCount: Int) {
        self.blobID = blobID
        self.itemID = itemID
        self.byteCount = byteCount
    }
}

public struct LegacyRecordGraphImageBlob: Sendable, Equatable {
    public let reference: LegacyRecordGraphBlobReference
    public let payload: Data

    public init(reference: LegacyRecordGraphBlobReference, payload: Data) {
        self.reference = reference
        self.payload = payload
    }
}

public enum RecordGraphRemovalResult: Sendable, Equatable {
    case removed
    case removedCleanupPending
}
