import Foundation
import XCTest
@testable import RillCore
@testable import RillPlatform

final class RillStorageResiduePurgerTests: XCTestCase {
    func testPurgeRunsRawStorageAndTemporaryArtifactCleanup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = try createOldArtifact(in: directory)
        let rawPurger = RawStoragePurger()
        let service = RillTemporaryFileCleanupService(
            janitor: RillTemporaryFileJanitor(temporaryDirectory: directory)
        )
        let purger = RillStorageResiduePurger(
            rawStoragePurger: rawPurger,
            temporaryFileCleanupService: service
        )

        try await purger.purgeSensitiveStorageResidue()

        let rawPurgeCallCount = await rawPurger.callCount()
        XCTAssertEqual(rawPurgeCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testPurgeStillCleansTemporaryArtifactsWhenRawStorageFailsAndRedactsCause() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = try createOldArtifact(in: directory)
        let rawPurger = RawStoragePurger(shouldFail: true)
        let service = RillTemporaryFileCleanupService(
            janitor: RillTemporaryFileJanitor(temporaryDirectory: directory)
        )
        let purger = RillStorageResiduePurger(
            rawStoragePurger: rawPurger,
            temporaryFileCleanupService: service
        )

        do {
            try await purger.purgeSensitiveStorageResidue()
            XCTFail("Expected a component-level purge failure")
        } catch let error as RillStorageResiduePurgeError {
            XCTAssertEqual(error.failedComponents, [.rawStorage])
            XCTAssertEqual(error.temporaryFileFailureCount, 0)
            XCTAssertEqual(error.errorDescription, "Storage residue purge incomplete.")
            XCTAssertFalse(error.localizedDescription.contains(RawStoragePurger.sensitiveFailureText))
        }

        let rawPurgeCallCount = await rawPurger.callCount()
        XCTAssertEqual(rawPurgeCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    }

    func testPurgeReturnsOnlyTemporaryFailureCountsAndTypes() async throws {
        let directory = try makeTemporaryDirectory()
        let parent = directory.deletingLastPathComponent()
        let link = parent.appendingPathComponent("rill-purger-link-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let rawPurger = RawStoragePurger()
        let service = RillTemporaryFileCleanupService(
            janitor: RillTemporaryFileJanitor(temporaryDirectory: link)
        )
        let purger = RillStorageResiduePurger(
            rawStoragePurger: rawPurger,
            temporaryFileCleanupService: service
        )

        do {
            try await purger.purgeSensitiveStorageResidue()
            XCTFail("Expected a temporary-artifact purge failure")
        } catch let error as RillStorageResiduePurgeError {
            XCTAssertEqual(error.failedComponents, [.temporaryArtifacts])
            XCTAssertEqual(error.temporaryFileFailureCount, 1)
            XCTAssertEqual(error.temporaryFileFailureOperations, [.inspectTemporaryDirectory])
            XCTAssertEqual(error.temporaryFileFailureArtifactKinds, [])
            XCTAssertFalse(error.localizedDescription.contains(link.path))
            XCTAssertFalse(error.localizedDescription.contains(directory.path))
        }

        let rawPurgeCallCount = await rawPurger.callCount()
        XCTAssertEqual(rawPurgeCallCount, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-residue-purger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func createOldArtifact(in directory: URL) throws -> URL {
        let artifact = directory.appendingPathComponent("rill-orphan.wav")
        try Data("temporary".utf8).write(to: artifact)
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date().addingTimeInterval(
                    -RillTemporaryFileJanitor.defaultMinimumAge - 60
                )
            ],
            ofItemAtPath: artifact.path
        )
        return artifact
    }
}

private actor RawStoragePurger: StorageResiduePurging {
    static let sensitiveFailureText = "/Users/private/Library/Application Support/Rill.sqlite"

    private let shouldFail: Bool
    private var calls = 0

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func purgeSensitiveStorageResidue() async throws {
        calls += 1
        if shouldFail {
            throw RawStoragePurgeFailure.failed(Self.sensitiveFailureText)
        }
    }

    func callCount() -> Int {
        calls
    }
}

private enum RawStoragePurgeFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(text): text
        }
    }
}
