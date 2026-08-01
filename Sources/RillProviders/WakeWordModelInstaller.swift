import CryptoKit
import Foundation

public struct WakeWordModelInstallation: Equatable, Sendable {
    public let modelDirectory: URL
    public let encoder: URL
    public let decoder: URL
    public let joiner: URL
    public let tokens: URL
    public let englishLexicon: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        encoder = modelDirectory.appendingPathComponent(WakeWordModelCatalog.encoderFileName)
        decoder = modelDirectory.appendingPathComponent(WakeWordModelCatalog.decoderFileName)
        joiner = modelDirectory.appendingPathComponent(WakeWordModelCatalog.joinerFileName)
        tokens = modelDirectory.appendingPathComponent(WakeWordModelCatalog.tokensFileName)
        englishLexicon = modelDirectory.appendingPathComponent(
            WakeWordModelCatalog.englishLexiconFileName
        )
    }
}

public struct WakeWordModelInstallationProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case checking
        case downloading
        case verifying
        case extracting
        case publishing
        case complete
    }

    public let phase: Phase
    public let completedByteCount: UInt64
    public let totalByteCount: UInt64

    public init(
        phase: Phase,
        completedByteCount: UInt64,
        totalByteCount: UInt64
    ) {
        self.phase = phase
        self.completedByteCount = completedByteCount
        self.totalByteCount = totalByteCount
    }
}

public enum WakeWordModelInstallationError: Error, LocalizedError, Sendable, Equatable {
    case distributionLicenseUnverified
    case invalidDestination
    case downloadFailed
    case archiveInvalid
    case archiveDigestMismatch
    case unsafeArchive
    case missingRequiredFile(String)
    case retainedFileMismatch(String)
    case publicationFailed

    public var errorDescription: String? {
        switch self {
        case .distributionLicenseUnverified:
            return "The wake-word model license has not been approved for public distribution."
        case .invalidDestination:
            return "The wake-word model destination is invalid."
        case .downloadFailed:
            return "The wake-word model could not be downloaded."
        case .archiveInvalid:
            return "The wake-word model archive is invalid."
        case .archiveDigestMismatch:
            return "The wake-word model archive failed its integrity check."
        case .unsafeArchive:
            return "The wake-word model archive contains an unsafe entry."
        case .missingRequiredFile(let path):
            return "The wake-word model archive is missing \(path)."
        case .retainedFileMismatch(let path):
            return "The wake-word model file failed verification: \(path)."
        case .publicationFailed:
            return "The wake-word model could not be published."
        }
    }
}

public actor WakeWordModelInstaller {
    private struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let modelID: String
        let archiveURL: String
        let archiveByteCount: UInt64
        let archiveSHA256: String
        let distributionLicenseEvidence: WakeWordModelLicenseEvidence?
        let retainedFiles: [ReceiptFile]
    }

    private struct ReceiptFile: Codable, Equatable {
        let name: String
        let byteCount: UInt64
        let sha256: String
    }

    private static let receiptFileName = ".rill-wake-word-model.json"
    private static let maximumArchiveEntryCount = 10_000

    public nonisolated let destinationRootURL: URL
    public nonisolated let allowsUnverifiedModelLicense: Bool

    private let descriptor: WakeWordModelDescriptor
    private let downloader: any SherpaOnnxArchiveDownloading
    private let extractor: any SherpaOnnxArchiveExtracting

    public init(
        destinationRootURL: URL,
        descriptor: WakeWordModelDescriptor = WakeWordModelCatalog.defaultModel,
        allowsUnverifiedModelLicense: Bool =
            WakeWordModelInstaller.defaultAllowsUnverifiedModelLicense
    ) {
        self.destinationRootURL = destinationRootURL
        self.descriptor = descriptor
        self.allowsUnverifiedModelLicense = allowsUnverifiedModelLicense
        downloader = SherpaOnnxURLSessionArchiveDownloader()
        extractor = SherpaOnnxTarArchiveExtractor()
    }

    public nonisolated static var defaultAllowsUnverifiedModelLicense: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    public func installedModel() throws -> WakeWordModelInstallation? {
        let publicationURL = publicationURL()
        guard try validatePublication(at: publicationURL) else { return nil }
        return WakeWordModelInstallation(modelDirectory: publicationURL)
    }

    public func install(
        progress: (@Sendable (WakeWordModelInstallationProgress) -> Void)? = nil
    ) async throws -> WakeWordModelInstallation {
        guard descriptor.distributionLicenseVerified || allowsUnverifiedModelLicense else {
            throw WakeWordModelInstallationError.distributionLicenseUnverified
        }
        let total = descriptor.archiveByteCount
        progress?(.init(phase: .checking, completedByteCount: 0, totalByteCount: total))
        try preparePrivateDestination()
        if let installed = try installedModel() {
            progress?(.init(phase: .complete, completedByteCount: total, totalByteCount: total))
            return installed
        }

        let downloaded: SherpaOnnxDownloadedArchive
        do {
            downloaded = try await downloader.download(
                SherpaOnnxArchiveDownloadRequest(
                    sourceURL: descriptor.archiveURL,
                    expectedByteCount: total
                ),
                progressCallback: { completed, reportedTotal in
                    progress?(
                        .init(
                            phase: .downloading,
                            completedByteCount: completed,
                            totalByteCount: reportedTotal > 0 ? reportedTotal : total
                        )
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WakeWordModelInstallationError.downloadFailed
        }
        defer { downloaded.discard() }

        progress?(.init(phase: .verifying, completedByteCount: total, totalByteCount: total))
        let archiveMetadata = try Self.fileMetadata(downloaded.fileURL)
        guard archiveMetadata.byteCount == descriptor.archiveByteCount else {
            throw WakeWordModelInstallationError.archiveInvalid
        }
        guard archiveMetadata.sha256 == descriptor.archiveSHA256 else {
            throw WakeWordModelInstallationError.archiveDigestMismatch
        }

        let entries: [SherpaOnnxArchiveEntry]
        do {
            entries = try await extractor.inspectArchive(at: downloaded.fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WakeWordModelInstallationError.archiveInvalid
        }
        try validateArchiveEntries(entries)

        let operationID = UUID().uuidString.lowercased()
        let extractionURL = destinationRootURL.appendingPathComponent(
            ".wake-word-\(operationID).extracted",
            isDirectory: true
        )
        let stagingURL = destinationRootURL.appendingPathComponent(
            ".wake-word-\(operationID).partial",
            isDirectory: true
        )
        try createPrivateDirectory(extractionURL)
        try createPrivateDirectory(stagingURL)
        defer {
            try? FileManager.default.removeItem(at: extractionURL)
            try? FileManager.default.removeItem(at: stagingURL)
        }

        progress?(.init(phase: .extracting, completedByteCount: total, totalByteCount: total))
        do {
            try await extractor.extractArchive(
                at: downloaded.fileURL,
                archiveRootDirectoryName: descriptor.archiveRootDirectoryName,
                to: extractionURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WakeWordModelInstallationError.archiveInvalid
        }

        progress?(.init(phase: .publishing, completedByteCount: total, totalByteCount: total))
        for file in descriptor.retainedFiles {
            try Task.checkCancellation()
            let source = extractionURL.appendingPathComponent(file.sourceRelativePath)
            guard try Self.isRegularNonSymbolicFile(source) else {
                throw WakeWordModelInstallationError.missingRequiredFile(
                    file.sourceRelativePath
                )
            }
            let metadata = try Self.fileMetadata(source)
            guard metadata.byteCount == file.byteCount, metadata.sha256 == file.sha256 else {
                throw WakeWordModelInstallationError.retainedFileMismatch(
                    file.sourceRelativePath
                )
            }
            let destination = stagingURL.appendingPathComponent(file.publishedFileName)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw WakeWordModelInstallationError.publicationFailed
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: destination.path
            )
        }
        let receiptData = try JSONEncoder().encode(expectedReceipt())
        try receiptData.write(
            to: stagingURL.appendingPathComponent(Self.receiptFileName),
            options: .atomic
        )
        guard try validatePublication(at: stagingURL) else {
            throw WakeWordModelInstallationError.publicationFailed
        }

        let publicationURL = publicationURL()
        let replacedURL = destinationRootURL.appendingPathComponent(
            ".wake-word-\(operationID).replaced",
            isDirectory: true
        )
        do {
            if FileManager.default.fileExists(atPath: publicationURL.path) {
                try FileManager.default.moveItem(at: publicationURL, to: replacedURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: publicationURL)
            try? FileManager.default.removeItem(at: replacedURL)
        } catch {
            if FileManager.default.fileExists(atPath: replacedURL.path),
                !FileManager.default.fileExists(atPath: publicationURL.path)
            {
                try? FileManager.default.moveItem(at: replacedURL, to: publicationURL)
            }
            throw WakeWordModelInstallationError.publicationFailed
        }

        progress?(.init(phase: .complete, completedByteCount: total, totalByteCount: total))
        return WakeWordModelInstallation(modelDirectory: publicationURL)
    }

    private func validateArchiveEntries(_ entries: [SherpaOnnxArchiveEntry]) throws {
        guard !entries.isEmpty, entries.count <= Self.maximumArchiveEntryCount else {
            throw WakeWordModelInstallationError.unsafeArchive
        }
        var names = Set<String>()
        for entry in entries {
            let path = entry.path
            guard
                !path.hasPrefix("/"),
                !path.contains("\0"),
                !path.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(".."),
                names.insert(path).inserted
            else {
                throw WakeWordModelInstallationError.unsafeArchive
            }
            switch entry.type {
            case .regularFile, .directory:
                break
            case .symbolicLink, .hardLink, .characterDevice, .blockDevice,
                .fifo, .socket, .unknown:
                throw WakeWordModelInstallationError.unsafeArchive
            }
        }
    }

    private func preparePrivateDestination() throws {
        do {
            try createPrivateDirectory(destinationRootURL)
            let values = try destinationRootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw WakeWordModelInstallationError.invalidDestination
            }
        } catch let error as WakeWordModelInstallationError {
            throw error
        } catch {
            throw WakeWordModelInstallationError.invalidDestination
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func publicationURL() -> URL {
        destinationRootURL.appendingPathComponent(
            "model-\(descriptor.id.rawValue)-\(descriptor.archiveSHA256.prefix(16))",
            isDirectory: true
        )
    }

    private func validatePublication(at url: URL) throws -> Bool {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            return false
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            return false
        }
        for file in descriptor.retainedFiles {
            let fileURL = url.appendingPathComponent(file.publishedFileName)
            guard try Self.isRegularNonSymbolicFile(fileURL) else { return false }
            let metadata = try Self.fileMetadata(fileURL)
            guard metadata.byteCount == file.byteCount, metadata.sha256 == file.sha256 else {
                return false
            }
        }
        let receiptURL = url.appendingPathComponent(Self.receiptFileName)
        guard try Self.isRegularNonSymbolicFile(receiptURL) else { return false }
        let receiptData = try Data(contentsOf: receiptURL)
        guard receiptData.count <= 32 * 1_024 else { return false }
        return try JSONDecoder().decode(Receipt.self, from: receiptData) == expectedReceipt()
    }

    private func expectedReceipt() -> Receipt {
        return Receipt(
            schemaVersion: 2,
            modelID: descriptor.id.rawValue,
            archiveURL: descriptor.archiveURL.absoluteString,
            archiveByteCount: descriptor.archiveByteCount,
            archiveSHA256: descriptor.archiveSHA256,
            distributionLicenseEvidence: descriptor.distributionLicenseEvidence,
            retainedFiles: descriptor.retainedFiles.map {
                ReceiptFile(
                    name: $0.publishedFileName,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256
                )
            }
        )
    }

    private static func isRegularNonSymbolicFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func fileMetadata(_ url: URL) throws -> (byteCount: UInt64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        while true {
            let data = try handle.read(upToCount: 1 * 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            byteCount += UInt64(data.count)
            hasher.update(data: data)
        }
        return (
            byteCount,
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
