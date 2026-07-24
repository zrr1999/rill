import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import RillProviders

final class SherpaOnnxModelInstallerTests: XCTestCase {
  func testTarProcessCancellationTerminatesChildPromptly() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let execution = SherpaOnnxTarProcessExecution(process: process)
    let task = Task {
      try await execution.run()
    }

    for _ in 0..<100 where !process.isRunning {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(process.isRunning)

    let cancelledAt = ContinuousClock.now
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected tar child cancellation to throw.")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, received \(error).")
    }

    XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2))
    XCTAssertFalse(process.isRunning)
  }

  func testInstallPinnedLocalArchiveWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RILL_RUN_SHERPA_INSTALL_DOGFOOD"] == "1" else {
      throw XCTSkip(
        "Set RILL_RUN_SHERPA_INSTALL_DOGFOOD=1 to install a pinned local archive."
      )
    }
    guard let archivePath = environment["RILL_SHERPA_ARCHIVE"],
      let destinationPath = environment["RILL_SHERPA_INSTALL_ROOT"],
      let rawModelID = environment["RILL_SHERPA_MODEL_ID"],
      let modelID = SherpaOnnxModelID(rawValue: rawModelID)
    else {
      return XCTFail(
        "RILL_SHERPA_ARCHIVE, RILL_SHERPA_INSTALL_ROOT, and RILL_SHERPA_MODEL_ID are required."
      )
    }

    let archiveURL = URL(fileURLWithPath: archivePath)
    let destinationURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
    let descriptor = SherpaOnnxModelCatalog.descriptor(for: modelID)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: destinationURL,
      downloader: LocalSherpaArchiveDownloader(archiveURL: archiveURL),
      extractor: SherpaOnnxTarArchiveExtractor()
    )

    let installedURL = try await installer.install(descriptor)
    let isVerified = try await installer.verifyInstalledModel(descriptor)

    XCTAssertTrue(isVerified)
    XCTAssertEqual(installedURL.deletingLastPathComponent(), destinationURL.standardizedFileURL)
  }

  func testCatalogPinsExactReleaseAssetsAndRequiredLayouts() throws {
    let qwen = SherpaOnnxModelCatalog.qwen3ASR06BInt8
    XCTAssertEqual(qwen.id.rawValue, "qwen3-asr-0.6b-int8")
    XCTAssertEqual(qwen.architecture, .qwen3ASR)
    XCTAssertEqual(qwen.archiveByteCount, 878_702_423)
    XCTAssertEqual(
      qwen.archiveSHA256,
      "393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96"
    )
    XCTAssertEqual(
      qwen.installedFileInventorySHA256,
      "24fd5947756b66b37fb4cb7193450c6212c84eba976027fe42de788447af787d"
    )
    XCTAssertEqual(qwen.archiveURL.host, "github.com")
    XCTAssertEqual(
      Set(qwen.requiredEntries.map(\.relativePath)),
      ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer"]
    )

    let senseVoice = SherpaOnnxModelCatalog.senseVoiceSmallInt8
    XCTAssertEqual(senseVoice.id.rawValue, "sense-voice-small-int8")
    XCTAssertEqual(senseVoice.architecture, .senseVoice)
    XCTAssertEqual(senseVoice.archiveByteCount, 163_002_883)
    XCTAssertEqual(
      senseVoice.archiveSHA256,
      "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e"
    )
    XCTAssertEqual(
      senseVoice.installedFileInventorySHA256,
      "856703c2ab4cf4dc79cf3efb17df1ad18d3afcd5922d1be227af0955d646ae38"
    )
    XCTAssertEqual(
      Set(senseVoice.requiredEntries.map(\.relativePath)),
      ["model.int8.onnx", "tokens.txt", "LICENSE"]
    )

    let streamingPreview =
      SherpaOnnxModelCatalog.streamingZipformerBilingualPreviewInt8
    XCTAssertEqual(streamingPreview.architecture, .streamingTransducer)
    XCTAssertEqual(streamingPreview.archiveByteCount, 458_187_351)
    XCTAssertEqual(
      streamingPreview.archiveSHA256,
      "2b7c63322b32e5e0f2526043a1103366119ca58dd615cd7105a37c01db9553d7"
    )
    XCTAssertEqual(
      streamingPreview.installedFileInventorySHA256,
      "cea6f98992fd166743ea63ca27ebf87c6b99e11b6d7cf5ae3944e2977dcbfc53"
    )

    let pinnedDescriptors: [
      SherpaOnnxModelID: (UInt64, String, String)
    ] = [
      .funASRNano08BInt8: (
        841_730_611,
        "eb43d7ccc2e86b243f6a03b7df361033dda66db9523d1a92bf6aca2b50c9476b",
        "8be2559116da7fa361886d4079ce4de11ec338c530eae38f82d955a48e58a445"
      ),
      .funASRNano08BFP16: (
        1_030_076_153,
        "a07a996361aa2f8b2c4f47861fe01953b5509664efa3392b734580b1eeb362e3",
        "3ac066dff02daab16a9af1c4a64e1a9e2ae67b499310c030c047bf55b831b216"
      ),
      .omnilingualASRCTCV2300MInt8: (
        292_313_120,
        "951b32409aade32bd525310bb39e9666773ba3fc611a39e817f620936d76c631",
        "0969be2410ec23a4f8af72d01b9a34b9116f4f5f681f9a6dbd301d795dc7535b"
      ),
      .omnilingualASRCTCV21BInt8: (
        787_296_506,
        "f4deae6e6cbf4ca785b89eaa3836156581208bf977ea2e6d7ae84d7efcfc3a40",
        "8bc2f5b579365eba2ea3f5d9c818d726f3cafc205c98276209a42b1e234f9489"
      ),
      .cohereTranscribe2BInt8: (
        1_699_791_751,
        "bd582588d50685a795dcd2807ab77e11361b8312d96c53884682def45ab4206d",
        "b230d5c78f7b6a50246a1b175504c9d0f0c58aa3ef8e11a493bfd349f740d2ec"
      ),
    ]
    for (modelID, expected) in pinnedDescriptors {
      let descriptor = SherpaOnnxModelCatalog.descriptor(for: modelID)
      XCTAssertEqual(descriptor.archiveByteCount, expected.0)
      XCTAssertEqual(descriptor.archiveSHA256, expected.1)
      XCTAssertEqual(descriptor.installedFileInventorySHA256, expected.2)
      XCTAssertEqual(descriptor.archiveURL.host, "github.com")
    }
  }

  func testPublicDistributionCatalogAndInstallerExcludeNonPublicModels() async throws {
    XCTAssertEqual(
      SherpaOnnxModelCatalog.distributable.map(\.id),
      [.qwen3ASR06BInt8]
    )
    XCTAssertEqual(
      SherpaOnnxModelCatalog.candidateOnly.map(\.id),
      [.omnilingualASRCTCV2300MInt8, .omnilingualASRCTCV21BInt8]
    )
    XCTAssertEqual(
      SherpaOnnxModelCatalog.previewOnly.map(\.id),
      [.senseVoiceSmallInt8]
    )
    XCTAssertEqual(
      SherpaOnnxModelCatalog.compatibilityOnly.map(\.id),
      [.funASRNano08BInt8, .funASRNano08BFP16, .cohereTranscribe2BInt8]
    )
    XCTAssertEqual(
      SherpaOnnxModelCatalog.allKnown.map(\.id),
      [
        .qwen3ASR06BInt8,
        .omnilingualASRCTCV2300MInt8,
        .omnilingualASRCTCV21BInt8,
        .senseVoiceSmallInt8,
        .funASRNano08BInt8,
        .funASRNano08BFP16,
        .cohereTranscribe2BInt8,
        .streamingZipformerBilingualPreviewInt8,
      ]
    )
    XCTAssertNil(
      SherpaOnnxModelCatalog.distributableDescriptor(for: .senseVoiceSmallInt8)
    )
    XCTAssertNil(
      SherpaOnnxModelCatalog.distributableDescriptor(
        for: .streamingZipformerBilingualPreviewInt8
      )
    )
    XCTAssertNil(
      SherpaOnnxModelCatalog.distributableDescriptor(for: .cohereTranscribe2BInt8)
    )
    XCTAssertNil(
      SherpaOnnxModelCatalog.distributableDescriptor(for: .omnilingualASRCTCV2300MInt8)
    )
    XCTAssertNil(
      SherpaOnnxModelCatalog.distributableDescriptor(for: .omnilingualASRCTCV21BInt8)
    )

    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-preview-model-gate-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: destination) }
    let installer = SherpaOnnxModelInstaller(destinationRootURL: destination)

    do {
      _ = try await installer.install(.senseVoiceSmallInt8)
      XCTFail("A preview-only model must fail before filesystem or network work.")
    } catch {
      XCTAssertEqual(
        error as? SherpaOnnxModelInstallationError,
        .invalidCatalogDescriptor
      )
    }

    for candidate in [
      SherpaOnnxModelID.omnilingualASRCTCV2300MInt8,
      .omnilingualASRCTCV21BInt8,
    ] {
      do {
        _ = try await installer.install(candidate)
        XCTFail("A candidate-only model must fail before filesystem or network work.")
      } catch {
        XCTAssertEqual(
          error as? SherpaOnnxModelInstallationError,
          .invalidCatalogDescriptor
        )
      }
    }
    do {
      _ = try await installer.install(.streamingZipformerBilingualPreviewInt8)
      XCTFail("The fixed preview model must not enter the selectable public installer API.")
    } catch {
      XCTAssertEqual(
        error as? SherpaOnnxModelInstallationError,
        .invalidCatalogDescriptor
      )
    }
    do {
      _ = try await installer.install(.cohereTranscribe2BInt8)
      XCTFail("A retired compatibility model must fail before filesystem or network work.")
    } catch {
      XCTAssertEqual(
        error as? SherpaOnnxModelInstallationError,
        .invalidCatalogDescriptor
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testInstallerVerifiesExtractsAndAtomicallyPublishesPrivateModel() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    let extractor = FakeSherpaArchiveExtractor.safeFixture(rootName: fixture.rootName)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )
    let progress = InstallProgressRecorder()

    let installedURL = try await installer.install(
      fixture.descriptor,
      progressCallback: { progress.record($0) }
    )
    let extractionDestinationName = await extractor.lastExtractionDestinationName

    XCTAssertEqual(installedURL.deletingLastPathComponent(), fixture.destinationRootURL)
    XCTAssertEqual(
      installedURL.lastPathComponent,
      "model-qwen3-asr-0.6b-int8-\(fixture.descriptor.archiveSHA256.prefix(16))"
    )
    XCTAssertTrue(extractionDestinationName?.hasPrefix(".model-qwen3-asr-0.6b-int8-") == true)
    XCTAssertTrue(extractionDestinationName?.hasSuffix(".partial") == true)
    XCTAssertFalse(extractionDestinationName?.contains("(") == true)
    XCTAssertEqual(
      try Data(contentsOf: installedURL.appendingPathComponent("model.bin")),
      Data("trusted-model".utf8)
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: installedURL.appendingPathComponent("tokenizer/tokenizer.json").path
      )
    )
    XCTAssertEqual(try permissions(at: installedURL), 0o700)
    XCTAssertEqual(try permissions(at: installedURL.appendingPathComponent("model.bin")), 0o600)
    XCTAssertEqual(try permissions(at: fixture.destinationRootURL), 0o700)
    XCTAssertEqual(progress.last?.phase, .complete)
    XCTAssertEqual(progress.last?.completedByteCount, UInt64(fixture.archivePayload.count))
    let verified = try await installer.verifyInstalledModel(fixture.descriptor)
    let cachedURL = try await installer.existingInstalledURL(for: fixture.descriptor)
    XCTAssertTrue(verified)
    XCTAssertEqual(cachedURL, installedURL)
  }

  func testVerifiedCacheHitSkipsDownloadAndCorruptionForcesCleanReinstall() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    let extractor = FakeSherpaArchiveExtractor.safeFixture(rootName: fixture.rootName)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    let first = try await installer.install(fixture.descriptor)
    let second = try await installer.install(fixture.descriptor)
    let initialDownloadCount = await downloader.requestCount
    let initialExtractionCount = await extractor.extractionCount
    XCTAssertEqual(first, second)
    XCTAssertEqual(initialDownloadCount, 1)
    XCTAssertEqual(initialExtractionCount, 1)

    try Data("tampered".utf8).write(to: first.appendingPathComponent("model.bin"))
    let corruptedCacheURL = try await installer.existingInstalledURL(for: fixture.descriptor)
    XCTAssertNil(corruptedCacheURL)
    let repaired = try await installer.install(fixture.descriptor)
    let repairedDownloadCount = await downloader.requestCount
    let repairedExtractionCount = await extractor.extractionCount
    let repairedIsVerified = try await installer.verifyInstalledModel(fixture.descriptor)

    XCTAssertEqual(repaired, first)
    XCTAssertEqual(repairedDownloadCount, 2)
    XCTAssertEqual(repairedExtractionCount, 2)
    XCTAssertEqual(
      try Data(contentsOf: repaired.appendingPathComponent("model.bin")),
      Data("trusted-model".utf8)
    )
    XCTAssertTrue(repairedIsVerified)
  }

  func testForgedReceiptCannotAuthorizeTamperedInstalledFiles() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    let extractor = FakeSherpaArchiveExtractor.safeFixture(rootName: fixture.rootName)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    let installedURL = try await installer.install(fixture.descriptor)
    let modelURL = installedURL.appendingPathComponent("model.bin")
    try Data("forged-model".utf8).write(to: modelURL)
    try forgeReceiptFileRecord(
      at: installedURL.appendingPathComponent(".voxtype-sherpa-model.json"),
      relativePath: "model.bin",
      payload: Data("forged-model".utf8)
    )

    let cachedURL = try await installer.existingInstalledURL(for: fixture.descriptor)

    XCTAssertNil(cachedURL)
  }

  func testDigestMismatchStopsBeforeArchiveInspectionAndLeavesNoCandidate() async throws {
    let fixture = try InstallerFixture.make(archiveSHA256: String(repeating: "0", count: 64))
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    let extractor = FakeSherpaArchiveExtractor.safeFixture(rootName: fixture.rootName)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    await assertThrowsErrorAsync(try await installer.install(fixture.descriptor)) { error in
      XCTAssertEqual(error as? SherpaOnnxModelInstallationError, .archiveDigestMismatch)
    }

    let inspectionCount = await extractor.inspectionCount
    XCTAssertEqual(inspectionCount, 0)
    XCTAssertEqual(try destinationChildren(fixture.destinationRootURL), [])
  }

  func testInstalledInventoryMismatchStopsPublication() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    var files = FakeSherpaArchiveExtractor.safeFiles
    files["model.bin"] = Data("untrusted-model".utf8)
    let extractor = FakeSherpaArchiveExtractor(
      entries: FakeSherpaArchiveExtractor.safeEntries(rootName: fixture.rootName),
      files: files,
      extractionError: nil
    )
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    await assertThrowsErrorAsync(try await installer.install(fixture.descriptor)) { error in
      XCTAssertEqual(
        error as? SherpaOnnxModelInstallationError,
        .extractedTreeInvalid(path: "<inventory>")
      )
    }

    XCTAssertEqual(try destinationChildren(fixture.destinationRootURL), [])
  }

  func testArchivePreflightRejectsTraversalMultipleRootsAndNonRegularEntries() async throws {
    let attacks:
      [(
        name: String,
        entry: SherpaOnnxArchiveEntry,
        violation: SherpaOnnxArchiveSafetyViolation
      )] = [
        ("absolute", .init(path: "/outside", type: .regularFile), .absolutePath),
        (
          "traversal",
          .init(path: "fixture-model/../outside", type: .regularFile),
          .parentTraversal
        ),
        ("second-root", .init(path: "other-root/payload", type: .regularFile), .multipleRoots),
        (
          "symlink",
          .init(path: "fixture-model/link", type: .symbolicLink),
          .linkOrSpecialEntry
        ),
        (
          "hardlink",
          .init(path: "fixture-model/hard", type: .hardLink),
          .linkOrSpecialEntry
        ),
        (
          "device",
          .init(path: "fixture-model/device", type: .characterDevice),
          .linkOrSpecialEntry
        ),
      ]

    for attack in attacks {
      let fixture = try InstallerFixture.make(suffix: attack.name)
      defer { fixture.remove() }
      let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
      let extractor = FakeSherpaArchiveExtractor(
        entries: FakeSherpaArchiveExtractor.safeEntries(rootName: fixture.rootName)
          + [attack.entry],
        files: FakeSherpaArchiveExtractor.safeFiles,
        extractionError: nil
      )
      let installer = SherpaOnnxModelInstaller(
        destinationRootURL: fixture.destinationRootURL,
        downloader: downloader,
        extractor: extractor
      )

      await assertThrowsErrorAsync(try await installer.install(fixture.descriptor)) { error in
        guard
          case .unsafeArchiveEntry(_, let violation) =
            error as? SherpaOnnxModelInstallationError
        else {
          return XCTFail("Unexpected error for \(attack.name): \(error)")
        }
        XCTAssertEqual(violation, attack.violation)
      }
      let extractionCount = await extractor.extractionCount
      XCTAssertEqual(extractionCount, 0)
      XCTAssertEqual(try destinationChildren(fixture.destinationRootURL), [])
    }
  }

  func testExtractionFailureDoesNotPublishPartialDirectory() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = FakeSherpaArchiveDownloader(payload: fixture.archivePayload)
    let extractor = FakeSherpaArchiveExtractor(
      entries: FakeSherpaArchiveExtractor.safeEntries(rootName: fixture.rootName),
      files: FakeSherpaArchiveExtractor.safeFiles,
      extractionError: FakeExtractionError()
    )
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    await assertThrowsErrorAsync(try await installer.install(fixture.descriptor)) { error in
      XCTAssertEqual(error as? SherpaOnnxModelInstallationError, .extractionFailed)
    }

    XCTAssertEqual(try destinationChildren(fixture.destinationRootURL), [])
  }

  func testCancellationCleansStagingDirectory() async throws {
    let fixture = try InstallerFixture.make()
    defer { fixture.remove() }
    let downloader = SuspendingSherpaArchiveDownloader()
    let extractor = FakeSherpaArchiveExtractor.safeFixture(rootName: fixture.rootName)
    let installer = SherpaOnnxModelInstaller(
      destinationRootURL: fixture.destinationRootURL,
      downloader: downloader,
      extractor: extractor
    )

    let task = Task {
      try await installer.install(fixture.descriptor)
    }
    await downloader.waitUntilStarted()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch is CancellationError {
      // Expected.
    }

    XCTAssertEqual(try destinationChildren(fixture.destinationRootURL), [])
  }
}

private actor LocalSherpaArchiveDownloader: SherpaOnnxArchiveDownloading {
  private let archiveURL: URL

  init(archiveURL: URL) {
    self.archiveURL = archiveURL
  }

  func download(
    _ request: SherpaOnnxArchiveDownloadRequest,
    progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  ) async throws -> SherpaOnnxDownloadedArchive {
    let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    progressCallback?(byteCount, request.expectedByteCount)
    return SherpaOnnxDownloadedArchive(fileURL: archiveURL) {}
  }
}

private struct InstallerFixture {
  let temporaryRootURL: URL
  let destinationRootURL: URL
  let archivePayload: Data
  let rootName: String
  let descriptor: SherpaOnnxModelDescriptor

  static func make(
    suffix: String = UUID().uuidString,
    archiveSHA256: String? = nil
  ) throws -> InstallerFixture {
    let temporaryRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-sherpa-installer-test-\(suffix)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporaryRootURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let archivePayload = Data("small-trusted-archive-fixture".utf8)
    let digest = archiveSHA256 ?? sha256Hex(archivePayload)
    let rootName = "fixture-model"
    return .init(
      temporaryRootURL: temporaryRootURL,
      destinationRootURL: temporaryRootURL.appendingPathComponent("models", isDirectory: true),
      archivePayload: archivePayload,
      rootName: rootName,
      descriptor: SherpaOnnxModelDescriptor(
        id: .qwen3ASR06BInt8,
        architecture: .qwen3ASR,
        archiveURL: URL(
          string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/fixture.tar.bz2"
        )!,
        archiveByteCount: UInt64(archivePayload.count),
        archiveSHA256: digest,
        archiveRootDirectoryName: rootName,
        installedFileInventorySHA256:
          "3183a04304ae12db805f721004f7f9345c08af6383e2f5950e46773058e1c95c",
        requiredEntries: [
          .init(relativePath: "model.bin", kind: .regularFile),
          .init(relativePath: "tokenizer", kind: .directory),
        ]
      )
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: temporaryRootURL)
  }
}

private actor FakeSherpaArchiveDownloader: SherpaOnnxArchiveDownloading {
  private let payload: Data
  private(set) var requestCount = 0

  init(payload: Data) {
    self.payload = payload
  }

  func download(
    _ request: SherpaOnnxArchiveDownloadRequest,
    progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  ) async throws -> SherpaOnnxDownloadedArchive {
    requestCount += 1
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-fake-sherpa-download-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let fileURL = root.appendingPathComponent("fixture.tar.bz2")
    try payload.write(to: fileURL)
    progressCallback?(UInt64(payload.count), request.expectedByteCount)
    return SherpaOnnxDownloadedArchive(fileURL: fileURL) {
      try? FileManager.default.removeItem(at: root)
    }
  }
}

private actor SuspendingSherpaArchiveDownloader: SherpaOnnxArchiveDownloading {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func download(
    _ request: SherpaOnnxArchiveDownloadRequest,
    progressCallback: (@Sendable (UInt64, UInt64) -> Void)?
  ) async throws -> SherpaOnnxDownloadedArchive {
    started = true
    let waiters = self.waiters
    self.waiters.removeAll()
    for waiter in waiters { waiter.resume() }
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
}

private actor FakeSherpaArchiveExtractor: SherpaOnnxArchiveExtracting {
  static let safeFiles: [String: Data] = [
    "model.bin": Data("trusted-model".utf8),
    "tokenizer/tokenizer.json": Data("{}".utf8),
  ]

  let entries: [SherpaOnnxArchiveEntry]
  let files: [String: Data]
  let extractionError: (any Error & Sendable)?
  private(set) var inspectionCount = 0
  private(set) var extractionCount = 0
  private(set) var lastExtractionDestinationName: String?

  init(
    entries: [SherpaOnnxArchiveEntry],
    files: [String: Data],
    extractionError: (any Error & Sendable)?
  ) {
    self.entries = entries
    self.files = files
    self.extractionError = extractionError
  }

  static func safeFixture(rootName: String) -> FakeSherpaArchiveExtractor {
    .init(
      entries: safeEntries(rootName: rootName),
      files: safeFiles,
      extractionError: nil
    )
  }

  static func safeEntries(rootName: String) -> [SherpaOnnxArchiveEntry] {
    [
      .init(path: "\(rootName)/", type: .directory),
      .init(path: "\(rootName)/model.bin", type: .regularFile),
      .init(path: "\(rootName)/tokenizer/", type: .directory),
      .init(path: "\(rootName)/tokenizer/tokenizer.json", type: .regularFile),
    ]
  }

  func inspectArchive(at archiveURL: URL) async throws -> [SherpaOnnxArchiveEntry] {
    inspectionCount += 1
    return entries
  }

  func extractArchive(
    at archiveURL: URL,
    archiveRootDirectoryName: String,
    to destinationURL: URL
  ) async throws {
    extractionCount += 1
    lastExtractionDestinationName = destinationURL.lastPathComponent
    if let extractionError { throw extractionError }
    for (relativePath, payload) in files {
      let fileURL = destinationURL.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o755)]
      )
      try payload.write(to: fileURL)
    }
  }
}

private struct FakeExtractionError: Error, Sendable {}

private final class InstallProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SherpaOnnxModelInstallationProgress] = []

  var last: SherpaOnnxModelInstallationProgress? {
    lock.withLock { values.last }
  }

  func record(_ value: SherpaOnnxModelInstallationProgress) {
    lock.withLock { values.append(value) }
  }
}

private func permissions(at url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private func destinationChildren(_ url: URL) throws -> [String] {
  guard FileManager.default.fileExists(atPath: url.path) else { return [] }
  return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func forgeReceiptFileRecord(
  at receiptURL: URL,
  relativePath: String,
  payload: Data
) throws {
  let receiptData = try Data(contentsOf: receiptURL)
  var receipt = try XCTUnwrap(
    JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
  )
  var files = try XCTUnwrap(receipt["files"] as? [[String: Any]])
  let index = try XCTUnwrap(files.firstIndex { $0["relativePath"] as? String == relativePath })
  files[index]["byteCount"] = payload.count
  files[index]["sha256"] = sha256Hex(payload)
  receipt["files"] = files
  let forged = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
  try forged.write(to: receiptURL)
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void = { _ in }
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw.")
  } catch {
    errorHandler(error)
  }
}
