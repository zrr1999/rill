import Foundation

public enum PrivacyNoticeDocumentError: Error, LocalizedError, Equatable, Sendable {
    case missingResource
    case invalidEncoding
    case emptyDocument
    case documentTooLarge
    case missingRequiredSection(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "The bundled technical privacy notice is unavailable."
        case .invalidEncoding:
            return "The bundled technical privacy notice is not valid UTF-8."
        case .emptyDocument:
            return "The bundled technical privacy notice is empty."
        case .documentTooLarge:
            return "The bundled technical privacy notice exceeds its size limit."
        case .missingRequiredSection(let section):
            return "The bundled technical privacy notice is missing: \(section)"
        }
    }
}

public struct PrivacyNoticeDocument: Identifiable, Equatable, Sendable {
    public static let resourceName = "PRIVACY"
    public static let resourceExtension = "md"
    public static let maximumByteCount = 256 * 1_024

    private static let requiredSections = [
        "# Rill Technical Privacy and Data Flow Notice",
        "Last updated:",
        "## Data processed by Rill",
        "## Network destinations",
        "## Local storage and retention",
        "## Your controls",
        "## Product boundaries",
        "# Rill 技术隐私与数据流说明",
        "## 网络目的地",
        "## 本地存储与留存",
        "## 用户控制",
        "## 产品边界",
    ]

    public static let bundled: PrivacyNoticeDocument? = try? load(from: .main)

    public let markdown: String

    public var id: String { "rill-technical-privacy-notice" }

    public init(markdown: String) throws {
        let utf8Count = markdown.lengthOfBytes(using: .utf8)
        guard utf8Count > 0 else {
            throw PrivacyNoticeDocumentError.emptyDocument
        }
        guard utf8Count <= Self.maximumByteCount else {
            throw PrivacyNoticeDocumentError.documentTooLarge
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrivacyNoticeDocumentError.emptyDocument
        }
        for section in Self.requiredSections where !markdown.contains(section) {
            throw PrivacyNoticeDocumentError.missingRequiredSection(section)
        }
        self.markdown = markdown
    }

    public static func load(from bundle: Bundle) throws -> PrivacyNoticeDocument {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw PrivacyNoticeDocumentError.missingResource
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumByteCount else {
            throw PrivacyNoticeDocumentError.documentTooLarge
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw PrivacyNoticeDocumentError.invalidEncoding
        }
        return try PrivacyNoticeDocument(markdown: markdown)
    }
}
