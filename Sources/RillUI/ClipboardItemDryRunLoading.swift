import Foundation
import RillCore
import RillRuntime

enum ClipboardItemDryRunFailure: Sendable, Equatable {
    case itemUnavailable
    case itemChanged
    case workflowUnavailable
    case providerUnavailable
    case invalidReceipt
}

enum ClipboardItemDryRunLoadState: Sendable, Equatable {
    case idle
    case loading(requestID: UUID)
    case loaded(requestID: UUID, PreparedClipboardItemDryRun)
    case failed(requestID: UUID, ClipboardItemDryRunFailure)
}

struct ClipboardItemDryRunLoadRequest: Sendable, Equatable {
    let id: UUID
    let itemID: UUID
    let expectedItemVersion: ClipboardItemVersion
    let operation: ClipboardItemDryRunOperation
    let workflowID: UUID?
}

enum ClipboardItemDryRunLoadOutcome: Sendable, Equatable {
    case loaded(requestID: UUID, PreparedClipboardItemDryRun)
    case failed(requestID: UUID, ClipboardItemDryRunFailure)
}

enum ClipboardItemDryRunCorrelation {
    static func validates(
        _ prepared: PreparedClipboardItemDryRun,
        request: ClipboardItemDryRunLoadRequest,
        currentItem: ClipboardHistoryItem
    ) -> Bool {
        let currentSubject = ClipboardItemDryRunSubject(
            itemID: currentItem.id,
            itemVersion: currentItem.version,
            groupID: currentItem.groupID,
            contentKind: currentItem.contentKind,
            captureTags: currentItem.captureTags,
            hasTransferableContent: currentItem.supportsDirectPaste
        )
        return request.itemID == currentItem.id
            && request.expectedItemVersion == currentItem.version
            && prepared.subject == currentSubject
            && prepared.receipt.version == ClipboardItemDryRunReceipt.currentVersion
            && prepared.receipt.operation == request.operation
            && prepared.receipt.workflowID == request.workflowID
    }
}

/// Coalesces rapid UI changes into one in-flight request and one latest pending
/// request. A provider that ignores cancellation therefore remains bounded.
actor ClipboardItemDryRunLoadCoordinator {
    typealias Load = @Sendable () async throws -> PreparedClipboardItemDryRun
    typealias Deliver = @MainActor @Sendable (ClipboardItemDryRunLoadOutcome) -> Void

    struct Snapshot: Sendable, Equatable {
        let inFlightCount: Int
        let pendingCount: Int
        let desiredRequestID: UUID?
    }

    private struct Pending: Sendable {
        let request: ClipboardItemDryRunLoadRequest
        let load: Load
        let deliver: Deliver
    }

    private var pending: Pending?
    private var isRunning = false
    private var desiredRequestID: UUID?

    func submit(
        _ request: ClipboardItemDryRunLoadRequest,
        load: @escaping Load,
        deliver: @escaping Deliver
    ) {
        desiredRequestID = request.id
        pending = Pending(request: request, load: load, deliver: deliver)
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    func cancel(requestID: UUID) {
        guard desiredRequestID == requestID else { return }
        desiredRequestID = nil
        if pending?.request.id == requestID {
            pending = nil
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            inFlightCount: isRunning ? 1 : 0,
            pendingCount: pending == nil ? 0 : 1,
            desiredRequestID: desiredRequestID
        )
    }

    private func drain() async {
        while let current = pending {
            pending = nil
            let outcome: ClipboardItemDryRunLoadOutcome
            do {
                let prepared = try await current.load()
                outcome = .loaded(requestID: current.request.id, prepared)
            } catch let error as ClipboardItemDryRunPreparationError {
                let failure: ClipboardItemDryRunFailure = switch error {
                case .itemUnavailable: .itemUnavailable
                case .itemChanged: .itemChanged
                }
                outcome = .failed(requestID: current.request.id, failure)
            } catch {
                outcome = .failed(requestID: current.request.id, .providerUnavailable)
            }

            if desiredRequestID == current.request.id {
                await current.deliver(outcome)
            }
        }

        isRunning = false
        if pending != nil {
            isRunning = true
            Task { await drain() }
        }
    }
}
