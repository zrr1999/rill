import AppKit
import Carbon
import CryptoKit
import Darwin
import Foundation
import RillInputMethodContracts

public enum RimeProfileImportError: LocalizedError {
  case sourceRunning, inputMethodRunning, alreadyImported, incompleteSource, sourceChanged,
    unsafeLink,
    deploymentFailed, helperMissing
  public var errorDescription: String? {
    switch self {
    case .sourceRunning: "请先切换到 ABC，并退出鼠须管和 Rill 输入法，再导入。"
    case .inputMethodRunning: "请先切换到 ABC 并退出 Rill 输入法，再安装。"
    case .alreadyImported: "Rill 输入法已有配置，已保留现有词库，不会覆盖。"
    case .incompleteSource: "所选目录缺少万象方案或个人词库。"
    case .sourceChanged: "导入期间源配置发生变化，未安装。请退出鼠须管后重试。"
    case .unsafeLink: "源配置包含符号链接，请先将链接内容复制为独立文件后导入。"
    case .deploymentFailed: "Rime 部署或词库校验失败，原配置未修改。"
    case .helperMissing: "当前 Rill 构建未包含输入法组件，请使用完整 app 构建。"
    }
  }
}

public struct RimeProfileInstaller: Sendable {
  public let helperBundle: URL
  public init(helperBundle: URL) {
    self.helperBundle = helperBundle
  }

  @MainActor
  public func install(from source: URL? = nil) async throws -> String {
    let destination = InputMethodPaths.dataDirectory
    let application = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Input Methods/RillInputMethod.app")
    try await prepareInstallation(importing: source, to: destination, application: application)
    let result = TISRegisterInputSource(application as CFURL)
    return result == noErr
      ? "Rill 输入法已安装。请在系统输入法设置中添加 Rill。配置与词库保存在 Rill 独立目录。"
      : "组件已安装。请注销并重新登录，再在系统输入法设置中添加 Rill。"
  }

  @concurrent
  func prepareInstallation(
    importing source: URL?, to destination: URL, application: URL,
    sourceIsStopped: @MainActor @Sendable () -> Bool = {
      NSRunningApplication.runningApplications(withBundleIdentifier: "im.rime.inputmethod.Squirrel")
        .isEmpty
    },
    inputMethodIsStopped: @MainActor @Sendable () -> Bool = {
      NSRunningApplication.runningApplications(
        withBundleIdentifier: InputMethodPaths.bundleIdentifier
      )
      .isEmpty
    }
  ) async throws {
    let files = FileManager.default
    func checkWriters() async throws {
      guard await inputMethodIsStopped() else { throw RimeProfileImportError.inputMethodRunning }
      if source != nil, !(await sourceIsStopped()) { throw RimeProfileImportError.sourceRunning }
    }
    try await checkWriters()
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
    guard !files.fileExists(atPath: destination.path), !files.fileExists(atPath: application.path)
    else {
      throw RimeProfileImportError.alreadyImported
    }
    let schemaID = source == nil ? "rill_pinyin" : "wanxiang"
    let dictionaryID = source == nil ? "pinyin_simp" : "wanxiang"
    guard files.fileExists(atPath: profile.appendingPathComponent("\(schemaID).schema.yaml").path),
      source == nil
        || files.fileExists(atPath: profile.appendingPathComponent("wanxiang.userdb").path)
    else {
      throw RimeProfileImportError.incompleteSource
    }
    let parent = destination.deletingLastPathComponent()
    try files.createDirectory(at: parent, withIntermediateDirectories: true)
    let importLock = open(
      parent.appendingPathComponent("input-method-import.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard importLock >= 0 else { throw RimeProfileImportError.deploymentFailed }
    defer { close(importLock) }
    guard flock(importLock, LOCK_EX | LOCK_NB) == 0 else {
      throw RimeProfileImportError.sourceRunning
    }
    let staging = parent.appendingPathComponent("InputMethod-import-\(UUID().uuidString)")
    let stagedApplication = parent.appendingPathComponent(
      "InputMethod-app-\(UUID().uuidString).app")
    try files.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
      try? files.removeItem(at: staging)
      try? files.removeItem(at: stagedApplication)
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
      files.fileExists(atPath: staging.appendingPathComponent("build/\(schemaID).schema.yaml").path),
      files.fileExists(atPath: staging.appendingPathComponent("build/\(dictionaryID).table.bin").path),
      before == (try Self.fingerprints(profile, excluding: excluded)),
      before.filter({ $0.key.contains(".userdb/") })
        == (try Self.fingerprints(staging, excluding: excluded)).filter({
          $0.key.contains(".userdb/")
        })
    else { throw RimeProfileImportError.deploymentFailed }
    try await checkWriters()
    try JSONEncoder().encode(expected).write(
      to: staging.appendingPathComponent("import-fingerprints.json"), options: .atomic)
    try files.copyItem(at: helperBundle, to: stagedApplication)
    try files.createDirectory(
      at: application.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.moveItem(at: staging, to: destination)
    do { try files.moveItem(at: stagedApplication, to: application) } catch {
      // Return the newly imported profile to staging so a failed install is retryable.
      try files.moveItem(at: destination, to: staging)
      throw error
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
