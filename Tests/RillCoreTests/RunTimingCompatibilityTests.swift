import Foundation
import RillCore
import Testing

struct RunTimingCompatibilityTests {
    @Test func newMeasurementsRoundTripAndOldReceiptsRemainUnmeasured() throws {
        let receipt = try WorkflowRunReceipt(
            runID: UUID(), workflowID: nil, trigger: .hotkey, timestamp: Date(),
            duration: .s1To4, termination: .completed,
            actionDetails: [.init(actionIndex: 0, result: .injected, duration: .under250ms, durationMilliseconds: 32)],
            recordingDurationMilliseconds: 12_500
        )
        let encoded = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(WorkflowRunReceipt.self, from: encoded) == receipt)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "recordingDurationMilliseconds")
        var actions = try #require(legacy["actionDetails"] as? [[String: Any]])
        actions[0].removeValue(forKey: "durationMilliseconds")
        legacy["actionDetails"] = actions
        let decoded = try JSONDecoder().decode(WorkflowRunReceipt.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.recordingDurationMilliseconds == nil)
        #expect(decoded.actionDetails.first?.durationMilliseconds == nil)
        #expect(decoded.actionDetails.first?.result == .injected)
    }
}
