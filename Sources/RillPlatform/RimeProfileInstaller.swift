import AppKit
import Carbon
import CryptoKit
import Darwin
import Foundation
import RillInputMethodContracts

public struct RimeProfileInstaller: Sendable {
  public let helperBundle: URL
  public let dataDirectory: URL
  public let application: URL

  public init(
    helperBundle: URL, dataDirectory: URL = InputMethodPaths.dataDirectory,
    application: URL = InputMethodPaths.application
  ) {
    self.helperBundle = helperBundle
    self.dataDirectory = dataDirectory
    self.application = application
  }

  @MainActor
  public func installationState() -> InputMethodInstallationState {
    let files = FileManager.default
    let hasProfile = files.fileExists(atPath: dataDirectory.path)
    let hasApplication = files.fileExists(atPath: application.path)
    guard hasProfile || hasApplication else { return .notInstalled }
    guard hasProfile, hasApplication,
      let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      info["CFBundleIdentifier"] as? String == InputMethodPaths.bundleIdentifier
    else { return .needsRepair }
    return InputMethodRegistration.state()
  }

  @MainActor
  public func install(from source: URL? = nil) async throws {
    try await prepareInstallation(importing: source, to: dataDirectory, application: application)
    try InputMethodRegistration.register(application)
  }

  @concurrent
  func prepareInstallation(
    importing source: URL?, to destination: URL, application: URL,
    sourceIsStopped: @MainActor @Sendable () -> Bool = {
      NSRunningApplication.runningApplications(withBundleIdentifier: "im.rime.inputmethod.Squirrel")
        .isEmpty
    },
    inputMethodIsStopped: @MainActor @Sendable () -> Bool = {
      [InputMethodPaths.bundleIdentifier, InputMethodPaths.legacyBundleIdentifier].allSatisfy {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
      }
    }
  ) async throws {
    let files = FileManager.default
    func checkWriters() async throws {
      guard await inputMethodIsStopped() else { throw RimeProfileImportError.inputMethodRunning }
      if source != nil, !(await sourceIsStopped()) { throw RimeProfileImportError.sourceRunning }
    }
    let parent = destination.deletingLastPathComponent()
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let importLock = open(
      parent.appendingPathComponent("input-method-import.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard importLock >= 0 else { throw RimeProfileImportError.deploymentFailed }
    defer { close(importLock) }
    guard flock(importLock, LOCK_EX | LOCK_NB) == 0 else {
      throw RimeProfileImportError.installationBusy
    }
    // A descriptor inherited during concurrent process launch must not extend this installation's lock.
    defer { _ = flock(importLock, LOCK_UN) }
    // An existing installation takes precedence over migration preconditions.
    if source != nil,
      files.fileExists(atPath: destination.path) || files.fileExists(atPath: application.path)
    {
      throw RimeProfileImportError.alreadyImported
    }
    try await checkWriters()
    if source == nil, files.fileExists(atPath: destination.path) {
      try await replaceApplication(at: application, inputMethodIsStopped: inputMethodIsStopped)
      return
    }
    let shared = helperBundle.appendingPathComponent("Contents/Resources/SharedData")
    let profile = source ?? helperBundle.appendingPathComponent("Contents/Resources/DefaultProfile")
    guard
      files.fileExists(
        atPath: helperBundle.appendingPathComponent("Contents/Helpers/rime_deployer").path),
      files.fileExists(atPath: shared.path),
      source != nil || files.fileExists(atPath: profile.path)
    else {
      throw RimeProfileImportError.helperMissing
    }
    let schemaID = source == nil ? "rill_pinyin" : "wanxiang"
    let dictionaryID = source == nil ? "pinyin_simp" : "wanxiang"
    guard files.fileExists(atPath: profile.appendingPathComponent("\(schemaID).schema.yaml").path),
      source == nil
        || files.fileExists(atPath: profile.appendingPathComponent("wanxiang.userdb").path)
    else {
      throw RimeProfileImportError.incompleteSource
    }
    let staging = parent.appendingPathComponent("InputMethod-import-\(UUID().uuidString)")
    try files.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
      try? files.removeItem(at: staging)
    }
    let excluded: Set<String> = [
      ".git", ".DS_Store", "build", "sync", "installation.yaml", "sync_rime.sh", "engine.lock",
    ]
    let before = try Self.fingerprints(profile, excluding: excluded)
    let sharedBefore = try Self.fingerprints(shared, excluding: excluded)
    for child in try files.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)
    where !excluded.contains(child.lastPathComponent) {
      try files.copyItem(at: child, to: staging.appendingPathComponent(child.lastPathComponent))
    }
    // Standard dictionaries come from Rill's bundle; imported custom files take precedence.
    for relative in sharedBefore.keys where before[relative] == nil {
      let target = staging.appendingPathComponent(relative)
      try files.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try files.copyItem(at: shared.appendingPathComponent(relative), to: target)
    }
    let expected = sharedBefore.merging(before) { _, user in user }
    let staged = try Self.fingerprints(staging, excluding: excluded)
    guard before == (try Self.fingerprints(profile, excluding: excluded)),
      sharedBefore == (try Self.fingerprints(shared, excluding: excluded)),
      expected == staged
    else { throw RimeProfileImportError.sourceChanged }
    try await checkWriters()
    let installation = """
      distribution_code_name: rill
      distribution_name: Rill
      distribution_version: '1'
      installation_id: 'rill-\(UUID().uuidString.lowercased())'
      rime_version: '1.16.0'
      sync_dir: '\(destination.appendingPathComponent("sync").path.replacingOccurrences(of: "'", with: "''"))'
      """
    try (installation + "\n").write(
      to: staging.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
    let deploy = Process()
    deploy.executableURL = helperBundle.appendingPathComponent("Contents/Helpers/rime_deployer")
    deploy.arguments = [
      "--build", staging.path, staging.path, staging.appendingPathComponent("build").path,
    ]
    deploy.currentDirectoryURL = staging
    // Rime diagnostics can contain user phrases. Do not forward them to the app log.
    deploy.standardOutput = FileHandle.nullDevice
    deploy.standardError = FileHandle.nullDevice
    try deploy.run()
    deploy.waitUntilExit()
    guard deploy.terminationStatus == 0,
      files.fileExists(
        atPath: staging.appendingPathComponent("build/\(schemaID).schema.yaml").path),
      files.fileExists(
        atPath: staging.appendingPathComponent("build/\(dictionaryID).table.bin").path),
      before == (try Self.fingerprints(profile, excluding: excluded)),
      before.filter({ $0.key.contains(".userdb/") })
        == (try Self.fingerprints(staging, excluding: excluded)).filter({
          $0.key.contains(".userdb/")
        })
    else { throw RimeProfileImportError.deploymentFailed }
    try await checkWriters()
    try JSONEncoder().encode(expected).write(
      to: staging.appendingPathComponent("import-fingerprints.json"), options: .atomic)
    try files.moveItem(at: staging, to: destination)
    do {
      try await replaceApplication(at: application, inputMethodIsStopped: inputMethodIsStopped)
    } catch {
      // Return the newly imported profile to staging so a failed install is retryable.
      try files.moveItem(at: destination, to: staging)
      throw error
    }
  }

  private func replaceApplication(
    at application: URL, inputMethodIsStopped: @MainActor @Sendable () -> Bool
  ) async throws {
    let files = FileManager.default
    guard
      files.fileExists(
        atPath: helperBundle.appendingPathComponent("Contents/Helpers/rime_deployer").path)
    else { throw RimeProfileImportError.helperMissing }
    let parent = application.deletingLastPathComponent()
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let staged = parent.appendingPathComponent(".RillInputMethod-\(UUID().uuidString).app")
    defer { try? files.removeItem(at: staged) }
    try files.copyItem(at: helperBundle, to: staged)
    guard await inputMethodIsStopped() else { throw RimeProfileImportError.inputMethodRunning }
    if files.fileExists(atPath: application.path) {
      guard
        renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, application.path, UInt32(RENAME_SWAP)) == 0
      else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } else {
      try files.moveItem(at: staged, to: application)
    }
  }

  public static func fingerprints(_ root: URL, excluding: Set<String> = []) throws -> [String:
    String]
  {
    let files = FileManager.default
    let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootInfo.isSymbolicLink != true else { throw RimeProfileImportError.unsafeLink }
    guard rootInfo.isDirectory == true else { throw RimeProfileImportError.incompleteSource }
    guard let resolvedPath = realpath(root.path, nil) else {
      throw RimeProfileImportError.incompleteSource
    }
    defer { free(resolvedPath) }
    let canonicalRoot = URL(fileURLWithPath: String(cString: resolvedPath))
    var enumerationError: (any Error)?
    guard
      let enumerator = files.enumerator(
        at: canonicalRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
        errorHandler: { _, error in
          enumerationError = error
          return false
        })
    else {
      throw RimeProfileImportError.incompleteSource
    }
    var result: [String: String] = [:]
    for case let file as URL in enumerator {
      guard file.path.hasPrefix(canonicalRoot.path + "/") else {
        throw RimeProfileImportError.unsafeLink
      }
      let relative = String(file.path.dropFirst(canonicalRoot.path.count + 1))
      let info = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
      ])
      if let top = relative.split(separator: "/").first, excluding.contains(String(top)) {
        if info.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard info.isSymbolicLink != true else { throw RimeProfileImportError.unsafeLink }
      guard info.isRegularFile == true else { continue }
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      var digest = SHA256()
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        digest.update(data: chunk)
      }
      result[relative] = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    if let enumerationError { throw enumerationError }
    return result
  }
}
