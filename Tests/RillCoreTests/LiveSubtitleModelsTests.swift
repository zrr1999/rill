import XCTest
@testable import RillCore

final class LiveSubtitleModelsTests: XCTestCase {
    func testDisplayTextSeparatesConfirmedAndHypothesis() {
        let snapshot = LiveSubtitleSnapshot(
            runID: UUID(),
            phase: .transcribing,
            confirmedText: "hello world",
            hypothesisText: "from cloud"
        )

        XCTAssertEqual(snapshot.displayText, "hello world from cloud")
    }

    func testJoinedDisplayTextNormalizesWhitespace() {
        XCTAssertEqual(
            LiveSubtitleSnapshot.joinedDisplayText(["  hello", "world  ", " from   vox "]),
            "hello world from vox"
        )
    }

    func testNetworkUsageRoundTripsWithoutExposingWorkflowDetails() throws {
        let snapshot = LiveSubtitleSnapshot(
            runID: UUID(),
            phase: .recording,
            networkUsage: .online
        )

        let decoded = try JSONDecoder().decode(
            LiveSubtitleSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.networkUsage, .online)
    }
}
