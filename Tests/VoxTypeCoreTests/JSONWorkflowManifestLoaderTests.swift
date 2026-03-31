import Foundation
import XCTest
@testable import VoxTypeCore

final class JSONWorkflowManifestLoaderTests: XCTestCase {
    func testLoaderDecodesValidManifest() throws {
        let json = """
        {
          "schemaVersion": 1,
          "voiceProfiles": [],
          "workflows": [
            {
              "id": "A0F99D93-7E4D-46CE-A188-8B713EF229DA",
              "name": "Valid Workflow",
              "titleKey": "directDemoClipboard",
              "trigger": "manual",
              "pipeline": {
                "recognizerID": "demo.direct",
                "postProcessSteps": [],
                "outputActions": [
                  {
                    "id": "clipboard.copy",
                    "configuration": {}
                  }
                ],
                "uncertaintyPolicy": {
                  "mode": "off",
                  "confidenceThreshold": 0,
                  "timeoutSeconds": 0
                },
                "deliveryPolicy": {
                  "strategy": "clipboardOnly"
                }
              },
              "ui": {
                "symbolName": "waveform",
                "accentColorName": "blue"
              },
              "metadata": {
                "source": "test"
              }
            }
          ],
          "metadata": {
            "format": "json"
          }
        }
        """

        let manifest = try JSONWorkflowManifestLoader(data: Data(json.utf8)).loadManifest()

        XCTAssertEqual(manifest.workflows.count, 1)
        XCTAssertEqual(manifest.workflows[0].metadata["source"], "test")
    }

    func testLoaderRejectsEmptyWorkflowList() {
        let json = """
        {
          "schemaVersion": 1,
          "voiceProfiles": [],
          "workflows": [],
          "metadata": {}
        }
        """

        XCTAssertThrowsError(try JSONWorkflowManifestLoader(data: Data(json.utf8)).loadManifest()) { error in
            XCTAssertEqual(
                error as? WorkflowManifestLoadError,
                .invalid("Workflow manifest must include at least one workflow.")
            )
        }
    }
}
