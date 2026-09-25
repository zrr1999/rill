import Foundation

public struct InputMethodLearningPolicy: Codable, Sendable, Equatable {
  public var revision: UUID
  public var applications: Set<String>
  public var expiresAt: Date

  public init(revision: UUID, applications: Set<String>, expiresAt: Date) {
    self.revision = revision
    self.applications = applications
    self.expiresAt = expiresAt
  }

  public func permits(_ application: String, now: Date = Date()) -> Bool {
    now < expiresAt && applications.contains(application)
  }
}

public struct InputMethodCommit: Codable, Sendable, Equatable {
  public let id: UUID
  public let policyRevision: UUID
  public let application: String
  public let text: String
  public let timestamp: Date

  public init(
    id: UUID = UUID(), policyRevision: UUID, application: String, text: String,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.policyRevision = policyRevision
    self.application = application
    self.text = text
    self.timestamp = timestamp
  }

  public var isValid: Bool {
    !application.isEmpty && application.utf8.count <= 255 && !text.isEmpty
      && text.utf8.count <= 2_048 && timestamp.timeIntervalSince1970.isFinite
  }
}

public struct InputMethodMessage: Codable, Sendable {
  public enum Payload: Codable, Sendable {
    case hello
    case policy(InputMethodLearningPolicy)
    case commit(InputMethodCommit)
  }
  public var version: Int = 1
  public var payload: Payload
  public init(_ payload: Payload) { self.payload = payload }
}

public enum InputMethodPaths {
  public static var dataDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Rill/InputMethod", isDirectory: true)
  }
  public static let bundleIdentifier = "dev.zrr.Rill.InputMethod"
  public static let connectionName = "RillInputMethodConnection"
}
