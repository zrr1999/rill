import Foundation
import RillCore

public struct LegacyWorkflowManifestFileLoader: WorkflowManifestLoader {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func loadManifest() throws -> WorkflowManifest {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw WorkflowManifestLoadError.unreadable(url) }
        return try JSONWorkflowManifestLoader(data: data).loadManifest()
    }
}
