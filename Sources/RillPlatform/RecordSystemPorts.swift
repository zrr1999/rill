import Foundation
import RillCore

public struct SystemClipboardSourceDecision: Sendable, Equatable {
    public var sourceApplication: FocusedApplicationIdentity
    public var allowsWorkflowCapture: Bool

    public init(
        sourceApplication: FocusedApplicationIdentity = FocusedApplicationIdentity(),
        allowsWorkflowCapture: Bool
    ) {
        self.sourceApplication = sourceApplication
        self.allowsWorkflowCapture = allowsWorkflowCapture
    }
}

/// A race-safe Record source over the real macOS pasteboard. Privacy is
/// supplied by the composition root and is re-evaluated before payload read.
public struct SystemClipboardSource: RecordSource {
    public typealias Authorization = @Sendable (
        SystemClipboardDescriptor
    ) async -> SystemClipboardSourceDecision?

    private let port: SystemClipboardPort
    private let authorization: Authorization

    public init(
        port: SystemClipboardPort,
        authorization: @escaping Authorization
    ) {
        self.port = port
        self.authorization = authorization
    }

    public func capture() async throws -> RecordCaptureEnvelope? {
        let descriptor = await port.currentDescriptor()
        guard descriptor.hasTransferableContent,
              descriptor.protections.isEmpty,
              let firstDecision = await authorization(descriptor),
              let snapshot = await port.readSnapshot(ifChangeCountIs: descriptor.changeCount)
        else { return nil }

        let descriptorAfterRead = await port.currentDescriptor()
        guard descriptorAfterRead == descriptor,
              let finalDecision = await authorization(descriptorAfterRead),
              finalDecision == firstDecision
        else { return nil }

        let payload: RecordPayload
        if let image = snapshot.imagePNGData {
            payload = .image(image)
        } else if !snapshot.fileURLs.isEmpty {
            payload = .files(snapshot.fileURLs)
        } else {
            payload = .text(snapshot.plainText)
        }
        var tags = snapshot.captureTags
        if !finalDecision.allowsWorkflowCapture,
           !tags.contains(.excludeFromWorkflowCapture) {
            tags.append(.excludeFromWorkflowCapture)
        }
        return RecordCaptureEnvelope(
            draft: RecordDraft(
                payload: payload,
                provenance: RecordProvenance(
                    source: RecordSourceIdentity(kind: .systemClipboard),
                    sourceApplicationName: finalDecision.sourceApplication.applicationName,
                    sourceBundleIdentifier: finalDecision.sourceApplication.bundleIdentifier,
                    captureTags: tags
                )
            )
        )
    }
}

public struct SystemClipboardSink: RecordSink {
    public let identity: RecordSinkIdentity = .systemClipboard
    private let port: SystemClipboardPort

    public init(port: SystemClipboardPort) {
        self.port = port
    }

    public func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt {
        _ = await port.writeSnapshot(Self.snapshot(for: request.record))
        return RecordDeliveryReceipt(
            recordID: request.record.id,
            membershipID: request.membershipID,
            sink: identity
        )
    }

    private static func snapshot(for record: Record) -> SystemClipboardSnapshot {
        switch record.payload {
        case .text(let text):
            SystemClipboardSnapshot(
                plainText: text,
                changeCount: 0,
                captureTags: record.provenance.captureTags
            )
        case .image(let image):
            SystemClipboardSnapshot(
                plainText: "",
                imagePNGData: image,
                changeCount: 0,
                captureTags: record.provenance.captureTags
            )
        case .files(let files):
            SystemClipboardSnapshot(
                plainText: "",
                fileURLs: files,
                changeCount: 0,
                captureTags: record.provenance.captureTags
            )
        }
    }
}

public struct FocusedApplicationSink: RecordSink {
    public let identity: RecordSinkIdentity = .focusedApplication
    private let engine: TextInjectionEngine
    private let focusProvider: @Sendable () async -> FocusSnapshot

    public init(
        engine: TextInjectionEngine,
        focusProvider: @escaping @Sendable () async -> FocusSnapshot
    ) {
        self.engine = engine
        self.focusProvider = focusProvider
    }

    public func deliver(_ request: RecordDeliveryRequest) async throws -> RecordDeliveryReceipt {
        let focus = await focusProvider()
        guard request.targetApplication?.matches(focus) != false else {
            throw FocusedApplicationSinkError.targetChanged
        }
        switch request.record.payload {
        case .text(let text):
            try await engine.inject(text, targetFocus: focus)
        case .image(let image):
            try await engine.injectClipboardSnapshot(
                SystemClipboardSnapshot(plainText: "", imagePNGData: image, changeCount: 0),
                targetFocus: focus
            )
        case .files(let files):
            try await engine.injectClipboardSnapshot(
                SystemClipboardSnapshot(plainText: "", fileURLs: files, changeCount: 0),
                targetFocus: focus
            )
        }
        return RecordDeliveryReceipt(
            recordID: request.record.id,
            membershipID: request.membershipID,
            sink: identity
        )
    }
}

public enum FocusedApplicationSinkError: Error, LocalizedError, Sendable {
    case targetChanged

    public var errorDescription: String? {
        "The focused application changed before the record could be delivered."
    }
}

private extension FocusedApplicationIdentity {
    func matches(_ focus: FocusSnapshot) -> Bool {
        if let bundleIdentifier { return focus.bundleIdentifier == bundleIdentifier }
        if let applicationName { return focus.applicationName == applicationName }
        return true
    }
}
