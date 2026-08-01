import Foundation

public enum WakeWordModelID: String, Codable, Sendable {
    case bilingualZipformer3MPreview = "kws-zipformer-zh-en-3m-preview-int8"
}

public enum WakeWordModelNoticeDisposition: String, Codable, Sendable {
    case notProvidedByPublisher
}

public struct WakeWordModelLicenseEvidence: Codable, Equatable, Sendable {
    public let licenseExpression: String
    public let sourceURL: URL
    public let sourceRevision: String
    public let sourceSHA256: String
    public let upstreamNotice: WakeWordModelNoticeDisposition

    public init(
        licenseExpression: String,
        sourceURL: URL,
        sourceRevision: String,
        sourceSHA256: String,
        upstreamNotice: WakeWordModelNoticeDisposition
    ) {
        self.licenseExpression = licenseExpression
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.sourceSHA256 = sourceSHA256
        self.upstreamNotice = upstreamNotice
    }

    public var isValid: Bool {
        guard
            !licenseExpression.isEmpty,
            !licenseExpression.contains(where: \.isWhitespace),
            sourceRevision.count == 40,
            sourceSHA256.count == 64,
            Self.isLowercaseHex(sourceRevision),
            Self.isLowercaseHex(sourceSHA256),
            let components = URLComponents(
                url: sourceURL,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port == nil || components.port == 443,
            components.path.contains(sourceRevision)
        else {
            return false
        }
        return true
    }

    private static func isLowercaseHex(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

public struct WakeWordModelFile: Equatable, Sendable {
    public let sourceRelativePath: String
    public let publishedFileName: String
    public let byteCount: UInt64
    public let sha256: String

    public init(
        sourceRelativePath: String,
        publishedFileName: String,
        byteCount: UInt64,
        sha256: String
    ) {
        self.sourceRelativePath = sourceRelativePath
        self.publishedFileName = publishedFileName
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct WakeWordModelDescriptor: Equatable, Sendable {
    public let id: WakeWordModelID
    public let archiveURL: URL
    public let archiveByteCount: UInt64
    public let archiveSHA256: String
    public let archiveRootDirectoryName: String
    public let retainedFiles: [WakeWordModelFile]
    public let distributionLicenseEvidence: WakeWordModelLicenseEvidence?

    public init(
        id: WakeWordModelID,
        archiveURL: URL,
        archiveByteCount: UInt64,
        archiveSHA256: String,
        archiveRootDirectoryName: String,
        retainedFiles: [WakeWordModelFile],
        distributionLicenseEvidence: WakeWordModelLicenseEvidence?
    ) {
        self.id = id
        self.archiveURL = archiveURL
        self.archiveByteCount = archiveByteCount
        self.archiveSHA256 = archiveSHA256
        self.archiveRootDirectoryName = archiveRootDirectoryName
        self.retainedFiles = retainedFiles
        self.distributionLicenseEvidence = distributionLicenseEvidence
    }

    public var distributionLicenseVerified: Bool {
        distributionLicenseEvidence?.isValid == true
    }
}

public enum WakeWordModelCatalog {
    public static let defaultModel = WakeWordModelDescriptor(
        id: .bilingualZipformer3MPreview,
        archiveURL: URL(
            string:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2"
        )!,
        archiveByteCount: 32_885_699,
        archiveSHA256: "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6",
        archiveRootDirectoryName: "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20",
        retainedFiles: [
            WakeWordModelFile(
                sourceRelativePath: "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
                publishedFileName: "encoder.int8.onnx",
                byteCount: 4_600_657,
                sha256: "2ca84d6bfe73e1ea3c9c49f600f7cad1c9ddd423c53c906b8bfe802444dd78d5"
            ),
            WakeWordModelFile(
                sourceRelativePath: "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
                publishedFileName: "decoder.onnx",
                byteCount: 759_829,
                sha256: "63a22dd60f40fff082ac3e09afa507f6787da36df76ded2fbe145fa233e22c21"
            ),
            WakeWordModelFile(
                sourceRelativePath: "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
                publishedFileName: "joiner.int8.onnx",
                byteCount: 86_629,
                sha256: "190d4067b4cc20b72a42a1916e69d92052000fb7051a427ebb1bc72a69207dc1"
            ),
            WakeWordModelFile(
                sourceRelativePath: "tokens.txt",
                publishedFileName: "tokens.txt",
                byteCount: 1_928,
                sha256: "2d3f32311f9b692b964da3c90e830258d3e78e013cb0c992dbfb15cd5a1a71b0"
            ),
            WakeWordModelFile(
                sourceRelativePath: "en.phone",
                publishedFileName: "en.phone",
                byteCount: 3_330_061,
                sha256: "f7000ec3a90544c0c7c16090d8951779c2b322e14dad5006290f498567d439ea"
            ),
        ],
        distributionLicenseEvidence: WakeWordModelLicenseEvidence(
            licenseExpression: "Apache-2.0",
            sourceURL: URL(
                string:
                    "https://modelscope.cn/models/pkufool/icefall-kws-zipformer-zh-en-3M-2025-12-20/resolve/541d04e28be57efc6fdf46a341da09e043a37b52/README.md"
            )!,
            sourceRevision: "541d04e28be57efc6fdf46a341da09e043a37b52",
            sourceSHA256: "34d92bb4dc9fb259efb67f329d2cd68f6e0a6226121a694a3b6b4c748378559c",
            upstreamNotice: .notProvidedByPublisher
        )
    )

    public static let encoderFileName = "encoder.int8.onnx"
    public static let decoderFileName = "decoder.onnx"
    public static let joinerFileName = "joiner.int8.onnx"
    public static let tokensFileName = "tokens.txt"
    public static let englishLexiconFileName = "en.phone"
}
