import Foundation
import RillCore

enum ClipboardPersistenceRetryPolicy {
    static func canRetry(
        availability: ClipboardPersistenceAvailability,
        isRetrying: Bool,
        hasBegunApplicationShutdown: Bool
    ) -> Bool {
        availability == .saveFailed
            && !isRetrying
            && !hasBegunApplicationShutdown
    }
}

enum ClipboardPersistenceResetPolicy {
    static func canReset(
        availability: ClipboardPersistenceAvailability,
        isResetting: Bool,
        hasBegunApplicationShutdown: Bool
    ) -> Bool {
        availability == .loadUnavailable
            && !isResetting
            && !hasBegunApplicationShutdown
    }
}

extension AppModel {
    func applyClipboardStoreSnapshot(_ snapshot: ClipboardStoreSnapshot) {
        clipboardPersistenceAvailability = snapshot.persistenceAvailability
        if snapshot.persistenceAvailability != .loadUnavailable {
            clipboardPersistenceResetFailed = false
        }
        clipboardStorageLimits = snapshot.storageLimits
        clipboardStorageRejection = snapshot.lastStorageRejection
        clipboardStoragePressureContext = snapshot.storagePressureContext
        updateClipboardSnapshot(snapshot)
    }

    /// Requests one immediate durable write. Availability remains authoritative
    /// from a fresh DeliveryStack snapshot; this action never optimistically
    /// clears the warning.
    public func retryClipboardPersistenceNow() {
        guard ClipboardPersistenceRetryPolicy.canRetry(
            availability: clipboardPersistenceAvailability,
            isRetrying: isRetryingClipboardPersistence,
            hasBegunApplicationShutdown: hasBegunApplicationShutdown
        ), let deliveryStack else {
            return
        }

        isRetryingClipboardPersistence = true
        let accepted = clipboardMutationTaskOwner.submit { [weak self, deliveryStack] in
            _ = await deliveryStack.flushPendingPersistenceWrites()
            let snapshot = await deliveryStack.clipboardSnapshot()
            guard let self else { return }
            self.applyClipboardStoreSnapshot(snapshot)
            self.isRetryingClipboardPersistence = false
        }
        if !accepted {
            isRetryingClipboardPersistence = false
        }
    }

    /// Runs only after `ClipboardView` has shown and accepted a destructive
    /// confirmation. Failure leaves both the protected row and the session
    /// projection unchanged.
    public func resetUnavailableClipboardPersistence() {
        guard ClipboardPersistenceResetPolicy.canReset(
            availability: clipboardPersistenceAvailability,
            isResetting: isResettingClipboardPersistence,
            hasBegunApplicationShutdown: hasBegunApplicationShutdown
        ), let deliveryStack else {
            return
        }

        isResettingClipboardPersistence = true
        clipboardPersistenceResetFailed = false
        let accepted = clipboardMutationTaskOwner.submit { [weak self, deliveryStack] in
            let result = await deliveryStack.resetUnavailablePersistedState()
            let snapshot = await deliveryStack.clipboardSnapshot()
            guard let self else { return }
            self.applyClipboardStoreSnapshot(snapshot)
            self.clipboardPersistenceResetFailed = switch result {
            case .failed, .notConfigured: true
            case .reset, .resetCleanupPending, .notRequired: false
            }
            self.isResettingClipboardPersistence = false
        }
        if !accepted {
            isResettingClipboardPersistence = false
        }
    }
}
