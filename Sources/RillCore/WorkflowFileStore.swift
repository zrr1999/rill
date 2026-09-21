import Foundation

/// One user-authored workflow loaded from the XDG configuration directory.
///
/// `fileURL` is retained so Rill can open the original file even
/// when its name was chosen by a person or another tool.
public struct WorkflowFileRecord: Sendable, Equatable {
  public var workflow: WorkflowDefinition
  public var isEnabled: Bool
  public var fileURL: URL
  public var source: String?

  public init(
    workflow: WorkflowDefinition,
    isEnabled: Bool = true,
    fileURL: URL,
    source: String? = nil
  ) {
    self.workflow = workflow
    self.isEnabled = isEnabled
    self.fileURL = fileURL
    self.source = source
  }
}

/// A bounded, display-safe parse or validation failure for one TOML file.
public struct WorkflowFileIssue: Sendable, Equatable {
  public var filename: String
  public var message: String
  public var workflowID: UUID?

  public init(filename: String, message: String, workflowID: UUID? = nil) {
    self.filename = filename
    self.message = message
    self.workflowID = workflowID
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
/// atomically. Callers provide `replacing` when a change should preserve
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

  func decodeDocument(_ source: String) throws -> WorkflowDocument
  func encodeDocument(_ document: WorkflowDocument) throws -> String
  func readSource(at fileURL: URL) async throws -> String
  func saveDocument(_ document: WorkflowDocument, replacing fileURL: URL?, expected: WorkflowFileExpectation) async throws -> WorkflowFileRecord
  func changes() async -> AsyncStream<Void>
  func versions(for workflowID: UUID) async throws -> [WorkflowFileVersion]
}

public enum WorkflowFileExpectation: Sendable, Equatable {
  case missing
  case source(String)
  case overwrite
}

public enum WorkflowFileConflict: Error, LocalizedError, Sendable {
  case changed
  public var errorDescription: String? { "The workflow file changed. Reload it before saving." }
}

public struct WorkflowFileVersion: Identifiable, Sendable, Equatable {
  public var id: URL
  public var date: Date
  public var source: String

  public init(id: URL, date: Date, source: String) {
    self.id = id; self.date = date; self.source = source
  }
}

public extension WorkflowFileStore {
  func decodeDocument(_ source: String) throws -> WorkflowDocument { throw WorkflowDocumentError("", "Document editing is unavailable.") }
  func encodeDocument(_ document: WorkflowDocument) throws -> String { throw WorkflowDocumentError("", "Document editing is unavailable.") }
  func readSource(at fileURL: URL) async throws -> String { throw WorkflowDocumentError("", "Document editing is unavailable.") }
  func saveDocument(_ document: WorkflowDocument, replacing fileURL: URL?, expected: WorkflowFileExpectation) async throws -> WorkflowFileRecord {
    let url = try await save(workflow: document.workflow, isEnabled: document.isEnabled, replacing: fileURL)
    return WorkflowFileRecord(workflow: document.workflow, isEnabled: document.isEnabled, fileURL: url)
  }
  func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  func versions(for workflowID: UUID) async throws -> [WorkflowFileVersion] { [] }
}
