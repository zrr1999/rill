import Foundation

/// A centralized admission budget for content retained by the local clipboard store.
///
/// The limits are intentionally independent from age retention. Age cleanup may
/// remove only history-only items, while this budget also prevents active
/// Stack/Queue/List content from growing without bound. Active or leased items
/// are never silently evicted to make room for a new item.
public struct ClipboardStorageLimits: Sendable, Equatable {
    public static let productDefault = ClipboardStorageLimits(
        maximumActiveItemCount: 1_000,
        maximumActiveItemCountPerGroup: 500,
        maximumHistoryOnlyItemCount: 500,
        maximumTextUTF8ByteCount: 1 * 1_024 * 1_024,
        maximumImageByteCount: 32 * 1_024 * 1_024,
        maximumDecodedImageByteCount: 128 * 1_024 * 1_024,
        maximumFileURLCount: 128,
        maximumFileURLUTF8ByteCount: 8 * 1_024,
        maximumTotalFileURLUTF8ByteCount: 512 * 1_024,
        maximumCaptureTagCount: ClipboardCaptureTag.allCases.count,
        maximumAlternativeCount: 32,
        maximumAlternativeUTF8ByteCount: 16 * 1_024,
        maximumTotalAlternativeUTF8ByteCount: 256 * 1_024,
        maximumTagCount: 32,
        maximumTagUTF8ByteCount: 128,
        maximumTotalTagUTF8ByteCount: 4 * 1_024,
        maximumWorkflowNameUTF8ByteCount: 1_024,
        maximumSourceApplicationNameUTF8ByteCount: 1_024,
        maximumSourceBundleIdentifierUTF8ByteCount: 1_024,
        maximumCustomGroupCount: 256,
        maximumGroupNameUTF8ByteCount: 1_024,
        maximumApplicationAssignmentCount: 1_024,
        maximumAssignmentApplicationNameUTF8ByteCount: 1_024,
        maximumAssignmentBundleIdentifierUTF8ByteCount: 1_024,
        maximumEncodedItemByteCount: 48 * 1_024 * 1_024,
        maximumTotalEncodedItemByteCount: 64 * 1_024 * 1_024,
        maximumPersistedStateUTF8ByteCount: 80 * 1_024 * 1_024
    )

    public var maximumActiveItemCount: Int
    public var maximumActiveItemCountPerGroup: Int
    public var maximumHistoryOnlyItemCount: Int
    public var maximumTextUTF8ByteCount: Int
    public var maximumImageByteCount: Int
    public var maximumDecodedImageByteCount: Int
    public var maximumFileURLCount: Int
    public var maximumFileURLUTF8ByteCount: Int
    public var maximumTotalFileURLUTF8ByteCount: Int
    public var maximumCaptureTagCount: Int
    public var maximumAlternativeCount: Int
    public var maximumAlternativeUTF8ByteCount: Int
    public var maximumTotalAlternativeUTF8ByteCount: Int
    public var maximumTagCount: Int
    public var maximumTagUTF8ByteCount: Int
    public var maximumTotalTagUTF8ByteCount: Int
    public var maximumWorkflowNameUTF8ByteCount: Int
    public var maximumSourceApplicationNameUTF8ByteCount: Int
    public var maximumSourceBundleIdentifierUTF8ByteCount: Int
    public var maximumCustomGroupCount: Int
    public var maximumGroupNameUTF8ByteCount: Int
    public var maximumApplicationAssignmentCount: Int
    public var maximumAssignmentApplicationNameUTF8ByteCount: Int
    public var maximumAssignmentBundleIdentifierUTF8ByteCount: Int
    public var maximumEncodedItemByteCount: Int
    public var maximumTotalEncodedItemByteCount: Int
    public var maximumPersistedStateUTF8ByteCount: Int

    public init(
        maximumActiveItemCount: Int,
        maximumActiveItemCountPerGroup: Int,
        maximumHistoryOnlyItemCount: Int,
        maximumTextUTF8ByteCount: Int,
        maximumImageByteCount: Int,
        maximumDecodedImageByteCount: Int,
        maximumFileURLCount: Int,
        maximumFileURLUTF8ByteCount: Int,
        maximumTotalFileURLUTF8ByteCount: Int,
        maximumCaptureTagCount: Int,
        maximumAlternativeCount: Int,
        maximumAlternativeUTF8ByteCount: Int,
        maximumTotalAlternativeUTF8ByteCount: Int,
        maximumTagCount: Int,
        maximumTagUTF8ByteCount: Int,
        maximumTotalTagUTF8ByteCount: Int,
        maximumWorkflowNameUTF8ByteCount: Int,
        maximumSourceApplicationNameUTF8ByteCount: Int,
        maximumSourceBundleIdentifierUTF8ByteCount: Int,
        maximumCustomGroupCount: Int,
        maximumGroupNameUTF8ByteCount: Int,
        maximumApplicationAssignmentCount: Int,
        maximumAssignmentApplicationNameUTF8ByteCount: Int,
        maximumAssignmentBundleIdentifierUTF8ByteCount: Int,
        maximumEncodedItemByteCount: Int,
        maximumTotalEncodedItemByteCount: Int,
        maximumPersistedStateUTF8ByteCount: Int
    ) {
        precondition(maximumActiveItemCount > 0)
        precondition(maximumActiveItemCountPerGroup > 0)
        precondition(maximumHistoryOnlyItemCount >= 0)
        precondition(maximumTextUTF8ByteCount > 0)
        precondition(maximumImageByteCount > 0)
        precondition(maximumDecodedImageByteCount >= maximumImageByteCount)
        precondition(maximumFileURLCount > 0)
        precondition(maximumFileURLUTF8ByteCount > 0)
        precondition(maximumTotalFileURLUTF8ByteCount >= maximumFileURLUTF8ByteCount)
        precondition(maximumCaptureTagCount > 0)
        precondition(maximumAlternativeCount >= 0)
        precondition(maximumAlternativeUTF8ByteCount > 0)
        precondition(maximumTotalAlternativeUTF8ByteCount >= maximumAlternativeUTF8ByteCount)
        precondition(maximumTagCount >= 0)
        precondition(maximumTagUTF8ByteCount > 0)
        precondition(maximumTotalTagUTF8ByteCount >= maximumTagUTF8ByteCount)
        precondition(maximumWorkflowNameUTF8ByteCount > 0)
        precondition(maximumSourceApplicationNameUTF8ByteCount > 0)
        precondition(maximumSourceBundleIdentifierUTF8ByteCount > 0)
        precondition(maximumCustomGroupCount > 0)
        precondition(maximumGroupNameUTF8ByteCount > 0)
        precondition(maximumApplicationAssignmentCount > 0)
        precondition(maximumAssignmentApplicationNameUTF8ByteCount > 0)
        precondition(maximumAssignmentBundleIdentifierUTF8ByteCount > 0)
        precondition(maximumEncodedItemByteCount > 0)
        precondition(maximumTotalEncodedItemByteCount >= maximumEncodedItemByteCount)
        precondition(maximumPersistedStateUTF8ByteCount >= maximumTotalEncodedItemByteCount)

        self.maximumActiveItemCount = maximumActiveItemCount
        self.maximumActiveItemCountPerGroup = maximumActiveItemCountPerGroup
        self.maximumHistoryOnlyItemCount = maximumHistoryOnlyItemCount
        self.maximumTextUTF8ByteCount = maximumTextUTF8ByteCount
        self.maximumImageByteCount = maximumImageByteCount
        self.maximumDecodedImageByteCount = maximumDecodedImageByteCount
        self.maximumFileURLCount = maximumFileURLCount
        self.maximumFileURLUTF8ByteCount = maximumFileURLUTF8ByteCount
        self.maximumTotalFileURLUTF8ByteCount = maximumTotalFileURLUTF8ByteCount
        self.maximumCaptureTagCount = maximumCaptureTagCount
        self.maximumAlternativeCount = maximumAlternativeCount
        self.maximumAlternativeUTF8ByteCount = maximumAlternativeUTF8ByteCount
        self.maximumTotalAlternativeUTF8ByteCount = maximumTotalAlternativeUTF8ByteCount
        self.maximumTagCount = maximumTagCount
        self.maximumTagUTF8ByteCount = maximumTagUTF8ByteCount
        self.maximumTotalTagUTF8ByteCount = maximumTotalTagUTF8ByteCount
        self.maximumWorkflowNameUTF8ByteCount = maximumWorkflowNameUTF8ByteCount
        self.maximumSourceApplicationNameUTF8ByteCount = maximumSourceApplicationNameUTF8ByteCount
        self.maximumSourceBundleIdentifierUTF8ByteCount = maximumSourceBundleIdentifierUTF8ByteCount
        self.maximumCustomGroupCount = maximumCustomGroupCount
        self.maximumGroupNameUTF8ByteCount = maximumGroupNameUTF8ByteCount
        self.maximumApplicationAssignmentCount = maximumApplicationAssignmentCount
        self.maximumAssignmentApplicationNameUTF8ByteCount = maximumAssignmentApplicationNameUTF8ByteCount
        self.maximumAssignmentBundleIdentifierUTF8ByteCount = maximumAssignmentBundleIdentifierUTF8ByteCount
        self.maximumEncodedItemByteCount = maximumEncodedItemByteCount
        self.maximumTotalEncodedItemByteCount = maximumTotalEncodedItemByteCount
        self.maximumPersistedStateUTF8ByteCount = maximumPersistedStateUTF8ByteCount
    }
}

/// A content-free reason explaining why a clipboard mutation was not admitted.
public enum ClipboardStorageRejectionReason: String, Codable, Error, Sendable, Equatable {
    case itemTooLarge = "item-too-large"
    case imageRepresentationInvalid = "image-representation-invalid"
    case activeItemLimitReached = "active-item-limit-reached"
    case activeItemInUse = "active-item-in-use"
    case historyItemLimitReached = "history-item-limit-reached"
    case totalByteLimitReached = "total-byte-limit-reached"
    case itemEncodingFailed = "item-encoding-failed"
    case metadataLimitReached = "metadata-limit-reached"
}

/// The atomic outcome of creating a group that also reassigns an application's
/// existing clipboard items. A rejected operation creates neither the group nor
/// the assignment, so callers never receive a ghost group after a partial move.
public enum ClipboardGroupCreationResult: Sendable, Equatable {
    case created(ClipboardGroup)
    case rejected(ClipboardStorageRejectionReason)

    public var group: ClipboardGroup? {
        guard case .created(let group) = self else { return nil }
        return group
    }

    public var rejectionReason: ClipboardStorageRejectionReason? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}

/// Distinguishes a rejected new mutation from a preserved legacy state or an
/// invalid current-schema row. UI copy must not describe all three as the same
/// "latest item" failure.
public enum ClipboardStoragePressureContext: Sendable, Equatable {
    case mutationRejected
    case legacyOverCapacity
    case persistedStateRejected
}

/// The authoritative result of adding or enlarging local clipboard content.
///
/// Callers must not report a successful Stack push when this value is rejected.
/// Eviction counts contain no item identity or payload information.
public enum ClipboardStorageMutationResult: Sendable, Equatable {
    case accepted(evictedHistoryItemCount: Int)
    case rejected(ClipboardStorageRejectionReason)

    public var wasAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    public var rejectionReason: ClipboardStorageRejectionReason? {
        guard case .rejected(let reason) = self else { return nil }
        return reason
    }
}
