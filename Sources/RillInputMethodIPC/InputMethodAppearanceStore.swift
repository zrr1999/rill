import Foundation
import RillInputMethodContracts

public struct InputMethodAppearanceStore: Sendable {
  public static let didChange = Notification.Name("dev.zrr.inputmethod.Rill.appearanceChanged")
  private let file: URL

  public init(
    file: URL = InputMethodPaths.dataDirectory.deletingLastPathComponent()
      .appendingPathComponent("input-method-appearance.json")
  ) {
    self.file = file
  }

  public func load() throws -> InputMethodAppearance {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return .defaults
    }
    return try JSONDecoder().decode(InputMethodAppearance.self, from: data).validated()
  }

  public func save(_ appearance: InputMethodAppearance) throws {
    let data = try JSONEncoder().encode(appearance.validated())
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: file, options: .atomic)
    DistributedNotificationCenter.default().postNotificationName(
      Self.didChange, object: nil, userInfo: nil, deliverImmediately: true)
  }
}
