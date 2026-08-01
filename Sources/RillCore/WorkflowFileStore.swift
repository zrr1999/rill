import Foundation

/// One user-authored workflow loaded from the XDG configuration directory.
///
/// `fileURL` is retained so a visual editor can update the original file even
/// when its name was chosen by a person or another tool.
public struct WorkflowFileRecord: Sendable, Equatable {
  public var workflow: WorkflowDefinition
  public var isEnabled: Bool
  public var fileURL: URL

  public init(
    workflow: WorkflowDefinition,
    isEnabled: Bool = true,
    fileURL: URL
  ) {
    self.workflow = workflow
    self.isEnabled = isEnabled
    self.fileURL = fileURL
  }
}

/// A bounded, display-safe parse or validation failure for one TOML file.
public struct WorkflowFileIssue: Sendable, Equatable {
  public var filename: String
  public var message: String

  public init(filename: String, message: String) {
    self.filename = filename
    self.message = message
  }
}

public struct WorkflowFileLoadResult: Sendable, Equatable {
  public var discoveredFileCount: Int
  public var records: [WorkflowFileRecord]
  public var issues: [WorkflowFileIssue]

  public init(
    discoveredFileCount: Int = 0,
    records: [WorkflowFileRecord] = [],
    issues: [WorkflowFileIssue] = []
  ) {
    self.discoveredFileCount = discoveredFileCount
    self.records = records
    self.issues = issues
  }
}

/// Durable source of truth for user workflows.
///
/// Implementations must use one TOML file per workflow and replace files
/// atomically. Callers provide `replacing` when a visual edit should preserve
/// a manually chosen filename.
public protocol WorkflowFileStore: Sendable {
  var configurationDirectoryURL: URL { get }

  func load() async -> WorkflowFileLoadResult

  @discardableResult
  func save(
    workflow: WorkflowDefinition,
    isEnabled: Bool,
    replacing fileURL: URL?
  ) async throws -> URL

  func delete(fileURL: URL) async throws
}
