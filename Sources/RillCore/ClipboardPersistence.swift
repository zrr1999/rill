import Foundation

/// The immutable coordinate of one protected clipboard image payload.
///
/// Blob identifiers are random generation identities, not content hashes. This
/// lets metadata-only clipboard mutations retain an existing encrypted payload
/// without exposing a dictionary-testable digest or rewriting the image.
public struct ClipboardPersistenceBlobReference: Sendable, Equatable, Hashable {
    public let blobID: UUID
    public let itemID: UUID
    public let byteCount: Int

    /// Callers must provide a positive byte count. Repository implementations
    /// validate this at their trust boundary before sealing or writing data.
    public init(blobID: UUID, itemID: UUID, byteCount: Int) {
        self.blobID = blobID
        self.itemID = itemID
        self.byteCount = byteCount
    }
}

public struct ClipboardPersistenceImageBlob: Sendable, Equatable {
    public let reference: ClipboardPersistenceBlobReference
    public let payload: Data

    public init(reference: ClipboardPersistenceBlobReference, payload: Data) {
        self.reference = reference
        self.payload = payload
    }
}

/// One authoritative read from the protected clipboard repository.
///
/// `legacy` is the original schema-7 settings row. A repository must never
/// choose between legacy and current state when both exist; that conflict is a
/// structural storage failure and must be thrown instead.
public enum ClipboardPersistenceReadSnapshot: Sendable, Equatable {
    case empty
    case legacy(metadata: Data)
    case current(
        revision: Int64,
        metadata: Data,
        imageBlobs: [ClipboardPersistenceImageBlob]
    )
}

/// A complete next clipboard snapshot expressed without retransmitting images
/// that are already durable under the same immutable blob identity.
public struct ClipboardPersistenceWriteSnapshot: Sendable, Equatable {
    /// `nil` admits only an empty or legacy repository. Current snapshots use a
    /// compare-and-swap revision so a stale writer cannot overwrite a newer one.
    public let expectedRevision: Int64?
    public let metadata: Data
    public let newImageBlobs: [ClipboardPersistenceImageBlob]
    public let retainedImageBlobReferences: [ClipboardPersistenceBlobReference]

    public init(
        expectedRevision: Int64?,
        metadata: Data,
        newImageBlobs: [ClipboardPersistenceImageBlob],
        retainedImageBlobReferences: [ClipboardPersistenceBlobReference]
    ) {
        self.expectedRevision = expectedRevision
        self.metadata = metadata
        self.newImageBlobs = newImageBlobs
        self.retainedImageBlobReferences = retainedImageBlobReferences
    }
}

public enum ClipboardPersistenceRemovalResult: Sendable, Equatable {
    /// Logical deletion and sensitive-residue cleanup both completed.
    case removed
    /// Logical deletion committed atomically. A durable cleanup marker remains
    /// so database/WAL residue is retried on the next repository open.
    case removedCleanupPending
}

/// A single-owner repository for the clipboard metadata graph and its image
/// blobs. Implementations must make replace/remove operations atomic.
public protocol ClipboardPersistenceStore: Sendable {
    func loadClipboardPersistence() async throws -> ClipboardPersistenceReadSnapshot

    /// Atomically commits metadata, new immutable blobs, retained references,
    /// stale-blob deletion, and legacy-row removal. Returns the committed CAS
    /// revision even if the caller's in-memory graph changed while awaiting I/O.
    func replaceClipboardPersistence(
        with snapshot: ClipboardPersistenceWriteSnapshot
    ) async throws -> Int64

    /// Atomically removes current metadata, all image blobs, and any legacy row.
    func removeClipboardPersistence() async throws -> ClipboardPersistenceRemovalResult
}
