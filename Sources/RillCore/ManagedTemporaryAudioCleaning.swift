import Foundation

/// Owns transferred temporary audio until removal succeeds, including during shutdown.
public protocol ManagedTemporaryAudioCleaning: Sendable {
    @discardableResult
    func transfer(fileURL: URL, runID: UUID) async -> Bool
    func drain(runID: UUID?) async
}

public extension ManagedTemporaryAudioCleaning {
    @discardableResult
    func transfer(_ audio: CapturedAudio, runID: UUID) async -> Bool {
        guard audio.fileOwnership == .managedTemporary, let fileURL = audio.fileURL else { return false }
        return await transfer(fileURL: fileURL, runID: runID)
    }

    func drain() async { await drain(runID: nil) }
}
