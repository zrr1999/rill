import XCTest
@testable import VoxTypeCore

final class WorkflowManifestTests: XCTestCase {
    func testManifestRoundTripPreservesMetadata() throws {
        let workflow = WorkflowDefinition(
            id: UUID(uuidString: "9B07CFCC-95DE-4EBA-A05F-AB2E8BE7DDB6")!,
            name: "Manifest Workflow",
            titleKey: .directDemoClipboard,
            trigger: .wakeWord,
            pipeline: PipelineDeclaration(
                recognizerID: "demo.direct",
                outputActions: [OutputActionReference(id: "clipboard.copy")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue"),
            metadata: ["owner": "tests"]
        )
        let manifest = WorkflowManifest(
            schemaVersion: 2,
            voiceProfiles: [
                VoiceProfile(
                    id: UUID(uuidString: "CBA8775A-0C88-4AC7-874A-0DB57D91F10D")!,
                    name: "Default",
                    defaultRecognizerID: "demo.direct"
                ),
            ],
            workflows: [workflow],
            metadata: ["source": "unit-test"]
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(WorkflowManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
    }
}
