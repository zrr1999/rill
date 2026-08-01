import CSherpaOnnx
import Foundation

public struct SherpaKeywordSpotterConfiguration: Equatable, Sendable {
    public var encoder: URL
    public var decoder: URL
    public var joiner: URL
    public var tokens: URL
    public var keywords: String
    public var threadCount: Int
    public var maximumActivePaths: Int
    public var trailingBlankCount: Int
    public var keywordScore: Float
    public var keywordThreshold: Float

    public init(
        encoder: URL,
        decoder: URL,
        joiner: URL,
        tokens: URL,
        keywords: String,
        threadCount: Int = 1,
        maximumActivePaths: Int = 4,
        trailingBlankCount: Int = 1,
        keywordScore: Float = 1,
        keywordThreshold: Float = 0.25
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.joiner = joiner
        self.tokens = tokens
        self.keywords = keywords
        self.threadCount = threadCount
        self.maximumActivePaths = maximumActivePaths
        self.trailingBlankCount = trailingBlankCount
        self.keywordScore = keywordScore
        self.keywordThreshold = keywordThreshold
    }
}

public struct SherpaKeywordDetection: Equatable, Sendable {
    public let keyword: String
    public let tokenTimestamps: [Float]
    public let segmentStartTime: Float

    public init(keyword: String, tokenTimestamps: [Float], segmentStartTime: Float) {
        self.keyword = keyword
        self.tokenTimestamps = tokenTimestamps
        self.segmentStartTime = segmentStartTime
    }

    public var estimatedKeywordEndTime: Double {
        Double(max(tokenTimestamps.last ?? segmentStartTime, segmentStartTime))
    }
}

public enum SherpaKeywordSpotterError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration
    case creationFailed
    case streamCreationFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The keyword spotter configuration is invalid."
        case .creationFailed:
            return "The keyword spotter could not be created."
        case .streamCreationFailed:
            return "The keyword stream could not be created."
        case .decodingFailed:
            return "Keyword spotting failed while decoding audio."
        }
    }
}

public final class SherpaKeywordSpotter: @unchecked Sendable {
    private let lock = NSLock()
    private var spotter: OpaquePointer?
    private var stream: OpaquePointer?

    public init(configuration: SherpaKeywordSpotterConfiguration) throws {
        try Self.validate(configuration)
        let createdSpotter = configuration.encoder.path.withCString { encoder in
            configuration.decoder.path.withCString { decoder in
                configuration.joiner.path.withCString { joiner in
                    configuration.tokens.path.withCString { tokens in
                        configuration.keywords.withCString { keywords in
                            RillSherpaCreateKeywordSpotter(
                                encoder,
                                decoder,
                                joiner,
                                tokens,
                                keywords,
                                Int32(configuration.threadCount),
                                Int32(configuration.maximumActivePaths),
                                Int32(configuration.trailingBlankCount),
                                configuration.keywordScore,
                                configuration.keywordThreshold
                            )
                        }
                    }
                }
            }
        }
        guard let createdSpotter else {
            throw SherpaKeywordSpotterError.creationFailed
        }
        let createdStream = configuration.keywords.withCString { keywords in
            RillSherpaCreateKeywordStream(createdSpotter, keywords)
        }
        guard let createdStream else {
            RillSherpaDestroyKeywordSpotter(createdSpotter)
            throw SherpaKeywordSpotterError.streamCreationFailed
        }
        spotter = createdSpotter
        stream = createdStream
    }

    deinit {
        if let stream {
            RillSherpaDestroyKeywordStream(stream)
        }
        if let spotter {
            RillSherpaDestroyKeywordSpotter(spotter)
        }
    }

    public func accept(samples: [Float], sampleRate: Int = 16_000) throws
        -> SherpaKeywordDetection?
    {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        return try lock.withLock {
            guard let spotter, let stream else {
                throw SherpaKeywordSpotterError.decodingFailed
            }
            var result: UnsafeMutablePointer<RillSherpaKeywordResult>?
            let status = samples.withUnsafeBufferPointer { buffer in
                RillSherpaKeywordStreamAcceptAndDecode(
                    spotter,
                    stream,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    Int32(sampleRate),
                    &result
                )
            }
            guard status == 1 else {
                throw SherpaKeywordSpotterError.decodingFailed
            }
            guard let result else { return nil }
            defer { RillSherpaDestroyKeywordResult(result) }
            let native = result.pointee
            guard let keywordPointer = native.keyword else {
                throw SherpaKeywordSpotterError.decodingFailed
            }
            let timestamps: [Float]
            if native.count > 0, let pointer = native.timestamps {
                timestamps = Array(
                    UnsafeBufferPointer(start: pointer, count: Int(native.count))
                )
            } else {
                timestamps = []
            }
            let detection = SherpaKeywordDetection(
                keyword: String(cString: keywordPointer),
                tokenTimestamps: timestamps,
                segmentStartTime: native.start_time
            )
            guard RillSherpaResetKeywordStream(spotter, stream) == 1 else {
                throw SherpaKeywordSpotterError.decodingFailed
            }
            return detection
        }
    }

    public func reset() throws {
        try lock.withLock {
            guard let spotter, let stream,
                RillSherpaResetKeywordStream(spotter, stream) == 1
            else {
                throw SherpaKeywordSpotterError.decodingFailed
            }
        }
    }

    private static func validate(_ configuration: SherpaKeywordSpotterConfiguration) throws {
        guard
            (1...16).contains(configuration.threadCount),
            configuration.maximumActivePaths > 0,
            configuration.trailingBlankCount >= 0,
            configuration.keywordScore.isFinite,
            configuration.keywordScore > 0,
            configuration.keywordThreshold.isFinite,
            configuration.keywordThreshold > 0,
            configuration.keywordThreshold < 1,
            !configuration.keywords.isEmpty,
            configuration.keywords.utf8.count <= 16 * 1_024
        else {
            throw SherpaKeywordSpotterError.invalidConfiguration
        }
        for url in [
            configuration.encoder,
            configuration.decoder,
            configuration.joiner,
            configuration.tokens,
        ] {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SherpaKeywordSpotterError.invalidConfiguration
            }
        }
    }
}
