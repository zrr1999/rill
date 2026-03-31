import AVFoundation
import Foundation
import VoxTypeCore

public actor AVAudioCaptureService: AudioCaptureService {
    public enum CaptureError: Error, LocalizedError, Equatable {
        case alreadyCapturing
        case notCapturing
        case recorderInitializationFailed
        case startFailed

        public var errorDescription: String? {
            switch self {
            case .alreadyCapturing:
                return "An audio capture is already in progress."
            case .notCapturing:
                return "No audio capture is currently active."
            case .recorderInitializationFailed:
                return "The audio recorder could not be initialized."
            case .startFailed:
                return "The audio recorder could not start recording."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private var activeRequest: AudioCaptureRequest?
    private var outputURL: URL?

    public init() {}

    public func startCapture(_ request: AudioCaptureRequest) async throws {
        guard recorder == nil else {
            throw CaptureError.alreadyCapturing
        }

        let format = request.preferredFormat ?? AudioFormat(
            sampleRateHz: 16_000,
            channelCount: 1,
            encoding: .pcm16
        )
        let outputURL = Self.makeTemporaryRecordingURL(for: request.runID)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRateHz,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw CaptureError.startFailed
        }

        self.recorder = recorder
        self.activeRequest = request
        self.outputURL = outputURL
    }

    public func finishCapture() async throws -> CapturedAudio {
        guard let recorder, let activeRequest, let outputURL else {
            throw CaptureError.notCapturing
        }

        recorder.stop()
        let durationSeconds = recorder.currentTime
        let format = activeRequest.preferredFormat ?? AudioFormat(
            sampleRateHz: recorder.settings[AVSampleRateKey] as? Double ?? 16_000,
            channelCount: recorder.settings[AVNumberOfChannelsKey] as? Int ?? 1,
            encoding: .pcm16
        )
        let metadata = activeRequest.metadata.merging(
            ["runID": activeRequest.runID.uuidString],
            uniquingKeysWith: { _, new in new }
        )

        self.recorder = nil
        self.activeRequest = nil
        self.outputURL = nil

        return try CapturedAudio(
            durationSeconds: durationSeconds,
            format: format,
            fileURL: outputURL,
            metadata: metadata
        )
    }

    public func cancelCapture() async {
        recorder?.stop()

        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }

        recorder = nil
        activeRequest = nil
        outputURL = nil
    }

    private static func makeTemporaryRecordingURL(for runID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtype-\(runID.uuidString)")
            .appendingPathExtension("wav")
    }
}
