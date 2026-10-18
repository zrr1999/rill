import Foundation
import RillCore

public struct BuiltinWorkflowCatalog: Sendable {
  private let directory: URL
  public init(directory: URL? = nil) {
    self.directory = directory ?? (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("BuiltinWorkflows")
  }
  private struct Entry: Decodable {
    let file: String
    let title: WorkflowTitleKey
  }
  public func manifest() throws -> WorkflowManifest {
    let index = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: directory.appendingPathComponent("index.json")))
    guard !index.isEmpty else { throw WorkflowDocumentError("builtin.index", "No built-in workflows were declared.") }
    var workflows: [WorkflowDefinition] = []
    var ids = Set<UUID>()
    for entry in index {
      guard URL(fileURLWithPath: entry.file).lastPathComponent == entry.file, entry.file.hasSuffix(".toml") else {
        throw WorkflowDocumentError("builtin.index", "Invalid workflow resource path.")
      }
      let source = try String(contentsOf: directory.appendingPathComponent(entry.file), encoding: .utf8)
      let document = try WorkflowDocumentCodec().decode(source)
      var workflow = document.workflow
      guard ids.insert(workflow.id).inserted else { throw WorkflowDocumentError("builtin.index", "Duplicate workflow identity.") }
      workflow.titleKey = entry.title
      workflow.properties.isBuiltin = true
      workflow.properties.defaultEnabled = document.isEnabled
      workflows.append(workflow)
    }
    return WorkflowManifest(workflows: workflows)
  }
}
