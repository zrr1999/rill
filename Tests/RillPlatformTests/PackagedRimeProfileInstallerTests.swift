import Foundation
import Testing

@testable import RillPlatform

struct PackagedRimeProfileInstallerTests {
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
}
