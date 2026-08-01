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
        guard (1...WorkflowManifest.currentSchemaVersion).contains(
            manifest.schemaVersion
        ) else {
            throw WorkflowManifestLoadError.invalid(
                "Workflow manifest schemaVersion must be between 1 and \(WorkflowManifest.currentSchemaVersion)."
            )
        }

        guard !manifest.workflows.isEmpty else {
            throw WorkflowManifestLoadError.invalid("Workflow manifest must include at least one workflow.")
        }

        var ids = Set<UUID>()
        for workflow in manifest.workflows {
            guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowManifestLoadError.invalid("Workflow names must not be empty.")
            }

            guard let speechRoute = workflow.plan.setup.speechRoute,
                  !speechRoute.recognizerID.isEmpty
            else {
                throw WorkflowManifestLoadError.invalid("Workflow \(workflow.name) is missing a recognizerID.")
            }

            guard !workflow.plan.output.actions.isEmpty else {
                throw WorkflowManifestLoadError.invalid("Workflow \(workflow.name) must declare at least one output action.")
            }

            do {
                try WorkflowPlanValidator.validate(workflow.plan, input: .audio)
            } catch {
                throw WorkflowManifestLoadError.invalid(
                    "Workflow \(workflow.name) has an invalid plan: \(error.localizedDescription)"
                )
            }

            for action in workflow.plan.output.actions {
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
