import CryptoKit
import Foundation

public protocol LocalDataProtector: Sendable {
    func seal(_ plaintext: Data, context: LocalDataProtectionContext) throws -> String
    func open(_ envelope: String, context: LocalDataProtectionContext) throws -> Data
    func sealBinary(_ plaintext: Data, context: LocalDataProtectionContext) throws -> Data
    func openBinary(_ envelope: Data, context: LocalDataProtectionContext) throws -> Data
}

public extension LocalDataProtector {
    /// Compatibility bridge for protectors that only expose the original text
    /// envelope. Production AES-GCM overrides this with a raw binary envelope so
    /// SQLite BLOB payloads do not incur another Base64 expansion.
    func sealBinary(
        _ plaintext: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        Data(try seal(plaintext, context: context).utf8)
    }

    func openBinary(
        _ envelope: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        guard let textEnvelope = String(data: envelope, encoding: .utf8) else {
            throw LocalDataProtectionError.invalidEnvelopeEncoding
        }
        return try open(textEnvelope, context: context)
    }
}

/// Binds protected bytes to their logical storage location.
///
/// The associated data uses an explicit domain and length-prefixed UTF-8
/// components so different component boundaries cannot produce the same bytes.
public struct LocalDataProtectionContext: Sendable, Equatable, Hashable {
    public let namespace: String
    public let recordID: String
    public let field: String

    public init(namespace: String, recordID: String, field: String) {
        self.namespace = namespace
        self.recordID = recordID
        self.field = field
    }

    public func associatedData() -> Data {
        var data = Data("rill:local-data-context:v1".utf8)
        for component in [namespace, recordID, field] {
            let componentData = Data(component.utf8)
            var length = UInt64(componentData.count).bigEndian
            Swift.withUnsafeBytes(of: &length) { bytes in
                data.append(contentsOf: bytes)
            }
            data.append(componentData)
        }
        return data
    }
}

public enum LocalDataProtectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidKeyLength(expected: Int, actual: Int)
    case invalidEnvelopePrefix
    case unsupportedEnvelopeVersion(String)
    case invalidEnvelopeEncoding
    case malformedSealedBox
    case authenticationFailed
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let expected, let actual):
            return "Local data key must contain exactly \(expected) bytes; received \(actual)."
        case .invalidEnvelopePrefix:
            return "Protected local data has an invalid envelope prefix."
        case .unsupportedEnvelopeVersion(let version):
            return "Protected local data uses unsupported envelope version \(version)."
        case .invalidEnvelopeEncoding:
            return "Protected local data does not use the required canonical encoding."
        case .malformedSealedBox:
            return "Protected local data does not contain a valid sealed box."
        case .authenticationFailed:
            return "Protected local data failed authentication."
        case .encryptionFailed:
            return "Local data could not be encrypted."
        }
    }
}

public struct AESGCMDataProtector: LocalDataProtector {
    public static let keyByteCount = 32
    public static let envelopePrefix = "rill"
    public static let envelopeVersion = "v1"
    private static let binaryEnvelopeNamespace = Data("rill\0".utf8)

    private let key: SymmetricKey

    public init(key: Data) throws {
        guard key.count == Self.keyByteCount else {
            throw LocalDataProtectionError.invalidKeyLength(
                expected: Self.keyByteCount,
                actual: key.count
            )
        }
        self.key = SymmetricKey(data: key)
    }

    public func seal(
        _ plaintext: Data,
        context: LocalDataProtectionContext
    ) throws -> String {
        let combined = try sealedCombined(plaintext, context: context)
        return [
            Self.envelopePrefix,
            Self.envelopeVersion,
            combined.base64EncodedString(),
        ].joined(separator: ":")
    }

    public func open(
        _ envelope: String,
        context: LocalDataProtectionContext
    ) throws -> Data {
        let components = envelope.split(
            separator: ":",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else {
            throw LocalDataProtectionError.invalidEnvelopePrefix
        }
        guard components[0] == Substring(Self.envelopePrefix) else {
            throw LocalDataProtectionError.invalidEnvelopePrefix
        }
        guard components[1] == Substring(Self.envelopeVersion) else {
            throw LocalDataProtectionError.unsupportedEnvelopeVersion(String(components[1]))
        }

        let encodedPayload = String(components[2])
        guard
            !encodedPayload.isEmpty,
            let combined = Data(base64Encoded: encodedPayload, options: []),
            combined.base64EncodedString() == encodedPayload
        else {
            throw LocalDataProtectionError.invalidEnvelopeEncoding
        }

        return try openCombined(combined, context: context)
    }

    public func sealBinary(
        _ plaintext: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        let combined = try sealedCombined(plaintext, context: context)
        var envelope = Self.binaryEnvelopeNamespace
        envelope.append(Data(Self.envelopeVersion.utf8))
        envelope.append(0)
        envelope.append(combined)
        return envelope
    }

    public func openBinary(
        _ envelope: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        guard envelope.starts(with: Self.binaryEnvelopeNamespace) else {
            throw LocalDataProtectionError.invalidEnvelopePrefix
        }
        let versionStart = Self.binaryEnvelopeNamespace.count
        guard let versionEnd = envelope[versionStart...].firstIndex(of: 0) else {
            throw LocalDataProtectionError.invalidEnvelopeEncoding
        }
        guard let version = String(
            data: envelope[versionStart..<versionEnd],
            encoding: .utf8
        ) else {
            throw LocalDataProtectionError.invalidEnvelopeEncoding
        }
        guard version == Self.envelopeVersion else {
            throw LocalDataProtectionError.unsupportedEnvelopeVersion(version)
        }
        let payloadStart = envelope.index(after: versionEnd)
        guard payloadStart < envelope.endIndex else {
            throw LocalDataProtectionError.malformedSealedBox
        }
        return try openCombined(Data(envelope[payloadStart...]), context: context)
    }

    private func sealedCombined(
        _ plaintext: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: context.associatedData()
            )
            guard let combined = sealedBox.combined else {
                throw LocalDataProtectionError.encryptionFailed
            }
            return combined
        } catch let error as LocalDataProtectionError {
            throw error
        } catch {
            throw LocalDataProtectionError.encryptionFailed
        }
    }

    private func openCombined(
        _ combined: Data,
        context: LocalDataProtectionContext
    ) throws -> Data {
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw LocalDataProtectionError.malformedSealedBox
        }

        do {
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: context.associatedData()
            )
        } catch {
            throw LocalDataProtectionError.authenticationFailed
        }
    }
}
