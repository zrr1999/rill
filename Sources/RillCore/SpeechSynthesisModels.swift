import Foundation

public enum SpeechSynthesisProvider: String, Codable, CaseIterable, Sendable, Equatable {
    case automatic
    case qwen3
    case system
}

public enum Qwen3TTSVoice: String, Codable, CaseIterable, Sendable, Equatable {
    case vivian = "Vivian"
    case serena = "Serena"
    case uncleFu = "Uncle_Fu"
    case dylan = "Dylan"
    case eric = "Eric"
    case ryan = "Ryan"
    case aiden = "Aiden"
    case onoAnna = "Ono_Anna"
    case sohee = "Sohee"
}

public struct SpeechSynthesisRequest: Sendable, Equatable {
    public static let maximumTextScalarCount = 4_096
    public static let maximumTextByteCount = 16 * 1_024

    public var runID: UUID
    public var text: String
    public var provider: SpeechSynthesisProvider
    public var voice: String
    public var language: String?

    public init(
        runID: UUID,
        text: String,
        provider: SpeechSynthesisProvider = .automatic,
        voice: String = Qwen3TTSVoice.vivian.rawValue,
        language: String? = nil
    ) {
        self.runID = runID
        self.text = text
        self.provider = provider
        self.voice = voice
        self.language = language
    }

    public var isValid: Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedText.isEmpty
            && trimmedText.unicodeScalars.count <= Self.maximumTextScalarCount
            && trimmedText.utf8.count <= Self.maximumTextByteCount
            && !trimmedText.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !trimmedVoice.isEmpty
            && trimmedVoice.utf8.count <= 128
            && !trimmedVoice.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && (language?.utf8.count ?? 0) <= 64
    }
}

public enum SpeechAssetOwnership: String, Codable, Sendable, Equatable {
    case callerManaged
    case managedTemporary
}

public struct SpeechAsset: Codable, Sendable, Equatable {
    public enum ValidationError: Error, LocalizedError, Sendable, Equatable {
        case invalidDuration
        case invalidFormat
        case invalidManagedTemporaryFileURL

        public var errorDescription: String? {
            switch self {
            case .invalidDuration:
                return "Synthesized speech must have a finite positive duration."
            case .invalidFormat:
                return "Synthesized speech must have a valid sample rate and channel count."
            case .invalidManagedTemporaryFileURL:
                return "Managed synthesized speech must use a Rill-owned temporary file."
            }
        }
    }

    public var fileURL: URL
    public var durationSeconds: Double
    public var format: AudioFormat
    public var ownership: SpeechAssetOwnership

    public init(
        fileURL: URL,
        durationSeconds: Double,
        format: AudioFormat,
        ownership: SpeechAssetOwnership = .callerManaged
    ) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ValidationError.invalidDuration
        }
        guard
            format.sampleRateHz.isFinite,
            format.sampleRateHz > 0,
            format.channelCount > 0,
            format.channelCount <= 8
        else {
            throw ValidationError.invalidFormat
        }
        if ownership == .managedTemporary,
            !Self.isManagedTemporaryFileURL(fileURL)
        {
            throw ValidationError.invalidManagedTemporaryFileURL
        }
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.format = format
        self.ownership = ownership
    }

    public static func isManagedTemporaryFileURL(
        _ fileURL: URL,
        using fileManager: FileManager = .default
    ) -> Bool {
        guard fileURL.isFileURL else { return false }
        let standardizedURL = fileURL.standardizedFileURL
        return standardizedURL.deletingLastPathComponent()
            == fileManager.temporaryDirectory.standardizedFileURL
            && standardizedURL.lastPathComponent.hasPrefix("rill-speech-")
            && standardizedURL.pathExtension.lowercased() == "wav"
    }

    @discardableResult
    public func removeManagedTemporaryFile(
        using fileManager: FileManager = .default
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard
            ownership == .managedTemporary,
            Self.isManagedTemporaryFileURL(fileURL, using: fileManager),
            fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }
}

public enum SpeechOutputActionID {
    public static let speak = "speech.speak"
}

public enum SpeechOutputActionConfigurationKey {
    public static let provider = "speech.provider"
    public static let voice = "speech.voice"
    public static let language = "speech.language"
}
