import Foundation
import RillCore

/// Serializes process-wide cleanup of Rill-owned temporary artifacts.
///
/// The actor intentionally performs the synchronous scan without suspension so startup cleanup
/// and history maintenance cannot race while inspecting and removing the same artifact.
public actor RillTemporaryFileCleanupService {
    private let janitor: RillTemporaryFileJanitor

    public init(janitor: RillTemporaryFileJanitor = RillTemporaryFileJanitor()) {
        self.janitor = janitor
    }

    public func cleanupOrphans(now: Date = Date()) -> RillTemporaryFileJanitor.Report {
        janitor.cleanupOrphans(now: now)
    }

    public func cleanupStartupOrphans(now: Date = Date()) -> RillTemporaryFileJanitor.Report {
        janitor.cleanupStartupOrphans(now: now)
    }

    public func cleanupRecoveryArtifacts() -> RillTemporaryFileJanitor.Report {
        janitor.cleanupRecoveryArtifacts()
    }
}

/// Physically purges both database residue and abandoned Rill temporary artifacts.
///
/// Both components are attempted on every call. Underlying errors are deliberately discarded;
/// callers receive only a stable component/type/count summary suitable for privacy-safe retries.
public struct RillStorageResiduePurger: StorageResiduePurging {
    private let rawStoragePurger: any StorageResiduePurging
    private let temporaryFileCleanupService: RillTemporaryFileCleanupService

    public init(
        rawStoragePurger: any StorageResiduePurging,
        temporaryFileCleanupService: RillTemporaryFileCleanupService
    ) {
        self.rawStoragePurger = rawStoragePurger
        self.temporaryFileCleanupService = temporaryFileCleanupService
    }

    public func purgeSensitiveStorageResidue() async throws {
        async let rawStorageSucceeded = Self.purgeRawStorage(rawStoragePurger)
        async let temporaryReport = temporaryFileCleanupService.cleanupOrphans()

        let (didPurgeRawStorage, report) = await (rawStorageSucceeded, temporaryReport)
        guard didPurgeRawStorage, report.failureCount == 0 else {
            throw RillStorageResiduePurgeError(
                rawStorageFailed: !didPurgeRawStorage,
                temporaryFileReport: report
            )
        }
    }

    private static func purgeRawStorage(_ purger: any StorageResiduePurging) async -> Bool {
        do {
            try await purger.purgeSensitiveStorageResidue()
            return true
        } catch {
            return false
        }
    }
}

public struct RillStorageResiduePurgeError: Error, LocalizedError, Sendable, Equatable {
    public enum Component: String, Sendable, Equatable {
        case rawStorage = "raw-storage"
        case temporaryArtifacts = "temporary-artifacts"
    }

    public let failedComponents: [Component]
    public let temporaryFileFailureCount: Int
    public let temporaryFileFailureOperations: [RillTemporaryFileJanitor.FailureOperation]
    public let temporaryFileFailureArtifactKinds: [RillTemporaryFileJanitor.ArtifactKind]

    public var errorDescription: String? {
        "Storage residue purge incomplete."
    }

    fileprivate init(
        rawStorageFailed: Bool,
        temporaryFileReport: RillTemporaryFileJanitor.Report
    ) {
        var components: [Component] = []
        if rawStorageFailed {
            components.append(.rawStorage)
        }
        if temporaryFileReport.failureCount > 0 {
            components.append(.temporaryArtifacts)
        }
        failedComponents = components
        temporaryFileFailureCount = temporaryFileReport.failureCount
        temporaryFileFailureOperations = Self.uniqueSorted(
            temporaryFileReport.failures.map(\.operation)
        )
        temporaryFileFailureArtifactKinds = Self.uniqueSorted(
            temporaryFileReport.failures.compactMap(\.artifactKind)
        )
    }

    private static func uniqueSorted<T: RawRepresentable & Equatable>(
        _ values: [T]
    ) -> [T] where T.RawValue == String {
        values.reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
        .sorted { $0.rawValue < $1.rawValue }
    }
}
