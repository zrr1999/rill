import Foundation
import RillCore

/// An exact stored-item subject plus its transient source application identity.
///
/// Only `DeliveryStack` can create this value. It is not serializable and does
/// not contain the stored payload, but lets live authorization apply sensitive
/// application rules to the source as well as the current action target.
public struct ClipboardItemRunAuthorizationSource: Sendable, Equatable {
    public let subject: ClipboardItemDryRunSubject

    let sourceApplicationName: String?
    let sourceBundleIdentifier: String?
    let capturedAt: Date

    fileprivate init(
        subject: ClipboardItemDryRunSubject,
        sourceApplicationName: String?,
        sourceBundleIdentifier: String?,
        capturedAt: Date
    ) {
        self.subject = subject
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.capturedAt = capturedAt
    }

    var privacyContext: ContextSnapshot {
        ContextSnapshot(
            focus: FocusSnapshot(
                applicationName: sourceApplicationName,
                bundleIdentifier: sourceBundleIdentifier,
                processIdentifier: nil,
                focusedRole: nil,
                selectedText: "",
                secureInput: false,
                capturedAt: capturedAt
            ),
            clipboard: ClipboardSnapshot(
                plainText: "",
                changeCount: 0,
                captureTags: subject.captureTags
            )
        )
    }
}

/// An actor-resolved, transient source snapshot for a clipboard group run.
///
/// Only `DeliveryStack` can create this value. The scheduler descriptor remains
/// free of application identity, while privacy authorization can still evaluate
/// the application that originally supplied the exact item incarnation. This
/// value is not serializable and does not contain the clipboard payload.
public struct ClipboardGroupRunAuthorizationSource: Sendable, Equatable {
    public var subject: ClipboardItemDryRunSubject {
        itemSource.subject
    }

    let itemSource: ClipboardItemRunAuthorizationSource
    let descriptor: ClipboardGroupEventDescriptor

    fileprivate init(
        itemSource: ClipboardItemRunAuthorizationSource,
        descriptor: ClipboardGroupEventDescriptor
    ) {
        self.itemSource = itemSource
        self.descriptor = descriptor
    }

    var privacyContext: ContextSnapshot {
        itemSource.privacyContext
    }
}

public enum ClipboardGroupRunAuthorizationBlockReason: String, Codable, Sendable,
    Equatable, CaseIterable {
    case executionSurfaceUnsupported
    case triggerMismatch
    case actionPlanUnsupported
    case sourceContentUnsupported
    case sourceExcludedFromWorkflowCapture
    case privacySettingsUnavailable
    case processingDestinationUnavailable
    case workflowCaptureBlocked
    case cloudProcessingBlocked
    case cloudConfirmationRequired
}

/// A content-free, non-interactive preflight result.
///
/// `.ready` is not an execution capability. It only proves that the current
/// source-aware policy does not require interaction. A future executor must
/// additionally require a revision-bound persistent grant, issue a one-shot
/// action lease, and revalidate the exact source immediately before effects.
public enum ClipboardGroupRunAuthorizationEvaluation: Sendable, Equatable {
    case ready(processingDestinations: [PrivacyProcessingDestination])
    case blocked(reason: ClipboardGroupRunAuthorizationBlockReason)
}

extension DeliveryStack {
    public func clipboardItemRunAuthorizationSource(
        itemID: UUID,
        expectedItemVersion: ClipboardItemVersion
    ) async -> ClipboardItemRunAuthorizationSource? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[itemID],
              item.version == expectedItemVersion else {
            return nil
        }
        return clipboardItemRunAuthorizationSource(for: item)
    }

    public func matchesClipboardItemRunAuthorizationSource(
        _ source: ClipboardItemRunAuthorizationSource
    ) async -> Bool {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        guard let item = itemsByID[source.subject.itemID],
              item.version == source.subject.itemVersion else {
            return false
        }
        return clipboardItemRunAuthorizationSource(for: item) == source
    }

    /// Atomically resolves the exact item incarnation and its transient source
    /// identity. Removed items and legacy descriptors without an item version
    /// cannot authorize a content-reading action.
    public func clipboardGroupRunAuthorizationSource(
        matching descriptor: ClipboardGroupEventDescriptor
    ) async -> ClipboardGroupRunAuthorizationSource? {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        return currentClipboardGroupRunAuthorizationSource(matching: descriptor)
    }

    public func matchesClipboardGroupRunAuthorizationSource(
        _ source: ClipboardGroupRunAuthorizationSource
    ) async -> Bool {
        await ensureInitialized()
        await waitForHistoryMaintenanceIfNeeded()
        return currentClipboardGroupRunAuthorizationSource(
            matching: source.descriptor
        ) == source
    }

    private func currentClipboardGroupRunAuthorizationSource(
        matching descriptor: ClipboardGroupEventDescriptor
    ) -> ClipboardGroupRunAuthorizationSource? {
        guard descriptor.kind != .itemRemoved,
              let descriptorVersion = descriptor.itemVersion,
              let descriptorTags = descriptor.captureTags,
              let item = itemsByID[descriptor.itemID],
              item.version == descriptorVersion,
              item.groupID == descriptor.groupID,
              item.captureTags == descriptorTags else {
            return nil
        }
        return ClipboardGroupRunAuthorizationSource(
            itemSource: clipboardItemRunAuthorizationSource(for: item),
            descriptor: descriptor
        )
    }

    private func clipboardItemRunAuthorizationSource(
        for item: ClipboardHistoryItem
    ) -> ClipboardItemRunAuthorizationSource {
        ClipboardItemRunAuthorizationSource(
            subject: dryRunSubject(for: item),
            sourceApplicationName: item.sourceApplicationName,
            sourceBundleIdentifier: item.sourceBundleIdentifier,
            capturedAt: item.createdAt
        )
    }
}
