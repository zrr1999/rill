import Foundation
import Testing

@testable import RillPlatform

struct RimeProfileInstallerTests {
  @Test func freshInstallationUsesOnlyBundledDataEvenWhenSquirrelIsRunning() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let installer = RimeProfileInstaller(helperBundle: fixture.helper)
    // A fresh install has no migration source or userdb and must never query Squirrel.
    try FileManager.default.removeItem(at: fixture.source)
    try await installer.prepareInstallation(
      importing: nil, to: fixture.destination, application: fixture.application,
      sourceIsStopped: {
        Issue.record("Fresh installation consulted the optional migration source")
        return false
      }, inputMethodIsStopped: { true })
    #expect(FileManager.default.fileExists(atPath: fixture.application.path))
    #expect(
      try String(
        contentsOf: fixture.destination.appendingPathComponent("rill_pinyin.schema.yaml"),
        encoding: .utf8) == "bundled schema")
    #expect(
      try String(
        contentsOf: fixture.destination.appendingPathComponent("opencc/s2t.json"),
        encoding: .utf8) == "shared")
    await #expect(throws: RimeProfileImportError.self) {
      try await installer.prepareInstallation(
        importing: nil, to: fixture.destination, application: fixture.application,
        inputMethodIsStopped: { true })
    }
  }

  @Test func freshInstallationRefusesAnActiveRillInputMethod() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let installer = RimeProfileInstaller(helperBundle: fixture.helper)
    await #expect(throws: RimeProfileImportError.self) {
      try await installer.prepareInstallation(
        importing: nil, to: fixture.destination, application: fixture.application,
        inputMethodIsStopped: { false })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.application.path))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_IME_VALIDATION_BUNDLE"] != nil))
  func installPackagedDefaultProfileWithoutAMigrationSource() async throws {
    let bundle = try #require(ProcessInfo.processInfo.environment["RILL_IME_VALIDATION_BUNDLE"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = RimeProfileInstaller(helperBundle: URL(fileURLWithPath: bundle))
    try await installer.prepareInstallation(
      importing: nil, to: root.appendingPathComponent("profile"),
      application: root.appendingPathComponent("RillInputMethod.app"),
      sourceIsStopped: { false }, inputMethodIsStopped: { true })
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "profile/build/pinyin_simp.table.bin"
        ).path))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_IME_VALIDATION_ROOT"] != nil))
  func migrateProvidedFrozenProfileWithThePackagedEngine() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["RILL_IME_VALIDATION_ROOT"])
    let bundle = try #require(ProcessInfo.processInfo.environment["RILL_IME_VALIDATION_BUNDLE"])
    let root = URL(fileURLWithPath: path)
    let source = root.appendingPathComponent("original")
    let destination = root.appendingPathComponent("migrated")
    let importer = RimeProfileInstaller(helperBundle: URL(fileURLWithPath: bundle))
    try await importer.prepareInstallation(
      importing: source, to: destination,
      application: root.appendingPathComponent("migrated.app"),
      sourceIsStopped: { true }, inputMethodIsStopped: { true })
    let before = try RimeProfileInstaller.fingerprints(
      source.appendingPathComponent("wanxiang.userdb"))
    #expect(
      try RimeProfileInstaller.fingerprints(destination.appendingPathComponent("wanxiang.userdb"))
        == before)
    #expect(
      FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("build/wanxiang.table.bin").path))
  }

  @Test func importPreservesCompleteUserDatabaseAndAddsMissingSharedData() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let importer = RimeProfileInstaller(helperBundle: fixture.helper)
    let before = try RimeProfileInstaller.fingerprints(fixture.source)
    try await importer.prepareInstallation(
      importing: fixture.source, to: fixture.destination,
      application: fixture.application, sourceIsStopped: { true }, inputMethodIsStopped: { true })
    #expect(try RimeProfileInstaller.fingerprints(fixture.source) == before)
    #expect(
      try Data(contentsOf: fixture.destination.appendingPathComponent("wanxiang.userdb/000001.log"))
        == fixture.databaseBytes)
    #expect(
      try String(
        contentsOf: fixture.destination.appendingPathComponent("opencc/s2t.json"), encoding: .utf8)
        == "shared")
    #expect(
      try String(
        contentsOf: fixture.destination.appendingPathComponent("opencc/custom.json"),
        encoding: .utf8) == "user override")
    #expect(FileManager.default.fileExists(atPath: fixture.application.path))
    let installation = try String(
      contentsOf: fixture.destination.appendingPathComponent("installation.yaml"), encoding: .utf8)
    #expect(installation.contains("installation_id: 'rill-"))
    #expect(!installation.contains("old-installation-id"))
    await #expect(throws: RimeProfileImportError.self) {
      try await importer.prepareInstallation(
        importing: fixture.source, to: fixture.destination,
        application: fixture.application, sourceIsStopped: { true }, inputMethodIsStopped: { true })
    }
  }

  @Test func activeWriterAndSymlinkedProfilesCannotBeInstalled() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let importer = RimeProfileInstaller(helperBundle: fixture.helper)
    await #expect(throws: RimeProfileImportError.self) {
      try await importer.prepareInstallation(
        importing: fixture.source, to: fixture.destination,
        application: fixture.application, sourceIsStopped: { false }, inputMethodIsStopped: { true }
      )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    try FileManager.default.createSymbolicLink(
      at: fixture.source.appendingPathComponent("linked-data"),
      withDestinationURL: fixture.shared)
    await #expect(throws: RimeProfileImportError.self) {
      try await importer.prepareInstallation(
        importing: fixture.source, to: fixture.destination,
        application: fixture.application, sourceIsStopped: { true }, inputMethodIsStopped: { true })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.application.path))
  }

  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var source: URL { root.appendingPathComponent("source") }
    var shared: URL { helper.appendingPathComponent("Contents/Resources/SharedData") }
    var helper: URL { root.appendingPathComponent("helper.app") }
    var bundled: URL { helper.appendingPathComponent("Contents/Resources/DefaultProfile") }
    var destination: URL { root.appendingPathComponent("target/InputMethod") }
    var application: URL { root.appendingPathComponent("apps/RillInputMethod.app") }
    let databaseBytes = Data([0, 255, 17, 0, 28, 3])

    init() throws {
      for url in [
        source.appendingPathComponent("wanxiang.userdb"), source.appendingPathComponent("opencc"),
        shared.appendingPathComponent("opencc"), helper.appendingPathComponent("Contents/Helpers"),
        bundled,
      ] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
      try databaseBytes.write(to: source.appendingPathComponent("wanxiang.userdb/000001.log"))
      try Data("schema".utf8).write(to: source.appendingPathComponent("wanxiang.schema.yaml"))
      try Data("bundled schema".utf8).write(
        to: bundled.appendingPathComponent("rill_pinyin.schema.yaml"))
      try Data("installation_id: old-installation-id".utf8).write(
        to: source.appendingPathComponent("installation.yaml"))
      try Data("user override".utf8).write(to: source.appendingPathComponent("opencc/custom.json"))
      try Data("shared override".utf8).write(
        to: shared.appendingPathComponent("opencc/custom.json"))
      try Data("shared".utf8).write(to: shared.appendingPathComponent("opencc/s2t.json"))
      let deployer = helper.appendingPathComponent("Contents/Helpers/rime_deployer")
      // The real Rime deployment/ABI is exercised by input_method_test.py. This fixture
      // isolates import atomicity and byte preservation from dictionary compilation.
      try Data(
        """
        #!/bin/sh
        mkdir -p build
        if [ -f rill_pinyin.schema.yaml ]; then
          touch build/rill_pinyin.schema.yaml build/pinyin_simp.table.bin
        else
          touch build/wanxiang.schema.yaml build/wanxiang.table.bin
        fi

        """
          .utf8
      ).write(to: deployer)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deployer.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
