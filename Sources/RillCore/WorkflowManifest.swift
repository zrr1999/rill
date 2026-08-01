import Foundation

public struct WorkflowManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var voiceProfiles: [VoiceProfile]
    public var workflows: [WorkflowDefinition]
    public var metadata: [String: String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        voiceProfiles: [VoiceProfile] = [],
        workflows: [WorkflowDefinition],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.voiceProfiles = voiceProfiles
        self.workflows = workflows
        self.metadata = metadata
    }
}
