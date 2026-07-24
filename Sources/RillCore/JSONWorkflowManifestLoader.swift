import Foundation

public enum WorkflowManifestLoadError: Error, LocalizedError, Equatable {
    case unreadable(URL)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Unable to read workflow manifest at \(url.path)."
        case .invalid(let message):
            return message
        }
    }
}

public struct JSONWorkflowManifestLoader: WorkflowManifestLoader {
    private let dataProvider: @Sendable () throws -> Data

    public init(data: Data) {
        self.dataProvider = { data }
    }

    public init(url: URL) {
        self.dataProvider = {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw WorkflowManifestLoadError.unreadable(url)
            }
        }
    }

    public func loadManifest() throws -> WorkflowManifest {
        let decoder = JSONDecoder()
        let manifest: WorkflowManifest

        do {
            manifest = try decoder.decode(WorkflowManifest.self, from: try dataProvider())
        } catch let error as WorkflowManifestLoadError {
            throw error
        } catch {
            throw WorkflowManifestLoadError.invalid(error.localizedDescription)
        }

        try validate(manifest)
        return manifest
    }

    private func validate(_ manifest: WorkflowManifest) throws {
        guard manifest.schemaVersion >= 1 else {
            throw WorkflowManifestLoadError.invalid("Workflow manifest schemaVersion must be at least 1.")
        }

        guard !manifest.workflows.isEmpty else {
            throw WorkflowManifestLoadError.invalid("Workflow manifest must include at least one workflow.")
        }

        var ids = Set<UUID>()
        for workflow in manifest.workflows {
            guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowManifestLoadError.invalid("Workflow names must not be empty.")
            }

            guard !workflow.pipeline.recognizerID.isEmpty else {
                throw WorkflowManifestLoadError.invalid("Workflow \(workflow.name) is missing a recognizerID.")
            }

            guard !workflow.pipeline.outputActions.isEmpty else {
                throw WorkflowManifestLoadError.invalid("Workflow \(workflow.name) must declare at least one output action.")
            }

            for action in workflow.pipeline.outputActions {
                if let plaintextKey = action.configuration.keys.first(where: {
                    $0 == ExternalOutputActionConfigurationKey.webhookURL
                        || $0 == ExternalOutputActionConfigurationKey.webhookHeadersJSON
                }) {
                    throw WorkflowManifestLoadError.invalid(
                        "Workflow \(workflow.name) contains plaintext Webhook configuration (\(plaintextKey)), which is not accepted."
                    )
                }
                guard action.id != ExternalOutputActionID.webhookPost else {
                    throw WorkflowManifestLoadError.invalid(
                        "Workflow \(workflow.name) uses unsupported output action \(ExternalOutputActionID.webhookPost)."
                    )
                }
            }

            guard ids.insert(workflow.id).inserted else {
                throw WorkflowManifestLoadError.invalid("Workflow manifest contains duplicate workflow IDs.")
            }
        }
    }
}
